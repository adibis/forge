// Provider dispatch: routes by name to built-in providers, falls back to subprocess for custom ones.
// Build flags control which built-in providers are compiled in:
//   -Dollama=false   omit Ollama   (default: included)
//   -Dopenai=false   omit OpenAI   (default: included)
//   -Danthropiclient=false  omit Anthropic  (default: included)
const std = @import("std");
const Io = std.Io;
const build_options = @import("build_options");
const plugin = @import("../retry/plugin.zig");

pub fn call(
    gpa: std.mem.Allocator,
    io: Io,
    provider_name: []const u8,
    req: plugin.PluginRequest,
    env: *const std.process.Environ.Map,
) ![]const u8 {
    if (comptime build_options.include_ollama) {
        if (std.mem.eql(u8, provider_name, "ollama")) {
            return @import("ollama.zig").call(gpa, io, req, env);
        }
    }
    if (comptime build_options.include_openai) {
        if (std.mem.eql(u8, provider_name, "openai")) {
            return @import("openai.zig").call(gpa, io, req, env);
        }
    }
    if (comptime build_options.include_anthropic) {
        if (std.mem.eql(u8, provider_name, "anthropic")) {
            return @import("anthropic.zig").call(gpa, io, req, env);
        }
    }

    // Unknown provider: fall back to subprocess protocol (forge-provider-{name} on PATH).
    // This is how custom providers work.
    const response = plugin.callPlugin(gpa, io, provider_name, req) catch |e| {
        if (e == error.PluginNotFound) {
            std.log.err("provider '{s}' is not built in and 'forge-provider-{s}' was not found on PATH", .{
                provider_name, provider_name,
            });
        }
        return e;
    };
    return response;
}
