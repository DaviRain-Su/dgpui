const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // 通过 Zig 0.17 的 translate-c 将 C 头文件转为可直接 @import("c") 的模块
    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/deps.h"),
        .target = target,
        .optimize = optimize,
    });
    c_translate.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include" });
    const c_mod = c_translate.createModule();

    const mod = b.addModule("dgpui", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "c", .module = c_mod },
        },
    });
    mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.addRPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    mod.linkSystemLibrary("SDL3", .{});

    const exe = b.addExecutable(.{
        .name = "dgpui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dgpui", .module = mod },
            },
        }),
    });
    exe.root_module.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.root_module.addRPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    exe.root_module.linkSystemLibrary("SDL3", .{});

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the dgpui demo app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
