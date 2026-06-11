const std = @import("std");
const ir = @import("../schema/ir.zig");
const c = @cImport(@cInclude("regex.h"));

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
        if (schema.minimum != null or schema.maximum != null or
            schema.exclusive_minimum != null or schema.exclusive_maximum != null)
        {
            try self.validateRange(out, schema, path, result);
        }
        if (out == .string) {
            try self.validateStringConstraints(out.string, schema, path, result);
        }
        for (schema.all_of) |sub| {
            out = try self.validateValue(out, sub, path, result, coerce);
        }
        if (schema.any_of.len > 0) {
            out = try self.validateAnyOf(out, schema.any_of, path, result, coerce);
        }
        if (schema.one_of.len > 0) {
            out = try self.validateOneOf(out, schema.one_of, path, result, coerce);
        }
        if (schema.not) |not_schema| {
            try self.validateNot(out, not_schema, path, result);
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
        const prop_count = value.object.count();
        const field = fieldFromPath(path);

        if (schema.min_properties) |min| {
            if (prop_count < min) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, ">= {d} properties", .{min}),
                    .received_type = "object",
                    .received_value = try std.fmt.allocPrint(a, "({d} properties)", .{prop_count}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "object '{s}' has {d} properties, expected at least {d} (minProperties)",
                        .{ field, prop_count, min }),
                });
            }
        }
        if (schema.max_properties) |max| {
            if (prop_count > max) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "<= {d} properties", .{max}),
                    .received_type = "object",
                    .received_value = try std.fmt.allocPrint(a, "({d} properties)", .{prop_count}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "object '{s}' has {d} properties, expected at most {d} (maxProperties)",
                        .{ field, prop_count, max }),
                });
            }
        }

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
            } else if (schema.additional_properties_schema) |ap_schema| {
                const out_val = try self.validateValue(child_val, ap_schema, cp, result, coerce);
                try out_obj.put(a, key, out_val);
            } else if (schema.additional_properties_forbidden) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = key, .path = cp,
                    .expected = "not present",
                    .received_type = jsonTypeLabel(child_val),
                    .received_value = try jsonValueRepr(a, child_val),
                    .coercible = coerce,
                    .coerced_to = if (coerce) "(removed)" else null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' is not allowed (additionalProperties: false)", .{key}),
                });
                if (!coerce) try out_obj.put(a, key, child_val);
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
        const a = self.arena;
        const len = value.array.items.len;
        const field = fieldFromPath(path);

        if (schema.min_items) |min| {
            if (len < min) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "length >= {d}", .{min}),
                    .received_type = "array",
                    .received_value = try std.fmt.allocPrint(a, "(length {d})", .{len}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "array '{s}' has {d} item(s), expected at least {d} (minItems)",
                        .{ field, len, min }),
                });
            }
        }
        if (schema.max_items) |max| {
            if (len > max) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "length <= {d}", .{max}),
                    .received_type = "array",
                    .received_value = try std.fmt.allocPrint(a, "(length {d})", .{len}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "array '{s}' has {d} item(s), expected at most {d} (maxItems)",
                        .{ field, len, max }),
                });
            }
        }

        if (schema.items == null) return value;

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

    fn validateStringConstraints(
        self: *Engine,
        s: []const u8,
        schema: *const ir.Schema,
        path: []const u8,
        result: *ValidationResult,
    ) !void {
        const a = self.arena;
        const field = fieldFromPath(path);
        if (schema.min_length) |min| {
            if (s.len < min) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "length >= {d}", .{min}),
                    .received_type = "string",
                    .received_value = try std.fmt.allocPrint(a, "\"{s}\"", .{s}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' length {d} is less than minLength {d}",
                        .{ field, s.len, min }),
                });
            }
        }
        if (schema.max_length) |max| {
            if (s.len > max) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "length <= {d}", .{max}),
                    .received_type = "string",
                    .received_value = try std.fmt.allocPrint(a, "\"{s}\"", .{s}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' length {d} exceeds maxLength {d}",
                        .{ field, s.len, max }),
                });
            }
        }
        if (schema.pattern) |pattern| {
            switch (matchesPattern(a, s, pattern)) {
                .matches => {},
                .no_match => {
                    result.valid = false;
                    try result.errors.append(a, .{
                        .field = field, .path = path,
                        .expected = try std.fmt.allocPrint(a, "matches pattern '{s}'", .{pattern}),
                        .received_type = "string",
                        .received_value = try std.fmt.allocPrint(a, "\"{s}\"", .{s}),
                        .coercible = false, .coerced_to = null,
                        .message = try std.fmt.allocPrint(a,
                            "field '{s}' value \"{s}\" does not match pattern '{s}'",
                            .{ field, s, pattern }),
                    });
                },
                .invalid_pattern => {
                    try result.warnings.append(a, try std.fmt.allocPrint(a,
                        "field '{s}': pattern '{s}' is not valid POSIX ERE (skipped)",
                        .{ field, pattern }));
                },
            }
        }
    }

    fn validateAnyOf(
        self: *Engine,
        value: std.json.Value,
        schemas: []const *ir.Schema,
        path: []const u8,
        result: *ValidationResult,
        coerce: bool,
    ) error{OutOfMemory}!std.json.Value {
        for (schemas) |sub| {
            var temp = ValidationResult.init(self.arena);
            defer temp.deinit();
            const out = try self.validateValue(value, sub, path, &temp, coerce);
            if (temp.errors.items.len == 0) return out;
        }
        result.valid = false;
        const field = fieldFromPath(path);
        try result.errors.append(self.arena, .{
            .field = field, .path = path,
            .expected = "match at least one subschema (anyOf)",
            .received_type = jsonTypeLabel(value),
            .received_value = try jsonValueRepr(self.arena, value),
            .coercible = false, .coerced_to = null,
            .message = try std.fmt.allocPrint(self.arena,
                "field '{s}' does not match any subschema (anyOf)", .{field}),
        });
        return value;
    }

    fn validateOneOf(
        self: *Engine,
        value: std.json.Value,
        schemas: []const *ir.Schema,
        path: []const u8,
        result: *ValidationResult,
        coerce: bool,
    ) error{OutOfMemory}!std.json.Value {
        var match_count: usize = 0;
        var matched_value = value;
        for (schemas) |sub| {
            var temp = ValidationResult.init(self.arena);
            defer temp.deinit();
            const out = try self.validateValue(value, sub, path, &temp, coerce);
            if (temp.errors.items.len == 0) {
                match_count += 1;
                matched_value = out;
            }
        }
        if (match_count == 1) return matched_value;
        result.valid = false;
        const field = fieldFromPath(path);
        try result.errors.append(self.arena, .{
            .field = field, .path = path,
            .expected = "match exactly one subschema (oneOf)",
            .received_type = jsonTypeLabel(value),
            .received_value = try jsonValueRepr(self.arena, value),
            .coercible = false, .coerced_to = null,
            .message = try std.fmt.allocPrint(self.arena,
                "field '{s}' matches {d} subschemas, expected exactly 1 (oneOf)",
                .{ field, match_count }),
        });
        return value;
    }

    fn validateNot(
        self: *Engine,
        value: std.json.Value,
        not_schema: *const ir.Schema,
        path: []const u8,
        result: *ValidationResult,
    ) !void {
        var temp = ValidationResult.init(self.arena);
        defer temp.deinit();
        _ = try self.validateValue(value, not_schema, path, &temp, false);
        if (temp.errors.items.len == 0) {
            result.valid = false;
            const field = fieldFromPath(path);
            try result.errors.append(self.arena, .{
                .field = field, .path = path,
                .expected = "not match subschema (not)",
                .received_type = jsonTypeLabel(value),
                .received_value = try jsonValueRepr(self.arena, value),
                .coercible = false, .coerced_to = null,
                .message = try std.fmt.allocPrint(self.arena,
                    "field '{s}' must not match the 'not' subschema", .{field}),
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
        if (schema.exclusive_minimum) |emin| {
            if (n <= emin) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "> {d}", .{emin}),
                    .received_type = "number",
                    .received_value = try std.fmt.allocPrint(a, "{d}", .{n}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' value {d} must be > {d} (exclusiveMinimum)", .{ field, n, emin }),
                });
            }
        }
        if (schema.exclusive_maximum) |emax| {
            if (n >= emax) {
                result.valid = false;
                try result.errors.append(a, .{
                    .field = field, .path = path,
                    .expected = try std.fmt.allocPrint(a, "< {d}", .{emax}),
                    .received_type = "number",
                    .received_value = try std.fmt.allocPrint(a, "{d}", .{n}),
                    .coercible = false, .coerced_to = null,
                    .message = try std.fmt.allocPrint(a,
                        "field '{s}' value {d} must be < {d} (exclusiveMaximum)", .{ field, n, emax }),
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

// --- pattern matching ---

const PatternResult = enum { matches, no_match, invalid_pattern };

fn matchesPattern(arena: std.mem.Allocator, s: []const u8, pattern: []const u8) PatternResult {
    const pattern_z = arena.dupeZ(u8, pattern) catch return .invalid_pattern;
    const s_z = arena.dupeZ(u8, s) catch return .invalid_pattern;

    var preg: c.regex_t = undefined;
    if (c.regcomp(&preg, pattern_z, c.REG_EXTENDED | c.REG_NOSUB) != 0)
        return .invalid_pattern;
    defer c.regfree(&preg);

    return if (c.regexec(&preg, s_z, 0, null, 0) == 0) .matches else .no_match;
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

