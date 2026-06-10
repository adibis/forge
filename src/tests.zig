// Top-level test runner for modules that have cross-directory imports.
// Each import causes Zig to include that file's `test` blocks in this binary.
const std = @import("std");
const loader = @import("schema/loader.zig");
const json_parse = @import("parse/json.zig");
const engine_mod = @import("validate/engine.zig");
const report_mod = @import("errors/report.zig");
const gen_pydantic = @import("generators/pydantic.zig");
const gen_ts = @import("generators/typescript.zig");
const gen_zig = @import("generators/zig_struct.zig");
const gen_jsonschema = @import("generators/jsonschema.zig");

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

// This test documents the retry loop termination bug.
//
// After coerce=true validation, `vr.valid` is false whenever any error was
// recorded — even if every error was coercible and best_effort is fully valid.
// The retry loop previously checked `if (vr.valid)` to decide success, so it
// would call the provider again instead of returning the already-fixed result.
//
// The correct check is: no hard errors (errors where coercible==false).
// This test verifies the pre-condition so the loop can be tested without IO.
test "retry termination: coercible-only errors have no hard errors" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    // Input has two coercible problems: numeric string + enum case fold
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"age":{"type":"integer"},"status":{"type":"string","enum":["active","inactive"]}},"required":["age","status"]}
    , "{\"age\":\"30\",\"status\":\"ACTIVE\"}", true);
    defer vr.deinit();

    // vr.valid is false — this is why the old retry loop kept looping
    try std.testing.expect(!vr.valid);
    // but best_effort IS present and is the corrected value
    try std.testing.expect(vr.best_effort != null);
    // and every error is coercible — so the loop SHOULD have terminated
    for (vr.errors.items) |e| {
        try std.testing.expect(e.coercible);
    }
    // verify the coerced values are correct
    try std.testing.expectEqual(@as(i64, 30), vr.best_effort.?.object.get("age").?.integer);
    try std.testing.expectEqualStrings("active", vr.best_effort.?.object.get("status").?.string);
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

// ---- errors/report tests ----

test "report: valid result has status ok and no retry prompt" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"x":{"type":"integer"}},"required":["x"]}
    , "{\"x\":1}", false);
    defer vr.deinit();
    const resp = try report_mod.buildResponse(a, &vr, true, true);
    try std.testing.expectEqualStrings("ok", resp.status);
    try std.testing.expect(resp.retry_prompt == null);
    try std.testing.expectEqual(@as(usize, 0), resp.errors.len);
}

test "report: invalid result has status error and retry prompt" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"x":{"type":"integer"}},"required":["x"]}
    , "{}", false);
    defer vr.deinit();
    const resp = try report_mod.buildResponse(a, &vr, true, true);
    try std.testing.expectEqualStrings("error", resp.status);
    try std.testing.expect(resp.retry_prompt != null);
    try std.testing.expect(resp.errors.len > 0);
}

test "report: retry prompt mentions the failing field" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"email":{"type":"string"}},"required":["email"]}
    , "{}", false);
    defer vr.deinit();
    const prompt = try report_mod.buildRetryPrompt(a, &vr);
    try std.testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "email"));
    try std.testing.expect(std.mem.containsAtLeast(u8, prompt, 1, "corrected JSON"));
}

test "report: no retry prompt when include_retry_prompt is false" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"x":{"type":"string"}},"required":["x"]}
    , "{}", false);
    defer vr.deinit();
    const resp = try report_mod.buildResponse(a, &vr, true, false);
    try std.testing.expect(resp.retry_prompt == null);
}

test "report: coercions reflected in response" {
    var arena = engineArena();
    defer arena.deinit();
    const a = arena.allocator();
    var vr = try parseAndValidate(a,
        \\{"type":"object","properties":{"n":{"type":"integer"}},"required":["n"]}
    , "{\"n\":\"42\"}", true);
    defer vr.deinit();
    const resp = try report_mod.buildResponse(a, &vr, true, true);
    try std.testing.expectEqual(@as(usize, 1), resp.coercions.len);
    try std.testing.expectEqualStrings("$.n", resp.coercions[0].path);
}

