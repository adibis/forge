const std = @import("std");
const Io = std.Io;
const ir = @import("../schema/ir.zig");
const json_parse = @import("../parse/json.zig");
const engine_mod = @import("../validate/engine.zig");
const report = @import("../errors/report.zig");
const plugin = @import("plugin.zig");

pub const RetryOptions = struct {
    provider: []const u8,
    max_retries: u32 = 3,
    schema_json: []const u8,
};

pub const RetryResult = struct {
    value: std.json.Value,
    attempts: u32,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *RetryResult) void {
        self.arena.deinit();
    }
};

pub fn run(
    gpa: std.mem.Allocator,
    io: Io,
    schema_root: *const ir.SchemaRoot,
    initial_input: []const u8,
    opts: RetryOptions,
) !RetryResult {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();

    var current_input: []const u8 = try a.dupe(u8, initial_input);
    var attempt: u32 = 0;

    while (attempt <= opts.max_retries) : (attempt += 1) {
        // Parse into the arena so string slices in vr.best_effort stay valid
        // after this iteration ends (gpa-backed ParseResult would be freed by defer
        // before the caller could use the returned value).
        var parse_result = json_parse.parseLenient(a, current_input) catch |e| {
            if (attempt == opts.max_retries) return e;
            // Build a prompt asking for valid JSON
            const prompt = try std.fmt.allocPrint(a,
                "The JSON you returned could not be parsed: {s}. Please return only valid JSON.",
                .{@errorName(e)});
            current_input = try callProviderForRetry(gpa, io, a, opts, prompt, attempt + 1);
            continue;
        };
        defer parse_result.deinit();

        // Validate
        var eng = engine_mod.Engine.init(a, schema_root);
        var vr = try eng.validate(parse_result.value, true);
        defer vr.deinit();

        // Accept if there are no hard (uncoercible) errors — mirrors fix subcommand logic.
        // vr.valid is false whenever any error was recorded, including coercible ones,
        // so checking vr.valid alone would cause unnecessary retries.
        const has_hard_error = blk: {
            for (vr.errors.items) |e| {
                if (!e.coercible) break :blk true;
            }
            break :blk false;
        };
        if (!has_hard_error) {
            return RetryResult{
                .value = vr.best_effort.?,
                .attempts = attempt + 1,
                .arena = arena,
            };
        }

        // Last attempt failed
        if (attempt == opts.max_retries) {
            return error.MaxRetriesExceeded;
        }

        // Build retry prompt and call plugin
        const resp = try report.buildResponse(a, &vr, true, true);
        const retry_prompt = resp.retry_prompt orelse "Please return valid JSON.";

        current_input = try callProviderForRetry(gpa, io, a, opts, retry_prompt, attempt + 1);
    }

    return error.MaxRetriesExceeded;
}

fn callProviderForRetry(
    gpa: std.mem.Allocator,
    io: Io,
    arena: std.mem.Allocator,
    opts: RetryOptions,
    prompt: []const u8,
    attempt: u32,
) ![]const u8 {
    const req = plugin.PluginRequest{
        .prompt = prompt,
        .schema_json = opts.schema_json,
        .previous_errors = &.{},
        .attempt_number = attempt,
    };
    const response = plugin.callPlugin(gpa, io, opts.provider, req) catch |e| {
        return switch (e) {
            error.PluginNotFound => blk: {
                std.log.err("provider 'forge-provider-{s}' not found on PATH", .{opts.provider});
                break :blk error.PluginNotFound;
            },
            else => e,
        };
    };
    defer gpa.free(response);
    return arena.dupe(u8, response);
}
