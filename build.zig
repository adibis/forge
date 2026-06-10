const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Main forge binary
    const exe = b.addExecutable(.{
        .name = "forge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run forge");
    run_step.dependOn(&run_cmd.step);

    // Provider binaries
    const providers = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "forge-provider-anthropic", .path = "providers/anthropic/main.zig" },
        .{ .name = "forge-provider-openai",    .path = "providers/openai/main.zig" },
        .{ .name = "forge-provider-ollama",    .path = "providers/ollama/main.zig" },
    };
    for (providers) |p| {
        const provider_exe = b.addExecutable(.{
            .name = p.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(p.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        b.installArtifact(provider_exe);
    }

    // Test suite
    const test_modules = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "schema-ir",      .path = "src/schema/ir.zig" },
        .{ .name = "schema-loader",  .path = "src/schema/loader.zig" },
        .{ .name = "parse-extract",  .path = "src/parse/extract.zig" },
        .{ .name = "parse-json",     .path = "src/parse/json.zig" },
        .{ .name = "levenshtein",    .path = "src/util/levenshtein.zig" },
    };
    const test_step = b.step("test", "Run all tests");
    for (test_modules) |m| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(m.path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
