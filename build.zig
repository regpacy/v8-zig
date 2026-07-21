const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    // The prebuilt Windows v8_monolith.lib is MSVC-ABI (V8's clang-cl
    // toolchain), so a mingw (gnu-abi) build cannot link it -- default the
    // native Windows target to msvc. Requires a Visual Studio + Windows SDK
    // installation for the CRT headers/libs.
    const default_target: std.Target.Query = if (builtin.os.tag == .windows)
        .{ .abi = .msvc }
    else
        .{};
    const target = b.standardTargetOptions(.{ .default_target = default_target });
    const optimize = b.standardOptimizeOption(.{});
    const is_windows = target.result.os.tag == .windows;

    const mod = b.addModule("v8_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        // On msvc targets zig cannot build its bundled libc++abi, and the C++
        // runtime comes from the MSVC CRT (libcmt/libcpmt) instead.
        .link_libcpp = !is_windows,
        .link_libc = is_windows,
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
    // Plain curl/tar argv (no shell wrapper) so the same steps work on both
    // Linux and Windows -- Windows 10+ ships both curl.exe and (bsd)tar.exe,
    // and the Run step pre-creates output directories, so no mkdir is needed.
    const fetch_include_tar = b.addSystemCommand(&.{
        "curl", "-fL", "--connect-timeout", "15", "--progress-bar", "-o",
    });
    const include_tar = fetch_include_tar.addOutputFileArg("include.tar.gz");
    fetch_include_tar.addArg("https://github.com/regpacy/v8-zig/releases/download/fd/include.tar.gz");

    const extract_include = b.addSystemCommand(&.{ "tar", "xzf" });
    extract_include.addFileArg(include_tar);
    extract_include.addArg("-C");
    const v8_include_root = extract_include.addOutputDirectoryArg("v8-include");
    // include.tar.gz contains a top-level "include/" directory, so the
    // actual headers live at v8_include_root/include.
    const v8_include_dir = v8_include_root.path(b, "include");

    const fetch_libv8 = b.addSystemCommand(&.{
        "curl", "-fL", "--connect-timeout", "15", "--progress-bar", "-o",
    });
    const v8_monolith = fetch_libv8.addOutputFileArg(
        if (is_windows) "v8_monolith.lib" else "libv8_monolith.a",
    );
    fetch_libv8.addArg(if (is_windows)
        "https://github.com/regpacy/v8-zig/releases/download/fd/v8_monolith.lib"
    else
        "https://github.com/regpacy/v8-zig/releases/download/fd/libv8_monolith.a");

    // These V8_*/CPPGC_* defines must match exactly what built the prebuilt
    // monolith (they affect struct layouts like Isolate::CreateParams and
    // HandleScope, and the V8::Initialize build-config bitmask) -- captured
    // from V8's own ninja build via
    // `ninja -t commands obj/v8_hello_world/hello-world.o`.
    const common_v8_defines = [_][]const u8{
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
        "-DV8_TARGET_ARCH_X64",
        "-DV8_STATIC_ROOTS",
        "-DNDEBUG",
    };

    if (is_windows) {
        const triple = b.fmt("{s}-windows-msvc", .{@tagName(target.result.cpu.arch)});

        // shim.cc must produce MSVC-mangled references against *Chromium's*
        // libc++ ABI: the prebuilt lib was built with clang-cl and V8's
        // default use_custom_libcxx=true, whose libc++ lives in ABI namespace
        // std::__Cr with the ABI-v2 flags (notably trivial-abi unique_ptr,
        // which changes how NewDefaultPlatform returns its value). zig's
        // clang + bundled libc++ headers reproduce that exactly when the two
        // _LIBCPP_ABI_* macros are overridden (zig passes its libc++ config
        // as -D flags, so a later -D wins). -fno-autolink stops clang from
        // embedding a /DEFAULTLIB:libc++.lib directive that msvc links can't
        // satisfy.
        const shim_cc = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "c++",
            "-target",
            triple,
            "-std=c++20",
            "-O2",
            "-fno-exceptions",
            "-fno-rtti",
            "-fno-autolink",
            "-fno-sanitize=undefined",
            "-Wno-macro-redefined",
            // zig c++ always passes -nostdinc++, which clang reports as
            // unused for compile-only invocations; the Run step treats any
            // stderr output as noteworthy, so silence it.
            "-Wno-unused-command-line-argument",
            "-D_LIBCPP_ABI_NAMESPACE=__Cr",
            "-D_LIBCPP_ABI_VERSION=2",
        });
        shim_cc.addArgs(&common_v8_defines);
        // The Windows lib was additionally built with the V8 sandbox enabled
        // (part of the V8::Initialize build-config check).
        shim_cc.addArgs(&.{ "-DV8_TARGET_OS_WIN", "-DV8_ENABLE_SANDBOX" });
        shim_cc.addArg("-I");
        shim_cc.addDirectoryArg(v8_include_root);
        shim_cc.addArg("-I");
        shim_cc.addDirectoryArg(v8_include_dir);
        shim_cc.addArg("-c");
        shim_cc.addFileArg(b.path("src/shim.cc"));
        shim_cc.addArg("-o");
        const shim_obj = shim_cc.addOutputFileArg("shim.obj");

        // The monolith references ~10k out-of-line std::__Cr symbols
        // (verbose_abort, __shared_weak_count, string/iostream externals...)
        // that Chromium normally provides as its own libc++.lib next to V8.
        // Rebuild that library here from zig's bundled libc++ sources with
        // the same __Cr/ABI-v2 configuration.
        const libcxx_cr = buildChromiumAbiLibcxx(b, triple);

        mod.addObjectFile(shim_obj);
        mod.addObjectFile(v8_monolith);
        mod.addObjectFile(libcxx_cr);
        // JS Temporal is backed by a separate Rust static library in V8's gn
        // build that is not part of the monolith; stub its C ABI out.
        mod.addCSourceFile(.{ .file = b.path("src/temporal_stubs.c") });
        // libcpmt: static MSVC C++ runtime (operator new/delete,
        // __ExceptionPtr* used by libc++'s MSVC exception_ptr glue). The
        // monolith's embedded /DEFAULTLIB directives pull in libcmt,
        // oldnames, uuid, kernel32, advapi32, bcrypt, dbghelp on their own.
        mod.linkSystemLibrary("libcpmt", .{});
        mod.linkSystemLibrary("winmm", .{});
        mod.linkSystemLibrary("dbghelp", .{});
        mod.linkSystemLibrary("advapi32", .{});
    } else {
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
        });
        shim_cc.addArgs(&common_v8_defines);
        shim_cc.addArg("-DV8_TARGET_OS_LINUX");
        shim_cc.addArg("-I");
        shim_cc.addDirectoryArg(v8_include_root);
        shim_cc.addArg("-I");
        shim_cc.addDirectoryArg(v8_include_dir);
        shim_cc.addArg("-c");
        shim_cc.addFileArg(b.path("src/shim.cc"));
        shim_cc.addArg("-o");
        const shim_o = shim_cc.addOutputFileArg("shim.o");

        mod.linkSystemLibrary("stdc++", .{});
        mod.addObjectFile(shim_o);
        mod.addObjectFile(v8_monolith);
        mod.linkSystemLibrary("pthread", .{});
        mod.linkSystemLibrary("dl", .{});
        mod.addObjectFile(.{ .cwd_relative = "/usr/lib/gcc/x86_64-pc-linux-gnu/16/libstdc++.so" });
    }

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

