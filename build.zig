const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Skip tests whose names do not match any filter",
    ) orelse &.{};

    const mod = b.addModule("pubsub", .{
        .root_source_file = b.path("src/pubsub/root.zig"),
        .target = target,
        .optimize = optimize,
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

    // Unit, property and fuzz-corpus tests. No network: a fake transport and a
    // fake clock drive everything. `zig build test -Dfuzz-runner --fuzz`
    // fuzzes the same tests.
    const unit_tests = b.addTest(.{
        .root_module = mod,
        .filters = test_filters,
        .test_runner = if (fuzz_runner) .{ .path = b.path("tools/test_runner.zig"), .mode = .server } else null,
        .use_llvm = if (fuzz_runner) true else null,
    });
    const test_step = b.step("test", "Run unit, property and fuzz-corpus tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);

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
