// Built-in Anthropic provider.
// Environment variables: ANTHROPIC_API_KEY (required), ANTHROPIC_MODEL (default: claude-haiku-4-5-20251001)
const std = @import("std");
const Io = std.Io;
const plugin = @import("../retry/plugin.zig");

const ANTHROPIC_API = "https://api.anthropic.com/v1/messages";
const DEFAULT_MODEL = "claude-haiku-4-5-20251001";

const Message = struct { role: []const u8, content: []const u8 };
const Body = struct {
    model: []const u8,
    max_tokens: u32,
    messages: []const Message,
};

pub fn call(
    gpa: std.mem.Allocator,
    io: Io,
    req: plugin.PluginRequest,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const api_key = env.get("ANTHROPIC_API_KEY") orelse return error.MissingAnthropicKey;
    const model = env.get("ANTHROPIC_MODEL") orelse DEFAULT_MODEL;
    const verbose = env.get("FORGE_VERBOSE") != null;

    const full_prompt = try std.fmt.allocPrint(a,
        "You are a JSON API. Return ONLY valid JSON — no explanation, no markdown.\n\nSchema:\n{s}\n\n{s}",
        .{ req.schema_json, req.prompt },
    );

    if (verbose) {
        std.debug.print("\n[forge-provider-anthropic] attempt {d}\n>>> PROMPT >>>\n{s}\n<<<\n",
            .{ req.attempt_number, full_prompt });
    }

    const body_json = try std.json.Stringify.valueAlloc(a, Body{
        .model = model,
        .max_tokens = 4096,
        .messages = &[_]Message{.{ .role = "user", .content = full_prompt }},
    }, .{});

    const auth_header = try std.fmt.allocPrint(a, "x-api-key: {s}", .{api_key});

    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST", ANTHROPIC_API,
        "-H", auth_header,
        "-H", "anthropic-version: 2023-06-01",
        "-H", "content-type: application/json",
        "-d", body_json,
    };

    var child = std.process.spawn(io, .{
        .argv = &argv, .stdout = .pipe, .stderr = .inherit,
    }) catch return error.ProviderNetworkError;

    const stdout_file = child.stdout.?;
    var resp_buf: [4096]u8 = undefined;
    var resp_reader = stdout_file.reader(io, &resp_buf);
    const resp_bytes = resp_reader.interface.allocRemaining(gpa, .unlimited) catch
        return error.ProviderNetworkError;
    defer gpa.free(resp_bytes);
    _ = child.wait(io) catch {};

    const resp_parsed = std.json.parseFromSlice(std.json.Value, a, resp_bytes, .{}) catch
        return error.ProviderProtocolError;
    if (resp_parsed.value != .object) return error.ProviderProtocolError;

    if (resp_parsed.value.object.get("error")) |_| return error.ProviderApiError;

    const content_arr = resp_parsed.value.object.get("content") orelse
        return error.ProviderProtocolError;
    if (content_arr != .array or content_arr.array.items.len == 0) return error.ProviderProtocolError;
    const first = content_arr.array.items[0];
    if (first != .object) return error.ProviderProtocolError;
    const text_val = first.object.get("text") orelse return error.ProviderProtocolError;
    if (text_val != .string) return error.ProviderProtocolError;

    if (verbose) {
        std.debug.print("<<< RESPONSE <<<\n{s}\n>>>\n", .{text_val.string});
    }

    return gpa.dupe(u8, text_val.string);
}
