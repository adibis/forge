// forge-provider-ollama: Ollama provider for forge retry protocol.
//
// Environment variables:
//   OLLAMA_HOST    (optional, default: http://localhost:11434)
//   OLLAMA_MODEL   (required)
const std = @import("std");
const Io = std.Io;

const DEFAULT_HOST = "http://localhost:11434";

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

    const schema_json = if (parsed.value.object.get("schema_json")) |v|
        if (v == .string) v.string else ""
    else "";

    const full_prompt = try std.fmt.allocPrint(a,
        "You are a JSON API. Return ONLY valid JSON — no explanation, no markdown.\n\nSchema:\n{s}\n\n{s}",
        .{ schema_json, prompt_val.string },
    );

    const host = env.get("OLLAMA_HOST") orelse DEFAULT_HOST;
    const model = env.get("OLLAMA_MODEL") orelse { writeError(gpa, io, "OLLAMA_MODEL not set"); std.process.exit(1); };

    const api_url = try std.fmt.allocPrint(a, "{s}/api/generate", .{host});
    const body_json = try std.fmt.allocPrint(a,
        \\{{"model":"{s}","prompt":"{s}","stream":false}}
    , .{ model, try jsonEscape(a, full_prompt) });

    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST", api_url,
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
        writeError(gpa, io, "failed to parse response"); std.process.exit(1);
    };
    if (resp_parsed.value != .object) { writeError(gpa, io, "unexpected response"); std.process.exit(1); }

    const resp_text = resp_parsed.value.object.get("response") orelse { writeError(gpa, io, "missing 'response'"); std.process.exit(1); };
    if (resp_text != .string) { writeError(gpa, io, "'response' is not string"); std.process.exit(1); }

    const out = try std.fmt.allocPrint(gpa, "{{\"response\":\"{s}\"}}\n", .{try jsonEscape(a, resp_text.string)});
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
