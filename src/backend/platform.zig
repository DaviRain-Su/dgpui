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
    /// 窗口坐标里的宽高（`SDL_GetWindowSize`）。布局和命中测试只看这个值。
    logical_width: f32,
    logical_height: f32,
    /// 像素密度（`SDL_GetWindowPixelDensity`）：1 个窗口坐标对应多少物理像素。
    /// macOS 打开 `SDL_WINDOW_HIGH_PIXEL_DENSITY` 时 Retina 通常是 2.0。
    /// Windows 的窗口坐标本身就是像素，这里经常是 1.0，即使系统缩放是 200%。
    scale_factor: f32,
    /// 内容缩放（`SDL_GetWindowDisplayScale`）：系统希望 UI 放大多少。
    /// 它不是像素密度。Windows 200% 时这个值可以是 2.0，但交换链像素不能用它去乘逻辑尺寸。
    content_scale: f32 = 1,
    /// `SDL_GetWindowSizeInPixels` 的宽。有值时 `physicalWidth` 直接用它。
    pixel_width: ?u32 = null,
    /// `SDL_GetWindowSizeInPixels` 的高。有值时 `physicalHeight` 直接用它。
    pixel_height: ?u32 = null,

    pub fn physicalWidth(self: WindowMetrics) u32 {
        if (self.pixel_width) |w| return @max(w, 1);
        return logicalToPhysicalPixels(self.logical_width, self.scale_factor);
    }

    pub fn physicalHeight(self: WindowMetrics) u32 {
        if (self.pixel_height) |h| return @max(h, 1);
        return logicalToPhysicalPixels(self.logical_height, self.scale_factor);
    }

    pub fn logicalSize(self: WindowMetrics) math.Size {
        return .{ .width = self.logical_width, .height = self.logical_height };
    }
};

/// 调用方没拿到 `SDL_GetWindowSizeInPixels` 时的回退：四舍五入，最小 1。
/// 这不是交换链尺寸的权威来源。1.5 倍缩放下 `round(logical * density)` 可能和系统报的像素差 1。
pub fn logicalToPhysicalPixels(logical: f32, scale: f32) u32 {
    if (!std.math.isFinite(logical) or !std.math.isFinite(scale)) return 1;
    const px = logical * scale;
    if (!std.math.isFinite(px)) return 1;
    return @intFromFloat(@max(1.0, @round(px)));
}

/// SDL 一次查询得到的原始数字。测试可以直接构造它，不必链接 SDL。
pub const PlatformSizeQuery = struct {
    logical_width: i32,
    logical_height: i32,
    pixel_width: ?i32 = null,
    pixel_height: ?i32 = null,
    /// `<= 0` 表示 `SDL_GetWindowPixelDensity` 失败。有像素尺寸时用像素 / 逻辑尺寸估算。
    pixel_density: f32 = 0,
    /// `<= 0` 表示 `SDL_GetWindowDisplayScale` 失败，记成 1。不参与物理像素计算。
    content_scale: f32 = 0,
};

pub fn metricsFromPlatformSizes(in: PlatformSizeQuery) WindowMetrics {
    const logical_w: i32 = if (in.logical_width > 0) in.logical_width else 1;
    const logical_h: i32 = if (in.logical_height > 0) in.logical_height else 1;
    const pixel_w = positivePixel(in.pixel_width);
    const pixel_h = positivePixel(in.pixel_height);

    const density = if (in.pixel_density > 0 and std.math.isFinite(in.pixel_density))
        in.pixel_density
    else if (pixel_w) |w|
        @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(logical_w))
    else
        1;
    const content = if (in.content_scale > 0 and std.math.isFinite(in.content_scale)) in.content_scale else 1;

    return .{
        .logical_width = @floatFromInt(logical_w),
        .logical_height = @floatFromInt(logical_h),
        .scale_factor = density,
        .content_scale = content,
        .pixel_width = pixel_w,
        .pixel_height = pixel_h,
    };
}

fn positivePixel(v: ?i32) ?u32 {
    const n = v orelse return null;
    if (n <= 0) return null;
    return @intCast(n);
}

