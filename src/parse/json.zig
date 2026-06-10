const std = @import("std");
const extract = @import("extract.zig");

pub const ParseError = error{
    InvalidJson,
    TruncatedJson,
    OutOfMemory,
};

pub const ParseResult = struct {
    value: std.json.Value,
    arena: std.heap.ArenaAllocator,
    was_repaired: bool = false,
    repairs: []const []const u8 = &.{},

    pub fn deinit(self: *ParseResult) void {
        self.arena.deinit();
    }
};

pub fn parseLenient(allocator: std.mem.Allocator, raw: []const u8) ParseError!ParseResult {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var repairs: std.ArrayList([]const u8) = .empty;
    var input = raw;
    var repaired = false;

    const extracted = extract.extractJson(input);
    if (!std.mem.eql(u8, extracted, input)) {
        input = extracted;
        repaired = true;
        try repairs.append(a, "extracted JSON from prose/markdown");
    }

    if (std.mem.startsWith(u8, input, "\xEF\xBB\xBF")) {
        input = input[3..];
        repaired = true;
        try repairs.append(a, "stripped UTF-8 BOM");
    }

    if (tryParse(a, input)) |value| {
        return .{
            .value = value,
            .arena = arena,
            .was_repaired = repaired,
            .repairs = try repairs.toOwnedSlice(a),
        };
    }

    const no_trailing = try repairTrailingCommas(a, input);
    if (!std.mem.eql(u8, no_trailing, input)) {
        repaired = true;
        try repairs.append(a, "removed trailing commas");
        if (tryParse(a, no_trailing)) |value| {
            return .{
                .value = value,
                .arena = arena,
                .was_repaired = repaired,
                .repairs = try repairs.toOwnedSlice(a),
            };
        }
        input = no_trailing;
    }

    const unquoted = try repairSingleQuotes(a, input);
    if (!std.mem.eql(u8, unquoted, input)) {
        repaired = true;
        try repairs.append(a, "converted single-quoted strings to double-quoted");
        if (tryParse(a, unquoted)) |value| {
            return .{
                .value = value,
                .arena = arena,
                .was_repaired = repaired,
                .repairs = try repairs.toOwnedSlice(a),
            };
        }
        input = unquoted;
    }

    if (isTruncated(input)) return error.TruncatedJson;

    return error.InvalidJson;
}

fn tryParse(arena: std.mem.Allocator, input: []const u8) ?std.json.Value {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, input, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .use_last,
    }) catch return null;
    return parsed.value;
}

fn repairTrailingCommas(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch == ',') {
            var j = i + 1;
            while (j < input.len and isWhitespace(input[j])) j += 1;
            if (j < input.len and (input[j] == '}' or input[j] == ']')) {
                i += 1;
                continue;
            }
        }
        try buf.append(arena, ch);
        i += 1;
    }
    return buf.toOwnedSlice(arena);
}

fn repairSingleQuotes(arena: std.mem.Allocator, input: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        const ch = input[i];
        if (ch == '\'') {
            try buf.append(arena, '"');
            i += 1;
            while (i < input.len) {
                const c = input[i];
                if (c == '\\' and i + 1 < input.len and input[i + 1] == '\'') {
                    try buf.append(arena, '\'');
                    i += 2;
                } else if (c == '"') {
                    try buf.appendSlice(arena, "\\\"");
                    i += 1;
                } else if (c == '\'') {
                    try buf.append(arena, '"');
                    i += 1;
                    break;
                } else {
                    try buf.append(arena, c);
                    i += 1;
                }
            }
        } else {
            try buf.append(arena, ch);
            i += 1;
        }
    }
    return buf.toOwnedSlice(arena);
}

fn isTruncated(input: []const u8) bool {
    var depth: isize = 0;
    var in_string = false;
    var escape = false;
    for (input) |ch| {
        if (escape) { escape = false; continue; }
        if (ch == '\\' and in_string) { escape = true; continue; }
        if (ch == '"') { in_string = !in_string; continue; }
        if (in_string) continue;
        if (ch == '{' or ch == '[') depth += 1;
        if (ch == '}' or ch == ']') depth -= 1;
    }
    return depth != 0 or in_string;
}

fn isWhitespace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\r' or ch == '\n';
}

test "parse plain json" {
    var result = try parseLenient(std.testing.allocator, "{\"a\": 1}");
    defer result.deinit();
    try std.testing.expect(result.value == .object);
}

test "repair trailing comma" {
    var result = try parseLenient(std.testing.allocator, "{\"a\": 1,}");
    defer result.deinit();
    try std.testing.expect(result.value == .object);
    try std.testing.expect(result.was_repaired);
}

test "repair single quotes" {
    var result = try parseLenient(std.testing.allocator, "{'key': 'value'}");
    defer result.deinit();
    try std.testing.expect(result.value == .object);
}

test "truncated json" {
    const err = parseLenient(std.testing.allocator, "{\"a\": 1");
    try std.testing.expectError(error.TruncatedJson, err);
}
