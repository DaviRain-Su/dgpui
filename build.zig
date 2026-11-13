const std = @import("std");

/// SDL3 的查找顺序：
/// 1. `-Dsdl-include` 与 `-Dsdl-lib`（macOS Homebrew、自定义前缀都走这里）
/// 2. `pkg-config sdl3`（Linux 发行版包、安装到 /usr/local 的 SDL）
/// 3. 常见前缀：/opt/homebrew、/usr/local、/usr（含 Debian 的 multiarch lib 目录）
///
/// `-Dsdl=false` 强制关掉，`-Dsdl=true` 强制打开（找不到就配置失败）。
/// 不传时自动探测。探测失败时 `zig build test` 仍然编译并运行 headless 测试。
const SdlLocate = struct {
    include_dirs: []const []const u8,
    lib_dirs: []const []const u8,
    use_pkg_config: bool,
    how: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sdl_include_opt = b.option([]const u8, "sdl-include", "Directory that contains SDL3/SDL.h");
    const sdl_lib_opt = b.option([]const u8, "sdl-lib", "Directory that contains libSDL3");
    const sdl_force = b.option(bool, "sdl", "Force the SDL3 backend on or off (default: auto-detect)");

    const located = locateSdl(b, sdl_include_opt, sdl_lib_opt);
    if (sdl_force == true and located == null) {
        std.process.fatal("SDL3 was requested with -Dsdl=true but was not found. Install it (pkg-config sdl3) or pass -Dsdl-include=DIR -Dsdl-lib=DIR.", .{});
    }
    const sdl_on = if (sdl_force) |forced| forced else located != null;

    const headless_mod = makeCoreModule(b, target, optimize, false);
    const headless_tests = b.addTest(.{ .root_module = headless_mod });
    const run_headless_tests = b.addRunArtifact(headless_tests);

    const headless_step = b.step("test-headless", "Run unit tests that do not link SDL3");
    headless_step.dependOn(&run_headless_tests.step);

    const test_step = b.step("test", "Run headless unit tests, and compile the SDL demo when SDL3 is available");
    test_step.dependOn(&run_headless_tests.step);

    const run_step = b.step("run", "Run the dgpui demo app");

    if (!sdl_on) {
        if (sdl_force == false) {
            std.log.info("SDL3 disabled with -Dsdl=false; headless tests only.", .{});
        } else {
            std.log.warn("SDL3 not found; headless tests only. Install SDL3 or pass -Dsdl-include and -Dsdl-lib.", .{});
        }
        const missing = b.addFail("SDL3 is off, so there is no windowed demo. Install SDL3 (pkg-config sdl3) or pass -Dsdl-include=DIR -Dsdl-lib=DIR. Headless tests do not need SDL: zig build test");
        run_step.dependOn(&missing.step);
        return;
    }

    const where = located orelse unreachable;
    std.log.info("SDL3 enabled via {s}", .{where.how});

    const c_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/deps.h"),
        .target = target,
        .optimize = optimize,
    });
    for (where.include_dirs) |inc| {
        c_translate.addSystemIncludePath(.{ .cwd_relative = inc });
    }
    const c_mod = c_translate.createModule();

    const sdl_mod = makeCoreModule(b, target, optimize, true);
    sdl_mod.link_libc = true;
    sdl_mod.addImport("c", c_mod);
    for (where.lib_dirs) |lib| {
        sdl_mod.addLibraryPath(.{ .cwd_relative = lib });
        sdl_mod.addRPath(.{ .cwd_relative = lib });
    }
    sdl_mod.linkSystemLibrary("SDL3", .{
        .use_pkg_config = if (where.use_pkg_config) .yes else .no,
    });

    const exe = b.addExecutable(.{
        .name = "dgpui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dgpui", .module = sdl_mod },
            },
        }),
    });
    b.installArtifact(exe);
    // 把 SDL 翻译单元的编译和链接放进 `zig build test`，这样机器上有 SDL3 时
    // 后端会一起被构建；测试本身仍然只跑 headless 模块，不打开窗口。
    test_step.dependOn(&exe.step);

    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
}

fn makeCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    sdl: bool,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const options = b.addOptions();
    options.addOption(bool, "sdl", sdl);
    mod.addOptions("build_options", options);
    return mod;
}

