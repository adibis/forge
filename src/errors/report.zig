const std = @import("std");
const engine = @import("../validate/engine.zig");

pub fn buildRetryPrompt(
    arena: std.mem.Allocator,
    result: *const engine.ValidationResult,
) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;

    try w.writeAll("The JSON you returned had the following validation errors:\n\n");
    for (result.errors.items) |err| {
        try w.print("- Field '{s}' (path: {s}): {s}\n", .{ err.field, err.path, err.message });
    }
    try w.writeAll("\nPlease return only the corrected JSON with no explanation.");
    return aw.toOwnedSlice();
}

pub const Response = struct {
    status: []const u8,
    input_parseable: bool,
    errors: []const engine.ValidationError,
    warnings: []const []const u8,
    coercions: []const engine.Coercion,
    best_effort: ?std.json.Value,
    retry_prompt: ?[]const u8,
    truncated: bool = false,

    pub fn jsonStringify(self: Response, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("status");          try jw.write(self.status);
        try jw.objectField("input_parseable"); try jw.write(self.input_parseable);

        try jw.objectField("errors");
        try jw.beginArray();
        for (self.errors) |err| try err.jsonStringify(jw);
        try jw.endArray();

        try jw.objectField("warnings");
        try jw.write(self.warnings);

        try jw.objectField("coercions");
        try jw.beginArray();
        for (self.coercions) |c| try c.jsonStringify(jw);
        try jw.endArray();

        if (self.best_effort) |be| {
            try jw.objectField("best_effort");
            try jw.write(be);
        }
        if (self.retry_prompt) |rp| {
            try jw.objectField("retry_prompt");
            try jw.write(rp);
        }
        if (self.truncated) {
            try jw.objectField("truncated");
            try jw.write(true);
        }
        try jw.endObject();
    }
};

pub fn buildResponse(
    arena: std.mem.Allocator,
    vr: *const engine.ValidationResult,
    input_parseable: bool,
    include_retry_prompt: bool,
) !Response {
    const retry: ?[]const u8 = if (include_retry_prompt and !vr.valid)
        try buildRetryPrompt(arena, vr)
    else
        null;

    return .{
        .status = if (vr.valid) "ok" else "error",
        .input_parseable = input_parseable,
        .errors = vr.errors.items,
        .warnings = vr.warnings.items,
        .coercions = vr.coercions.items,
        .best_effort = vr.best_effort,
        .retry_prompt = retry,
    };
}
