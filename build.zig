const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Provider compile-time flags (all default true)
    const include_ollama    = b.option(bool, "ollama",    "Include built-in Ollama provider (default: true)")    orelse true;
    const include_openai    = b.option(bool, "openai",    "Include built-in OpenAI provider (default: true)")    orelse true;
    const include_anthropic = b.option(bool, "anthropiclient", "Include built-in Anthropic provider (default: true)") orelse true;

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "include_ollama",    include_ollama);
    build_opts.addOption(bool, "include_openai",    include_openai);
    build_opts.addOption(bool, "include_anthropic", include_anthropic);

    // Main forge binary
    const exe = b.addExecutable(.{
        .name = "forge",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addOptions("build_options", build_opts);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run forge");
    run_step.dependOn(&run_cmd.step);

    // Test suite
    const test_modules = [_]struct { name: []const u8, path: []const u8 }{
        // standalone modules (no cross-directory imports)
        .{ .name = "schema-ir",     .path = "src/schema/ir.zig" },
        .{ .name = "schema-loader", .path = "src/schema/loader.zig" },
        .{ .name = "parse-extract", .path = "src/parse/extract.zig" },
        .{ .name = "parse-json",    .path = "src/parse/json.zig" },
        .{ .name = "levenshtein",   .path = "src/util/levenshtein.zig" },
        // cross-module tests (engine, generate, errors — all via src/tests.zig)
        .{ .name = "integration",   .path = "src/tests.zig" },
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
