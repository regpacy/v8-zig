const std = @import("std");


pub fn build(b: *std.Build) void {

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("v8_zig", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const exe = b.addExecutable(.{
        .name = "v8_zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "v8_zig", .module = mod },
            },
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    exe.root_module.linkSystemLibrary("stdc++", .{});
    exe.root_module.addObjectFile(b.path("thirdparty/v8/libv8_monolith.a"));
    exe.root_module.linkSystemLibrary("pthread", .{});
    exe.root_module.linkSystemLibrary("dl", .{}); // Linux
        exe.root_module.addObjectFile(.{ .cwd_relative = "/usr/lib/gcc/x86_64-pc-linux-gnu/16/libstdc++.so" });
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
