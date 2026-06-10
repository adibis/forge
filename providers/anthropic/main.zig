// forge-provider-anthropic: Anthropic provider for forge retry protocol.
//
// Environment variables:
//   ANTHROPIC_API_KEY   (required)
//   ANTHROPIC_MODEL     (optional, default: claude-haiku-4-5-20251001)
const std = @import("std");
const Io = std.Io;

const ANTHROPIC_API = "https://api.anthropic.com/v1/messages";
const DEFAULT_MODEL = "claude-haiku-4-5-20251001";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map.*;

    var read_buf: [4096]u8 = undefined;
    var stdin_reader = Io.File.stdin().reader(io, &read_buf);
    const input = try stdin_reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(input);

    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, trimmed, .{}) catch {
        writeError(gpa, io, "failed to parse request JSON");
        std.process.exit(1);
    };
    if (parsed.value != .object) { writeError(gpa, io, "request must be a JSON object"); std.process.exit(1); }

    const prompt_val = parsed.value.object.get("prompt") orelse { writeError(gpa, io, "missing 'prompt'"); std.process.exit(1); };
    if (prompt_val != .string) { writeError(gpa, io, "'prompt' must be a string"); std.process.exit(1); }
    const schema_json = if (parsed.value.object.get("schema_json")) |v|
        if (v == .string) v.string else ""
    else "";

    const attempt_num = if (parsed.value.object.get("attempt_number")) |v|
        if (v == .integer) v.integer else 1
    else @as(i64, 1);

    const verbose = env.get("FORGE_VERBOSE") != null;

    const full_prompt = try std.fmt.allocPrint(a,
        "You are a JSON API. Return ONLY valid JSON — no explanation, no markdown.\n\nSchema:\n{s}\n\n{s}",
        .{ schema_json, prompt_val.string },
    );

    if (verbose) {
        std.debug.print("\n[forge-provider-anthropic] attempt {d}\n>>> PROMPT >>>\n{s}\n<<<\n", .{ attempt_num, full_prompt });
    }

    const api_key = env.get("ANTHROPIC_API_KEY") orelse {
        writeError(gpa, io, "ANTHROPIC_API_KEY not set"); std.process.exit(1);
    };
    const model = env.get("ANTHROPIC_MODEL") orelse DEFAULT_MODEL;

    const body_json = try std.fmt.allocPrint(a,
        \\{{"model":"{s}","max_tokens":4096,"messages":[{{"role":"user","content":"{s}"}}]}}
    , .{ model, try jsonEscape(a, full_prompt) });

    const auth_header = try std.fmt.allocPrint(a, "x-api-key: {s}", .{api_key});

    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST", ANTHROPIC_API,
        "-H", auth_header,
        "-H", "anthropic-version: 2023-06-01",
        "-H", "content-type: application/json",
        "-d", body_json,
    };

    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdout = .pipe,
        .stderr = .inherit,
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

    const content_arr = resp_parsed.value.object.get("content") orelse { writeError(gpa, io, "missing 'content'"); std.process.exit(1); };
    if (content_arr != .array or content_arr.array.items.len == 0) { writeError(gpa, io, "empty content"); std.process.exit(1); }
    const first = content_arr.array.items[0];
    if (first != .object) { writeError(gpa, io, "invalid content[0]"); std.process.exit(1); }
    const text_val = first.object.get("text") orelse { writeError(gpa, io, "missing 'text'"); std.process.exit(1); };
    if (text_val != .string) { writeError(gpa, io, "text is not string"); std.process.exit(1); }

    if (verbose) {
        std.debug.print("<<< RESPONSE <<<\n{s}\n>>>\n", .{text_val.string});
    }

    const escaped = try jsonEscape(a, text_val.string);
    const out = try std.fmt.allocPrint(gpa, "{{\"response\":\"{s}\"}}\n", .{escaped});
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
