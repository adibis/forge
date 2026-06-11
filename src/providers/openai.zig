// Built-in OpenAI provider.
// Environment variables: OPENAI_API_KEY (required), OPENAI_MODEL (default: gpt-4o-mini)
const std = @import("std");
const Io = std.Io;
const plugin = @import("../retry/plugin.zig");

const OPENAI_API = "https://api.openai.com/v1/chat/completions";
const DEFAULT_MODEL = "gpt-4o-mini";

const Message = struct { role: []const u8, content: []const u8 };
const Body = struct {
    model: []const u8,
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

    const api_key = env.get("OPENAI_API_KEY") orelse return error.MissingOpenAIKey;
    const model = env.get("OPENAI_MODEL") orelse DEFAULT_MODEL;
    const verbose = env.get("FORGE_VERBOSE") != null;

    const full_prompt = try std.fmt.allocPrint(a,
        "You are a JSON API. Return ONLY valid JSON — no explanation, no markdown.\n\nSchema:\n{s}\n\n{s}",
        .{ req.schema_json, req.prompt },
    );

    if (verbose) {
        std.debug.print("\n[forge-provider-openai] attempt {d}\n>>> PROMPT >>>\n{s}\n<<<\n",
            .{ req.attempt_number, full_prompt });
    }

    const body_json = try std.json.Stringify.valueAlloc(a, Body{
        .model = model,
        .messages = &[_]Message{.{ .role = "user", .content = full_prompt }},
    }, .{});

    const auth_header = try std.fmt.allocPrint(a, "Authorization: Bearer {s}", .{api_key});

    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST", OPENAI_API,
        "-H", auth_header,
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

    const choices = resp_parsed.value.object.get("choices") orelse
        return error.ProviderProtocolError;
    if (choices != .array or choices.array.items.len == 0) return error.ProviderProtocolError;
    const choice = choices.array.items[0];
    if (choice != .object) return error.ProviderProtocolError;
    const message = choice.object.get("message") orelse return error.ProviderProtocolError;
    if (message != .object) return error.ProviderProtocolError;
    const content_val = message.object.get("content") orelse return error.ProviderProtocolError;
    if (content_val != .string) return error.ProviderProtocolError;

    if (verbose) {
        std.debug.print("<<< RESPONSE <<<\n{s}\n>>>\n", .{content_val.string});
    }

    return gpa.dupe(u8, content_val.string);
}
