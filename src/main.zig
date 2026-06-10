const std = @import("std");
const Io = std.Io;

const build_options = @import("build_options");
const loader = @import("schema/loader.zig");
const json_parse = @import("parse/json.zig");
const engine_mod = @import("validate/engine.zig");
const report = @import("errors/report.zig");
const retry_loop = @import("retry/loop.zig");
const gen_pydantic = @import("generators/pydantic.zig");
const gen_typescript = @import("generators/typescript.zig");
const gen_zig = @import("generators/zig_struct.zig");
const gen_jsonschema = @import("generators/jsonschema.zig");

const usage =
    \\forge — LLM output validator and repair tool
    \\
    \\Usage:
    \\  forge validate  --schema <file> [--input <file>] [--output <file>]
    \\  forge fix       --schema <file> [--input <file>] [--output <file>]
    \\  forge retry     --schema <file> --provider <name> [--max-retries N] [--input <file>] [--output <file>]
    \\  forge generate  --schema <file> --target <lang> [--output <file>]
    \\
    \\Subcommands:
    \\  validate   Validate JSON; exit 0=ok, 1=invalid, 2=schema error, 3=parse error
    \\  fix        Validate + coerce/repair; emit fixed JSON
    \\  retry      Validate, and if invalid, call provider plugin to fix; loop up to N times
    \\  generate   Emit type definitions from schema (targets: pydantic, typescript, zig, jsonschema)
    \\
    \\Options:
    \\  --schema <file>    JSON Schema file (required)
    \\  --input <file>     Input JSON file (default: stdin)
    \\  --output <file>    Write output to file instead of stdout
    \\  --provider <name>  Provider name for retry (e.g. openai, anthropic, ollama)
    \\  --max-retries N    Max retry attempts (default: 3)
    \\  --target <lang>    Code generation target
    \\  --model-name <n>   Name for generated class/struct (default: Model)
    \\  --help             Show this help
    \\
;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena_alloc = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena_alloc);

    if (args.len < 2) {
        try Io.File.stderr().writeStreamingAll(io, usage);
        std.process.exit(1);
    }

    const subcmd = args[1];

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "help")) {
        try Io.File.stdout().writeStreamingAll(io, usage);
        return;
    }
    if (std.mem.eql(u8, subcmd, "--version") or std.mem.eql(u8, subcmd, "version")) {
        try Io.File.stdout().writeStreamingAll(io, "forge " ++ build_options.version ++ "\n");
        return;
    }

    if (std.mem.eql(u8, subcmd, "validate") or std.mem.eql(u8, subcmd, "fix")) {
        try runValidateOrFix(gpa, io, args[2..], std.mem.eql(u8, subcmd, "fix"));
    } else if (std.mem.eql(u8, subcmd, "retry")) {
        try runRetry(gpa, io, args[2..], init.environ_map);
    } else if (std.mem.eql(u8, subcmd, "generate")) {
        try runGenerate(gpa, io, args[2..]);
    } else {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "unknown subcommand: {s}\n", .{subcmd}) catch "unknown subcommand\n";
        try Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    }
}

// --- validate / fix ---

fn runValidateOrFix(
    gpa: std.mem.Allocator,
    io: Io,
    args: []const [:0]const u8,
    do_fix: bool,
) !void {
    var schema_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    parseCommonArgs(args, &schema_path, &input_path, &output_path);

    const sp = schema_path orelse exitWithError(gpa, io, 2, "schema-load-error", "missing --schema");
    const schema_text = readFile(gpa, io, sp, 2);
    defer gpa.free(schema_text);

    var schema_root = loader.loadFromSlice(gpa, schema_text) catch |e| {
        exitWithErrorFmt(gpa, io, 2, "schema-load-error", "invalid schema: {s}", .{@errorName(e)});
    };
    defer schema_root.deinit();

    const input_text = readInput(gpa, io, input_path, 3);
    defer gpa.free(input_text);

    const out_file = openOutputFile(gpa, io, output_path);
    defer if (out_file) |f| f.close(io);

    var parse_result = json_parse.parseLenient(gpa, input_text) catch |e| {
        const trunc = e == error.TruncatedJson;
        if (trunc) {
            emit(io, out_file, "{\"status\":\"error\",\"input_parseable\":false,\"truncated\":true,\"errors\":[],\"warnings\":[],\"coercions\":[]}\n");
        } else {
            emit(io, out_file, "{\"status\":\"error\",\"input_parseable\":false,\"errors\":[],\"warnings\":[],\"coercions\":[]}\n");
        }
        std.process.exit(3);
    };
    defer parse_result.deinit();

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var eng = engine_mod.Engine.init(a, &schema_root);
    var vr = try eng.validate(parse_result.value, do_fix);
    defer vr.deinit();

    if (do_fix) {
        emitJson(gpa, io, out_file, vr.best_effort orelse parse_result.value);
        const has_hard_error = blk: {
            for (vr.errors.items) |e| {
                if (!e.coercible) break :blk true;
            }
            break :blk false;
        };
        if (has_hard_error) std.process.exit(1);
    } else {
        const resp = try report.buildResponse(a, &vr, true, true);
        emitJson(gpa, io, out_file, resp);
        if (!vr.valid) std.process.exit(1);
    }
}