// ---- generators/pydantic tests ----

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

// ---- generators/typescript tests ----

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

// ---- generators/zig_struct tests ----

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

// ---- new schema keywords: allOf, anyOf, oneOf, not, minLength, maxLength, additionalProperties ----

fn parseAndValidateKeywords(a: std.mem.Allocator, schema_json: []const u8, input: []const u8, coerce: bool) !engine_mod.ValidationResult {
    var root = try loader.loadFromSlice(a, schema_json);
    var eng = engine_mod.Engine.init(a, &root);
    var pr = try json_parse.parseLenient(a, input);
    defer pr.deinit();
    return eng.validate(pr.value, coerce);
}

test "minLength: rejects short string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"string","minLength":3}
    , "\"ab\"", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
    try std.testing.expectEqual(@as(usize, 1), vr.errors.items.len);
}

test "minLength: accepts string at boundary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"string","minLength":3}
    , "\"abc\"", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "maxLength: rejects long string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"string","maxLength":3}
    , "\"toolong\"", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
}

test "additionalProperties: false rejects extra fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"object","properties":{"name":{"type":"string"}},"additionalProperties":false}
    , "{\"name\":\"Alice\",\"extra\":\"oops\"}", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
    try std.testing.expectEqual(@as(usize, 1), vr.errors.items.len);
}

test "additionalProperties: false strips extra fields in coerce mode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"object","properties":{"name":{"type":"string"}},"additionalProperties":false}
    , "{\"name\":\"Alice\",\"extra\":\"oops\"}", true);
    defer vr.deinit();
    try std.testing.expect(vr.best_effort != null);
    try std.testing.expect(vr.best_effort.?.object.get("extra") == null);
    try std.testing.expect(vr.best_effort.?.object.get("name") != null);
}

test "allOf: valid when all subschemas pass" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"allOf":[{"type":"object","properties":{"x":{"type":"integer"}}},{"type":"object","required":["x"]}]}
    , "{\"x\":1}", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "allOf: invalid when any subschema fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"allOf":[{"type":"object","properties":{"x":{"type":"integer"}}},{"type":"object","required":["x"]}]}
    , "{}", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
}

test "anyOf: valid when one subschema passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"anyOf":[{"type":"string"},{"type":"integer"}]}
    , "42", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "anyOf: invalid when no subschema passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"anyOf":[{"type":"string"},{"type":"integer"}]}
    , "true", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
}

test "oneOf: valid when exactly one subschema passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"oneOf":[{"type":"string"},{"type":"integer"}]}
    , "42", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "oneOf: invalid when more than one subschema passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"oneOf":[{"type":"number"},{"type":"integer"}]}
    , "42", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
}

test "not: valid when subschema fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"not":{"type":"string"}}
    , "42", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "not: invalid when subschema passes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"not":{"type":"string"}}
    , "\"hello\"", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
}

// ---- minItems / maxItems tests ----

test "minItems: accepts array at exact minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"array","minItems":2}
    , "[1,2]", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "minItems: rejects array below minimum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"array","minItems":3}
    , "[1,2]", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
    try std.testing.expectEqual(@as(usize, 1), vr.errors.items.len);
}

test "maxItems: accepts array at exact maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"array","maxItems":3}
    , "[1,2,3]", false);
    defer vr.deinit();
    try std.testing.expect(vr.valid);
}

test "maxItems: rejects array above maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"array","maxItems":2}
    , "[1,2,3]", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
    try std.testing.expectEqual(@as(usize, 1), vr.errors.items.len);
}

test "minItems and maxItems: both enforced together" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"array","minItems":2,"maxItems":4}
    , "[1]", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
}

test "minItems: works without items schema" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var vr = try parseAndValidateKeywords(arena.allocator(),
        \\{"type":"array","minItems":1}
    , "[]", false);
    defer vr.deinit();
    try std.testing.expect(!vr.valid);
}

// ---- generators/jsonschema tests ----

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
