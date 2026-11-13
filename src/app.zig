//! 事件主循环与重绘合并器（Event Loop + Redraw Coalescing）
//!
//! 面试重点：GUI 循环和游戏循环的本质区别
//! - 游戏循环：while(running) { update(); render(); } -> 永远 60/120fps 空转。
//! - GUI 循环：没有事件时调用 waitEvent() **阻塞休眠**（CPU ≈ 0%）；
//!   醒来后先用 pollEvent() 把当前一批积压的事件全部消化完，如果期间有多个事件
//!   都调用了 requestRedraw()，只设 dirty = true，最终**合并成 1 次渲染提交**。

const std = @import("std");
const math = @import("math.zig");
const arena = @import("arena.zig");
const scene = @import("scene.zig");
const platform = @import("backend/platform.zig");
const renderer = @import("backend/renderer.zig");
const HeadlessBackend = @import("backend/headless.zig").HeadlessBackend;

pub const AppCallbacks = struct {
    ctx: *anyopaque,
    onEvent: ?*const fn (ctx: *anyopaque, ev: platform.Event, loop: *AppLoop) void = null,
    onRender: ?*const fn (
        ctx: *anyopaque,
        dl: *scene.DisplayList,
        frame_alloc: std.mem.Allocator,
        metrics: platform.WindowMetrics,
    ) anyerror!void = null,
};

pub const AppLoop = struct {
    allocator: std.mem.Allocator,
    platform_backend: platform.PlatformBackend,
    renderer_backend: renderer.RendererBackend,
    frame_arena: arena.FrameArena,
    display_list: scene.DisplayList,
    prev_display_list: ?scene.DisplayList = null,
    clear_color: math.Color = math.Color.fromHex(0x1e1e2e),
    needs_redraw: bool = true,
    running: bool = true,
    callbacks: ?AppCallbacks = null,

    pub fn init(
        allocator: std.mem.Allocator,
        platform_backend: platform.PlatformBackend,
        renderer_backend: renderer.RendererBackend,
    ) AppLoop {
        return .{
            .allocator = allocator,
            .platform_backend = platform_backend,
            .renderer_backend = renderer_backend,
            .frame_arena = arena.FrameArena.init(allocator),
            .display_list = scene.DisplayList.init(allocator),
        };
    }

    pub fn deinit(self: *AppLoop) void {
        if (self.prev_display_list) |*prev| prev.deinit();
        self.display_list.deinit();
        self.frame_arena.deinit();
    }

    pub fn requestRedraw(self: *AppLoop) void {
        if (!self.needs_redraw) {
            self.needs_redraw = true;
            self.platform_backend.requestRedraw();
        }
    }

    pub fn quit(self: *AppLoop) void {
        self.running = false;
    }

    /// 运行主循环，直到收到 quit 事件或事件流结束
    pub fn run(self: *AppLoop) !void {
        // 首次启动先画第一帧
        if (self.needs_redraw) {
            try self.drawOnce();
        }

        while (self.running) {
            // 1. 阻塞等待：没有事做时 CPU 休眠
            const first_ev = self.platform_backend.waitEvent() orelse break;
            self.handleEvent(first_ev);

            // 2. 非阻塞排空：把同一批队列里的其他事件一次性吃掉
            while (self.running) {
                const next_ev = self.platform_backend.pollEvent() orelse break;
                self.handleEvent(next_ev);
            }

            // 3. 重绘合并：无论这一批来了多少个 resize/click，只渲染 1 次
            if (self.running and self.needs_redraw) {
                try self.drawOnce();
            }
        }
    }

    fn handleEvent(self: *AppLoop, ev: platform.Event) void {
        switch (ev) {
            .quit => {
                self.running = false;
                return;
            },
            .resized => |m| {
                self.renderer_backend.resize(m.physicalWidth(), m.physicalHeight());
                self.needs_redraw = true;
            },
            .scale_changed => |m| {
                self.renderer_backend.resize(m.physicalWidth(), m.physicalHeight());
                self.needs_redraw = true;
            },
            .redraw_requested => {
                self.needs_redraw = true;
            },
            // 输入事件留给回调。text_editing 只是翻译进了平台事件，循环本身还不画 IME。
            .mouse_move, .mouse_down, .mouse_up, .scroll, .key_down, .text_input, .text_editing => {},
        }

        if (self.callbacks) |cb| {
            if (cb.onEvent) |handler| {
                handler(cb.ctx, ev, self);
            }
        }
    }

    fn drawOnce(self: *AppLoop) !void {
        self.needs_redraw = false;
        defer self.frame_arena.reset();

        const m = self.platform_backend.metrics();
        self.display_list.clearRetainingCapacity();

        var has_scene = false;
        if (self.callbacks) |cb| {
            if (cb.onRender) |render_fn| {
                try render_fn(cb.ctx, &self.display_list, self.frame_arena.allocator(), m);
                has_scene = true;
            }
        }

        const damage: ?math.Rect = if (has_scene and self.prev_display_list != null)
            scene.DamageRegion.fromDisplayListDiff(&self.prev_display_list.?, &self.display_list).rect
        else
            null;

        try self.renderer_backend.renderFrame(.{
            .logical_size = m.logicalSize(),
            .scale_factor = m.scale_factor,
            .clear_color = self.clear_color,
            .display_list = if (has_scene) &self.display_list else null,
            .damage_rect = damage,
        });

        if (has_scene) {
            if (self.prev_display_list) |*prev| {
                prev.clearRetainingCapacity();
                try prev.commands.appendSlice(self.allocator, self.display_list.commands.items);
            } else {
                self.prev_display_list = try self.display_list.clone(self.allocator);
            }
        }
    }
};