// --- retry ---

fn runRetry(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8, env: *const std.process.Environ.Map) !void {
    var schema_path: ?[]const u8 = null;
    var input_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var provider: ?[]const u8 = null;
    var max_retries: u32 = 3;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--schema") and i + 1 < args.len) {
            i += 1; schema_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--input") and i + 1 < args.len) {
            i += 1; input_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1; output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
            i += 1; provider = args[i];
        } else if (std.mem.eql(u8, args[i], "--max-retries") and i + 1 < args.len) {
            i += 1;
            max_retries = std.fmt.parseInt(u32, args[i], 10) catch 3;
        }
    }

    const sp = schema_path orelse exitWithError(gpa, io, 2, "schema-load-error", "missing --schema");
    const prov = provider orelse exitWithError(gpa, io, 1, "usage-error", "missing --provider");

    const schema_text = readFile(gpa, io, sp, 2);
    defer gpa.free(schema_text);

    var schema_root = loader.loadFromSlice(gpa, schema_text) catch |e| {
        exitWithErrorFmt(gpa, io, 2, "schema-load-error", "invalid schema: {s}", .{@errorName(e)});
    };
    defer schema_root.deinit();

    const input_text = readInput(gpa, io, input_path, 3);
    defer gpa.free(input_text);

    var result = retry_loop.run(gpa, io, &schema_root, input_text, .{
        .provider = prov,
        .max_retries = max_retries,
        .schema_json = schema_text,
        .verbose = env.get("FORGE_VERBOSE") != null,
        .env = env,
    }) catch |e| {
        exitWithErrorFmt(gpa, io, 4, "retry-error", "retry failed: {s}", .{@errorName(e)});
    };
    defer result.deinit();

    const out_file = openOutputFile(gpa, io, output_path);
    defer if (out_file) |f| f.close(io);

    const out_json = std.json.Stringify.valueAlloc(gpa, result.value, .{}) catch return;
    defer gpa.free(out_json);

    var resp_buf: [128]u8 = undefined;
    const wrapper = std.fmt.bufPrint(&resp_buf,
        "{{\"status\":\"ok\",\"attempts\":{d},\"data\":", .{result.attempts}) catch return;
    emit(io, out_file, wrapper);
    emit(io, out_file, out_json);
    emit(io, out_file, "}\n");
}

// --- generate ---

