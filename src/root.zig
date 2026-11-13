//! dgpui — 教育型精简 GPUI 框架（Zig 0.17.1）

pub const version = "0.1.0-pr1";

pub const math = @import("math.zig");
pub const app = @import("app.zig");
pub const backend = struct {
    pub const platform = @import("backend/platform.zig");
    pub const renderer = @import("backend/renderer.zig");
    pub const headless = @import("backend/headless.zig");
    pub const sdl = @import("backend/sdl.zig");
};

test {
    @import("std").testing.refAllDecls(@This());
}
