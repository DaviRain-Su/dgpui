const std = @import("std");
const dgpui = @import("dgpui");

const DemoState = struct {
    clicks: usize = 0,

    fn onEvent(ctx: *anyopaque, ev: dgpui.backend.platform.Event, loop: *dgpui.app.AppLoop) void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .mouse_down => |md| {
                self.clicks += 1;
                // 演示用：每次点击换一个背景色调，证明事件确实唤醒了循环并触发了 Metal 重绘
                const palette = [_]u24{ 0x1e1e2e, 0x181825, 0x1e293b, 0x2a1e2e };
                loop.clear_color = dgpui.math.Color.fromHex(palette[self.clicks % palette.len]);
                loop.requestRedraw();
                std.log.info("mouse_down at ({d:.1}, {d:.1}), clicks={d}", .{ md.pos.x, md.pos.y, self.clicks });
            },
            .resized => |m| {
                std.log.info("window resized: logical={d:.0}x{d:.0} density={d:.2} content_scale={d:.2} pixels={d}x{d}", .{
                    m.logical_width,
                    m.logical_height,
                    m.scale_factor,
                    m.content_scale,
                    m.physicalWidth(),
                    m.physicalHeight(),
                });
            },
            .key_down => |kd| {
                if (kd.key == .escape) loop.quit();
            },
            .text_input => |text| {
                std.log.info("text input: {s}", .{text.slice()});
            },
            .text_editing => |editing| {
                std.log.info("ime: {s} start={d} length={d}", .{ editing.slice(), editing.start, editing.length });
            },
            .quit, .scale_changed, .redraw_requested, .mouse_move, .mouse_up, .scroll => {},
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const sdl = try dgpui.backend.sdl.SdlBackend.init(gpa, "dgpui — PR 1: Backend & Event Loop", 800, 600);
    defer sdl.deinitSelf();

    const m = sdl.platformBackend().metrics();
    std.log.info("PR 1 ready: logical={d:.0}x{d:.0}, density={d:.2}, content_scale={d:.2}, pixels={d}x{d}", .{
        m.logical_width,
        m.logical_height,
        m.scale_factor,
        m.content_scale,
        m.physicalWidth(),
        m.physicalHeight(),
    });

    var state = DemoState{};
    var loop = dgpui.app.AppLoop.init(sdl.platformBackend(), sdl.rendererBackend());
    loop.callbacks = .{
        .ctx = &state,
        .onEvent = DemoState.onEvent,
    };

    try loop.run();
}
