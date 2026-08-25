// Built-in llama.cpp provider — talks to a local `llama-server` instance
// over its OpenAI-compatible /v1/chat/completions endpoint.
//
// This is the right target for small ARM/RISC-V boards (Raspberry Pi Zero,
// Banana Pi Zero, RISC-V SBCs): llama.cpp is pure C++ with official builds
// for armv6/armv7/aarch64/riscv64 and a footprint small enough for 512MB
// boards, unlike Ollama (amd64/arm64 only, heavier Go-runtime footprint).
//
// Environment variables:
//   LLAMACPP_HOST     (default: http://localhost:8080)
//   LLAMACPP_MODEL    (optional — llama-server serves whichever model it was
//                      started with; only needed for a multi-model proxy)
//   LLAMACPP_API_KEY  (optional — only if llama-server was started with --api-key)
const std = @import("std");
const Io = std.Io;
const plugin = @import("../retry/plugin.zig");

const DEFAULT_HOST = "http://localhost:8080";
const DEFAULT_MODEL = "local";

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

    const host = env.get("LLAMACPP_HOST") orelse DEFAULT_HOST;
    const model = env.get("LLAMACPP_MODEL") orelse DEFAULT_MODEL;
    const verbose = env.get("FORGE_VERBOSE") != null;

    const full_prompt = try std.fmt.allocPrint(
        a,
        "You are a JSON API. Return ONLY valid JSON — no explanation, no markdown.\n\nSchema:\n{s}\n\n{s}",
        .{ req.schema_json, req.prompt },
    );

    if (verbose) {
        std.debug.print("\n[forge-provider-llamacpp] attempt {d}\n>>> PROMPT >>>\n{s}\n<<<\n", .{ req.attempt_number, full_prompt });
    }

    const api_url = try std.fmt.allocPrint(a, "{s}/v1/chat/completions", .{host});
    const body_json = try std.json.Stringify.valueAlloc(a, Body{
        .model = model,
        .messages = &[_]Message{.{ .role = "user", .content = full_prompt }},
    }, .{});

    var argv_list: std.ArrayList([]const u8) = .empty;
    try argv_list.appendSlice(a, &[_][]const u8{
        "curl", "-s",                             "-X", "POST", api_url,
        "-H",   "content-type: application/json",
    });
    if (env.get("LLAMACPP_API_KEY")) |api_key| {
        const auth_header = try std.fmt.allocPrint(a, "Authorization: Bearer {s}", .{api_key});
        try argv_list.appendSlice(a, &[_][]const u8{ "-H", auth_header });
    }
    try argv_list.appendSlice(a, &[_][]const u8{ "-d", body_json });

    var child = std.process.spawn(io, .{
        .argv = argv_list.items,
        .stdout = .pipe,
        .stderr = .inherit,
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
