const std = @import("std");
const ir = @import("../schema/ir.zig");

pub const ValidationError = struct {
    field: []const u8,
    path: []const u8,
    expected: []const u8,
    received_type: []const u8,
    received_value: []const u8,
    coercible: bool,
    coerced_to: ?[]const u8,
    message: []const u8,

    pub fn jsonStringify(self: ValidationError, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("field");       try jw.write(self.field);
        try jw.objectField("path");        try jw.write(self.path);
        try jw.objectField("expected");    try jw.write(self.expected);
        try jw.objectField("received_type"); try jw.write(self.received_type);
        try jw.objectField("received_value"); try jw.write(self.received_value);
        try jw.objectField("coercible");   try jw.write(self.coercible);
        if (self.coerced_to) |ct| {
            try jw.objectField("coerced_to"); try jw.write(ct);
        }
        try jw.objectField("message");     try jw.write(self.message);
        try jw.endObject();
    }
};

pub const Coercion = struct {
    path: []const u8,
    from: []const u8,
    to: []const u8,
    reason: []const u8,

    pub fn jsonStringify(self: Coercion, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("path");   try jw.write(self.path);
        try jw.objectField("from");   try jw.write(self.from);
        try jw.objectField("to");     try jw.write(self.to);
        try jw.objectField("reason"); try jw.write(self.reason);
        try jw.endObject();
    }
};

