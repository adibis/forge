const std = @import("std");
const ir = @import("ir.zig");

pub const LoadError = error{
    InvalidSchema,
    UnsupportedFeature,
    OutOfMemory,
};

pub fn loadFromSlice(allocator: std.mem.Allocator, input: []const u8) LoadError!ir.SchemaRoot {
    var root = ir.SchemaRoot.init(allocator);
    errdefer root.deinit();
    const arena = root.allocator();

    const parsed = std.json.parseFromSlice(std.json.Value, arena, input, .{}) catch |e| {
        std.log.err("JSON parse error: {}", .{e});
        return error.InvalidSchema;
    };

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidSchema,
    };

    try loadDefs(&root, obj);
    root.schema = try loadSchema(&root, parsed.value);
    return root;
}

fn loadDefs(root: *ir.SchemaRoot, obj: std.json.ObjectMap) LoadError!void {
    const arena = root.allocator();
    const defs_keys = [_][]const u8{ "$defs", "definitions" };
    for (defs_keys) |key| {
        const defs_val = obj.get(key) orelse continue;
        const defs_obj = switch (defs_val) {
            .object => |o| o,
            else => continue,
        };
        var it = defs_obj.iterator();
        while (it.next()) |entry| {
            const name = try arena.dupe(u8, entry.key_ptr.*);
            const s = try arena.create(ir.Schema);
            s.* = try loadSchema(root, entry.value_ptr.*);
            try root.defs.put(name, s);
        }
        break;
    }
}

pub fn loadSchema(root: *ir.SchemaRoot, val: std.json.Value) LoadError!ir.Schema {
    const arena = root.allocator();
    const obj = switch (val) {
        .object => |o| o,
        .bool => return .{},
        else => return error.InvalidSchema,
    };

    var schema = ir.Schema{};

    if (obj.get("$ref")) |ref_val| {
        switch (ref_val) {
            .string => |s| schema.ref = try arena.dupe(u8, s),
            else => {},
        }
        return schema;
    }

    if (obj.get("type")) |type_val| {
        switch (type_val) {
            .string => |s| {
                schema.type = ir.SchemaType.fromStr(s) orelse return error.InvalidSchema;
            },
            .array => |arr| {
                var primary: ?ir.SchemaType = null;
                for (arr.items) |item| {
                    if (item == .string) {
                        if (std.mem.eql(u8, item.string, "null")) {
                            schema.nullable = true;
                        } else if (ir.SchemaType.fromStr(item.string)) |t| {
                            primary = t;
                        }
                    }
                }
                schema.type = primary orelse .any;
            },
            else => return error.InvalidSchema,
        }
    }

    if (obj.get("title")) |v| {
        if (v == .string) schema.title = try arena.dupe(u8, v.string);
    }
    if (obj.get("description")) |v| {
        if (v == .string) schema.description = try arena.dupe(u8, v.string);
    }
    if (obj.get("format")) |v| {
        if (v == .string) schema.format = ir.Format.fromStr(v.string);
    }

    if (obj.get("minimum")) |v| schema.minimum = jsonToF64(v);
    if (obj.get("maximum")) |v| schema.maximum = jsonToF64(v);

    if (obj.get("enum")) |v| {
        if (v == .array) {
            var vals: std.ArrayList(ir.EnumValue) = .empty;
            for (v.array.items) |item| {
                try vals.append(arena, try jsonToEnumValue(arena, item));
            }
            schema.enum_values = try vals.toOwnedSlice(arena);
        }
    }

    if (obj.get("properties")) |v| {
        if (v == .object) {
            var props: std.ArrayList(ir.Property) = .empty;
            var it = v.object.iterator();
            while (it.next()) |entry| {
                const name = try arena.dupe(u8, entry.key_ptr.*);
                const child = try arena.create(ir.Schema);
                child.* = try loadSchema(root, entry.value_ptr.*);
                try props.append(arena, .{ .name = name, .schema = child });
            }
            schema.properties = try props.toOwnedSlice(arena);
        }
    }

    if (obj.get("required")) |v| {
        if (v == .array) {
            var reqs: std.ArrayList([]const u8) = .empty;
            for (v.array.items) |item| {
                if (item == .string) try reqs.append(arena, try arena.dupe(u8, item.string));
            }
            schema.required = try reqs.toOwnedSlice(arena);
        }
    }

    if (obj.get("items")) |v| {
        const child = try arena.create(ir.Schema);
        child.* = try loadSchema(root, v);
        schema.items = child;
    }

    return schema;
}

fn jsonToF64(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        .number_string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

fn jsonToEnumValue(arena: std.mem.Allocator, v: std.json.Value) LoadError!ir.EnumValue {
    return switch (v) {
        .string => |s| .{ .string = try arena.dupe(u8, s) },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .bool => |b| .{ .boolean = b },
        .null => .{ .null = {} },
        else => error.InvalidSchema,
    };
}

test "load simple schema" {
    const schema_json =
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": {"type": "string"},
        \\    "age": {"type": "integer", "minimum": 0},
        \\    "status": {"type": "string", "enum": ["active", "inactive"]}
        \\  },
        \\  "required": ["name", "age"]
        \\}
    ;
    var root = try loadFromSlice(std.testing.allocator, schema_json);
    defer root.deinit();

    try std.testing.expectEqual(ir.SchemaType.object, root.schema.type);
    try std.testing.expectEqual(@as(usize, 3), root.schema.properties.len);
    try std.testing.expectEqual(@as(usize, 2), root.schema.required.len);

    const age_schema = root.schema.getProperty("age").?;
    try std.testing.expectEqual(ir.SchemaType.integer, age_schema.type);
    try std.testing.expect(age_schema.minimum != null);
    try std.testing.expectEqual(@as(f64, 0), age_schema.minimum.?);
}
