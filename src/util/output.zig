const std = @import("std");

pub fn toJsonString(value: anytype, allocator: std.mem.Allocator) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try std.json.stringify(value, .{}, buf.writer(allocator));
    return buf.toOwnedSlice(allocator);
}
