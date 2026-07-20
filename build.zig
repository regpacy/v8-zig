const std = @import("std");


pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("v8_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .link_libcpp = true,
    });

    const exe = b.addExecutable(.{
        .name = "v8_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "v8_zig", .module = mod },
            },
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    mod.linkSystemLibrary("stdc++", .{});

    // Pulls the prebuilt V8 headers/static lib from GitHub releases. These
    // are written into Zig's own build cache via addOutputDirectoryArg /
    // addOutputFileArg (NOT into a path inside this package's own source
    // tree) for two reasons:
    //   1. When this package is consumed as a fetched dependency, its
    //      source tree lives in Zig's read-only, content-addressed global
    //      package cache -- writing into it there is both wrong and, for
    //      concurrent/multiple consuming projects, unsafe.
    //   2. Using output-arg LazyPaths gets Zig's own Run-step caching for
    //      free: identical inputs (same URL) hit the cache and skip
    //      re-downloading, so no manual "does the file already exist"
    //      check is needed.
    const fetch_include = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\out="$1"
        \\mkdir -p "$out"
        \\echo "Fetching V8 headers..." 1>&2
        \\curl -fL --connect-timeout 5 --progress-bar -o "$out.tar.gz" "$2"
        \\tar xzf "$out.tar.gz" -C "$out"
        \\rm "$out.tar.gz"
        ,
        "sh",
    });
    const v8_include_root = fetch_include.addOutputDirectoryArg("v8-include");
    fetch_include.addArg("https://github.com/regpacy/v8-zig/releases/download/fd/include.tar.gz");
    // include.tar.gz contains a top-level "include/" directory, so the
    // actual headers live at v8_include_root/include.
    const v8_include_dir = v8_include_root.path(b, "include");

    const fetch_libv8 = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\echo "Fetching libv8_monolith.a..." 1>&2
        \\curl -fL --connect-timeout 5 --progress-bar -o "$1" "$2"
        ,
        "sh",
    });
    const v8_monolith_a = fetch_libv8.addOutputFileArg("libv8_monolith.a");
    fetch_libv8.addArg("https://github.com/regpacy/v8-zig/releases/download/fd/libv8_monolith.a");

    // shim.cc must be compiled against libstdc++ (the same STL
    // libv8_monolith.a was built with -- its mangled symbols
    // encode `std::unique_ptr`, not libc++'s `std::__1::unique_ptr`).
    // Zig's bundled clang hardcodes libc++ and ignores -stdlib=libstdc++,
    // so this is compiled out-of-band with the system compiler and the
    // resulting object file is linked in directly.
    const shim_cc = b.addSystemCommand(&.{
        "c++",
        "-std=c++20",
        "-fno-exceptions",
        "-fno-rtti",
        "-fPIC",
        // These V8_*/CPPGC_* defines must match exactly what built
        // thirdparty/v8/libv8_monolith.a (they affect struct layouts like
        // Isolate::CreateParams and HandleScope, and the V8::Initialize
        // build-config bitmask) -- captured from V8's own ninja build via
        // `ninja -t commands obj/v8_hello_world/hello-world.o`.
        "-DV8_TYPED_ARRAY_MAX_SIZE_IN_HEAP=64",
        "-DV8_ENABLE_WEBASSEMBLY",
        "-DV8_ENABLE_CONTINUATION_PRESERVED_EMBEDDER_DATA",
        "-DV8_ARRAY_BUFFER_INTERNAL_FIELD_COUNT=0",
        "-DV8_ARRAY_BUFFER_VIEW_INTERNAL_FIELD_COUNT=0",
        "-DV8_PROMISE_INTERNAL_FIELD_COUNT=0",
        "-DV8_USE_DEFAULT_HASHER_SECRET=true",
        "-DV8_COMPRESS_POINTERS",
        "-DV8_COMPRESS_POINTERS_IN_SHARED_CAGE",
        "-DV8_31BIT_SMIS_ON_64BIT_ARCH",
        "-DV8_DEPRECATION_WARNINGS",
        "-DV8_IMMINENT_DEPRECATION_WARNINGS",
        "-DV8_HAVE_TARGET_OS",
        "-DV8_TARGET_OS_LINUX",
        "-DV8_TARGET_ARCH_X64",
        "-DV8_STATIC_ROOTS",
        "-DNDEBUG",
        "-I",
    });
    shim_cc.addDirectoryArg(v8_include_root);
    shim_cc.addArg("-I");
    shim_cc.addDirectoryArg(v8_include_dir);
    shim_cc.addArg("-c");
    shim_cc.addFileArg(b.path("src/shim.cc"));
    shim_cc.addArg("-o");
    const shim_o = shim_cc.addOutputFileArg("shim.o");

    mod.addObjectFile(shim_o);
    mod.addObjectFile(v8_monolith_a);
    mod.linkSystemLibrary("pthread", .{});
    mod.linkSystemLibrary("dl", .{}); // Linux
    mod.addObjectFile(.{ .cwd_relative = "/usr/lib/gcc/x86_64-pc-linux-gnu/16/libstdc++.so" });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");


    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
