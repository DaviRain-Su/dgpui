//! 渲染后端抽象（RendererBackend）
//!
//! 为什么要把渲染也抽成接口？
//! 框架前半段算出来的只是“在哪画什么”（PR 2 会引入与 GPU 无关的 DisplayList）。
//! 真正把指令变成像素，可以接 Metal/Vulkan/wgpu，也可以接软件光栅或测试桩（Headless）。
//! 这和 Slint 支持 FemtoVG / Skia / Software 多渲染后端是同一个架构思路。

const math = @import("../math.zig");

pub const FrameParams = struct {
    logical_size: math.Size,
    scale_factor: f32,
    clear_color: math.Color,
    /// 可选的脏区矩形（逻辑像素）；为 null 时代表整屏重绘
    damage_rect: ?math.Rect = null,
};

pub const RendererBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 开始一帧渲染并提交本帧数据（后续 PR 2 会在这里传入 DisplayList）
        renderFrame: *const fn (ptr: *anyopaque, params: FrameParams) anyerror!void,
        /// 窗口像素尺寸变化时通知后端更新视口或交换链
        resize: *const fn (ptr: *anyopaque, physical_width: u32, physical_height: u32) void,
        /// 释放 GPU / 渲染器资源
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn renderFrame(self: RendererBackend, params: FrameParams) !void {
        return self.vtable.renderFrame(self.ptr, params);
    }

    pub fn resize(self: RendererBackend, physical_width: u32, physical_height: u32) void {
        self.vtable.resize(self.ptr, physical_width, physical_height);
    }

    pub fn deinit(self: RendererBackend) void {
        self.vtable.deinit(self.ptr);
    }
};
