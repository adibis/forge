// Top-level test runner for modules that have cross-directory imports.
// Each import causes Zig to include that file's `test` blocks in this binary.
const std = @import("std");
const loader = @import("schema/loader.zig");
const json_parse = @import("parse/json.zig");
const engine_mod = @import("validate/engine.zig");
const report_mod = @import("errors/report.zig");
const gen_pydantic = @import("generate/pydantic.zig");
const gen_ts = @import("generate/typescript.zig");
const gen_zig = @import("generate/zig_struct.zig");
const gen_jsonschema = @import("generate/jsonschema.zig");

// ---- engine tests ----

const Engine = engine_mod.Engine;
const ValidationResult = engine_mod.ValidationResult;

fn engineArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn parseAndValidate(
    arena: std.mem.Allocator,
    schema_json: []const u8,
    input_json: []const u8,
    coerce: bool,
) !ValidationResult {
    var root = try loader.loadFromSlice(arena, schema_json);
    const pr = try json_parse.parseLenient(arena, input_json);
    var eng = Engine.init(arena, &root);
    return eng.validate(pr.value, coerce);
}

test "engine: valid input passes" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name","age"]}
    , "{\"name\":\"Alice\",\"age\":30}", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
    try std.testing.expectEqual(@as(usize, 0), vr.errors.items.len);
}

test "engine: missing required field is hard error" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    , "{}", true);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
    try std.testing.expectEqual(@as(usize, 1), vr.errors.items.len);
    try std.testing.expect(!vr.errors.items[0].coercible);
}

test "engine: type mismatch is hard error" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"count":{"type":"integer"}},"required":["count"]}
    , "{\"count\":true}", true);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
    try std.testing.expect(!vr.errors.items[0].coercible);
}

test "engine: numeric string coerced to integer" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"age":{"type":"integer"}},"required":["age"]}
    , "{\"age\":\"30\"}", true);
    defer vr.deinit();
    try std.testing.expectEqual(@as(usize, 1), vr.coercions.items.len);
    try std.testing.expect(vr.best_effort != null);
    try std.testing.expectEqual(@as(i64, 30), vr.best_effort.?.object.get("age").?.integer);
}

test "engine: enum case fold coercion" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"status":{"type":"string","enum":["active","inactive"]}},"required":["status"]}
    , "{\"status\":\"ACTIVE\"}", true);
    defer vr.deinit();
    try std.testing.expectEqual(@as(usize, 1), vr.errors.items.len);
    try std.testing.expect(vr.errors.items[0].coercible);
    try std.testing.expectEqualStrings("active", vr.best_effort.?.object.get("status").?.string);
}

test "engine: extra field stripped in fix mode" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    , "{\"name\":\"Bob\",\"extra\":\"drop\"}", true);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
    try std.testing.expectEqual(@as(usize, 1), vr.warnings.items.len);
    try std.testing.expect(vr.best_effort.?.object.get("extra") == null);
}

test "engine: extra field preserved when not coercing" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}
    , "{\"name\":\"Bob\",\"extra\":\"keep\"}", false);
    defer vr.deinit();
    try std.testing.expect(vr.best_effort.?.object.get("extra") != null);
}

test "engine: nullable field accepts null" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"note":{"type":["string","null"]}},"required":[]}
    , "{\"note\":null}", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "engine: array items validated" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"tags":{"type":"array","items":{"type":"string"}}},"required":["tags"]}
    , "{\"tags\":[\"a\",\"b\"]}", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "engine: float coerced to integer when lossless" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}
    , "{\"n\":3.0}", true);
    defer vr.deinit();
    try std.testing.expectEqual(@as(i64, 3), vr.best_effort.?.object.get("n").?.integer);
}

// ---- generate/pydantic tests ----

fn collectOutput(comptime genFn: anytype, args: anytype) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    const w = &aw.writer;
    try @call(.auto, genFn, args ++ .{w, std.testing.allocator});
    return aw.toOwnedSlice();
}

test "pydantic: simple object" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"object","properties":{"name":{"type":"string"},"age":{"type":"integer"}},"required":["name","age"]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_pydantic.generate(&root, "Person", &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "class Person(BaseModel):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "name: str"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "age: int"));
}

test "pydantic: enum field generates Enum class" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"object","properties":{"status":{"type":"string","enum":["on","off"]}},"required":["status"]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_pydantic.generate(&root, "Device", &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "class DeviceStatus(str, Enum):"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "on = \"on\""));
}

test "pydantic: optional field uses Optional" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"object","properties":{"email":{"type":"string"}},"required":[]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_pydantic.generate(&root, "User", &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "Optional[str]"));
}

// ---- generate/typescript tests ----

test "typescript: object produces zod schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"object","properties":{"id":{"type":"integer"},"name":{"type":"string"}},"required":["id","name"]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_ts.generate(&root, "Item", &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "z.object({"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "z.number().int()"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "export type Item ="));
}

test "typescript: enum field produces z.enum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"object","properties":{"role":{"type":"string","enum":["admin","user"]}},"required":["role"]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_ts.generate(&root, "Account", &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "z.enum(["));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "\"admin\""));
}

// ---- generate/zig_struct tests ----

test "zig: struct has correct field types" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"object","properties":{"name":{"type":"string"},"count":{"type":"integer"}},"required":["name","count"]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_zig.generate(&root, "Item", &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "pub const Item = struct {"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "name: []const u8"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "count: i64"));
}

test "zig: string enum generates enum type" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"string","enum":["red","green","blue"]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_zig.generate(&root, "Color", &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "pub const Color = enum {"));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "red,"));
}

// ---- generate/jsonschema tests ----

test "jsonschema: round-trip preserves type and required" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = try loader.loadFromSlice(a,
        \\{"type":"object","properties":{"x":{"type":"string"}},"required":["x"]}
    );
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    try gen_jsonschema.generate(&root, &aw.writer, std.testing.allocator);
    const out = try aw.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "\"type\": \"object\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "\"required\""));
    try std.testing.expect(std.mem.containsAtLeast(u8, out, 1, "\"x\""));
}
