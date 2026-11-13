//! 事件主循环与重绘合并器（Event Loop + Redraw Coalescing）
//!
//! 面试重点：GUI 循环和游戏循环的本质区别
//! - 游戏循环：while(running) { update(); render(); } -> 永远 60/120fps 空转。
//! - GUI 循环：没有事件时调用 waitEvent() **阻塞休眠**（CPU ≈ 0%）；
//!   醒来后先用 pollEvent() 把当前一批积压的事件全部消化完，如果期间有多个事件
//!   都调用了 requestRedraw()，只设 dirty = true，最终**合并成 1 次渲染提交**。

const std = @import("std");
const math = @import("math.zig");
const platform = @import("backend/platform.zig");
const renderer = @import("backend/renderer.zig");
const HeadlessBackend = @import("backend/headless.zig").HeadlessBackend;

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
        try self.renderer_backend.renderFrame(.{
            .logical_size = m.logicalSize(),
            .scale_factor = m.scale_factor,
            .clear_color = self.clear_color,
            // TODO(PR2): 这里还不会算脏区并集。null = 整屏。字段已经接到渲染后端，只是还不用来裁剪。
            .damage_rect = null,
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

test "resize reports explicit pixel size instead of logical times content scale" {
    var hb = HeadlessBackend.init(std.testing.allocator, .{
        .logical_width = 800,
        .logical_height = 600,
        .scale_factor = 1,
    });
    defer hb.deinitSelf();

    // Windows 200% 那种数字：逻辑尺寸已经等于像素，content_scale 是 2，不能再乘一次。
    try hb.pushEvent(.{ .resized = .{
        .logical_width = 3840,
        .logical_height = 2160,
        .scale_factor = 1,
        .content_scale = 2,
        .pixel_width = 3840,
        .pixel_height = 2160,
    } });

    var loop = AppLoop.init(hb.platformBackend(), hb.rendererBackend());
    try loop.run();

    try std.testing.expectEqual(@as(u32, 3840), hb.last_resize_physical.?.w);
    try std.testing.expectEqual(@as(u32, 2160), hb.last_resize_physical.?.h);
}