/// `SDL_BUTTON_LEFT` / `MIDDLE` / `RIGHT` 分别是 1 / 2 / 3。其余（含 0 和侧键）记成 `.other`。
pub fn mouseButtonFromCode(code: u8) MouseButton {
    return switch (code) {
        1 => .left,
        2 => .middle,
        3 => .right,
        else => .other,
    };
}

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
    /// 已提交的文本（对应 `SDL_EVENT_TEXT_INPUT`）。字节已经从 SDL 拷进定长缓冲。
    text_input: TextBytes,
    /// IME 预编辑（对应 `SDL_EVENT_TEXT_EDITING`）。本 PR 只翻译，界面还不画组合串。
    /// `start` / `length` 沿用 SDL 的定义：按 UTF-8 字符计，-1 表示未设置。
    text_editing: struct {
        bytes: TextBytes,
        start: i32,
        length: i32,

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes.slice();
        }
    },
};

/// 文本事件的定长缓冲。`Event` 按值进队列，所以不能持有 SDL 的指针。
/// 超长时在码点边界截断，避免把一个汉字或 emoji 切成非法 UTF-8。
pub const text_byte_cap = 256;

pub const TextBytes = struct {
    utf8: [text_byte_cap]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const TextBytes) []const u8 {
        return self.utf8[0..self.len];
    }

    pub fn fromUtf8(src: []const u8) TextBytes {
        var out: TextBytes = .{};
        out.len = copyUtf8Bounded(&out.utf8, src);
        return out;
    }
};

pub fn textInputFromUtf8(src: []const u8) Event {
    return .{ .text_input = TextBytes.fromUtf8(src) };
}

pub fn textEditingFromUtf8(src: []const u8, start: i32, length: i32) Event {
    return .{ .text_editing = .{
        .bytes = TextBytes.fromUtf8(src),
        .start = start,
        .length = length,
    } };
}

/// 把 `src` 拷进 `dst`，返回写入的字节数。只写入完整的 UTF-8 码点。
/// 源字符串在码点中间断开、或第一个字节就不是合法起始字节时，停在最后一个完整码点。
pub fn copyUtf8Bounded(dst: []u8, src: []const u8) usize {
    var i: usize = 0;
    while (i < src.len and i < dst.len) {
        const seq_len_u3 = std.unicode.utf8ByteSequenceLength(src[i]) catch break;
        const seq_len: usize = seq_len_u3;
        if (seq_len == 0 or i + seq_len > src.len or i + seq_len > dst.len) break;
        if (!utf8SequenceValid(src[i..][0..seq_len])) break;
        i += seq_len;
    }
    if (i > 0) @memcpy(dst[0..i], src[0..i]);
    return i;
}

fn utf8SequenceValid(seq: []const u8) bool {
    switch (seq.len) {
        1 => return seq[0] < 0x80,
        2 => return if (std.unicode.utf8Decode2(seq[0..2].*)) |_| true else |_| false,
        3 => return if (std.unicode.utf8Decode3(seq[0..3].*)) |_| true else |_| false,
        4 => return if (std.unicode.utf8Decode4(seq[0..4].*)) |_| true else |_| false,
        else => return false,
    }
}

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

test "utf-8 copy stops on a codepoint boundary" {
    const nihao = "你好";
    var buf: [4]u8 = undefined;
    const n = copyUtf8Bounded(&buf, nihao);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("你", buf[0..n]);

    var tight: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), copyUtf8Bounded(&tight, "你"));

    var mid: [3]u8 = undefined;
    const n2 = copyUtf8Bounded(&mid, "a你");
    try std.testing.expectEqualStrings("a", mid[0..n2]);

    var emo: [3]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), copyUtf8Bounded(&emo, "🙂"));
    var emo_ok: [4]u8 = undefined;
    const n3 = copyUtf8Bounded(&emo_ok, "🙂");
    try std.testing.expectEqualStrings("🙂", emo_ok[0..n3]);

    var bad: [8]u8 = undefined;
    const n4 = copyUtf8Bounded(&bad, "ok\xff!");
    try std.testing.expectEqualStrings("ok", bad[0..n4]);

    var partial: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), copyUtf8Bounded(&partial, "你"[0..2]));

    var exact: [6]u8 = undefined;
    try std.testing.expectEqualStrings("你好", exact[0..copyUtf8Bounded(&exact, "你好")]);
}

