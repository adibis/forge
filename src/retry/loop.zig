const std = @import("std");
const Io = std.Io;
const ir = @import("../schema/ir.zig");
const json_parse = @import("../parse/json.zig");
const engine_mod = @import("../validate/engine.zig");
const report = @import("../errors/report.zig");
const plugin = @import("plugin.zig");
const dispatch = @import("../providers/dispatch.zig");

pub const RetryOptions = struct {
    provider: []const u8,
    max_retries: u32 = 3,
    schema_json: []const u8,
    verbose: bool = false,
    env: *const std.process.Environ.Map,
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
        if (opts.verbose) {
            std.debug.print("\n[forge retry] attempt {d}: validating input ({d} bytes)\n", .{ attempt, current_input.len });
        }

        var parse_result = json_parse.parseLenient(a, current_input) catch |e| {
            if (opts.verbose) {
                std.debug.print("[forge retry] attempt {d}: parse failed ({s}), calling provider\n", .{ attempt, @errorName(e) });
            }
            if (attempt == opts.max_retries) return e;
            const prompt = try std.fmt.allocPrint(a,
                "The JSON you returned could not be parsed: {s}. Please return only valid JSON.",
                .{@errorName(e)});
            current_input = try callProviderForRetry(gpa, io, a, opts, prompt, attempt + 1);
            continue;
        };
        defer parse_result.deinit();

        var eng = engine_mod.Engine.init(a, schema_root);
        var vr = try eng.validate(parse_result.value, true);
        defer vr.deinit();

        const has_hard_error = blk: {
            for (vr.errors.items) |e| {
                if (!e.coercible) break :blk true;
            }
            break :blk false;
        };

        if (opts.verbose) {
            if (vr.errors.items.len == 0) {
                std.debug.print("[forge retry] attempt {d}: valid — done\n", .{attempt});
            } else {
                std.debug.print("[forge retry] attempt {d}: {d} error(s) ({s})\n", .{
                    attempt,
                    vr.errors.items.len,
                    if (has_hard_error) "hard errors, will call provider" else "coercible only, accepting",
                });
            }
        }

        if (!has_hard_error) {
            return RetryResult{
                .value = vr.best_effort.?,
                .attempts = attempt + 1,
                .arena = arena,
            };
        }

        if (attempt == opts.max_retries) {
            return error.MaxRetriesExceeded;
        }

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
    const response = try dispatch.call(gpa, io, opts.provider, req, opts.env);
    defer gpa.free(response);
    return arena.dupe(u8, response);
}
