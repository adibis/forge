const std = @import("std");
const Io = std.Io;
const ir = @import("../schema/ir.zig");
const engine = @import("../validate/engine.zig");

pub const PluginRequest = struct {
    prompt: []const u8,
    schema_json: []const u8,
    previous_errors: []const []const u8,
    attempt_number: u32,
};

pub const PluginResponse = struct {
    response: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

pub const PluginError = error{
    PluginNotFound,
    PluginCrashed,
    PluginProtocolError,
    OutOfMemory,
};

// Call a provider plugin via stdio JSON protocol.
// Plugin is resolved as "forge-provider-{name}" on PATH.
pub fn callPlugin(
    gpa: std.mem.Allocator,
    io: Io,
    provider_name: []const u8,
    req: PluginRequest,
) PluginError![]const u8 {
    // Build plugin executable name
    const plugin_bin = std.fmt.allocPrint(gpa, "forge-provider-{s}", .{provider_name}) catch
        return error.OutOfMemory;
    defer gpa.free(plugin_bin);

    // Serialize request
    const req_json = std.json.Stringify.valueAlloc(gpa, req, .{}) catch
        return error.OutOfMemory;
    defer gpa.free(req_json);

    // Spawn plugin
    const argv = [_][]const u8{plugin_bin};
    var child = std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .inherit,
    }) catch |e| {
        if (e == error.FileNotFound) return error.PluginNotFound;
        return error.PluginCrashed;
    };

    // Write request JSON + newline to plugin stdin
    const stdin_file = child.stdin.?;
    stdin_file.writeStreamingAll(io, req_json) catch return error.PluginCrashed;
    stdin_file.writeStreamingAll(io, "\n") catch return error.PluginCrashed;
    stdin_file.close(io);
    child.stdin = null;

    // Read response from plugin stdout
    const stdout_file = child.stdout.?;
    var read_buf: [4096]u8 = undefined;
    var reader = stdout_file.reader(io, &read_buf);
    const resp_bytes = reader.interface.allocRemaining(gpa, .unlimited) catch
        return error.PluginCrashed;
    defer gpa.free(resp_bytes);

    _ = child.wait(io) catch return error.PluginCrashed;

    // Parse response
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, a, std.mem.trim(u8, resp_bytes, " \t\r\n"), .{}) catch
        return error.PluginProtocolError;

    if (parsed.value != .object) return error.PluginProtocolError;

    if (parsed.value.object.get("error")) |err_val| {
        if (err_val == .string) {
            std.log.err("plugin error: {s}", .{err_val.string});
        }
        return error.PluginCrashed;
    }

    const resp_val = parsed.value.object.get("response") orelse return error.PluginProtocolError;
    if (resp_val != .string) return error.PluginProtocolError;

    return gpa.dupe(u8, resp_val.string) catch error.OutOfMemory;
}
