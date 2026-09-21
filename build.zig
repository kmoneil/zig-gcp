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

    // Credentials for the service modules. It imports core, never a service.
    const auth = b.addModule("auth", .{
        .root_source_file = b.path("src/auth/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    const mod = b.addModule("pubsub", .{
        .root_source_file = b.path("src/pubsub/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "core", .module = core }},
    });

    // Secrets. It imports core, never a service.
    const secret_manager = b.addModule("secret_manager", .{
        .root_source_file = b.path("src/secret_manager/root.zig"),
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
    const unit_modules = [_]struct { []const u8, *std.Build.Module }{
        .{ "core", core },
        .{ "auth", auth },
        .{ "pubsub", mod },
        .{ "secret_manager", secret_manager },
    };
    // The nightly fuzz job runs one module per job, so each gets the whole
    // time budget: `--fuzz=N` fuzzes every property N times, and the
    // properties of all the modules together outgrew one job.
    const only_module = b.option(
        []const u8,
        "module",
        "Run only this module's unit tests: core, auth, pubsub or secret_manager",
    );
    if (only_module) |name| {
        for (unit_modules) |entry| {
            if (std.mem.eql(u8, entry[0], name)) break;
        } else std.process.fatal("-Dmodule={s} names no module; use core, auth, pubsub or secret_manager", .{name});
    }
    const test_step = b.step("test", "Run unit, property and fuzz-corpus tests");
    for (unit_modules) |entry| {
        if (only_module) |name| if (!std.mem.eql(u8, entry[0], name)) continue;
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
        "Run integration tests against PUBSUB_EMULATOR_HOST, or Google when configured",
    );
    integration_step.dependOn(&run_integration.step);

    // auth against Google's token endpoint, when AUTH_TEST_CREDENTIALS names
    // a credentials file. They skip otherwise.
    const auth_integration_tests = b.addTest(.{
        .name = "auth-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/auth_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "auth", .module = auth },
                .{ .name = "pubsub", .module = mod },
            },
        }),
        .filters = test_filters,
    });
    const run_auth_integration = b.addRunArtifact(auth_integration_tests);
    run_auth_integration.has_side_effects = true;
    integration_step.dependOn(&run_auth_integration.step);

    // Secret Manager against a real project: there is no emulator, so these
    // need GCP_TEST_PROJECT and GCP_TEST_TOKEN, and skip without them. They
    // are a step of their own, never part of `test-integration`, because
    // they need cloud credentials that CI does not have.
    const gcp_tests = b.addTest(.{
        .name = "secret-manager-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/secret_manager_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "secret_manager", .module = secret_manager }},
        }),
        .filters = test_filters,
    });
    const run_gcp = b.addRunArtifact(gcp_tests);
    run_gcp.has_side_effects = true;
    b.step(
        "test-integration-gcp",
        "Run Secret Manager tests against the project GCP_TEST_PROJECT names",
    ).dependOn(&run_gcp.step);

    // Fault injection: the full stack against the emulator, through a proxy
    // that drops, cuts, delays and rewrites responses. Skips without
    // PUBSUB_EMULATOR_HOST; never runs against production.
    const fault_tests = b.addTest(.{
        .name = "fault-injection",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/fault_injection.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "pubsub", .module = mod },
                .{ .name = "core", .module = core },
            },
        }),
        .filters = test_filters,
    });
    const run_fault = b.addRunArtifact(fault_tests);
    run_fault.has_side_effects = true;
    integration_step.dependOn(&run_fault.step);

    inline for (.{ "publish", "worker", "whoami", "secret" }) |name| {
        // whoami and secret pick their own credentials.
        const imports: []const std.Build.Module.Import = if (std.mem.eql(u8, name, "whoami"))
            &.{ .{ .name = "pubsub", .module = mod }, .{ .name = "auth", .module = auth } }
        else if (std.mem.eql(u8, name, "secret"))
            &.{ .{ .name = "secret_manager", .module = secret_manager }, .{ .name = "auth", .module = auth } }
        else
            &.{.{ .name = "pubsub", .module = mod }};
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = imports,
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
