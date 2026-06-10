const std = @import("std");
const ir = @import("../schema/ir.zig");

// Emit a normalized, canonical JSON Schema from a SchemaRoot.
// Useful for round-tripping YAML input back to JSON Schema.
pub fn generate(
    root: *const ir.SchemaRoot,
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    const schema_val = try irToJsonValue(a, root, &root.schema);
    const json_str = std.json.Stringify.valueAlloc(a, schema_val, .{ .whitespace = .indent_2 }) catch
        return error.OutOfMemory;

    try writer.writeAll(json_str);
    try writer.writeByte('\n');
}

fn irToJsonValue(gpa: std.mem.Allocator, root: *const ir.SchemaRoot, schema: *const ir.Schema) !std.json.Value {
    var obj: std.json.ObjectMap = .{};

    if (schema.ref) |ref| {
        try obj.put(gpa, "$ref", .{ .string = ref });
        return .{ .object = obj };
    }

    if (schema.type != .any) {
        if (schema.nullable) {
            var arr = std.json.Array.init(gpa);
            try arr.append(.{ .string = schema.type.label() });
            try arr.append(.{ .string = "null" });
            try obj.put(gpa, "type", .{ .array = arr });
        } else {
            try obj.put(gpa, "type", .{ .string = schema.type.label() });
        }
    }

    if (schema.format != .none) {
        try obj.put(gpa, "format", .{ .string = schema.format.label() });
    }

    if (schema.minimum) |min| {
        try obj.put(gpa, "minimum", .{ .float = min });
    }
    if (schema.maximum) |max| {
        try obj.put(gpa, "maximum", .{ .float = max });
    }

    if (schema.enum_values) |vals| {
        var arr = std.json.Array.init(gpa);
        for (vals) |v| {
            try arr.append(switch (v) {
                .string => |s| .{ .string = s },
                .integer => |i| .{ .integer = i },
                .float => |f| .{ .float = f },
                .boolean => |b| .{ .bool = b },
                .null => .null,
            });
        }
        try obj.put(gpa, "enum", .{ .array = arr });
    }

    if (schema.properties.len > 0) {
        var props_obj: std.json.ObjectMap = .{};
        for (schema.properties) |prop| {
            const child_val = try irToJsonValue(gpa, root, prop.schema);
            try props_obj.put(gpa, prop.name, child_val);
        }
        try obj.put(gpa, "properties", .{ .object = props_obj });
    }

    if (schema.required.len > 0) {
        var req_arr = std.json.Array.init(gpa);
        for (schema.required) |r| try req_arr.append(.{ .string = r });
        try obj.put(gpa, "required", .{ .array = req_arr });
    }

    if (schema.items) |items| {
        const items_val = try irToJsonValue(gpa, root, items);
        try obj.put(gpa, "items", items_val);
    }

    if (schema.title) |t| try obj.put(gpa, "title", .{ .string = t });
    if (schema.description) |d| try obj.put(gpa, "description", .{ .string = d });

    // Embed $defs if this is the root schema
    if (&root.schema == schema and root.defs.count() > 0) {
        var defs_obj: std.json.ObjectMap = .{};
        var it = root.defs.iterator();
        while (it.next()) |entry| {
            const def_val = try irToJsonValue(gpa, root, entry.value_ptr.*);
            try defs_obj.put(gpa, entry.key_ptr.*, def_val);
        }
        try obj.put(gpa, "$defs", .{ .object = defs_obj });
    }

    return .{ .object = obj };
}
