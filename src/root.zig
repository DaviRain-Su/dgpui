//! dgpui — 教育型精简 GPUI 框架（Zig 0.17.1）

const std = @import("std");
const build_options = @import("build_options");

pub const version = "0.1.0-pr2";

pub const math = @import("math.zig");
pub const frame_arena = @import("frame_arena.zig");
pub const sdf = @import("sdf.zig");
pub const damage = @import("damage.zig");
pub const display_list = @import("display_list.zig");
pub const app = @import("app.zig");
pub const backend = struct {
    pub const platform = @import("backend/platform.zig");
    pub const renderer = @import("backend/renderer.zig");
    pub const headless = @import("backend/headless.zig");
    /// headless 测试把 `build_options.sdl` 关掉，这里就不会 `@import` SDL。
    /// 桌面 demo 的模块才把它打开。两边都提供 `available`，测试可以锁住这个开关。
    pub const sdl = if (build_options.sdl) @import("backend/sdl.zig") else SdlDisabled;
};

const SdlDisabled = struct {
    pub const available = false;
};

test {
    std.testing.refAllDecls(@This());
}

test "sdl switch follows build_options" {
    try std.testing.expectEqual(build_options.sdl, backend.sdl.available);
}