test "event loop sleeps on idle and coalesces multiple redraw requests into 1 frame" {
    var hb = HeadlessBackend.init(std.testing.allocator, .{
        .logical_width = 400,
        .logical_height = 300,
        .scale_factor = 2.0,
    });
    defer hb.deinitSelf();

    // 同一批次塞入连续两次 resize + 一次 redraw_requested，不立即 quit，让主循环完成本轮合并渲染后退出
    try hb.pushEvent(.{ .resized = .{
        .logical_width = 500,
        .logical_height = 300,
        .scale_factor = 2.0,
    } });
    try hb.pushEvent(.{ .resized = .{
        .logical_width = 600,
        .logical_height = 400,
        .scale_factor = 2.0,
    } });
    try hb.pushEvent(.redraw_requested);

    var loop = AppLoop.init(std.testing.allocator, hb.platformBackend(), hb.rendererBackend());
    defer loop.deinit();
    try loop.run();

    // 首帧 1 次 + 批处理合并后 1 次 = 总共仅 2 帧（而不是 4 帧）
    try std.testing.expectEqual(@as(usize, 2), hb.rendered_frames);
    try std.testing.expectEqual(@as(usize, 2), hb.wait_calls);
    try std.testing.expectEqual(@as(u32, 1200), hb.last_resize_physical.?.w);
    try std.testing.expectEqual(@as(u32, 800), hb.last_resize_physical.?.h);
    // 无场景回调时传给渲染器的 damage_rect 保持 null（整屏）。
    try std.testing.expectEqual(@as(?math.Rect, null), hb.last_damage_rect);
}

test "resize uses normalized metrics and keeps SizeInPixels" {
    var hb = HeadlessBackend.init(std.testing.allocator, .{
        .logical_width = 800,
        .logical_height = 600,
        .scale_factor = 1,
    });
    defer hb.deinitSelf();

    const normalized = platform.metricsFromPlatformSizes(.{
        .logical_width = 1600,
        .logical_height = 1200,
        .pixel_width = 1600,
        .pixel_height = 1200,
        .pixel_density = 1,
        .content_scale = 2,
    });
    try std.testing.expectEqual(@as(f32, 800), normalized.logical_width);
    try std.testing.expectEqual(@as(f32, 600), normalized.logical_height);
    try std.testing.expectEqual(@as(f32, 2), normalized.scale_factor);
    try std.testing.expectEqual(@as(f32, 2), normalized.content_scale);
    try std.testing.expectEqual(@as(f32, 1), normalized.pixel_density);

    try hb.pushEvent(.{ .resized = normalized });
    var loop = AppLoop.init(std.testing.allocator, hb.platformBackend(), hb.rendererBackend());
    defer loop.deinit();
    try loop.run();

    try std.testing.expectEqual(@as(u32, 1600), hb.last_resize_physical.?.w);
    try std.testing.expectEqual(@as(u32, 1200), hb.last_resize_physical.?.h);
}

test "AppLoop resets FrameArena each frame and computes DamageRegion between frames" {
    const SceneState = struct {
        active: bool = false,

        fn onEvent(ctx: *anyopaque, ev: platform.Event, loop: *AppLoop) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (ev == .mouse_down) {
                self.active = !self.active;
                loop.requestRedraw();
            }
        }

        fn onRender(
            ctx: *anyopaque,
            dl: *scene.DisplayList,
            frame_alloc: std.mem.Allocator,
            _: platform.WindowMetrics,
        ) !void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            // 从 FrameArena 分配一笔临时字符串，验证帧末会释放容量复用且不泄漏
            _ = try frame_alloc.dupe(u8, "frame-temp");

            try dl.pushQuad(.{
                .bounds = math.Rect.init(0, 0, 800, 600),
                .background = math.Color.fromHex(0x1e1e2e),
            });
            try dl.pushQuad(.{
                .bounds = math.Rect.init(50, 60, 120, 40),
                .background = if (self.active) math.Color.fromHex(0x89b4fa) else math.Color.fromHex(0x313244),
                .corner_radius = 8,
            });
        }
    };

    var hb = HeadlessBackend.init(std.testing.allocator, .{
        .logical_width = 800,
        .logical_height = 600,
        .scale_factor = 2.0,
    });
    defer hb.deinitSelf();

    try hb.pushEvent(.{ .mouse_down = .{ .pos = .{ .x = 80, .y = 75 }, .button = .left, .clicks = 1 } });

    var st = SceneState{};
    var loop = AppLoop.init(std.testing.allocator, hb.platformBackend(), hb.rendererBackend());
    defer loop.deinit();
    loop.callbacks = .{
        .ctx = &st,
        .onEvent = SceneState.onEvent,
        .onRender = SceneState.onRender,
    };

    try loop.run();

    try std.testing.expectEqual(@as(usize, 2), hb.rendered_frames);
    try std.testing.expectEqual(@as(usize, 2), loop.frame_arena.frame_count);
    try std.testing.expectEqual(@as(usize, 1), hb.last_batch_count);
    try std.testing.expectEqual(@as(usize, 2), hb.last_instance_count);
    // 第 2 帧只有 (50, 60, 120, 40) 变色了，背景没变，所以脏区精确等于按钮矩形
    try std.testing.expectEqual(math.Rect.init(50, 60, 120, 40), hb.last_damage_rect.?);
}