fn locateSdl(b: *std.Build, include_opt: ?[]const u8, lib_opt: ?[]const u8) ?SdlLocate {
    // 探测 pkg-config 和系统路径发生在配置阶段。不把缓存标脏的话，
    // 装上或卸掉 SDL3 之后 `zig build` 会一直沿用上一次的结论。
    b.graph.poisonCache();
    if (include_opt != null or lib_opt != null) {
        const include_dir = include_opt orelse std.process.fatal("-Dsdl-include and -Dsdl-lib must be set together.", .{});
        const lib_dir = lib_opt orelse std.process.fatal("-Dsdl-include and -Dsdl-lib must be set together.", .{});
        if (!fileExists(b, b.pathJoin(&.{ include_dir, "SDL3", "SDL.h" }))) {
            std.process.fatal("SDL3/SDL.h was not found under -Dsdl-include={s}", .{include_dir});
        }
        if (!dirHasSdlLib(b, lib_dir)) {
            std.process.fatal("libSDL3 was not found under -Dsdl-lib={s}", .{lib_dir});
        }
        const include_dirs = b.allocator.dupe([]const u8, &.{include_dir}) catch @panic("OOM");
        const lib_dirs = b.allocator.dupe([]const u8, &.{lib_dir}) catch @panic("OOM");
        return .{
            .include_dirs = include_dirs,
            .lib_dirs = lib_dirs,
            .use_pkg_config = false,
            .how = "explicit -Dsdl-include/-Dsdl-lib",
        };
    }

    if (pkgConfigOk(b, &.{ "pkg-config", "--exists", "sdl3" })) {
        const cflags = pkgConfigStdout(b, &.{ "pkg-config", "--cflags-only-I", "sdl3" }) orelse "";
        const ldflags = pkgConfigStdout(b, &.{ "pkg-config", "--libs-only-L", "sdl3" }) orelse "";
        var include_dirs = collectFlagValues(b, cflags, "-I");
        if (include_dirs.len == 0) {
            include_dirs = fallbackIncludeDirs(b);
        }
        return .{
            .include_dirs = include_dirs,
            .lib_dirs = collectFlagValues(b, ldflags, "-L"),
            .use_pkg_config = true,
            .how = "pkg-config sdl3",
        };
    }

    const known = [_]struct { inc: []const u8, lib: []const u8 }{
        .{ .inc = "/opt/homebrew/include", .lib = "/opt/homebrew/lib" },
        .{ .inc = "/usr/local/include", .lib = "/usr/local/lib" },
        .{ .inc = "/usr/include", .lib = "/usr/lib/x86_64-linux-gnu" },
        .{ .inc = "/usr/include", .lib = "/usr/lib/aarch64-linux-gnu" },
        .{ .inc = "/usr/include", .lib = "/usr/lib" },
    };
    for (known) |prefix| {
        if (!fileExists(b, b.pathJoin(&.{ prefix.inc, "SDL3", "SDL.h" }))) continue;
        if (!dirHasSdlLib(b, prefix.lib)) continue;
        const include_dirs = b.allocator.dupe([]const u8, &.{prefix.inc}) catch @panic("OOM");
        const lib_dirs = b.allocator.dupe([]const u8, &.{prefix.lib}) catch @panic("OOM");
        return .{
            .include_dirs = include_dirs,
            .lib_dirs = lib_dirs,
            .use_pkg_config = false,
            .how = "well-known prefix",
        };
    }
    return null;
}

fn fallbackIncludeDirs(b: *std.Build) []const []const u8 {
    const candidates = [_][]const u8{
        "/usr/local/include",
        "/usr/include",
        "/opt/homebrew/include",
    };
    var list: std.ArrayList([]const u8) = .empty;
    for (candidates) |inc| {
        if (fileExists(b, b.pathJoin(&.{ inc, "SDL3", "SDL.h" }))) {
            list.append(b.allocator, inc) catch @panic("OOM");
        }
    }
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn collectFlagValues(b: *std.Build, text: []const u8, prefix: []const u8) []const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (it.next()) |tok| {
        if (!std.mem.startsWith(u8, tok, prefix)) continue;
        const value = tok[prefix.len..];
        if (value.len == 0) continue;
        list.append(b.allocator, value) catch @panic("OOM");
    }
    return list.toOwnedSlice(b.allocator) catch @panic("OOM");
}

fn pkgConfigOk(b: *std.Build, argv: []const []const u8) bool {
    return switch (b.runFallible(argv, .{ .stderr_behavior = .ignore })) {
        .success => true,
        else => false,
    };
}

fn pkgConfigStdout(b: *std.Build, argv: []const []const u8) ?[]const u8 {
    return switch (b.runFallible(argv, .{ .stderr_behavior = .ignore })) {
        .success => |stdout| std.mem.trim(u8, stdout, " \t\r\n"),
        else => null,
    };
}

fn dirHasSdlLib(b: *std.Build, lib_dir: []const u8) bool {
    const names = [_][]const u8{
        "libSDL3.so",
        "libSDL3.dylib",
        "libSDL3.a",
        "libSDL3.dll.a",
        "SDL3.lib",
    };
    for (names) |name| {
        if (fileExists(b, b.pathJoin(&.{ lib_dir, name }))) return true;
    }
    return false;
}

fn fileExists(b: *std.Build, path: []const u8) bool {
    if (!std.Io.Dir.path.isAbsolute(path)) return false;
    std.Io.Dir.accessAbsolute(b.graph.io, path, .{}) catch return false;
    return true;
}
