const std = @import("std");

pub fn jsonEscape(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        switch (ch) {
            '"'  => try buf.appendSlice(arena, "\\\""),
            '\\' => try buf.appendSlice(arena, "\\\\"),
            '\n' => try buf.appendSlice(arena, "\\n"),
            '\r' => try buf.appendSlice(arena, "\\r"),
            '\t' => try buf.appendSlice(arena, "\\t"),
            else => try buf.append(arena, ch),
        }
    }
    return buf.toOwnedSlice(arena);
}
