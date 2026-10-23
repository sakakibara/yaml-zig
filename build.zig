const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.path("src/yaml.zig");

    const yaml_module = b.addModule("yaml", .{
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

    // Conformance suite over the vendored yaml-test-suite corpus. Cases are
    // discovered at test time via std.fs, so the corpus root is passed as
    // an absolute path on the build host; the suite then works from any cwd
    // there (not from a test binary moved to another machine).
    const conformance_options = b.addOptions();
    conformance_options.addOption([]const u8, "corpus_path", fromRoot(b, "tests/corpus"));

    const conformance_module = b.createModule(.{
        .root_source_file = b.path("src/conformance.zig"),
        .target = target,
        .optimize = optimize,
    });
    conformance_module.addOptions("conformance_options", conformance_options);

    const conformance_tests = b.addTest(.{ .root_module = conformance_module });
    const run_conformance = b.addRunArtifact(conformance_tests);
    test_step.dependOn(&run_conformance.step);

    // KYAML golden files. The directory is an absolute host path, same as
    // the conformance corpus, so `zig build test` does not depend on cwd.
    const kyaml_fixture_options = b.addOptions();
    kyaml_fixture_options.addOption([]const u8, "fixtures_path", fromRoot(b, "tests/kyaml"));

    const kyaml_fixture_module = b.createModule(.{
        .root_source_file = b.path("src/kyaml_fixtures.zig"),
        .target = target,
        .optimize = optimize,
    });
    kyaml_fixture_module.addOptions("kyaml_fixture_options", kyaml_fixture_options);

    const kyaml_fixture_tests = b.addTest(.{ .root_module = kyaml_fixture_module });
    const run_kyaml_fixtures = b.addRunArtifact(kyaml_fixture_tests);
    test_step.dependOn(&run_kyaml_fixtures.step);

    // Deterministic property/round-trip battery over Document's editor.
    const document_property_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/document_property.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_document_property = b.addRunArtifact(document_property_tests);
    test_step.dependOn(&run_document_property.step);

    // Microbenchmarks. Always built ReleaseFast for representative timing.
    // Fixture files are discovered at run time via the injected absolute
    // path, same pattern as the conformance corpus above. Excluded from
    // `zig build test`.
    const bench_options = b.addOptions();
    bench_options.addOption([]const u8, "fixtures_path", fromRoot(b, "bench/fixtures"));

    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &.{.{ .name = "yaml", .module = yaml_module }},
    });
    bench_module.addOptions("bench_options", bench_options);

    const bench_exe = b.addExecutable(.{
        .name = "yaml-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run microbenchmarks");
    bench_step.dependOn(&run_bench.step);

    // Random-input fuzzer: a portable, scriptable harness that does not
    // depend on `zig test --fuzz`. Excluded from `zig build test`.
    const fuzz_exe = b.addExecutable(.{
        .name = "yaml-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz/main.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "yaml", .module = yaml_module }},
        }),
    });
    b.installArtifact(fuzz_exe);
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.addPassthruArgs();
    const fuzz_step = b.step("fuzz", "Run the random-input fuzzer (zig build fuzz -- [seed] [iterations])");
    fuzz_step.dependOn(&run_fuzz.step);

    // Runnable examples. `zig build examples` compiles all of them;
    // `zig build example-<name>` compiles and runs that one.
    const example_names = [_][]const u8{ "basic", "typed", "stream", "emit", "spans", "edit", "event_stream" };
    const examples_step = b.step("examples", "Build all examples");
    for (example_names) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(b.fmt("examples/{s}.zig", .{name})),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "yaml", .module = yaml_module }},
            }),
        });
        examples_step.dependOn(&exe.step);

        const run = b.addRunArtifact(exe);
        const run_step = b.step(
            b.fmt("example-{s}", .{name}),
            b.fmt("Build and run examples/{s}.zig", .{name}),
        );
        run_step.dependOn(&run.step);
    }

    // Generated reference documentation. `zig build docs` emits
    // zig-out/docs/index.html from the library's public API.
    const docs_obj = b.addObject(.{
        .name = "yaml-docs",
        .root_module = b.createModule(.{
            .root_source_file = root,
            .target = target,
            .optimize = optimize,
        }),
    });
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_obj.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Generate reference documentation into zig-out/docs/");
    docs_step.dependOn(&install_docs.step);
}

/// Absolute path of `sub_path` under the directory holding build.zig.
fn fromRoot(b: *std.Build, sub_path: []const u8) []const u8 {
    const cwd = std.process.currentPathAlloc(b.graph.io, b.allocator) catch @panic("cannot read the current directory");
    return b.pathResolve(&.{ cwd, b.root.root_dir.path orelse ".", b.root.sub_path, sub_path });
}
