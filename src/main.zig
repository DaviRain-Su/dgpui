const std = @import("std");
const dgpui = @import("dgpui");

const DemoState = struct {
    clicks: usize = 0,
    accent_on: bool = false,

    fn onEvent(ctx: *anyopaque, ev: dgpui.backend.platform.Event, loop: *dgpui.app.AppLoop) void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .mouse_down => |md| {
                self.clicks += 1;
                self.accent_on = !self.accent_on;
                loop.requestRedraw();
                std.log.info("mouse_down at ({d:.1}, {d:.1}), clicks={d}", .{ md.pos.x, md.pos.y, self.clicks });
            },
            .key_down => |kd| {
                if (kd.key == .escape) loop.quit();
            },
            else => {},
        }
    }

    fn onRender(
        ctx: *anyopaque,
        dl: *dgpui.scene.DisplayList,
        _: std.mem.Allocator,
        metrics: dgpui.backend.platform.WindowMetrics,
    ) !void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));

        // 居中摆放一张 420x260 的信息卡片骨架（展示阴影 + 圆角 + 1px 边框 + Scissor 裁剪）
        const card_w: f32 = @min(420.0, @max(200.0, metrics.logical_width - 64.0));
        const card_h: f32 = 250.0;
        const card_x = (metrics.logical_width - card_w) * 0.5;
        const card_y = (metrics.logical_height - card_h) * 0.5;

        // 1. 卡片主体（一个 SDF Quad 同时画出柔和阴影 + 圆角填充 + 1px 描边）
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x, card_y, card_w, card_h),
            .background = dgpui.math.Color.fromHex(0x24273a),
            .border_color = dgpui.math.Color.fromHex(if (self.accent_on) 0x8aadf4 else 0x494d64),
            .border_width = 1.5,
            .corner_radius = 16.0,
            .shadow_color = dgpui.math.Color.fromHexRgba(0x00000090),
            .shadow_blur = 20.0,
            .shadow_offset = .{ .x = 0, .y = 8 },
        });

        // 2. 顶部“标题占位条”（PR 3 会把真正的文字画在这里）
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x + 24, card_y + 24, card_w - 48, 28),
            .background = dgpui.math.Color.fromHex(0xcad3f5),
            .corner_radius = 6.0,
        });

        // 3. 正文占位条两行
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x + 24, card_y + 68, card_w - 48, 14),
            .background = dgpui.math.Color.fromHex(0x8087a2),
            .corner_radius = 4.0,
        });
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x + 24, card_y + 92, (card_w - 48) * 0.7, 14),
            .background = dgpui.math.Color.fromHex(0x6e738d),
            .corner_radius = 4.0,
        });

        // 4. 演示 Scissor 裁剪栈：把一个故意画超宽的进度条限制在圆角容器内
        const clip_box = dgpui.math.Rect.init(card_x + 24, card_y + 126, card_w - 48, 28);
        try dl.pushQuad(.{
            .bounds = clip_box,
            .background = dgpui.math.Color.fromHex(0x181926),
            .border_color = dgpui.math.Color.fromHex(0x363a4f),
            .border_width = 1.0,
            .corner_radius = 8.0,
        });
        try dl.pushClip(clip_box);
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(clip_box.x, clip_box.y, clip_box.width * 1.4, clip_box.height),
            .background = dgpui.math.Color.fromHex(if (self.accent_on) 0xa6da95 else 0x8aadf4),
            .corner_radius = 8.0,
        });
        try dl.popClip();

        // 5. 底部两个圆角标签 + 右侧交互按钮骨架
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x + 24, card_y + 184, 88, 34),
            .background = dgpui.math.Color.fromHex(0x363a4f),
            .corner_radius = 17.0,
        });
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x + 122, card_y + 184, 72, 34),
            .background = dgpui.math.Color.fromHex(0x363a4f),
            .corner_radius = 17.0,
        });
        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x + card_w - 124, card_y + 184, 100, 34),
            .background = dgpui.math.Color.fromHex(if (self.accent_on) 0xf5a97f else 0x8aadf4),
            .corner_radius = 10.0,
        });
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const sdl = try dgpui.backend.sdl.SdlBackend.init(gpa, "dgpui — PR 2: DisplayList & SDF Quads", 800, 600);
    defer sdl.deinitSelf();

    var state = DemoState{};
    var loop = dgpui.app.AppLoop.init(gpa, sdl.platformBackend(), sdl.rendererBackend());
    defer loop.deinit();
    loop.clear_color = dgpui.math.Color.fromHex(0x181926);
    loop.callbacks = .{
        .ctx = &state,
        .onEvent = DemoState.onEvent,
        .onRender = DemoState.onRender,
    };

    try loop.run();
}
