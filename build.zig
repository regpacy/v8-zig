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
    mod.addIncludePath(b.path("thirdparty/v8"));

    // Pulls the prebuilt V8 headers/static lib from GitHub releases if
    // they're not already present locally, so a clean checkout can build
    // without a manual V8 build/vendoring step first.
    const fetch_v8 = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -e
        \\mkdir -p thirdparty/v8
        \\if [ ! -d thirdparty/v8/include ]; then
        \\  echo "Fetching V8 headers..." 1>&2
        \\  curl -fL --connect-timeout 5 --progress-bar -o thirdparty/v8/include.tar.gz https://github.com/regpacy/v8-zig/releases/download/fd/include.tar.gz
        \\  tar xzf thirdparty/v8/include.tar.gz -C thirdparty/v8
        \\  rm thirdparty/v8/include.tar.gz
        \\fi
        \\if [ ! -f thirdparty/v8/libv8_monolith.a ]; then
        \\  echo "Fetching libv8_monolith.a..." 1>&2
        \\  curl -fL --connect-timeout 5 --progress-bar -o thirdparty/v8/libv8_monolith.a https://github.com/regpacy/v8-zig/releases/download/fd/libv8_monolith.a
        \\fi
    });

    // shim.cc must be compiled against libstdc++ (the same STL
    // thirdparty/v8/libv8_monolith.a was built with -- its mangled symbols
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
    shim_cc.step.dependOn(&fetch_v8.step);
    shim_cc.addDirectoryArg(b.path("thirdparty/v8"));
    shim_cc.addArg("-I");
    shim_cc.addDirectoryArg(b.path("thirdparty/v8/include"));
    shim_cc.addArg("-c");
    shim_cc.addFileArg(b.path("src/shim.cc"));
    shim_cc.addArg("-o");
    const shim_o = shim_cc.addOutputFileArg("shim.o");

    mod.addObjectFile(shim_o);
    mod.addObjectFile(b.path("thirdparty/v8/libv8_monolith.a"));
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
