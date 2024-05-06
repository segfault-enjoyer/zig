const std = @import("std");

pub fn build(b: *std.Build) void {
    const host = b.standardTargetOptions(.{
        .whitelist = &.{
            .{
                .cpu_arch = .x86_64,
                .cpu_model = .baseline,
                .os_tag = .linux,
                .abi = .musl,
            },
            .{
                .cpu_arch = .aarch64,
                .cpu_model = .baseline,
                .os_tag = .linux,
                .abi = .musl,
            },
            .{
                .cpu_arch = .x86_64,
                .cpu_model = .baseline,
                .os_tag = .macos,
                .abi = .none,
            },
            .{
                .cpu_arch = .aarch64,
                .cpu_model = .baseline,
                .os_tag = .macos,
                .abi = .none,
            },
            .{
                .cpu_arch = .x86_64,
                .cpu_model = .baseline,
                .os_tag = .windows,
                .abi = .gnu,
            },
            .{
                .cpu_arch = .aarch64,
                .cpu_model = .baseline,
                .os_tag = .windows,
                .abi = .gnu,
            },
        },
        .default_target = .{
            .cpu_arch = b.graph.host.result.cpu.arch,
            .cpu_model = .baseline,
            .os_tag = b.graph.host.result.os.tag,
            .abi = if (b.graph.host.result.os.tag == .windows)
                .gnu
            else if (b.graph.host.result.isDarwin())
                .none
            else
                .musl,
        },
    });
    const host_triple = host.result.linuxTriple(b.allocator) catch @panic("OOM");
    const host_cpu = host.query.serializeCpuAlloc(b.allocator) catch @panic("OOM");
    const host_exe_file_ext = host.result.exeFileExt();
    const build_type = b.option(enum { Debug, Release }, "build-type", "CMake build type") orelse .Debug;
    const tool_optimize = b.option(
        std.builtin.OptimizeMode,
        "tool-optimize",
        "Prioritize performance, safety, or binary size for build tools",
    ) orelse .ReleaseSafe;

    const binaryen_lazy_dep = if (host.result.cpu.arch != .aarch64 or host.result.os.tag != .windows)
        b.lazyDependency(b.fmt("binaryen-{s}", .{host_triple}), .{})
    else
        null;
    const cmake_lazy_dep = b.lazyDependency(b.fmt("cmake-{s}", .{host_triple}), .{});
    const ninja_lazy_dep = b.lazyDependency(b.fmt("ninja-{s}", .{host_triple}), .{});
    const qemu_lazy_dep = if (host.result.cpu.arch == .x86_64 and host.result.os.tag == .linux)
        b.lazyDependency(b.fmt("qemu-{s}", .{host_triple}), .{})
    else
        null;
    const tidy_lazy_dep = b.lazyDependency(b.fmt("tidy-{s}", .{host_triple}), .{});
    const wasmtime_lazy_dep = if (host.result.cpu.arch != .aarch64 or host.result.os.tag != .windows)
        b.lazyDependency(b.fmt("wasmtime-{s}", .{host_triple}), .{})
    else
        null;
    const zig_llvm_lld_clang_lazy_dep =
        b.lazyDependency(b.fmt("zig+llvm+lld+clang-{s}", .{host_triple}), .{});

    const cmake_dep = cmake_lazy_dep orelse return;
    const ninja_dep = ninja_lazy_dep orelse return;
    const tidy_dep = tidy_lazy_dep orelse return;
    const zig_llvm_lld_clang_dep = zig_llvm_lld_clang_lazy_dep orelse return;

    const cmake_exe = cmake_dep.path(b.fmt("{s}bin/cmake{s}", .{
        if (host.result.isDarwin()) "CMake.app/Contents/" else "",
        host_exe_file_ext,
    }));
    const ninja_exe = ninja_dep.path(b.fmt("ninja{s}", .{host_exe_file_ext}));
    const tidy_exe = tidy_dep.path(b.fmt("bin/tidy{s}", .{host_exe_file_ext}));

    const build_file = b.path("../build.zig");
    const local_cache_dir = b.path("zig-local-cache");
    const global_cache_dir = b.path("zig-global-cache");

    const clean_step = b.step("clean", "Cleanup previous CI runs");
    clean_step.dependOn(&b.addRemoveDirTree(b.cache_root.path orelse ".").step);
    clean_step.dependOn(&b.addRemoveDirTree(b.pathFromRoot("../zig-cache")).step);
    clean_step.dependOn(&b.addRemoveDirTree(local_cache_dir.getPath(b)).step);
    clean_step.dependOn(&b.addRemoveDirTree(global_cache_dir.getPath(b)).step);

    const run_exe = b.addExecutable(.{
        .name = "run",
        .root_source_file = b.path("run.zig"),
        .target = host,
        .optimize = tool_optimize,
        .strip = false,
    });
    run_exe.step.max_rss = 231714816;

    const run_chmod_step = if (host.result.isDarwin()) steps: {
        const chmod_exe = b.addExecutable(.{
            .name = "chmod",
            .root_source_file = b.path("chmod.zig"),
            .target = host,
            .optimize = tool_optimize,
            .strip = false,
        });
        chmod_exe.step.max_rss = 1;

        const run_chmod = b.addRunArtifact(chmod_exe);
        if (binaryen_lazy_dep) |binaryen_dep| for ([_][]const u8{
            "binaryen-unittests",
            "wasm2js",
            "wasm-as",
            "wasm-ctor-eval",
            "wasm-dis",
            "wasm-emscripten-finalize",
            "wasm-fuzz-lattices",
            "wasm-fuzz-types",
            "wasm-merge",
            "wasm-metadce",
            "wasm-opt",
            "wasm-reduce",
            "wasm-shell",
            "wasm-split",
        }) |exe| run_chmod.addFileArg(binaryen_dep.path(b.fmt("bin/{s}{s}", .{ exe, host_exe_file_ext })));
        run_chmod.addFileArg(cmake_exe);
        run_chmod.addFileArg(ninja_exe);
        if (qemu_lazy_dep) |qemu_dep| for ([_][]const u8{
            "cris",
            "mips64el",
            "ppc64",
            "loongarch64",
            "sparc",
            "aarch64",
            "sparc64",
            "alpha",
            "sparc32plus",
            "sh4",
            "hexagon",
            "xtensaeb",
            "riscv64",
            "aarch64_be",
            "i386",
            "armeb",
            "mips",
            "s390x",
            "mips64",
            "ppc64le",
            "mipsel",
            "x86_64",
            "arm",
            "hppa",
            "ppc",
            "or1k",
            "xtensa",
            "microblaze",
            "riscv32",
            "m68k",
            "sh4eb",
            "mipsn32el",
            "nios2",
            "microblazeel",
            "mipsn32",
        }) |qemu_target| run_chmod.addFileArg(qemu_dep.path(b.fmt("bin/qemu-{s}{s}", .{ qemu_target, host_exe_file_ext })));
        run_chmod.addFileArg(tidy_exe);
        if (wasmtime_lazy_dep) |wasmtime_dep| run_chmod.addFileArg(wasmtime_dep.path(b.fmt("wasmtime{s}", .{host_exe_file_ext})));
        run_chmod.addFileArg(zig_llvm_lld_clang_dep.path(b.fmt("bin/zig{s}", .{host_exe_file_ext})));
        run_chmod.step.max_rss = 2;

        break :steps &run_chmod.step;
    } else null;

    const build_cc_stage2_step = if (b.option(
        []const u8,
        "cc",
        "System C compiler to use for cc bootstrap",
    )) |cc| steps: {
        const cc_bootstrap_step = b.step("cc-bootstrap", "Test cc bootstrap");

        const build_bootstrap = b.addSystemCommand(&.{ cc, "-o" });
        const bootstrap_exe = build_bootstrap.addOutputFileArg("bootstrap");
        build_bootstrap.addArgs(&.{ "-MD", "-MF" });
        _ = build_bootstrap.addDepFileOutputArg("bootstrap.d");
        build_bootstrap.addFileArg(b.path("../bootstrap.c"));
        build_bootstrap.setCwd(b.path(".."));
        build_bootstrap.step.max_rss = 29884416;

        const build_stage2 = std.Build.Step.Run.create(b, "build cc bootstrap");
        build_stage2.addArtifactArg(run_exe);
        build_stage2.addArgs(&.{
            "$0",
            "--delete",
            "zig-wasm2c",
            "zig1.c",
            "zig1",
            "config.zig",
            "zig2.c",
            "compiler_rt.c",
            "--rename",
            "zig2",
            "$1",
            "--",
        });
        build_stage2.addFileArg(bootstrap_exe);
        const stage2_exe = build_stage2.addOutputFileArg("zig2");
        build_stage2.setEnvironmentVariable("CC", cc);
        build_stage2.setCwd(b.path(".."));
        build_stage2.step.max_rss = 4836036608;

        const build_stage3 = std.Build.Step.Run.create(b, "build cc bootstrap");
        build_stage3.addFileArg(stage2_exe);
        build_stage3.addArg("build");
        build_stage3.addArg("--build-file");
        build_stage3.addFileArg(build_file);
        build_stage3.addArg("--prefix");
        const stage3_out = build_stage3.addOutputDirectoryArg("stage3");
        build_stage3.addArg("--cache-dir");
        build_stage3.addDirectoryArg(local_cache_dir);
        build_stage3.addArg("--global-cache-dir");
        build_stage3.addDirectoryArg(global_cache_dir);
        build_stage3.addArg("-Dno-lib");
        build_stage3.step.max_rss = 3;

        const run_tests = std.Build.Step.Run.create(b, "test cc bootstrap (stage3)");
        run_tests.addFileArg(stage3_out.path(b, b.fmt("bin/zig{s}", .{host_exe_file_ext})));
        run_tests.addArg("test");
        run_tests.addFileArg(b.path("../test/behavior.zig"));
        run_tests.step.max_rss = 4;
        cc_bootstrap_step.dependOn(&run_tests.step);

        break :steps &build_stage2.step;
    } else null;

    {
        const cmake_bootstrap_step = b.step("cmake-bootstrap", "test cmake bootstrap");

        const build_stage3 = std.Build.Step.Run.create(b, "build cmake bootstrap");
        build_stage3.addArtifactArg(run_exe);
        build_stage3.addArgs(&.{
            "$4",
            "-GNinja",
            "-S..",
            "-B$6",
            "-DCMAKE_MAKE_PROGRAM=$5",
            "-DCMAKE_BUILD_TYPE=$2",
            "-DCMAKE_PREFIX_PATH=$7",
            "-DCMAKE_C_COMPILER=$7/bin/zig$3;cc;-target;$0;-mcpu=$1",
            "-DCMAKE_CXX_COMPILER=$7/bin/zig$3;c++;-target;$0;-mcpu=$1",
            "-DCMAKE_AR=$7/bin/zig$3",
            "-DZIG_AR_WORKAROUND=ON",
            "-DZIG_TARGET_TRIPLE=$0",
            "-DZIG_TARGET_MCPU=$1",
            "-DZIG_STATIC=ON",
            "-DZIG_STATIC_CURSES=OFF",
            "-DZIG_NO_LIB=ON",
            "--then",
            "$5",
            "-C",
            "$6",
            "install",
            "--",
            host_triple,
            host_cpu,
            @tagName(build_type),
            host_exe_file_ext,
        });
        build_stage3.addFileArg(cmake_exe);
        build_stage3.addFileArg(ninja_exe);
        const stage3_exe = build_stage3.addOutputDirectoryArg("build")
            .path(b, b.fmt("stage3/bin/zig{s}", .{host_exe_file_ext}));
        build_stage3.addDirectoryArg(zig_llvm_lld_clang_dep.path(""));
        build_stage3.addFileInput(b.path("../stage1/zig1.wasm"));
        build_stage3.addFileInput(b.path("../stage1/zig.h"));
        build_stage3.step.max_rss = 9798598656;
        if (run_chmod_step) |step| build_stage3.step.dependOn(step);

        const run_tests = std.Build.Step.Run.create(b, "test cmake bootstrap (stage3)");
        run_tests.addArtifactArg(run_exe);
        run_tests.addArgs(&.{
            "$0",
            "build",
            "$--build-file",
            "$1",
            "$--prefix",
            "$2",
            "$--cache-dir",
            "$3",
            "$--global-cache-dir",
            "$4",
            "test-fmt",
            "test",
            "docs",
            "-Dstatic-llvm",
            "$--search-prefix",
            "$5",
        });
        if (host.result.isDarwin()) run_tests.addArg("-Denable-macos-sdk");
        if (host.result.os.tag == .windows) run_tests.addArgs(&.{"-Denable-symlinks-windows"});
        if (b.option(bool, "skip-non-native", "Skip non-native tests") orelse false)
            run_tests.addArg("-Dskip-non-native");
        if (qemu_lazy_dep) |_| run_tests.addArg("-fqemu");
        if (wasmtime_lazy_dep) |_| run_tests.addArg("-fwasmtime");
        run_tests.addArg("--path");
        {
            var index: usize = 6;
            for ([_]?*std.Build.Dependency{
                qemu_lazy_dep,
                wasmtime_lazy_dep,
            }) |mabye_dep| if (mabye_dep) |_| {
                run_tests.addArg(b.fmt("${d}", .{index}));
                index += 1;
            };
        }
        run_tests.addArg("--");
        run_tests.addFileArg(stage3_exe);
        run_tests.addFileArg(build_file);
        const tests_install = run_tests.addOutputDirectoryArg("tests");
        run_tests.addDirectoryArg(local_cache_dir);
        run_tests.addDirectoryArg(global_cache_dir);
        run_tests.addDirectoryArg(zig_llvm_lld_clang_dep.path(""));
        if (qemu_lazy_dep) |qemu_dep| run_tests.addDirectoryArg(qemu_dep.path("bin"));
        if (wasmtime_lazy_dep) |wasmtime_dep| run_tests.addDirectoryArg(wasmtime_dep.path(""));
        run_tests.step.max_rss = 5;
        if (run_chmod_step) |step| run_tests.step.dependOn(step);
        cmake_bootstrap_step.dependOn(&run_tests.step);

        for (b.option([]const []const u8, "extra-target", "Extra targets to build") orelse &.{}) |build_target| {
            const build_stage4 = std.Build.Step.Run.create(b, "build");
            build_stage4.addFileArg(stage3_exe);
            build_stage4.addArgs(&.{
                "build",
                "--build-file",
            });
            build_stage4.addFileArg(build_file);
            build_stage4.addArg("--prefix");
            _ = build_stage4.addOutputDirectoryArg(b.fmt("stage4-{s}", .{build_target}));
            build_stage4.addArg("--cache-dir");
            build_stage4.addDirectoryArg(local_cache_dir);
            build_stage4.addArg("--global-cache-dir");
            build_stage4.addDirectoryArg(global_cache_dir);
            build_stage4.addArgs(&.{ b.fmt("-Dtarget={s}", .{build_target}), "-Dno-lib" });
            build_stage4.step.max_rss = 6;
            cmake_bootstrap_step.dependOn(&build_stage4.step);
        }

        {
            const tidy_step = b.step("tidy", "Look for HTML errors");

            const run_tidy = std.Build.Step.Run.create(b, "run tidy");
            run_tidy.addFileArg(tidy_exe);
            run_tidy.addArgs(&.{ "--drop-empty-elements", "no", "-quiet", "-errors" });
            run_tidy.addFileArg(tests_install.path(b, "doc/langref.html"));
            run_tidy.step.max_rss = 7;
            if (run_chmod_step) |step| run_tidy.step.dependOn(step);
            tidy_step.dependOn(&run_tidy.step);
        }

        switch (build_type) {
            .Debug => {},
            .Release => {
                const reproducible_step = b.step("reproducible", "Ensure that stage3 and stage4 are byte-for-byte identical");

                const run_stage3_version = std.Build.Step.Run.create(b, "get stage3 version");
                run_stage3_version.addFileArg(stage3_exe);
                run_stage3_version.addArg("version");
                const stage3_version = run_stage3_version.captureStdOut();
                run_stage3_version.step.max_rss = 8;

                const build_stage4 = b.addRunArtifact(run_exe);
                build_stage4.addArgs(&.{
                    "$2",
                    "build",
                    "$--build-file",
                    "$3",
                    "$--prefix",
                    "$4",
                    "$--cache-dir",
                    "$5",
                    "$--global-cache-dir",
                    "$6",
                    "-Denable-llvm",
                    "-Dno-lib",
                    "-Doptimize=ReleaseFast",
                    "-Dstrip",
                    "-Dtarget=$0",
                    "-Dcpu=$1",
                    "-Duse-zig-libcxx",
                    "-Dversion-string=@7",
                    "--",
                    host_triple,
                    host_cpu,
                });
                build_stage4.addFileArg(stage3_exe);
                build_stage4.addFileArg(build_file);
                const stage4_prefix = build_stage4.addOutputDirectoryArg("stage4");
                build_stage4.addDirectoryArg(local_cache_dir);
                build_stage4.addDirectoryArg(global_cache_dir);
                build_stage4.addFileArg(stage3_version);
                build_stage4.step.max_rss = 9;

                const cmp_exe = b.addExecutable(.{
                    .name = "cmp",
                    .root_source_file = b.path("cmp.zig"),
                    .target = host,
                    .optimize = tool_optimize,
                    .strip = false,
                });
                cmp_exe.step.max_rss = 219934720;

                const run_cmp = std.Build.Step.Run.create(b, "Check stage3 and stage4 are byte-for-byte identical");
                run_cmp.addArtifactArg(cmp_exe);
                run_cmp.addFileArg(stage3_exe);
                run_cmp.addFileArg(stage4_prefix.path(b, b.fmt("bin/zig{s}", .{host_exe_file_ext})));
                run_cmp.step.max_rss = 10;
                reproducible_step.dependOn(&run_cmp.step);
            },
        }

        if (binaryen_lazy_dep) |binaryen_dep| {
            const update_stage1_step = b.step("update-stage1", "Test bootstrap after updating the stage1 wasm binary");

            const update_zig1 = std.Build.Step.Run.create(b, "update zig1");
            update_zig1.addArtifactArg(run_exe);
            update_zig1.addArgs(&.{
                "$0",
                "build",
                "$--build-file",
                "$1",
                "$--cache-dir",
                "$2",
                "$--global-cache-dir",
                "$3",
                "update-zig1",
                "--path",
                "$4",
                "--",
            });
            update_zig1.addFileArg(stage3_exe);
            update_zig1.addFileArg(build_file);
            update_zig1.addDirectoryArg(local_cache_dir);
            update_zig1.addDirectoryArg(global_cache_dir);
            update_zig1.addDirectoryArg(binaryen_dep.path("bin"));
            update_zig1.step.max_rss = 11;
            if (run_chmod_step) |step| update_zig1.step.dependOn(step);
            // Clobbering stage1 depends on all steps that use the original stage1
            if (build_cc_stage2_step) |step| update_zig1.step.dependOn(step);
            update_zig1.step.dependOn(&build_stage3.step);

            const build_updated_stage3 = std.Build.Step.Run.create(b, "build updated cmake bootstrap");
            build_updated_stage3.addArtifactArg(run_exe);
            build_updated_stage3.addArgs(&.{
                "$4",
                "-GNinja",
                "-S..",
                "-B$6",
                "-DCMAKE_MAKE_PROGRAM=$5",
                "-DCMAKE_BUILD_TYPE=$2",
                "-DCMAKE_PREFIX_PATH=$7",
                "-DCMAKE_C_COMPILER=$7/bin/zig$3;cc;-target;$0;-mcpu=$1",
                "-DCMAKE_CXX_COMPILER=$7/bin/zig$3;c++;-target;$0;-mcpu=$1",
                "-DCMAKE_AR=$7/bin/zig$3",
                "-DZIG_AR_WORKAROUND=ON",
                "-DZIG_TARGET_TRIPLE=$0",
                "-DZIG_TARGET_MCPU=$1",
                "-DZIG_STATIC=ON",
                "-DZIG_STATIC_CURSES=OFF",
                "-DZIG_NO_LIB=ON",
                "--then",
                "$5",
                "-C",
                "$6",
                "install",
                "--",
                host_triple,
                host_cpu,
                @tagName(build_type),
                host_exe_file_ext,
            });
            build_updated_stage3.addFileArg(cmake_exe);
            build_updated_stage3.addFileArg(ninja_exe);
            const updated_stage3_exe = build_updated_stage3.addOutputDirectoryArg("build")
                .path(b, b.fmt("stage3/bin/zig{s}", .{host_exe_file_ext}));
            build_updated_stage3.addDirectoryArg(zig_llvm_lld_clang_dep.path(""));
            build_updated_stage3.addFileInput(b.path("../stage1/zig1.wasm"));
            build_updated_stage3.addFileInput(b.path("../stage1/zig.h"));
            build_updated_stage3.step.max_rss = 12;
            if (run_chmod_step) |step| build_updated_stage3.step.dependOn(step);
            build_updated_stage3.step.dependOn(&update_zig1.step);

            const build_updated_stage4 = b.addRunArtifact(run_exe);
            build_updated_stage4.addArgs(&.{
                "$2",
                "build",
                "$--build-file",
                "$3",
                "$--prefix",
                "$4",
                "$--cache-dir",
                "$5",
                "$--global-cache-dir",
                "$6",
                "-Denable-llvm",
                "-Dno-lib",
                "-Doptimize=ReleaseFast",
                "-Dstrip",
                "-Dtarget=$0",
                "-Dcpu=$1",
                "-Duse-zig-libcxx",
                "--",
                host_triple,
                host_cpu,
            });
            build_updated_stage4.addFileArg(updated_stage3_exe);
            build_updated_stage4.addFileArg(build_file);
            const updated_stage4_prefix = build_updated_stage4.addOutputDirectoryArg("stage4");
            build_updated_stage4.addDirectoryArg(local_cache_dir);
            build_updated_stage4.addDirectoryArg(global_cache_dir);
            build_updated_stage4.step.max_rss = 13;

            const run_tests_with_updated_stage4 = std.Build.Step.Run.create(b, "test updated cmake bootstrap (stage3)");
            run_tests_with_updated_stage4.addFileArg(updated_stage4_prefix.path(b, b.fmt("bin/zig{s}", .{host_exe_file_ext})));
            run_tests_with_updated_stage4.addArg("test");
            run_tests_with_updated_stage4.addFileArg(b.path("../test/behavior.zig"));
            run_tests_with_updated_stage4.step.max_rss = 14;
            update_stage1_step.dependOn(&run_tests_with_updated_stage4.step);
        }
    }
}