pub const ValidationResult = struct {
    valid: bool,
    errors: std.ArrayList(ValidationError),
    warnings: std.ArrayList([]const u8),
    coercions: std.ArrayList(Coercion),
    best_effort: ?std.json.Value,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ValidationResult {
        return .{
            .valid = true,
            .errors = .empty,
            .warnings = .empty,
            .coercions = .empty,
            .best_effort = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ValidationResult) void {
        self.errors.deinit(self.allocator);
        self.warnings.deinit(self.allocator);
        self.coercions.deinit(self.allocator);
    }
};

pub const Engine = struct {
    arena: std.mem.Allocator,
    root: *const ir.SchemaRoot,

    pub fn init(arena: std.mem.Allocator, root: *const ir.SchemaRoot) Engine {
        return .{ .arena = arena, .root = root };
    }

    pub fn validate(self: *Engine, value: std.json.Value, coerce: bool) !ValidationResult {
        var result = ValidationResult.init(self.arena);
        const schema = self.resolveRef(&self.root.schema);
        const out = try self.validateValue(value, schema, "$", &result, coerce);
        result.best_effort = out;
        result.valid = result.errors.items.len == 0;
        return result;
    }

    fn resolveRef(self: *const Engine, schema: *const ir.Schema) *const ir.Schema {
        if (schema.ref) |ref| {
            if (self.root.resolve(ref)) |resolved| return resolved;
        }
        return schema;
    }

    fn validateValue(
        self: *Engine,
        value: std.json.Value,
        schema_in: *const ir.Schema,
        path: []const u8,
        result: *ValidationResult,
        coerce: bool,
    ) error{OutOfMemory}!std.json.Value {
        const schema = self.resolveRef(schema_in);
        const a = self.arena;

        if (value == .null) {
            if (schema.type != .null and schema.type != .any and !schema.nullable) {
                result.valid = false;
                const field = fieldFromPath(path);
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = schema.type.label(),
                    .received_type = "null", .received_value = "null",
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' expected {s}, received null", .{ field, schema.type.label() }),
                });
            }
            return value;
        }

        if (schema.enum_values) |enum_vals| {
            return self.validateEnum(value, enum_vals, path, result, coerce);
        }

        var out = value;
        if (schema.type != .any) {
            out = try self.checkType(value, schema, path, result, coerce);
        }

        if (schema.type == .object or (schema.type == .any and out == .object)) {
            out = try self.validateObject(out, schema, path, result, coerce);
        }
        if (schema.type == .array or (schema.type == .any and out == .array)) {
            out = try self.validateArray(out, schema, path, result, coerce);
        }
        if (schema.format != .none and out == .string) {
            try self.validateFormat(out.string, schema.format, path, result);
        }
        if (schema.minimum != null or schema.maximum != null) {
            try self.validateRange(out, schema, path, result);
        }
        return out;
    }

    fn checkType(
        self: *Engine,
        value: std.json.Value,
        schema: *const ir.Schema,
        path: []const u8,
        result: *ValidationResult,
        coerce: bool,
    ) error{OutOfMemory}!std.json.Value {
        const a = self.arena;
        const expected = schema.type;
        const actual = jsonTypeLabel(value);

        const matches = switch (expected) {
            .string  => value == .string,
            .number  => value == .float or value == .integer or value == .number_string,
            .integer => value == .integer,
            .boolean => value == .bool,
            .array   => value == .array,
            .object  => value == .object,
            .null    => value == .null,
            .any     => true,
        };
        if (matches) return value;

        if (coerce) {
            // Numeric string → integer/number
            if ((expected == .integer or expected == .number) and value == .string) {
                if (expected == .integer) {
                    if (std.fmt.parseInt(i64, value.string, 10)) |n| {
                        try result.coercions.append(a, .{
                            .path = path,
                            .from = try std.fmt.allocPrint(a, "\"{s}\"", .{value.string}),
                            .to = try std.fmt.allocPrint(a, "{d}", .{n}),
                            .reason = "numeric string to integer",
                        });
                        return .{ .integer = n };
                    } else |_| {}
                }
                if (std.fmt.parseFloat(f64, value.string)) |f| {
                    try result.coercions.append(a, .{
                        .path = path,
                        .from = try std.fmt.allocPrint(a, "\"{s}\"", .{value.string}),
                        .to = try std.fmt.allocPrint(a, "{d}", .{f}),
                        .reason = "numeric string to number",
                    });
                    return .{ .float = f };
                } else |_| {}
            }
            // Float with integral value → integer
            if (expected == .integer and value == .float) {
                const f = value.float;
                if (f == @trunc(f)) {
                    const n: i64 = @intFromFloat(f);
                    try result.coercions.append(a, .{
                        .path = path,
                        .from = try std.fmt.allocPrint(a, "{d}", .{f}),
                        .to = try std.fmt.allocPrint(a, "{d}", .{n}),
                        .reason = "float to integer (lossless)",
                    });
                    return .{ .integer = n };
                }
            }
            // Single-element array → scalar
            if (value == .array and value.array.items.len == 1) {
                const inner = value.array.items[0];
                const inner_ok = switch (expected) {
                    .string  => inner == .string,
                    .number  => inner == .float or inner == .integer,
                    .integer => inner == .integer,
                    .boolean => inner == .bool,
                    else => false,
                };
                if (inner_ok) {
                    try result.warnings.append(a, try std.fmt.allocPrint(a,
                        "field '{s}': unwrapped single-element array to scalar", .{fieldFromPath(path)}));
                    try result.coercions.append(a, .{
                        .path = path, .from = "[...]", .to = "(scalar)",
                        .reason = "single-item array unwrap",
                    });
                    return inner;
                }
            }
        }

        result.valid = false;
        const field = fieldFromPath(path);
        try result.errors.append(a, .{
            .field = field, .path = path,
            .expected = expected.label(),
            .received_type = actual,
            .received_value = try jsonValueRepr(a, value),
            .coercible = false, .coerced_to = null,
            .message = try std.fmt.allocPrint(a,
                "field '{s}' expected {s}, received {s} — no safe cast available",
                .{ field, expected.label(), actual }),
        });
        return value;
    }

    fn validateEnum(
        self: *Engine,
        value: std.json.Value,
        enum_vals: []const ir.EnumValue,
        path: []const u8,
        result: *ValidationResult,
        coerce: bool,
    ) error{OutOfMemory}!std.json.Value {
        const a = self.arena;
        const field = fieldFromPath(path);
        const json_ev = jsonToEnumValue(value);

        var string_candidates: std.ArrayList([]const u8) = .empty;
        for (enum_vals) |ev| {
            if (ev.eql(json_ev)) return value;
            if (ev == .string) try string_candidates.append(a, ev.string);
        }

        if (coerce and value == .string) {
            const lev = @import("../util/levenshtein.zig");
            if (try lev.closest(a, value.string, string_candidates.items, 2)) |matched| {
                if (!std.mem.eql(u8, value.string, matched)) {
                    const from = try std.fmt.allocPrint(a, "\"{s}\"", .{value.string});
                    const to = try std.fmt.allocPrint(a, "\"{s}\"", .{matched});
                    try result.coercions.append(a, .{
                        .path = path, .from = from, .to = to,
                        .reason = "enum case fold / fuzzy match",
                    });
                    try result.errors.append(a, .{
                        .field = field, .path = path,
                        .expected = try enumLabel(a, enum_vals),
                        .received_type = "string", .received_value = from,
                        .coercible = true, .coerced_to = matched,
                        .message = try std.fmt.allocPrint(a,
                            "field '{s}' received '{s}', case-folded to '{s}'",
                            .{ field, value.string, matched }),
                    });
                    return .{ .string = matched };
                }
            }
        }

        result.valid = false;
        try result.errors.append(a, .{
            .field = field, .path = path,
            .expected = try enumLabel(a, enum_vals),
            .received_type = jsonTypeLabel(value),
            .received_value = try jsonValueRepr(a, value),
            .coercible = false, .coerced_to = null,
            .message = try std.fmt.allocPrint(a,
                "field '{s}' value {s} not in {s}",
                .{ field, try jsonValueRepr(a, value), try enumLabel(a, enum_vals) }),
        });
        return value;
    }

    fn validateObject(
        self: *Engine,
        value: std.json.Value,
        schema: *const ir.Schema,
        path: []const u8,
        result: *ValidationResult,
        coerce: bool,
    ) error{OutOfMemory}!std.json.Value {
        if (value != .object) return value;
        const a = self.arena;
        var out_obj: std.json.ObjectMap = .{};

        for (schema.required) |req| {
            if (value.object.get(req) == null) {
                result.valid = false;
                const cp = try std.fmt.allocPrint(a, "{s}.{s}", .{ path, req });
                try result.errors.append(a, .{
                    .field = req, .path = cp,
                    .expected = "present", .received_type = "missing",
                    .received_value = "undefined",
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "required field '{s}' is missing", .{req}),
                });
            }
        }

        var it = value.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const child_val = entry.value_ptr.*;
            const cp = try std.fmt.allocPrint(a, "{s}.{s}", .{ path, key });

            if (schema.getProperty(key)) |prop_schema| {
                const out_val = try self.validateValue(child_val, prop_schema, cp, result, coerce);
                try out_obj.put(a, key, out_val);
            } else if (coerce) {
                try result.warnings.append(a, try std.fmt.allocPrint(a,
                    "field '{s}' (path: {s}) not in schema, stripped", .{ key, cp }));
            } else {
                try out_obj.put(a, key, child_val);
            }
        }

        return .{ .object = out_obj };
    }

    fn validateArray(
        self: *Engine,
        value: std.json.Value,
        schema: *const ir.Schema,
        path: []const u8,
        result: *ValidationResult,
        coerce: bool,
    ) error{OutOfMemory}!std.json.Value {
        if (value != .array) return value;
        if (schema.items == null) return value;
        const a = self.arena;

        var out_arr = std.json.Array.init(a);
        for (value.array.items, 0..) |item, i| {
            const cp = try std.fmt.allocPrint(a, "{s}[{d}]", .{ path, i });
            const out_item = try self.validateValue(item, schema.items.?, cp, result, coerce);
            try out_arr.append(out_item);
        }
        return .{ .array = out_arr };
    }

    fn validateFormat(
        self: *Engine,
        s: []const u8,
        fmt: ir.Format,
        path: []const u8,
        result: *ValidationResult,
    ) !void {
        const a = self.arena;
        const valid = switch (fmt) {
            .email => isValidEmail(s),
            .uuid  => isValidUuid(s),
            .date  => isValidDate(s),
            .date_time => isValidDateTime(s),
            .uri   => s.len > 0 and std.mem.indexOf(u8, s, "://") != null,
            .ipv4  => isValidIpv4(s),
            else   => true,
        };
        if (!valid) {
            result.valid = false;
            const field = fieldFromPath(path);
            try result.errors.append(a, .{
                .field = field, .path = path,
                .expected = fmt.label(),
                .received_type = "string",
                .received_value = try std.fmt.allocPrint(a, "\"{s}\"", .{s}),
                .coercible = false, .coerced_to = null,
                .message = try std.fmt.allocPrint(a,
                    "field '{s}' value \"{s}\" does not match format '{s}'",
                    .{ field, s, fmt.label() }),
            });
        }
    }

    fn validateRange(
        self: *Engine,
        value: std.json.Value,
        schema: *const ir.Schema,
        path: []const u8,
        result: *ValidationResult,
    ) !void {
        const a = self.arena;
        const n: f64 = switch (value) {
            .integer => |i| @floatFromInt(i),
            .float   => |f| f,
            else     => return,
        };
        const field = fieldFromPath(path);
        if (schema.minimum) |min| {
            if (n < min) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, ">= {d}", .{min}),
                    .received_type = "number",
                    .received_value = try std.fmt.allocPrint(a, "{d}", .{n}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' value {d} is less than minimum {d}", .{ field, n, min }),
                });
            }
        }
        if (schema.maximum) |max| {
            if (n > max) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "<= {d}", .{max}),
                    .received_type = "number",
                    .received_value = try std.fmt.allocPrint(a, "{d}", .{n}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' value {d} is greater than maximum {d}", .{ field, n, max }),
                });
            }
        }
    }
};

