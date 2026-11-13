const std = @import("std");
const dgpui = @import("dgpui");

const button = dgpui.math.Rect.init(48, 48, 180, 56);

const DemoState = struct {
    clicks: usize = 0,
    damage: ?dgpui.math.Rect = null,

    fn buttonColor(self: DemoState) dgpui.math.Color {
        const palette = [_]u24{ 0x89b4fa, 0xf9e2af, 0xa6e3a1, 0xf38ba8 };
        return dgpui.math.Color.fromHex(palette[self.clicks % palette.len]);
    }

    fn build(ctx: *anyopaque, arena: *dgpui.frame_arena.FrameArena) dgpui.display_list.BuiltFrame {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        arena.reset();
        var list = dgpui.display_list.DisplayList.init(arena);
        list.addQuad(.{
            .rect = dgpui.math.Rect.init(24, 24, 752, 552),
            .radius = 16,
            .fill = dgpui.math.Color.fromHex(0x313244),
        }) catch {};
        const face = dgpui.display_list.Quad{
            .rect = button,
            .radius = 12,
            .fill = self.buttonColor(),
            .border_width = 2,
            .border_color = dgpui.math.Color.white,
            .shadow_blur = 16,
            .shadow_color = dgpui.math.Color.fromHexRgba(0x00000059),
        };
        list.addQuad(face) catch {};
        return .{ .list = list, .damage = self.damage };
    }

    fn onEvent(ctx: *anyopaque, ev: dgpui.backend.platform.Event, loop: *dgpui.app.AppLoop) void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .mouse_down => |md| {
                self.clicks += 1;
                self.damage = dgpui.display_list.DisplayList.visualBounds(.{
                    .rect = button,
                    .fill = self.buttonColor(),
                    .shadow_blur = 16,
                });
                loop.requestRedraw();
                std.log.info("mouse_down at ({d:.1}, {d:.1}), clicks={d}", .{ md.pos.x, md.pos.y, self.clicks });
            },
            .resized => |m| {
                std.log.info("window resized: logical={d:.0}x{d:.0} scale={d:.2} content_scale={d:.2} pixel_density={d:.2} pixels={d}x{d}", .{
                    m.logical_width,
                    m.logical_height,
                    m.scale_factor,
                    m.content_scale,
                    m.pixel_density,
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
    std.log.info("PR 2 ready: logical={d:.0}x{d:.0}, scale={d:.2}, content_scale={d:.2}, pixel_density={d:.2}, pixels={d}x{d}", .{
        m.logical_width,
        m.logical_height,
        m.scale_factor,
        m.content_scale,
        m.pixel_density,
        m.physicalWidth(),
        m.physicalHeight(),
    });

    var state = DemoState{};
    var arena = try dgpui.frame_arena.FrameArena.init(gpa, 64 * 1024);
    defer arena.deinit();
    var loop = dgpui.app.AppLoop.init(sdl.platformBackend(), sdl.rendererBackend());
    loop.callbacks = .{
        .ctx = &state,
        .onEvent = DemoState.onEvent,
    };
    loop.frame_ctx = &state;
    loop.frame_arena = &arena;
    loop.frame_build = DemoState.build;

    try loop.run();
}
