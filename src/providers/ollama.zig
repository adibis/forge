// Built-in Ollama provider.
// Environment variables: OLLAMA_HOST (default: http://localhost:11434), OLLAMA_MODEL (required)
const std = @import("std");
const Io = std.Io;
const plugin = @import("../retry/plugin.zig");

const DEFAULT_HOST = "http://localhost:11434";

const Body = struct {
    model: []const u8,
    prompt: []const u8,
    stream: bool,
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

    const host = env.get("OLLAMA_HOST") orelse DEFAULT_HOST;
    const model = env.get("OLLAMA_MODEL") orelse return error.MissingOllamaModel;
    const verbose = env.get("FORGE_VERBOSE") != null;

    const full_prompt = try std.fmt.allocPrint(a,
        "You are a JSON API. Return ONLY valid JSON — no explanation, no markdown.\n\nSchema:\n{s}\n\n{s}",
        .{ req.schema_json, req.prompt },
    );

    if (verbose) {
        std.debug.print("\n[forge-provider-ollama] attempt {d}\n>>> PROMPT >>>\n{s}\n<<<\n",
            .{ req.attempt_number, full_prompt });
    }

    const api_url = try std.fmt.allocPrint(a, "{s}/api/generate", .{host});
    const body_json = try std.json.Stringify.valueAlloc(a, Body{
        .model = model,
        .prompt = full_prompt,
        .stream = false,
    }, .{});

    const argv = [_][]const u8{
        "curl", "-s", "-X", "POST", api_url,
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

    const resp_text = resp_parsed.value.object.get("response") orelse
        return error.ProviderProtocolError;
    if (resp_text != .string) return error.ProviderProtocolError;

    if (verbose) {
        std.debug.print("<<< RESPONSE <<<\n{s}\n>>>\n", .{resp_text.string});
    }

    return gpa.dupe(u8, resp_text.string);
}