fn runGenerate(gpa: std.mem.Allocator, io: Io, args: []const [:0]const u8) !void {
    var schema_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var target: ?[]const u8 = null;
    var model_name: []const u8 = "Model";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--schema") and i + 1 < args.len) {
            i += 1; schema_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1; output_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
            i += 1; target = args[i];
        } else if (std.mem.eql(u8, args[i], "--model-name") and i + 1 < args.len) {
            i += 1; model_name = args[i];
        }
    }

    const sp = schema_path orelse exitWithError(gpa, io, 2, "schema-load-error", "missing --schema");
    const tgt = target orelse exitWithError(gpa, io, 1, "usage-error", "missing --target (pydantic, typescript, zig, jsonschema)");

    const schema_text = readFile(gpa, io, sp, 2);
    defer gpa.free(schema_text);

    var schema_root = loader.loadFromSlice(gpa, schema_text) catch |e| {
        exitWithErrorFmt(gpa, io, 2, "schema-load-error", "invalid schema: {s}", .{@errorName(e)});
    };
    defer schema_root.deinit();

    // Collect all output into an Allocating writer, then stream to stdout
    var aw: std.Io.Writer.Allocating = .init(gpa);
    const w = &aw.writer;

    if (std.mem.eql(u8, tgt, "pydantic")) {
        try gen_pydantic.generate(&schema_root, model_name, w, gpa);
    } else if (std.mem.eql(u8, tgt, "typescript") or std.mem.eql(u8, tgt, "ts")) {
        try gen_typescript.generate(&schema_root, model_name, w, gpa);
    } else if (std.mem.eql(u8, tgt, "zig")) {
        try gen_zig.generate(&schema_root, model_name, w, gpa);
    } else if (std.mem.eql(u8, tgt, "jsonschema") or std.mem.eql(u8, tgt, "json")) {
        try gen_jsonschema.generate(&schema_root, w, gpa);
    } else {
        exitWithErrorFmt(gpa, io, 1, "usage-error", "unknown target '{s}' (pydantic, typescript, zig, jsonschema)", .{tgt});
    }

    const generated = try aw.toOwnedSlice();
    defer gpa.free(generated);

    const out_file = openOutputFile(gpa, io, output_path);
    defer if (out_file) |f| f.close(io);
    emit(io, out_file, generated);
}

// --- helpers ---

fn parseCommonArgs(
    args: []const [:0]const u8,
    schema_path: *?[]const u8,
    input_path: *?[]const u8,
    output_path: *?[]const u8,
) void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--schema") and i + 1 < args.len) {
            i += 1; schema_path.* = args[i];
        } else if (std.mem.eql(u8, args[i], "--input") and i + 1 < args.len) {
            i += 1; input_path.* = args[i];
        } else if (std.mem.eql(u8, args[i], "--output") and i + 1 < args.len) {
            i += 1; output_path.* = args[i];
        }
    }
}

fn readFile(gpa: std.mem.Allocator, io: Io, path: []const u8, exit_code: u8) []const u8 {
    return Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch |e| {
        exitWithErrorFmt(gpa, io, exit_code, "file-read-error", "cannot read '{s}': {s}", .{ path, @errorName(e) });
    };
}

fn readInput(gpa: std.mem.Allocator, io: Io, path: ?[]const u8, exit_code: u8) []const u8 {
    if (path) |p| return readFile(gpa, io, p, exit_code);
    var buf: [8192]u8 = undefined;
    var reader = Io.File.stdin().reader(io, &buf);
    return reader.interface.allocRemaining(gpa, .unlimited) catch |e| {
        exitWithErrorFmt(gpa, io, exit_code, "stdin-read-error", "cannot read stdin: {s}", .{@errorName(e)});
    };
}

fn openOutputFile(gpa: std.mem.Allocator, io: Io, path: ?[]const u8) ?Io.File {
    const p = path orelse return null;
    return Io.Dir.cwd().createFile(io, p, .{}) catch |e| {
        exitWithErrorFmt(gpa, io, 1, "output-error", "cannot open output file '{s}': {s}", .{ p, @errorName(e) });
    };
}

fn emit(io: Io, out: ?Io.File, s: []const u8) void {
    const f = out orelse Io.File.stdout();
    f.writeStreamingAll(io, s) catch {};
}

fn emitJson(gpa: std.mem.Allocator, io: Io, out: ?Io.File, value: anytype) void {
    const s = std.json.Stringify.valueAlloc(gpa, value, .{}) catch return;
    defer gpa.free(s);
    emit(io, out, s);
    emit(io, out, "\n");
}

fn exitWithError(gpa: std.mem.Allocator, io: Io, code: u8, err_code: []const u8, msg: []const u8) noreturn {
    const s = std.fmt.allocPrint(gpa,
        "{{\"status\":\"error\",\"code\":\"{s}\",\"message\":\"{s}\"}}\n",
        .{ err_code, msg },
    ) catch "";
    defer if (s.len > 0) gpa.free(s);
    Io.File.stdout().writeStreamingAll(io, s) catch {};
    std.process.exit(code);
}

fn exitWithErrorFmt(
    gpa: std.mem.Allocator,
    io: Io,
    code: u8,
    err_code: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) noreturn {
    const msg = std.fmt.allocPrint(gpa, fmt, args) catch "error";
    defer gpa.free(msg);
    exitWithError(gpa, io, code, err_code, msg);
}
