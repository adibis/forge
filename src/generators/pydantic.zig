const std = @import("std");
const ir = @import("../schema/ir.zig");

// Emit a Pydantic v2 model from a SchemaRoot.
// Output is written to `writer` (std.Io.Writer).
pub fn generate(
    root: *const ir.SchemaRoot,
    model_name: []const u8,
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
) !void {
    // Use an internal arena so all temporary allocations (enum name strings, etc.)
    // are freed together at the end without needing explicit cleanup.
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var ctx = Ctx{
        .root = root,
        .writer = writer,
        .gpa = a,
        .enums_emitted = std.StringHashMap(void).init(a),
    };

    try writer.writeAll(
        \\from __future__ import annotations
        \\from typing import Optional, List, Literal
        \\from pydantic import BaseModel, EmailStr
        \\from uuid import UUID
        \\from datetime import date, datetime
        \\
        \\
    );

    // Emit any $defs models first
    var defs_it = root.defs.iterator();
    while (defs_it.next()) |entry| {
        if (entry.value_ptr.*.type == .object) {
            try ctx.emitModel(entry.key_ptr.*, entry.value_ptr.*);
            try writer.writeByte('\n');
        }
    }

    // Emit root model
    try ctx.emitModel(model_name, &root.schema);
}

const Ctx = struct {
    root: *const ir.SchemaRoot,
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    enums_emitted: std.StringHashMap(void),

    fn emitModel(self: *Ctx, name: []const u8, schema: *const ir.Schema) !void {
        const w = self.writer;
        // First emit inline enum classes for properties that have enum values
        for (schema.properties) |prop| {
            if (prop.schema.enum_values != null and prop.schema.type == .string) {
                const enum_name = try titleCase(self.gpa, prop.name);
                defer self.gpa.free(enum_name);
                const full_name = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ name, enum_name });
                defer self.gpa.free(full_name);

                if (!self.enums_emitted.contains(full_name)) {
                    try self.enums_emitted.put(try self.gpa.dupe(u8, full_name), {});
                    try self.emitEnumClass(full_name, prop.schema.enum_values.?);
                    try w.writeByte('\n');
                }
            }
        }

        try w.print("class {s}(BaseModel):\n", .{name});

        if (schema.properties.len == 0) {
            try w.writeAll("    pass\n");
            return;
        }

        for (schema.properties) |prop| {
            const is_required = schema.isRequired(prop.name);
            const type_str = try self.schemaToType(prop.name, name, prop.schema, is_required);
            defer self.gpa.free(type_str);

            if (is_required) {
                try w.print("    {s}: {s}\n", .{ prop.name, type_str });
            } else {
                try w.print("    {s}: {s} = None\n", .{ prop.name, type_str });
            }
        }
    }

    fn emitEnumClass(self: *Ctx, name: []const u8, vals: []const ir.EnumValue) !void {
        const w = self.writer;
        try w.print("class {s}(str, Enum):\n", .{name});
        for (vals) |v| {
            if (v == .string) {
                try w.print("    {s} = \"{s}\"\n", .{ v.string, v.string });
            }
        }
    }

    fn schemaToType(
        self: *Ctx,
        field_name: []const u8,
        parent_name: []const u8,
        schema: *const ir.Schema,
        required: bool,
    ) ![]const u8 {
        const resolved = if (schema.ref) |ref|
            self.root.resolve(ref) orelse schema
        else
            schema;

        var base: []const u8 = undefined;
        var owned = false;

        if (resolved.enum_values != null and resolved.type == .string) {
            const enum_name = try titleCase(self.gpa, field_name);
            defer self.gpa.free(enum_name);
            base = try std.fmt.allocPrint(self.gpa, "{s}{s}", .{ parent_name, enum_name });
            owned = true;
        } else {
            base = switch (resolved.type) {
                .string => switch (resolved.format) {
                    .email => "EmailStr",
                    .uuid => "UUID",
                    .date => "date",
                    .date_time => "datetime",
                    else => "str",
                },
                .integer => "int",
                .number => "float",
                .boolean => "bool",
                .array => blk: {
                    if (resolved.items) |items| {
                        const inner = try self.schemaToType("item", parent_name, items, true);
                        defer self.gpa.free(inner);
                        break :blk try std.fmt.allocPrint(self.gpa, "List[{s}]", .{inner});
                    }
                    break :blk try self.gpa.dupe(u8, "List");
                },
                .object => blk: {
                    // Inline object - just use dict or Any
                    break :blk try self.gpa.dupe(u8, "dict");
                },
                else => try self.gpa.dupe(u8, "Any"),
            };
            if (resolved.type == .array or resolved.type == .object or resolved.type == .any) owned = true;
        }

        if (!required or resolved.nullable) {
            const opt = try std.fmt.allocPrint(self.gpa, "Optional[{s}]", .{base});
            if (owned) self.gpa.free(base);
            return opt;
        }
        if (owned) return base;
        return self.gpa.dupe(u8, base);
    }
};

fn titleCase(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return gpa.dupe(u8, s);
    var buf = try gpa.alloc(u8, s.len);
    buf[0] = std.ascii.toUpper(s[0]);
    @memcpy(buf[1..], s[1..]);
    return buf;
}
