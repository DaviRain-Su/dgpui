//! 无头测试后端（HeadlessBackend）
//!
//! 同时实现 PlatformBackend 和 RendererBackend：
//! - 不创建任何操作系统窗口、不启动 Metal/GPU
//! - 测试代码可以往事件队列里塞入“假鼠标点击 / 假窗口缩放”
//! - 记录到底等待了多少次事件、合并后实际重绘了几帧、收到什么脏区

const std = @import("std");
const math = @import("../math.zig");
const scene = @import("../scene.zig");
const platform = @import("platform.zig");
const renderer = @import("renderer.zig");

pub const HeadlessBackend = struct {
    allocator: std.mem.Allocator,
    queue: std.ArrayList(platform.Event) = .empty,
    read_index: usize = 0,
    window_metrics: platform.WindowMetrics,

    // 用于测试断言的观测计数器
    wait_calls: usize = 0,
    redraw_requests: usize = 0,
    rendered_frames: usize = 0,
    last_frame_params: ?renderer.FrameParams = null,
    last_damage_rect: ?math.Rect = null,
    last_command_count: usize = 0,
    last_batch_count: usize = 0,
    last_instance_count: usize = 0,
    current_cursor: platform.CursorShape = .arrow,
    last_resize_physical: ?struct { w: u32, h: u32 } = null,

    pub fn init(allocator: std.mem.Allocator, initial_metrics: platform.WindowMetrics) HeadlessBackend {
        return .{
            .allocator = allocator,
            .window_metrics = initial_metrics,
        };
    }

    pub fn deinitSelf(self: *HeadlessBackend) void {
        self.queue.deinit(self.allocator);
    }

    pub fn pushEvent(self: *HeadlessBackend, ev: platform.Event) !void {
        try self.queue.append(self.allocator, ev);
    }

    pub fn platformBackend(self: *HeadlessBackend) platform.PlatformBackend {
        return .{
            .ptr = self,
            .vtable = &platform_vtable,
        };
    }

    pub fn rendererBackend(self: *HeadlessBackend) renderer.RendererBackend {
        return .{
            .ptr = self,
            .vtable = &renderer_vtable,
        };
    }

    fn popNext(self: *HeadlessBackend) ?platform.Event {
        if (self.read_index >= self.queue.items.len) return null;
        const ev = self.queue.items[self.read_index];
        self.read_index += 1;

        // 同步维护窗口尺寸状态
        switch (ev) {
            .resized => |m| self.window_metrics = m,
            .scale_changed => |m| self.window_metrics = m,
            .quit, .redraw_requested, .mouse_move, .mouse_down, .mouse_up, .scroll, .key_down, .text_input, .text_editing => {},
        }
        return ev;
    }

    const platform_vtable: platform.PlatformBackend.VTable = .{
        .waitEvent = struct {
            fn call(ptr: *anyopaque) ?platform.Event {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                self.wait_calls += 1;
                return self.popNext();
            }
        }.call,
        .pollEvent = struct {
            fn call(ptr: *anyopaque) ?platform.Event {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                return self.popNext();
            }
        }.call,
        .metrics = struct {
            fn call(ptr: *anyopaque) platform.WindowMetrics {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                return self.window_metrics;
            }
        }.call,
        .requestRedraw = struct {
            fn call(ptr: *anyopaque) void {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                self.redraw_requests += 1;
            }
        }.call,
        .setCursor = struct {
            fn call(ptr: *anyopaque, shape: platform.CursorShape) void {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                self.current_cursor = shape;
            }
        }.call,
        .deinit = struct {
            fn call(ptr: *anyopaque) void {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                self.deinitSelf();
            }
        }.call,
    };

    const renderer_vtable: renderer.RendererBackend.VTable = .{
        .renderFrame = struct {
            fn call(ptr: *anyopaque, params: renderer.FrameParams) anyerror!void {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                self.rendered_frames += 1;
                self.last_frame_params = params;
                self.last_damage_rect = params.damage_rect;
                if (params.display_list) |dl| {
                    self.last_command_count = dl.commands.items.len;
                    var built = try dl.buildBatches(self.allocator);
                    defer built.deinit(self.allocator);
                    self.last_batch_count = built.batches.len;
                    self.last_instance_count = built.instances.len;
                } else {
                    self.last_command_count = 0;
                    self.last_batch_count = 0;
                    self.last_instance_count = 0;
                }
            }
        }.call,
        .resize = struct {
            fn call(ptr: *anyopaque, physical_width: u32, physical_height: u32) void {
                const self: *HeadlessBackend = @ptrCast(@alignCast(ptr));
                self.last_resize_physical = .{ .w = physical_width, .h = physical_height };
            }
        }.call,
        .deinit = struct {
            fn call(_: *anyopaque) void {}
        }.call,
    };
};

test "headless backend records events and rendered frames" {
    var hb = HeadlessBackend.init(std.testing.allocator, .{
        .logical_width = 800,
        .logical_height = 600,
        .scale_factor = 2.0,
    });
    defer hb.deinitSelf();

    try hb.pushEvent(.{ .mouse_move = .{ .x = 10, .y = 20 } });
    try hb.pushEvent(.quit);

    const pb = hb.platformBackend();
    const rb = hb.rendererBackend();

    try std.testing.expectEqual(@as(u32, 1600), pb.metrics().physicalWidth());
    try std.testing.expect(pb.waitEvent().? == .mouse_move);
    try std.testing.expect(pb.pollEvent().? == .quit);
    try std.testing.expect(pb.pollEvent() == null);

    try rb.renderFrame(.{
        .logical_size = pb.metrics().logicalSize(),
        .scale_factor = pb.metrics().scale_factor,
        .clear_color = math.Color.fromHex(0x1e1e2e),
    });
    try std.testing.expectEqual(@as(usize, 1), hb.rendered_frames);
    try std.testing.expectEqual(@as(?math.Rect, null), hb.last_damage_rect);

    const damage = math.Rect.init(4, 5, 6, 7);
    try rb.renderFrame(.{
        .logical_size = pb.metrics().logicalSize(),
        .scale_factor = pb.metrics().scale_factor,
        .clear_color = math.Color.fromHex(0x1e1e2e),
        .damage_rect = damage,
    });
    try std.testing.expectEqual(@as(usize, 2), hb.rendered_frames);
    try std.testing.expectEqual(damage, hb.last_damage_rect.?);
}