// --- helpers ---

fn fieldFromPath(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |idx| return path[idx + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, path, '[')) |idx| return path[idx..];
    return path;
}

fn jsonTypeLabel(v: std.json.Value) []const u8 {
    return switch (v) {
        .null         => "null",
        .bool         => "boolean",
        .integer      => "integer",
        .float        => "number",
        .number_string => "number",
        .string       => "string",
        .array        => "array",
        .object       => "object",
    };
}

fn jsonValueRepr(arena: std.mem.Allocator, v: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, v, .{});
}

fn jsonToEnumValue(v: std.json.Value) ir.EnumValue {
    return switch (v) {
        .string  => |s| .{ .string = s },
        .integer => |i| .{ .integer = i },
        .float   => |f| .{ .float = f },
        .bool    => |b| .{ .boolean = b },
        else     => .{ .null = {} },
    };
}

fn enumLabel(arena: std.mem.Allocator, vals: []const ir.EnumValue) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.appendSlice(arena, "enum[");
    for (vals, 0..) |v, i| {
        if (i > 0) try buf.appendSlice(arena, ", ");
        try buf.appendSlice(arena, v.label());
    }
    try buf.append(arena, ']');
    return buf.toOwnedSlice(arena);
}

// --- format validators ---

fn isValidEmail(s: []const u8) bool {
    const at = std.mem.indexOfScalar(u8, s, '@') orelse return false;
    return at > 0 and std.mem.indexOfScalar(u8, s[at + 1 ..], '.') != null;
}

fn isValidUuid(s: []const u8) bool {
    if (s.len != 36) return false;
    for ([_]usize{ 8, 13, 18, 23 }) |d| if (s[d] != '-') return false;
    for (s, 0..) |ch, i| {
        if (i == 8 or i == 13 or i == 18 or i == 23) continue;
        if (!std.ascii.isHex(ch)) return false;
    }
    return true;
}

fn isValidDate(s: []const u8) bool {
    return s.len == 10 and s[4] == '-' and s[7] == '-';
}

fn isValidDateTime(s: []const u8) bool {
    return s.len >= 19 and isValidDate(s[0..10]) and (s[10] == 'T' or s[10] == ' ');
}

fn isValidIpv4(s: []const u8) bool {
    var it = std.mem.splitScalar(u8, s, '.');
    var count: usize = 0;
    while (it.next()) |part| {
        _ = std.fmt.parseUnsigned(u8, part, 10) catch return false;
        count += 1;
    }
    return count == 4;
}

