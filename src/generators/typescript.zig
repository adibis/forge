const std = @import("std");
const ir = @import("../schema/ir.zig");

// Emit a TypeScript interface + Zod schema from a SchemaRoot.
pub fn generate(
    root: *const ir.SchemaRoot,
    model_name: []const u8,
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
) !void {
    var ctx = Ctx{ .root = root, .writer = writer, .gpa = gpa };

    try writer.writeAll("import { z } from \"zod\";\n\n");

    // Emit $defs first
    var defs_it = root.defs.iterator();
    while (defs_it.next()) |entry| {
        try ctx.emitZodConst(entry.key_ptr.*, entry.value_ptr.*);
        try writer.writeByte('\n');
        try ctx.emitTsType(entry.key_ptr.*);
        try writer.writeByte('\n');
    }

    try ctx.emitZodConst(model_name, &root.schema);
    try writer.writeByte('\n');
    try ctx.emitTsType(model_name);
}

const Ctx = struct {
    root: *const ir.SchemaRoot,
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,

    fn emitZodConst(self: *Ctx, name: []const u8, schema: *const ir.Schema) !void {
        const w = self.writer;
        const const_name = try camelCase(self.gpa, name);
        defer self.gpa.free(const_name);
        try w.print("export const {s}Schema = ", .{const_name});
        try self.emitZodSchema(schema, &self.root.schema == schema);
        try w.writeAll(";\n");
    }

    fn emitZodSchema(self: *Ctx, schema_in: *const ir.Schema, _: bool) !void {
        const w = self.writer;
        const schema = if (schema_in.ref) |ref|
            self.root.resolve(ref) orelse schema_in
        else
            schema_in;

        if (schema.enum_values) |vals| {
            try w.writeAll("z.enum([");
            for (vals, 0..) |v, i| {
                if (i > 0) try w.writeAll(", ");
                if (v == .string) {
                    try w.print("\"{s}\"", .{v.string});
                } else {
                    try w.print("{s}", .{v.label()});
                }
            }
            try w.writeAll("])");
            if (schema.nullable) try w.writeAll(".nullable()");
            return;
        }

        switch (schema.type) {
            .string => {
                const base: []const u8 = switch (schema.format) {
                    .email => "z.string().email()",
                    .uuid => "z.string().uuid()",
                    .date, .date_time => "z.string().datetime()",
                    .uri => "z.string().url()",
                    else => "z.string()",
                };
                try w.writeAll(base);
            },
            .integer => try w.writeAll("z.number().int()"),
            .number => try w.writeAll("z.number()"),
            .boolean => try w.writeAll("z.boolean()"),
            .null => try w.writeAll("z.null()"),
            .array => {
                if (schema.items) |items| {
                    try w.writeAll("z.array(");
                    try self.emitZodSchema(items, false);
                    try w.writeAll(")");
                } else {
                    try w.writeAll("z.array(z.unknown())");
                }
            },
            .object => {
                try w.writeAll("z.object({\n");
                for (schema.properties) |prop| {
                    const is_req = schema.isRequired(prop.name);
                    try w.print("    {s}: ", .{prop.name});
                    try self.emitZodSchema(prop.schema, false);
                    if (!is_req) try w.writeAll(".optional()");
                    try w.writeAll(",\n");
                }
                try w.writeAll("})");
            },
            .any => try w.writeAll("z.unknown()"),
        }
        if (schema.nullable and schema.type != .null) {
            try w.writeAll(".nullable()");
        }
    }

    fn emitTsType(self: *Ctx, name: []const u8) !void {
        const w = self.writer;
        const const_name = try camelCase(self.gpa, name);
        defer self.gpa.free(const_name);
        try w.print("export type {s} = z.infer<typeof {s}Schema>;\n", .{ name, const_name });
    }
};

fn camelCase(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    if (s.len == 0) return gpa.dupe(u8, s);
    var buf = try gpa.alloc(u8, s.len);
    buf[0] = std.ascii.toLower(s[0]);
    @memcpy(buf[1..], s[1..]);
    return buf;
}
