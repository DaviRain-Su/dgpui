//! 事件主循环与重绘合并器（Event Loop + Redraw Coalescing）
//!
//! 面试重点：GUI 循环和游戏循环的本质区别
//! - 游戏循环：while(running) { update(); render(); } -> 永远 60/120fps 空转。
//! - GUI 循环：没有事件时调用 waitEvent() **阻塞休眠**（CPU ≈ 0%）；
//!   醒来后先用 pollEvent() 把当前一批积压的事件全部消化完，如果期间有多个事件
//!   都调用了 requestRedraw()，只设 dirty = true，最终**合并成 1 次渲染提交**。

const std = @import("std");
const math = @import("math.zig");
const display_list = @import("display_list.zig");
const FrameArena = @import("frame_arena.zig").FrameArena;
const platform = @import("backend/platform.zig");
const renderer = @import("backend/renderer.zig");
const HeadlessBackend = @import("backend/headless.zig").HeadlessBackend;

pub const FrameBuildFn = *const fn (ctx: *anyopaque, arena: *FrameArena) display_list.BuiltFrame;

pub const AppCallbacks = struct {
    ctx: *anyopaque,
    onEvent: ?*const fn (ctx: *anyopaque, ev: platform.Event, loop: *AppLoop) void = null,
};

pub const AppLoop = struct {
    platform_backend: platform.PlatformBackend,
    renderer_backend: renderer.RendererBackend,
    clear_color: math.Color = math.Color.fromHex(0x1e1e2e),
    needs_redraw: bool = true,
    running: bool = true,
    callbacks: ?AppCallbacks = null,
    /// 有的话，每帧先 `arena.reset` 的责任在回调里。没有就只清屏。
    frame_ctx: ?*anyopaque = null,
    frame_arena: ?*FrameArena = null,
    frame_build: ?FrameBuildFn = null,

    pub fn init(
        platform_backend: platform.PlatformBackend,
        renderer_backend: renderer.RendererBackend,
    ) AppLoop {
        return .{
            .platform_backend = platform_backend,
            .renderer_backend = renderer_backend,
        };
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
        const m = self.platform_backend.metrics();
        var built: ?display_list.BuiltFrame = null;
        if (self.frame_build) |build| {
            if (self.frame_arena) |arena| {
                if (self.frame_ctx) |ctx| built = build(ctx, arena);
            }
        }
        try self.renderer_backend.renderFrame(.{
            .logical_size = m.logicalSize(),
            .scale_factor = m.scale_factor,
            .clear_color = self.clear_color,
            .damage_rect = if (built) |frame| frame.damage else null,
            .display_list = if (built) |*frame| &frame.list else null,
        });
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

    var loop = AppLoop.init(hb.platformBackend(), hb.rendererBackend());
    try loop.run();

    // 首帧 1 次 + 批处理合并后 1 次 = 总共仅 2 帧（而不是 4 帧）
    try std.testing.expectEqual(@as(usize, 2), hb.rendered_frames);
    try std.testing.expectEqual(@as(usize, 2), hb.wait_calls);
    try std.testing.expectEqual(@as(u32, 1200), hb.last_resize_physical.?.w);
    try std.testing.expectEqual(@as(u32, 800), hb.last_resize_physical.?.h);
    // 主循环还没算脏区，传给渲染器的 damage_rect 保持 null（整屏）。
    try std.testing.expectEqual(@as(?math.Rect, null), hb.last_damage_rect);
}

test "resize uses normalized metrics and keeps SizeInPixels" {
    var hb = HeadlessBackend.init(std.testing.allocator, .{
        .logical_width = 800,
        .logical_height = 600,
        .scale_factor = 1,
    });
    defer hb.deinitSelf();

    // 现在的 metricsFromPlatformSizes 不会再产出
    // 「逻辑 3840、scale_factor 1、content_scale 2、像素 3840」。
    // Windows 200% 调完窗口后是：窗口坐标 1600×1200，content_scale 2，
    // 逻辑 800×600，scale_factor 2，像素仍是 1600×1200。
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
    var loop = AppLoop.init(hb.platformBackend(), hb.rendererBackend());
    try loop.run();

    try std.testing.expectEqual(@as(u32, 1600), hb.last_resize_physical.?.w);
    try std.testing.expectEqual(@as(u32, 1200), hb.last_resize_physical.?.h);
}

test "frame builder sends a display list and a partial damage rect" {
    var arena = try FrameArena.init(std.testing.allocator, 8192);
    defer arena.deinit();
    var hb = HeadlessBackend.init(std.testing.allocator, .{
        .logical_width = 400,
        .logical_height = 300,
        .scale_factor = 2,
    });
    defer hb.deinitSelf();

    const Builder = struct {
        fn build(ctx: *anyopaque, frame_arena: *FrameArena) display_list.BuiltFrame {
            _ = ctx;
            frame_arena.reset();
            var list = display_list.DisplayList.init(frame_arena);
            list.addQuad(.{
                .rect = math.Rect.init(8, 8, 40, 20),
                .radius = 4,
                .fill = math.Color.white,
            }) catch unreachable;
            list.addQuad(.{
                .rect = math.Rect.init(12, 10, 10, 10),
                .fill = math.Color.black,
            }) catch unreachable;
            return .{
                .list = list,
                .damage = math.Rect.init(8, 8, 40, 24),
            };
        }
    };

    try hb.pushEvent(.redraw_requested);
    var loop = AppLoop.init(hb.platformBackend(), hb.rendererBackend());
    loop.frame_ctx = &loop;
    loop.frame_arena = &arena;
    loop.frame_build = Builder.build;
    try loop.run();

    try std.testing.expect(hb.last_quad_count >= 2);
    try std.testing.expectEqual(@as(usize, 1), hb.last_batch_count);
    try std.testing.expect(!hb.last_clear_full);
    try std.testing.expect(hb.last_scissor.width > 0);
}
