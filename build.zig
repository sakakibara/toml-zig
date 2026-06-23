const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.path("src/toml.zig");

    const toml_module = b.addModule("toml", .{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit and conformance tests");
    test_step.dependOn(&run_tests.step);

    // Generated reference docs (Zig stdlib pattern). Browse
    // `zig-out/docs/index.html` after `zig build docs`.
    const docs_obj = b.addObject(.{
        .name = "toml",
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = .Debug,
        }),
    });
    const docs_install = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate API reference docs to zig-out/docs/");
    docs_step.dependOn(&docs_install.step);

    // Driver binaries (toml-test decoder/encoder, microbenchmarks) need
    // `std.process.Init` and a hosted I/O surface; skip them on
    // freestanding targets where those don't exist. The library itself
    // builds on every target Zig supports.
    if (target.result.os.tag != .freestanding and target.result.os.tag != .other) {
        // toml-test drivers  -  run the upstream `toml-test` tool against
        // these to validate full spec conformance in both directions.
        inline for (.{
            .{ "toml-test-decoder", "tools/toml_test_decoder.zig" },
            .{ "toml-test-encoder", "tools/toml_test_encoder.zig" },
        }) |entry| {
            const exe = b.addExecutable(.{
                .name = entry[0],
                .root_module = b.createModule(.{
                    .root_source_file = b.path(entry[1]),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "toml", .module = toml_module }},
                }),
            });
            b.installArtifact(exe);
        }

        // Microbenchmarks. Always built ReleaseFast for representative timing.
        const bench_exe = b.addExecutable(.{
            .name = "toml-bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("bench/main.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "toml", .module = toml_module }},
            }),
        });
        const run_bench = b.addRunArtifact(bench_exe);
        const bench_step = b.step("bench", "Run microbenchmarks");
        bench_step.dependOn(&run_bench.step);

        // Random-input fuzzer. Sidesteps the broken `zig test --fuzz`
        // mode in 0.16.0 and gives us a portable, scriptable harness.
        const fuzz_exe = b.addExecutable(.{
            .name = "toml-fuzz",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/fuzz.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{.{ .name = "toml", .module = toml_module }},
            }),
        });
        b.installArtifact(fuzz_exe);
        const run_fuzz = b.addRunArtifact(fuzz_exe);
        if (b.args) |args| run_fuzz.addArgs(args);
        const fuzz_step = b.step("fuzz", "Run the random-input fuzzer (pass --iters N etc. via -- )");
        fuzz_step.dependOn(&run_fuzz.step);

        // Runnable examples. `zig build example-NAME` runs each.
        const examples_step = b.step("examples", "Build all examples");
        inline for (.{ "basic", "typed", "edit", "spans", "event_stream" }) |name| {
            const exe = b.addExecutable(.{
                .name = "example-" ++ name,
                .root_module = b.createModule(.{
                    .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{.{ .name = "toml", .module = toml_module }},
                }),
            });
            const install = b.addInstallArtifact(exe, .{});
            examples_step.dependOn(&install.step);

            const run = b.addRunArtifact(exe);
            const run_step = b.step("example-" ++ name, "Run the " ++ name ++ " example");
            run_step.dependOn(&run.step);
        }
    }
}
