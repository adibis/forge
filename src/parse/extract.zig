const std = @import("std");

// Extracts the first complete JSON object or array from text that may contain
// markdown fences, prose before/after, or other LLM decoration.
pub fn extractJson(input: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, input, " \t\r\n");

    // Strip markdown code fences: ```json ... ``` or ``` ... ```
    if (std.mem.startsWith(u8, trimmed, "```")) {
        const fence_end = std.mem.indexOfScalar(u8, trimmed[3..], '\n') orelse return trimmed;
        const after_fence = trimmed[3 + fence_end + 1 ..];
        // Find closing ```
        if (std.mem.lastIndexOf(u8, after_fence, "```")) |close| {
            const inner = std.mem.trim(u8, after_fence[0..close], " \t\r\n");
            if (looksLikeJson(inner)) return inner;
        }
        const inner = std.mem.trim(u8, after_fence, " \t\r\n");
        if (looksLikeJson(inner)) return inner;
    }

    // If the whole trimmed input is valid-looking JSON, use it
    if (looksLikeJson(trimmed)) return trimmed;

    // Scan for first '{' or '[' and try to find the matching closer
    if (findJsonBounds(trimmed)) |bounds| {
        return trimmed[bounds.start..bounds.end];
    }

    return trimmed;
}

const Bounds = struct { start: usize, end: usize };

fn findJsonBounds(text: []const u8) ?Bounds {
    var start: ?usize = null;
    for (text, 0..) |ch, i| {
        if (ch == '{' or ch == '[') {
            start = i;
            break;
        }
    }
    const s = start orelse return null;
    const open = text[s];
    const close: u8 = if (open == '{') '}' else ']';

    var depth: usize = 0;
    var in_string = false;
    var escape = false;
    var i: usize = s;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (ch == '\\' and in_string) {
            escape = true;
            continue;
        }
        if (ch == '"') {
            in_string = !in_string;
            continue;
        }
        if (in_string) continue;
        if (ch == open) depth += 1;
        if (ch == close) {
            depth -= 1;
            if (depth == 0) return .{ .start = s, .end = i + 1 };
        }
    }
    return null;
}

fn looksLikeJson(s: []const u8) bool {
    if (s.len == 0) return false;
    return (s[0] == '{' or s[0] == '[' or s[0] == '"' or
        std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "false") or
        std.mem.eql(u8, s, "null"));
}

test "extract from markdown fence" {
    const input =
        \\Here is the result:
        \\```json
        \\{"name": "Alice", "age": 30}
        \\```
        \\Done.
    ;
    const result = extractJson(input);
    try std.testing.expectEqualStrings("{\"name\": \"Alice\", \"age\": 30}", result);
}

test "extract from prose" {
    const input = "The user data is: {\"name\": \"Bob\"} and nothing else.";
    const result = extractJson(input);
    try std.testing.expectEqualStrings("{\"name\": \"Bob\"}", result);
}

test "plain json passthrough" {
    const input = "{\"x\": 1}";
    const result = extractJson(input);
    try std.testing.expectEqualStrings("{\"x\": 1}", result);
}
