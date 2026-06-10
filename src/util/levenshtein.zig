const std = @import("std");

pub fn distance(allocator: std.mem.Allocator, a: []const u8, b: []const u8) !usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;

    // Two-row DP to save memory
    const cols = b.len + 1;
    var prev = try allocator.alloc(usize, cols);
    defer allocator.free(prev);
    var curr = try allocator.alloc(usize, cols);
    defer allocator.free(curr);

    for (0..cols) |j| prev[j] = j;

    for (0..a.len) |i| {
        curr[0] = i + 1;
        for (0..b.len) |j| {
            const cost: usize = if (a[i] == b[j]) 0 else 1;
            curr[j + 1] = @min(
                curr[j] + 1,
                @min(prev[j + 1] + 1, prev[j] + cost),
            );
        }
        @memcpy(prev, curr);
    }

    return prev[b.len];
}

// Returns the closest enum string within max_distance, or null.
pub fn closest(
    allocator: std.mem.Allocator,
    needle: []const u8,
    haystack: []const []const u8,
    max_distance: usize,
) !?[]const u8 {
    var best: ?[]const u8 = null;
    var best_dist: usize = max_distance + 1;

    for (haystack) |candidate| {
        // Case-insensitive comparison first
        if (eqlFold(needle, candidate)) return candidate;

        const d = try distance(allocator, needle, candidate);
        if (d < best_dist) {
            best_dist = d;
            best = candidate;
        }
    }
    if (best_dist <= max_distance) return best;
    return null;
}

fn eqlFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "levenshtein basic" {
    const d = try distance(std.testing.allocator, "Active", "active");
    try std.testing.expectEqual(@as(usize, 1), d);
}

test "closest enum" {
    const candidates = [_][]const u8{ "active", "inactive", "pending" };
    const result = try closest(std.testing.allocator, "Active", &candidates, 2);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("active", result.?);
}

test "distance identical strings" {
    const d = try distance(std.testing.allocator, "hello", "hello");
    try std.testing.expectEqual(@as(usize, 0), d);
}

test "distance empty strings" {
    try std.testing.expectEqual(@as(usize, 3), try distance(std.testing.allocator, "abc", ""));
    try std.testing.expectEqual(@as(usize, 3), try distance(std.testing.allocator, "", "abc"));
    try std.testing.expectEqual(@as(usize, 0), try distance(std.testing.allocator, "", ""));
}

test "distance single operations" {
    try std.testing.expectEqual(@as(usize, 1), try distance(std.testing.allocator, "cat", "bat"));
    try std.testing.expectEqual(@as(usize, 1), try distance(std.testing.allocator, "cat", "cats"));
    try std.testing.expectEqual(@as(usize, 1), try distance(std.testing.allocator, "cats", "cat"));
}

test "closest exact case-insensitive match wins over levenshtein" {
    const candidates = [_][]const u8{ "ACTIVE", "active", "pending" };
    const result = try closest(std.testing.allocator, "ACTIVE", &candidates, 5);
    try std.testing.expectEqualStrings("ACTIVE", result.?);
}

test "closest returns null when all too far" {
    const candidates = [_][]const u8{ "cat", "dog" };
    const result = try closest(std.testing.allocator, "elephant", &candidates, 2);
    try std.testing.expect(result == null);
}
