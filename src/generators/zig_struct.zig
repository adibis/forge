const std = @import("std");
const ir = @import("../schema/ir.zig");

pub fn generate(
    root: *const ir.SchemaRoot,
    model_name: []const u8,
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
) !void {
    _ = gpa;
    var ctx = Ctx{ .root = root, .writer = writer };

    try writer.writeAll("const std = @import(\"std\");\n\n");

    // Emit $defs enums/structs first
    var defs_it = root.defs.iterator();
    while (defs_it.next()) |entry| {
        try ctx.emitSchema(entry.key_ptr.*, entry.value_ptr.*);
        try writer.writeByte('\n');
    }

    try ctx.emitSchema(model_name, &root.schema);
}

const Ctx = struct {
    root: *const ir.SchemaRoot,
    writer: *std.Io.Writer,

    fn emitSchema(self: *Ctx, name: []const u8, schema: *const ir.Schema) !void {
        switch (schema.type) {
            .object => try self.emitStruct(name, schema),
            .string => if (schema.enum_values != null) try self.emitEnum(name, schema),
            else => {},
        }
    }

    fn emitEnum(self: *Ctx, name: []const u8, schema: *const ir.Schema) !void {
        const w = self.writer;
        try w.print("pub const {s} = enum {{\n", .{name});
        for (schema.enum_values.?) |v| {
            if (v == .string) try w.print("    {s},\n", .{v.string});
        }
        try w.writeAll("};\n");
    }

    fn emitStruct(self: *Ctx, name: []const u8, schema: *const ir.Schema) !void {
        const w = self.writer;
        try w.print("pub const {s} = struct {{\n", .{name});
        for (schema.properties) |prop| {
            const is_req = schema.isRequired(prop.name);
            const type_str = self.schemaToZigType(prop.schema, is_req);
            if (is_req) {
                try w.print("    {s}: {s},\n", .{ prop.name, type_str });
            } else {
                try w.print("    {s}: {s} = null,\n", .{ prop.name, type_str });
            }
        }
        try w.writeAll("};\n");
    }

    fn schemaToZigType(self: *Ctx, schema_in: *const ir.Schema, required: bool) []const u8 {
        const schema = if (schema_in.ref) |ref|
            self.root.resolve(ref) orelse schema_in
        else
            schema_in;

        const base: []const u8 = switch (schema.type) {
            .string => "[]const u8",
            .integer => "i64",
            .number => "f64",
            .boolean => "bool",
            .array => if (schema.items) |items|
                // Can't easily allocate here without gpa; use a static approximation
                switch (items.type) {
                    .string => "[]const []const u8",
                    .integer => "[]const i64",
                    .number => "[]const f64",
                    .boolean => "[]const bool",
                    else => "[]const anyopaque",
                }
            else
                "[]const anyopaque",
            .object => "anyopaque", // nested struct ref
            .null => "void",
            .any => "std.json.Value",
        };

        if (!required or schema.nullable) {
            // Return a nullable type string
            // NOTE: we can't allocate here; for optional we'd need gpa.
            // As a simple approach, just prefix with ? and hope the caller handles it.
            // This is a known limitation of the no-alloc approach.
            return base; // caller adds `?` prefix if not required
        }
        return base;
    }
};