/// Compiles zig's bundled libc++ sources into a static library with
/// Chromium's ABI configuration (namespace std::__Cr, ABI version 2) for the
/// MSVC target, matching what V8's default use_custom_libcxx=true build links
/// against. Each source is compiled out-of-band with `zig c++` so zig's own
/// libc++ include paths and config defines are applied automatically, then
/// the objects are archived with `zig ar`.
fn buildChromiumAbiLibcxx(b: *std.Build, triple: []const u8) std.Build.LazyPath {
    const zig_lib_path = b.graph.zig_lib_directory.path orelse
        @panic("zig lib directory path unavailable");

    // Same source layout LLVM's own CMake uses for a Windows libc++ build:
    // all common sources plus the win32 support files.
    const source_dirs = [_][]const u8{
        "libcxx/src",
        "libcxx/src/ryu",
        "libcxx/src/support/win32",
    };

    const io = b.graph.io;
    var sources: std.ArrayList([]const u8) = .empty;
    for (source_dirs) |sub| {
        var dir = b.graph.zig_lib_directory.handle.openDir(io, sub, .{ .iterate = true }) catch
            @panic("cannot open zig's bundled libcxx sources");
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch @panic("error iterating libcxx sources")) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".cpp")) continue;
            sources.append(
                b.allocator,
                b.pathJoin(&.{ zig_lib_path, sub, entry.name }),
            ) catch @panic("OOM");
        }
    }
    // Deterministic argv ordering keeps Run-step cache digests stable.
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.lessThan(u8, lhs, rhs);
        }
    }.lessThan);

    const ar = b.addSystemCommand(&.{ b.graph.zig_exe, "ar", "rcs" });
    const out_lib = ar.addOutputFileArg("libcxx_cr.lib");

    for (sources.items) |src| {
        const cc = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "c++",
            "-target",
            triple,
            "-std=c++26",
            "-O2",
            "-fno-sanitize=undefined",
            "-fno-autolink",
            "-Wno-macro-redefined",
            "-Wno-unused-command-line-argument",
            "-D_LIBCPP_BUILDING_LIBRARY",
            "-D_LIBCPP_ABI_NAMESPACE=__Cr",
            "-D_LIBCPP_ABI_VERSION=2",
            // charconv.cpp pulls fp_bits.h from the llvm-libc shared headers;
            // the ryu sources include "include/ryu/..." relative to src/.
            "-I",
            b.pathJoin(&.{ zig_lib_path, "libcxx", "src" }),
            "-I",
            b.pathJoin(&.{ zig_lib_path, "libcxx", "libc" }),
            "-c",
            src,
            "-o",
        });
        const obj = cc.addOutputFileArg(b.fmt("{s}.obj", .{std.fs.path.stem(src)}));
        ar.addFileArg(obj);
    }

    return out_lib;
}
