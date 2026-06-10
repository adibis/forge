const std = @import("std");

pub const SchemaType = enum {
    string,
    number,
    integer,
    boolean,
    array,
    object,
    null,
    any,

    pub fn fromStr(s: []const u8) ?SchemaType {
        if (std.mem.eql(u8, s, "string")) return .string;
        if (std.mem.eql(u8, s, "number")) return .number;
        if (std.mem.eql(u8, s, "integer")) return .integer;
        if (std.mem.eql(u8, s, "boolean")) return .boolean;
        if (std.mem.eql(u8, s, "array")) return .array;
        if (std.mem.eql(u8, s, "object")) return .object;
        if (std.mem.eql(u8, s, "null")) return .null;
        return null;
    }

    pub fn label(self: SchemaType) []const u8 {
        return switch (self) {
            .string => "string",
            .number => "number",
            .integer => "integer",
            .boolean => "boolean",
            .array => "array",
            .object => "object",
            .null => "null",
            .any => "any",
        };
    }
};

pub const Format = enum {
    none,
    email,
    date,
    date_time,
    uri,
    uuid,
    ipv4,
    ipv6,

    pub fn fromStr(s: []const u8) Format {
        if (std.mem.eql(u8, s, "email")) return .email;
        if (std.mem.eql(u8, s, "date")) return .date;
        if (std.mem.eql(u8, s, "date-time")) return .date_time;
        if (std.mem.eql(u8, s, "uri")) return .uri;
        if (std.mem.eql(u8, s, "uuid")) return .uuid;
        if (std.mem.eql(u8, s, "ipv4")) return .ipv4;
        if (std.mem.eql(u8, s, "ipv6")) return .ipv6;
        return .none;
    }

    pub fn label(self: Format) []const u8 {
        return switch (self) {
            .none => "",
            .email => "email",
            .date => "date",
            .date_time => "date-time",
            .uri => "uri",
            .uuid => "uuid",
            .ipv4 => "ipv4",
            .ipv6 => "ipv6",
        };
    }
};

pub const EnumValue = union(enum) {
    string: []const u8,
    integer: i64,
    float: f64,
    boolean: bool,
    null: void,

    pub fn eql(a: EnumValue, b: EnumValue) bool {
        if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
        return switch (a) {
            .string => |s| std.mem.eql(u8, s, b.string),
            .integer => |n| n == b.integer,
            .float => |f| f == b.float,
            .boolean => |v| v == b.boolean,
            .null => true,
        };
    }

    pub fn label(self: EnumValue) []const u8 {
        return switch (self) {
            .string => |s| s,
            .integer => "(integer)",
            .float => "(float)",
            .boolean => |v| if (v) "true" else "false",
            .null => "null",
        };
    }
};

pub const Property = struct {
    name: []const u8,
    schema: *Schema,
};

pub const Schema = struct {
    type: SchemaType = .any,
    nullable: bool = false,

    // object fields
    properties: []Property = &.{},
    required: []const []const u8 = &.{},

    // array element schema and size constraints
    items: ?*Schema = null,
    min_items: ?usize = null,
    max_items: ?usize = null,

    // string constraints
    format: Format = .none,
    min_length: ?usize = null,
    max_length: ?usize = null,
    pattern: ?[]const u8 = null,

    // numeric constraints
    minimum: ?f64 = null,
    maximum: ?f64 = null,

    // enum (null means no enum constraint)
    enum_values: ?[]const EnumValue = null,

    // schema combiners
    all_of: []const *Schema = &.{},
    any_of: []const *Schema = &.{},
    one_of: []const *Schema = &.{},
    not: ?*Schema = null,

    // additional properties:
    //   forbidden=false, schema=null  → allow any extra properties (default)
    //   forbidden=true,  schema=null  → additionalProperties: false
    //   forbidden=false, schema=*S    → validate extra properties against S
    additional_properties_forbidden: bool = false,
    additional_properties_schema: ?*Schema = null,

    // unresolved $ref path (e.g. "#/$defs/Foo")
    ref: ?[]const u8 = null,

    // metadata
    title: ?[]const u8 = null,
    description: ?[]const u8 = null,

    pub fn isRequired(self: *const Schema, field: []const u8) bool {
        for (self.required) |r| {
            if (std.mem.eql(u8, r, field)) return true;
        }
        return false;
    }

    pub fn getProperty(self: *const Schema, name: []const u8) ?*Schema {
        for (self.properties) |prop| {
            if (std.mem.eql(u8, prop.name, name)) return prop.schema;
        }
        return null;
    }

    pub fn enumLabel(self: *const Schema, allocator: std.mem.Allocator) ![]const u8 {
        const vals = self.enum_values orelse return try allocator.dupe(u8, "");
        var buf = std.ArrayList(u8).init(allocator);
        try buf.appendSlice("enum[");
        for (vals, 0..) |v, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(v.label());
        }
        try buf.append(']');
        return buf.toOwnedSlice();
    }
};

// Top-level container: owns all memory via arena.
pub const SchemaRoot = struct {
    arena: std.heap.ArenaAllocator,
    schema: Schema,
    defs: std.StringHashMap(*Schema),

    // Must be called on a variable that is already at its final address —
    // the defs HashMap stores a pointer to self.arena, so moving the struct
    // after init would leave a dangling pointer.
    pub fn init(self: *SchemaRoot, child_allocator: std.mem.Allocator) void {
        self.arena = std.heap.ArenaAllocator.init(child_allocator);
        self.schema = .{};
        self.defs = std.StringHashMap(*Schema).init(self.arena.allocator());
    }

    pub fn deinit(self: *SchemaRoot) void {
        self.arena.deinit();
    }

    pub fn allocator(self: *SchemaRoot) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn resolve(self: *const SchemaRoot, ref: []const u8) ?*Schema {
        // Handles "#/$defs/Name" and "#/definitions/Name"
        const prefixes = [_][]const u8{ "#/$defs/", "#/definitions/" };
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, ref, prefix)) {
                const name = ref[prefix.len..];
                return self.defs.get(name);
            }
        }
        return null;
    }
};
