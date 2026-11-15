const std = @import("std");
const dgpui = @import("dgpui");

const DemoState = struct {
    clicks: usize = 0,
    accent_on: bool = false,
    text_system: dgpui.text.TextSystem = undefined,
    text_ready: bool = false,
    scale: f32 = 1,

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

    fn measureText(
        ctx: ?*anyopaque,
        bytes: []const u8,
        font_size: f32,
        max_width: dgpui.layout.AvailableSpace,
    ) dgpui.math.Size {
        const self: *DemoState = @ptrCast(@alignCast(ctx.?));
        if (!self.text_ready) {
            return .{ .width = @as(f32, @floatFromInt(bytes.len)) * font_size * 0.5, .height = font_size * 1.25 };
        }
        const mw: ?f32 = switch (max_width) {
            .definite => |v| v,
            .max_content => null,
        };
        return self.text_system.measureText(bytes, font_size, self.scale, mw) catch .{
            .width = @as(f32, @floatFromInt(bytes.len)) * font_size * 0.5,
            .height = font_size * 1.25,
        };
    }

    fn paintText(
        ctx: ?*anyopaque,
        dl: *dgpui.scene.DisplayList,
        text: dgpui.ui.element.TextContent,
        origin: dgpui.math.Point,
        max_width: f32,
    ) !void {
        const self: *DemoState = @ptrCast(@alignCast(ctx.?));
        if (!self.text_ready) return;
        var prepared = try self.text_system.prepareWrapped(
            text.bytes,
            origin,
            text.font_size,
            self.scale,
            max_width,
            text.color,
        );
        defer prepared.deinit(self.text_system.allocator);
        for (prepared.glyphs) |g| {
            try dl.pushGlyph(.{ .bounds = g.bounds, .uv = g.uv, .color = g.color });
        }
    }

    fn onRender(
        ctx: *anyopaque,
        dl: *dgpui.scene.DisplayList,
        frame_alloc: std.mem.Allocator,
        metrics: dgpui.backend.platform.WindowMetrics,
    ) !void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        self.scale = metrics.scale_factor;

        const accent = dgpui.math.Color.fromHex(if (self.accent_on) 0xa6da95 else 0x8aadf4);
        const title_color = dgpui.math.Color.fromHex(0xcad3f5);
        const body_color = dgpui.math.Color.fromHex(0xa5adce);

        var counter_buf: [64]u8 = undefined;
        const counter_text = try std.fmt.bufPrint(&counter_buf, "clicks = {d}", .{self.clicks});
        const card_w: f32 = @min(480.0, @max(280.0, metrics.logical_width - 64.0));

        // GPUI 风格链式 DSL：布局由 Flex 引擎算，不再手写绝对 x/y。
        var tags = (try dgpui.ui.div(frame_alloc)).flexRow().gap(10);
        tags = try tags.child((try dgpui.ui.div(frame_alloc)).bg(dgpui.math.Color.fromHex(0x363a4f)).rounded(17).w(88).h(34));
        tags = try tags.child((try dgpui.ui.div(frame_alloc)).bg(dgpui.math.Color.fromHex(0x363a4f)).rounded(17).w(72).h(34));
        tags = try tags.child((try dgpui.ui.div(frame_alloc)).bg(accent).rounded(10).grow(1).h(34));

        var card = (try dgpui.ui.div(frame_alloc))
            .flexCol()
            .gap(12)
            .p(24)
            .w(card_w)
            .bg(dgpui.math.Color.fromHex(0x24273a))
            .border(dgpui.math.Color.fromHex(if (self.accent_on) 0x8aadf4 else 0x494d64), 1.5)
            .rounded(16)
            .shadow(dgpui.math.Color.fromHexRgba(0x00000090), 20, .{ .x = 0, .y = 8 });
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, "dgpui · DSL + Flex", 22, title_color));
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, "HarfBuzz measure_text drives wrapping height", 14, body_color));
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, "Hello 世界 · 窗口变窄时这段字会自动折行并撑高卡片", 16, accent));
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, counter_text, 18, title_color));
        card = try card.child(tags);

        var root = (try dgpui.ui.div(frame_alloc))
            .flexCol()
            .items(.center)
            .justify(.center)
            .w(metrics.logical_width)
            .h(metrics.logical_height);
        root = try root.child(card);

        const root_elem = root.finish();
        try dgpui.ui.layoutTree(root_elem, metrics.logicalSize(), frame_alloc, DemoState.measureText, self);

        // 根高度若被内容撑开，重新用内容高度居中一次（教育向简化：直接 paint）
        try dgpui.ui.paintTree(root_elem, dl, 0, 0, DemoState.paintText, self);
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

    const sdl = try dgpui.backend.sdl.SdlBackend.init(gpa, "dgpui — PR 4: DSL + Flex", 900, 640);
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
