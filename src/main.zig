const std = @import("std");
const dgpui = @import("dgpui");

const Counter = struct {
    clicks: usize = 0,
    accent_on: bool = false,
};

const DemoState = struct {
    entities: dgpui.entity.EntityStore = undefined,
    counter: Counter = .{},
    counter_id: dgpui.entity.EntityId = .{ .index = 0, .generation = 0 },
    view_key: u64 = 1,
    text_system: dgpui.text.TextSystem = undefined,
    text_ready: bool = false,
    scale: f32 = 1,

    fn setup(self: *DemoState, gpa: std.mem.Allocator) !void {
        self.entities = dgpui.entity.EntityStore.init(gpa);
        self.counter_id = try self.entities.insert(&self.counter);
        try self.entities.observe(self.counter_id, self.view_key);

        const path = dgpui.text.font.defaultFontPath() orelse {
            std.log.err("no system font found for demo text", .{});
            return error.FontNotFound;
        };
        try self.text_system.init(gpa, path.ptr, 1024, 1024);
        self.text_ready = true;
    }

    fn deinit(self: *DemoState) void {
        if (self.text_ready) self.text_system.deinit();
        self.text_ready = false;
        self.entities.deinit();
    }

    fn onBump(ctx: ?*anyopaque, _: dgpui.math.Point) bool {
        const self: *DemoState = @ptrCast(@alignCast(ctx.?));
        // 回调只持有持久 DemoState / EntityId，绝不捕获本帧 Element*
        if (self.entities.get(self.counter_id)) |ptr| {
            const c: *Counter = @ptrCast(@alignCast(ptr));
            c.clicks += 1;
            c.accent_on = !c.accent_on;
            self.entities.notify(self.counter_id) catch {};
            std.log.info("counter clicked -> {d}", .{c.clicks});
            return true;
        }
        return false;
    }

    fn onEvent(ctx: *anyopaque, ev: dgpui.backend.platform.Event, loop: *dgpui.app.AppLoop) void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .key_down => |kd| {
                if (kd.key == .escape) loop.quit();
            },
            else => {
                // mouse_down 由 AppLoop 通过 Hitbox 倒序命中处理；
                // Entity notify 的脏标记在此合并成一次 requestRedraw。
                if (self.entities.anyDirty()) {
                    self.entities.clearDirty();
                    loop.requestRedraw();
                }
            },
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
        hits: *dgpui.hitbox.HitList,
    ) !void {
        const self: *DemoState = @ptrCast(@alignCast(ctx));
        self.scale = metrics.scale_factor;

        const counter = if (self.entities.get(self.counter_id)) |ptr|
            @as(*Counter, @ptrCast(@alignCast(ptr))).*
        else
            self.counter;

        const accent = dgpui.math.Color.fromHex(if (counter.accent_on) 0xa6da95 else 0x8aadf4);
        const title_color = dgpui.math.Color.fromHex(0xcad3f5);
        const body_color = dgpui.math.Color.fromHex(0xa5adce);

        var counter_buf: [64]u8 = undefined;
        const counter_text = try std.fmt.bufPrint(&counter_buf, "clicks = {d}", .{counter.clicks});
        const card_w: f32 = @min(480.0, @max(280.0, metrics.logical_width - 64.0));

        // 可点击按钮：Hitbox 在 paintTreeHit 时登记；回调只持有 self。
        var button = (try dgpui.ui.div(frame_alloc))
            .flexRow()
            .items(.center)
            .justify(.center)
            .gap(8)
            .px(16)
            .py(10)
            .bg(accent)
            .rounded(10)
            .onClick(DemoState.onBump, self)
            .hitTag(1);
        button = try button.child(try dgpui.ui.textStyled(frame_alloc, "Bump Counter", 16, dgpui.math.Color.fromHex(0x1e1e2e)));

        var card = (try dgpui.ui.div(frame_alloc))
            .flexCol()
            .gap(12)
            .p(24)
            .w(card_w)
            .bg(dgpui.math.Color.fromHex(0x24273a))
            .border(dgpui.math.Color.fromHex(if (counter.accent_on) 0x8aadf4 else 0x494d64), 1.5)
            .rounded(16)
            .shadow(dgpui.math.Color.fromHexRgba(0x00000090), 20, .{ .x = 0, .y = 8 });
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, "dgpui · Entity + Hitbox", 22, title_color));
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, "observe/notify + reverse hit-test + bubble", 14, body_color));
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, "点击按钮：EntityStore 改状态并 notify；不要把 FrameArena 指针塞进回调", 15, accent));
        card = try card.child(try dgpui.ui.textStyled(frame_alloc, counter_text, 18, title_color));
        card = try card.child(button);

        var root = (try dgpui.ui.div(frame_alloc))
            .flexCol()
            .items(.center)
            .justify(.center)
            .w(metrics.logical_width)
            .h(metrics.logical_height);
        root = try root.child(card);

        const root_elem = root.finish();
        try dgpui.ui.layoutTree(root_elem, metrics.logicalSize(), frame_alloc, DemoState.measureText, self);
        try dgpui.ui.paintTreeHit(root_elem, dl, 0, 0, DemoState.paintText, self, hits, null, null);
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

    const sdl = try dgpui.backend.sdl.SdlBackend.init(gpa, "dgpui — PR 5: Entity + Hitbox", 900, 640);
    defer sdl.deinitSelf();

    var state = DemoState{};
    try state.setup(gpa);
    defer state.deinit();

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
