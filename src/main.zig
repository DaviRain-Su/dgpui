const std = @import("std");
const dgpui = @import("dgpui");

const DemoState = struct {
    clicks: usize = 0,
    accent_on: bool = false,
    text_system: dgpui.text.TextSystem = undefined,
    text_ready: bool = false,

    fn setupText(self: *DemoState, gpa: std.mem.Allocator) !void {
        const path = dgpui.text.font.defaultFontPath() orelse {
            std.log.err("no system font found for demo text", .{});
            return error.FontNotFound;
        };
        try self.text_system.init(gpa, path.ptr, 1024, 1024);
        self.text_ready = true;
    }

    fn deinitText(self: *DemoState) void {
        if (self.text_ready) self.text_system.deinit();
        self.text_ready = false;
    }

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

        const card_w: f32 = @min(460.0, @max(240.0, metrics.logical_width - 64.0));
        const card_h: f32 = 280.0;
        const card_x = (metrics.logical_width - card_w) * 0.5;
        const card_y = (metrics.logical_height - card_h) * 0.5;

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

        if (self.text_ready) {
            const title_color = dgpui.math.Color.fromHex(0xcad3f5);
            const body_color = dgpui.math.Color.fromHex(0xa5adce);
            const accent = dgpui.math.Color.fromHex(if (self.accent_on) 0xa6da95 else 0x8aadf4);

            var title = try self.text_system.prepareLine(
                "dgpui · Text Shaping",
                .{ .x = card_x + 24, .y = card_y + 22 },
                22,
                metrics.scale_factor,
                title_color,
            );
            defer title.deinit(self.text_system.allocator);
            for (title.glyphs) |g| try dl.pushGlyph(.{ .bounds = g.bounds, .uv = g.uv, .color = g.color });

            var body = try self.text_system.prepareLine(
                "HarfBuzz + FreeType + GlyphAtlas",
                .{ .x = card_x + 24, .y = card_y + 58 },
                15,
                metrics.scale_factor,
                body_color,
            );
            defer body.deinit(self.text_system.allocator);
            for (body.glyphs) |g| try dl.pushGlyph(.{ .bounds = g.bounds, .uv = g.uv, .color = g.color });

            var mixed = try self.text_system.prepareLine(
                "Hello 世界 · 点击切换高亮",
                .{ .x = card_x + 24, .y = card_y + 90 },
                16,
                metrics.scale_factor,
                accent,
            );
            defer mixed.deinit(self.text_system.allocator);
            for (mixed.glyphs) |g| try dl.pushGlyph(.{ .bounds = g.bounds, .uv = g.uv, .color = g.color });

            var counter_buf: [64]u8 = undefined;
            const counter_text = try std.fmt.bufPrint(&counter_buf, "clicks = {d}", .{self.clicks});
            var counter = try self.text_system.prepareLine(
                counter_text,
                .{ .x = card_x + 24, .y = card_y + 130 },
                18,
                metrics.scale_factor,
                title_color,
            );
            defer counter.deinit(self.text_system.allocator);
            for (counter.glyphs) |g| try dl.pushGlyph(.{ .bounds = g.bounds, .uv = g.uv, .color = g.color });
        }

        // Scissor 演示：故意超宽的进度条，限制在圆角槽内
        const clip_box = dgpui.math.Rect.init(card_x + 24, card_y + 180, card_w - 48, 28);
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

        try dl.pushQuad(.{
            .bounds = dgpui.math.Rect.init(card_x + card_w - 124, card_y + 224, 100, 34),
            .background = dgpui.math.Color.fromHex(if (self.accent_on) 0xf5a97f else 0x8aadf4),
            .corner_radius = 10.0,
        });
    }

    fn atlasFrame(ctx: *anyopaque) ?dgpui.app.AtlasFrame {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        if (!self.text_ready) return null;
        return .{
            .pixels = self.text_system.atlas.pixels,
            .width = self.text_system.atlas.width,
            .height = self.text_system.atlas.height,
            .dirty = self.text_system.atlas.dirty,
        };
    }

    fn atlasClearDirty(ctx: *anyopaque) void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        if (self.text_ready) self.text_system.atlas.dirty = false;
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;

    const sdl = try dgpui.backend.sdl.SdlBackend.init(gpa, "dgpui — PR 3: Text Shaping & GlyphAtlas", 840, 620);
    defer sdl.deinitSelf();

    var state = DemoState{};
    try state.setupText(gpa);
    defer state.deinitText();

    var loop = dgpui.app.AppLoop.init(gpa, sdl.platformBackend(), sdl.rendererBackend());
    defer loop.deinit();
    loop.clear_color = dgpui.math.Color.fromHex(0x181926);
    loop.callbacks = .{
        .ctx = &state,
        .onEvent = DemoState.onEvent,
        .onRender = DemoState.onRender,
        .atlasFrame = DemoState.atlasFrame,
        .atlasClearDirty = DemoState.atlasClearDirty,
    };

    try loop.run();
}
