//! 平台后端抽象（PlatformBackend）
//!
//! 为什么要抽这层接口？
//! GUI 核心引擎（布局、状态、Hitbox、DisplayList）不应该直接依赖 macOS AppKit、SDL3 或 Linux X11。
//! 把“怎么开窗口、怎么等事件、怎么拿缩放比”抽象成统一的 VTable 接口后：
//!   1. 桌面端可以接 SDL3 / winit；
//!   2. 测试时可以接 HeadlessBackend（零窗口、可注入假事件）；
//!   3. 嵌入式 Linux 可以接 DRM/KMS + libinput（无窗口系统，直接 scanout）。

const std = @import("std");
const math = @import("../math.zig");

pub const CursorShape = enum {
    arrow,
    pointer,
    text,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    other,
};

pub const KeyCode = enum {
    unknown,
    enter,
    backspace,
    tab,
    escape,
    space,
    up,
    down,
    left,
    right,
    character,
};

pub const WindowMetrics = struct {
    /// 逻辑宽高：布局引擎只看这个值（比如 800x600），与屏幕是不是 Retina 无关
    logical_width: f32,
    logical_height: f32,
    /// DPI 缩放倍数：普通屏 1.0，Mac Retina 屏通常是 2.0
    scale_factor: f32,

    pub fn physicalWidth(self: WindowMetrics) u32 {
        return @intFromFloat(@max(1.0, @round(self.logical_width * self.scale_factor)));
    }

    pub fn physicalHeight(self: WindowMetrics) u32 {
        return @intFromFloat(@max(1.0, @round(self.logical_height * self.scale_factor)));
    }

    pub fn logicalSize(self: WindowMetrics) math.Size {
        return .{ .width = self.logical_width, .height = self.logical_height };
    }
};

/// 跨后端统一输入事件
pub const Event = union(enum) {
    quit,
    resized: WindowMetrics,
    scale_changed: WindowMetrics,
    redraw_requested,
    mouse_move: math.Point,
    mouse_down: struct {
        pos: math.Point,
        button: MouseButton,
        clicks: u8,
    },
    mouse_up: struct {
        pos: math.Point,
        button: MouseButton,
    },
    scroll: struct {
        pos: math.Point,
        dx: f32,
        dy: f32,
    },
    key_down: struct {
        key: KeyCode,
        repeat: bool,
    },
    text_input: struct {
        /// 仅在当前事件处理周期内有效；如需保留必须复制到持久缓冲
        utf8: [32]u8,
        len: u8,

        pub fn slice(self: *const @This()) []const u8 {
            return self.utf8[0..self.len];
        }
    },
};

/// 平台抽象接口（Zig 手写 VTable，对应 Rust 的 `trait PlatformBackend`）
pub const PlatformBackend = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// 阻塞等待下一条系统事件：没有事件时线程休眠，CPU 占用接近 0%
        waitEvent: *const fn (ptr: *anyopaque) ?Event,
        /// 非阻塞取出排队的下一条事件：用于在醒来后一次性排空事件队列
        pollEvent: *const fn (ptr: *anyopaque) ?Event,
        /// 查询当前窗口的逻辑尺寸与 DPI 缩放比
        metrics: *const fn (ptr: *anyopaque) WindowMetrics,
        /// 标记需要重绘（向系统事件队列注入唤醒信号，避免死锁在 waitEvent 里）
        requestRedraw: *const fn (ptr: *anyopaque) void,
        /// 切换鼠标指针形状
        setCursor: *const fn (ptr: *anyopaque, shape: CursorShape) void,
        /// 释放底层平台资源
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn waitEvent(self: PlatformBackend) ?Event {
        return self.vtable.waitEvent(self.ptr);
    }

    pub fn pollEvent(self: PlatformBackend) ?Event {
        return self.vtable.pollEvent(self.ptr);
    }

    pub fn metrics(self: PlatformBackend) WindowMetrics {
        return self.vtable.metrics(self.ptr);
    }

    pub fn requestRedraw(self: PlatformBackend) void {
        self.vtable.requestRedraw(self.ptr);
    }

    pub fn setCursor(self: PlatformBackend, shape: CursorShape) void {
        self.vtable.setCursor(self.ptr, shape);
    }

    pub fn deinit(self: PlatformBackend) void {
        self.vtable.deinit(self.ptr);
    }
};
