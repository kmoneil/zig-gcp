const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests whose names do not match any filter",
    ) orelse &.{};

    // What the service modules share. It imports nothing but std.
    const core = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mod = b.addModule("pubsub", .{
        .root_source_file = b.path("src/pubsub/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Fuzzing on Zig 0.16.0 needs two things the defaults lack: a test runner
    // that compiles in fuzz mode (see tools/test_runner.zig), and the LLVM
    // backend. The self-hosted x86_64 backend, the Debug default there,
    // emits no coverage instrumentation, so the fuzzer would run blind.
    const fuzz_runner = b.option(
        bool,
        "fuzz-runner",
        "Build the unit tests for `zig build test --fuzz`: patched runner, LLVM backend",
    ) orelse false;

    // Unit, property and fuzz-corpus tests, one run per module. No network: a
    // fake transport and a fake clock drive everything.
    // `zig build test -Dfuzz-runner --fuzz` fuzzes the same tests.
    const unit_modules = [_]struct { []const u8, *std.Build.Module }{ .{ "core", core }, .{ "pubsub", mod } };
    const test_step = b.step("test", "Run unit, property and fuzz-corpus tests");
    for (unit_modules) |entry| {
        const unit_tests = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .filters = test_filters,
            .test_runner = if (fuzz_runner) .{ .path = b.path("tools/test_runner.zig"), .mode = .server } else null,
            .use_llvm = if (fuzz_runner) true else null,
        });
        test_step.dependOn(&b.addRunArtifact(unit_tests).step);
    }

    // Line coverage of the unit tests, measured by kcov, which must be on
    // PATH. Each module's tests run under kcov, and the merged report is
    // installed to zig-out/coverage: index.html, plus coverage.json and
    // cobertura.xml in kcov-merged/.
    const coverage_step = b.step("coverage", "Measure the unit tests' line coverage with kcov");
    const merge = b.addSystemCommand(&.{ "kcov", "--merge" });
    const merged = merge.addOutputDirectoryArg("coverage");
    for (unit_modules) |entry| {
        const coverage_tests = b.addTest(.{
            .name = entry[0],
            .root_module = entry[1],
            .filters = test_filters,
            // kcov maps addresses to lines through DWARF, which LLVM emits in full.
            .use_llvm = true,
        });
        const kcov = b.addSystemCommand(&.{ "kcov", b.fmt("--include-path={s}", .{b.pathFromRoot("src")}) });
        merge.addDirectoryArg(kcov.addOutputDirectoryArg(entry[0]));
        kcov.addArtifactArg(coverage_tests);
        // The tests' progress output is captured: the build shows it only
        // when they fail, which kcov reports by exiting as they did.
        _ = kcov.captureStdErr(.{});
    }
    coverage_step.dependOn(&b.addInstallDirectory(.{
        .source_dir = merged,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    }).step);

    // Integration tests against the emulator (PUBSUB_EMULATOR_HOST) or, when
    // configured, a real project. They skip cleanly when neither is set.
    const integration_tests = b.addTest(.{
        .name = "integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "pubsub", .module = mod }},
        }),
        .filters = test_filters,
    });
    const run_integration = b.addRunArtifact(integration_tests);
    // The result depends on external state, so never serve it from the cache.
    run_integration.has_side_effects = true;
    const integration_step = b.step(
        "test-integration",
        "Run integration tests against PUBSUB_EMULATOR_HOST",
    );
    integration_step.dependOn(&run_integration.step);

    inline for (.{ "publish", "worker" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "pubsub", .module = mod }},
            }),
        });
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        const step = b.step("example-" ++ name, "Run examples/" ++ name ++ ".zig");
        step.dependOn(&run.step);
        // Compile the examples with the unit tests so they never rot.
        test_step.dependOn(&exe.step);
    }

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src", "tests", "examples", "tools" },
        .check = true,
    });
    b.step("fmt", "Check formatting (zig fmt --check)").dependOn(&fmt.step);
}