test "text events keep whole codepoints inside the fixed buffer" {
    var src: [text_byte_cap + 3]u8 = undefined;
    const ch = "你";
    var i: usize = 0;
    while (i + ch.len <= src.len) : (i += ch.len) {
        @memcpy(src[i..][0..ch.len], ch);
    }
    const input = textInputFromUtf8(src[0..i]);
    const slice = input.text_input.slice();
    try std.testing.expect(slice.len <= text_byte_cap);
    try std.testing.expectEqual(@as(usize, 0), slice.len % 3);
    try std.testing.expect(slice.len + ch.len > text_byte_cap);
    try std.testing.expectEqualStrings("你", slice[0..3]);

    const editing = textEditingFromUtf8("你a", 1, 2);
    try std.testing.expectEqualStrings("你a", editing.text_editing.slice());
    try std.testing.expectEqual(@as(i32, 1), editing.text_editing.start);
    try std.testing.expectEqual(@as(i32, 2), editing.text_editing.length);

    const empty = textInputFromUtf8("");
    try std.testing.expectEqual(@as(usize, 0), empty.text_input.len);
}

test "physical pixels come from SizeInPixels, not display scale" {
    // SDL highdpi 文档里的 Windows 200%：窗口坐标已经是像素，display scale 是 2，像素密度是 1。
    // 旧算法 logical * display_scale 会得到 7680，比真实交换链大一倍。
    const windows = metricsFromPlatformSizes(.{
        .logical_width = 3840,
        .logical_height = 2160,
        .pixel_width = 3840,
        .pixel_height = 2160,
        .pixel_density = 1,
        .content_scale = 2,
    });
    try std.testing.expectEqual(@as(u32, 3840), windows.physicalWidth());
    try std.testing.expectEqual(@as(u32, 2160), windows.physicalHeight());
    try std.testing.expectEqual(@as(f32, 1), windows.scale_factor);
    try std.testing.expectEqual(@as(f32, 2), windows.content_scale);
    const doubled = logicalToPhysicalPixels(windows.logical_width, windows.content_scale);
    try std.testing.expectEqual(@as(u32, 7680), doubled);
    try std.testing.expect(windows.physicalWidth() != doubled);

    // macOS + HIGH_PIXEL_DENSITY：点坐标 1920x1080，像素 3840x2160，两个 scale 都是 2。
    const mac = metricsFromPlatformSizes(.{
        .logical_width = 1920,
        .logical_height = 1080,
        .pixel_width = 3840,
        .pixel_height = 2160,
        .pixel_density = 2,
        .content_scale = 2,
    });
    try std.testing.expectEqual(@as(u32, 3840), mac.physicalWidth());
    try std.testing.expectEqual(@as(u32, 2160), mac.physicalHeight());

    // 分数倍缩放下，round(logical * density) 和系统报的像素可以差 1。以 SizeInPixels 为准。
    const odd = metricsFromPlatformSizes(.{
        .logical_width = 801,
        .logical_height = 100,
        .pixel_width = 1201,
        .pixel_height = 150,
        .pixel_density = 1.5,
        .content_scale = 1.5,
    });
    try std.testing.expectEqual(@as(u32, 1201), odd.physicalWidth());
    try std.testing.expectEqual(@as(u32, 150), odd.physicalHeight());
    try std.testing.expectEqual(@as(u32, 1202), logicalToPhysicalPixels(801, 1.5));

    // 没拿到像素尺寸时，才回退到 round(logical * pixel density)。headless 测试走这条。
    const fallback = metricsFromPlatformSizes(.{
        .logical_width = 800,
        .logical_height = 600,
        .pixel_density = 2,
    });
    try std.testing.expectEqual(@as(?u32, null), fallback.pixel_width);
    try std.testing.expectEqual(@as(u32, 1600), fallback.physicalWidth());
    try std.testing.expectEqual(@as(u32, 1200), fallback.physicalHeight());

    const derived = metricsFromPlatformSizes(.{
        .logical_width = 100,
        .logical_height = 50,
        .pixel_width = 200,
        .pixel_height = 100,
    });
    try std.testing.expectEqual(@as(f32, 2), derived.scale_factor);
    try std.testing.expectEqual(@as(u32, 200), derived.physicalWidth());
}

test "mouse button codes match SDL_BUTTON values" {
    try std.testing.expectEqual(MouseButton.left, mouseButtonFromCode(1));
    try std.testing.expectEqual(MouseButton.middle, mouseButtonFromCode(2));
    try std.testing.expectEqual(MouseButton.right, mouseButtonFromCode(3));
    try std.testing.expectEqual(MouseButton.other, mouseButtonFromCode(0));
    try std.testing.expectEqual(MouseButton.other, mouseButtonFromCode(8));
}
