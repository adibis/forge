// forge-provider-openai: OpenAI provider for forge retry protocol.
//
// Environment variables:
//   OPENAI_API_KEY   (required)
//   OPENAI_MODEL     (optional, default: gpt-4o-mini)
const std = @import("std");
const Io = std.Io;

const OPENAI_API = "https://api.openai.com/v1/chat/completions";
const DEFAULT_MODEL = "gpt-4o-mini";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map.*;

    var read_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &read_buf);
    const input = try stdin_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(input);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, input, " \t\r\n"), .{}) catch {
        writeError(gpa, io, "failed to parse request"); std.process.exit(1);
    };
    if (parsed.value != .object) { writeError(gpa, io, "request must be JSON object"); std.process.exit(1); }

    const prompt_val = parsed.value.object.get("prompt") orelse { writeError(gpa, io, "missing 'prompt'"); std.process.exit(1); };
    if (prompt_val != .string) { writeError(gpa, io, "'prompt' must be string"); std.process.exit(1); }

    const api_key = env.get("OPENAI_API_KEY") orelse { writeError(gpa, io, "OPENAI_API_KEY not set"); std.process.exit(1); };
    const model = env.get("OPENAI_MODEL") orelse DEFAULT_MODEL;

    const body_json = try std.fmt.allocPrint(a,
        \\{{"model":"{s}","messages":[{{"role":"user","content":"{s}"}}]}}
    , .{ model, try jsonEscape(a, prompt_val.string) });

    const auth_header = try std.fmt.allocPrint(a, "Authorization: Bearer {s}", .{api_key});

    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST", OPENAI_API,
        "-H", auth_header,
        "-H", "content-type: application/json",
        "-d", body_json,
    };

    var child = std.process.spawn(io, .{
        .argv = &argv, .stdout = .pipe, .stderr = .inherit,
    }) catch { writeError(gpa, io, "failed to spawn curl"); std.process.exit(1); };

    const stdout_file = child.stdout.?;
    var resp_buf: [4096]u8 = undefined;
    var resp_reader = stdout_file.reader(io, &resp_buf);
    const resp_bytes = resp_reader.interface.allocRemaining(gpa, .unlimited) catch {
        writeError(gpa, io, "failed to read response"); std.process.exit(1);
    };
    defer gpa.free(resp_bytes);
    _ = child.wait(io) catch {};

    const resp_parsed = std.json.parseFromSlice(std.json.Value, a, resp_bytes, .{}) catch {
        writeError(gpa, io, "failed to parse API response"); std.process.exit(1);
    };
    if (resp_parsed.value != .object) { writeError(gpa, io, "unexpected response"); std.process.exit(1); }

    if (resp_parsed.value.object.get("error")) |err_val| {
        const msg = if (err_val == .object)
            if (err_val.object.get("message")) |m| (if (m == .string) m.string else "API error") else "API error"
        else "API error";
        writeError(gpa, io, msg); std.process.exit(1);
    }

    const choices = resp_parsed.value.object.get("choices") orelse { writeError(gpa, io, "missing 'choices'"); std.process.exit(1); };
    if (choices != .array or choices.array.items.len == 0) { writeError(gpa, io, "empty choices"); std.process.exit(1); }
    const choice = choices.array.items[0];
    if (choice != .object) { writeError(gpa, io, "invalid choice"); std.process.exit(1); }
    const message = choice.object.get("message") orelse { writeError(gpa, io, "missing 'message'"); std.process.exit(1); };
    if (message != .object) { writeError(gpa, io, "invalid message"); std.process.exit(1); }
    const content_val = message.object.get("content") orelse { writeError(gpa, io, "missing 'content'"); std.process.exit(1); };
    if (content_val != .string) { writeError(gpa, io, "content not string"); std.process.exit(1); }

    const out = try std.fmt.allocPrint(gpa, "{{\"response\":\"{s}\"}}\n", .{try jsonEscape(a, content_val.string)});
    defer gpa.free(out);
    try Io.File.stdout().writeStreamingAll(io, out);
}

fn writeError(gpa: std.mem.Allocator, io: Io, msg: []const u8) void {
    const escaped = jsonEscape(gpa, msg) catch return;
    defer gpa.free(escaped);
    const out = std.fmt.allocPrint(gpa, "{{\"error\":\"{s}\"}}\n", .{escaped}) catch return;
    defer gpa.free(out);
    Io.File.stdout().writeStreamingAll(io, out) catch {};
}

fn jsonEscape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(arena, "\\\""),
            '\\' => try buf.appendSlice(arena, "\\\\"),
            '\n' => try buf.appendSlice(arena, "\\n"),
            '\r' => try buf.appendSlice(arena, "\\r"),
            '\t' => try buf.appendSlice(arena, "\\t"),
            else => try buf.append(arena, ch),
        }
    }
    return buf.toOwnedSlice(arena);
}
