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
    /// 归一化后的逻辑宽高（单位：逻辑点）。布局和命中测试只看这个值：
    /// 有像素尺寸和 `content_scale` 时按 `pixel / content_scale` 计算，
    /// 让 macOS Retina、Windows 200%、X11 拿到一致的逻辑坐标系。
    logical_width: f32,
    logical_height: f32,
    /// 逻辑点到物理像素的缩放系数（`content_scale`，无 `SizeInPixels` 回退时为 `pixel_density`）。
    scale_factor: f32,
    /// 内容缩放（`SDL_GetWindowDisplayScale`）：系统希望 UI 放大多少。
    content_scale: f32 = 1,
    /// 原始 `SDL_GetWindowPixelDensity`：1 个 SDL 窗口坐标对应多少物理像素。
    pixel_density: f32 = 1,
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
    /// `<= 0` 表示 `SDL_GetWindowDisplayScale` 失败，这时退回像素密度。
    /// 有权威像素时，逻辑尺寸是 `pixel / content_scale`。物理像素仍以 `SizeInPixels` 为准。
    content_scale: f32 = 0,
};

pub fn metricsFromPlatformSizes(in: PlatformSizeQuery) WindowMetrics {
    const win_w: i32 = if (in.logical_width > 0) in.logical_width else 1;
    const win_h: i32 = if (in.logical_height > 0) in.logical_height else 1;
    const pixel_w = positivePixel(in.pixel_width);
    const pixel_h = positivePixel(in.pixel_height);

    const density = if (in.pixel_density > 0 and std.math.isFinite(in.pixel_density))
        in.pixel_density
    else if (pixel_w) |w|
        @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(win_w))
    else
        1;
    const has_explicit_content = in.content_scale > 0 and std.math.isFinite(in.content_scale);
    const content = if (has_explicit_content) in.content_scale else density;

    // 当同时拿到权威物理像素 (`SizeInPixels`) 和 `content_scale` (`SDL_GetWindowDisplayScale`) 时，
    // 用 `pixel / content_scale` 推导逻辑尺寸，消除 Windows/X11 与 macOS 窗口坐标语义差异。
    const logical_w: f32 = if (pixel_w != null and has_explicit_content)
        @max(1.0, @as(f32, @floatFromInt(pixel_w.?)) / content)
    else
        @floatFromInt(win_w);
    const logical_h: f32 = if (pixel_h != null and has_explicit_content)
        @max(1.0, @as(f32, @floatFromInt(pixel_h.?)) / content)
    else
        @floatFromInt(win_h);

    return .{
        .logical_width = logical_w,
        .logical_height = logical_h,
        .scale_factor = if (pixel_w != null and has_explicit_content) content else density,
        .content_scale = content,
        .pixel_density = density,
        .pixel_width = pixel_w,
        .pixel_height = pixel_h,
    };
}

/// 将 SDL 窗口坐标（如 `motion.x/y`、`button.x/y`）归一到框架逻辑坐标系。
/// - macOS Retina：`window_w == logical_width` -> 乘数 1.0
/// - Windows/X11 200%：`window_w == 2 * logical_width` -> 乘数 0.5
pub fn windowPointToLogical(window_w: i32, window_h: i32, metrics: WindowMetrics, pt: math.Point) math.Point {
    const sx = if (window_w > 0) metrics.logical_width / @as(f32, @floatFromInt(window_w)) else 1.0;
    const sy = if (window_h > 0) metrics.logical_height / @as(f32, @floatFromInt(window_h)) else 1.0;
    return .{
        .x = pt.x * sx,
        .y = pt.y * sy,
    };
}

pub const WindowCoordSize = struct {
    w: i32,
    h: i32,
};

/// 把「调用方要的逻辑尺寸」换回 `SDL_CreateWindow` 使用的窗口坐标。
/// macOS 上窗口坐标已经等于逻辑尺寸，结果不变。
/// Windows/X11 200% 上窗口坐标是像素，第一次按 800×600 建出来逻辑只有 400×300，
/// 这里返回 1600×1200，让 `pixel / content_scale` 重新等于请求值。
pub fn windowSizeForRequestedLogical(
    requested_w: i32,
    requested_h: i32,
    window_w: i32,
    window_h: i32,
    logical_w: f32,
    logical_h: f32,
) WindowCoordSize {
    const req_w: f32 = @floatFromInt(@max(requested_w, 1));
    const req_h: f32 = @floatFromInt(@max(requested_h, 1));
    const win_w: f32 = @floatFromInt(@max(window_w, 1));
    const win_h: f32 = @floatFromInt(@max(window_h, 1));
    const log_w = if (logical_w > 0 and std.math.isFinite(logical_w)) logical_w else 1;
    const log_h = if (logical_h > 0 and std.math.isFinite(logical_h)) logical_h else 1;
    if (@abs(log_w - req_w) < 0.5 and @abs(log_h - req_h) < 0.5) {
        return .{ .w = @max(window_w, 1), .h = @max(window_h, 1) };
    }
    return .{
        .w = roundToWindowCoord(req_w * win_w / log_w),
        .h = roundToWindowCoord(req_h * win_h / log_h),
    };
}

fn roundToWindowCoord(v: f32) i32 {
    if (!std.math.isFinite(v) or v <= 1) return 1;
    const max_i: f32 = @floatFromInt(std.math.maxInt(i32));
    return @intFromFloat(@round(@min(v, max_i)));
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
/// 单条事件放不下时，`TEXT_INPUT` 会按码点拆成多条；非法 UTF-8 换成 U+FFFD 后继续。
pub const text_byte_cap = 256;

/// UTF-8 替换字符。非法或半截序列写成它，而不是把后面的字节丢掉。
pub const utf8_replacement = "\u{FFFD}";

pub const TextBytes = struct {
    utf8: [text_byte_cap]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const TextBytes) []const u8 {
        return self.utf8[0..self.len];
    }

    pub fn fromUtf8(src: []const u8) TextBytes {
        var out: TextBytes = .{};
        out.len = copyUtf8Bounded(&out.utf8, src).written;
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

/// 将任意长度的 UTF-8 文本按完整码点边界切分成一条或多条 `.text_input` 事件。
/// 非法字节换成 U+FFFD 后继续，不把后半段丢掉。
/// 分配失败时回滚到调用前的长度，一条残缺分片都不留。
pub fn appendTextInputChunks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Event),
    src: []const u8,
) !void {
    const start_len = out.items.len;
    errdefer out.shrinkRetainingCapacity(start_len);

    var rest = src;
    while (rest.len > 0) {
        var tb: TextBytes = .{};
        const copied = copyUtf8Bounded(&tb.utf8, rest);
        if (copied.consumed == 0) return error.NoSpaceLeft;
        tb.len = copied.written;
        try out.append(allocator, .{ .text_input = tb });
        rest = rest[copied.consumed..];
    }
}

/// `queueTextInputChunks` 的结果。SDL 后端只根据它决定发队列还是发截断前缀。
pub const QueuedTextInput = union(enum) {
    /// 全部分片已经追加进 `out`。
    queued,
    /// 分配失败，`out` 已回滚。`prefix` 是不分配内存就能发出的第一段（最多 256 字节），其余放弃。
    oom_prefix: Event,
};

/// SDL 文本输入的完整路径，不依赖 SDL。
/// 成功时分片在 `out` 里；失败时只给出第一段前缀，调用方必须打日志，不能假装没丢。
pub fn queueTextInputChunks(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Event),
    src: []const u8,
) QueuedTextInput {
    appendTextInputChunks(allocator, out, src) catch {
        return .{ .oom_prefix = textInputFromUtf8(src) };
    };
    return .queued;
}

pub const Utf8Copy = struct {
    written: usize,
    consumed: usize,
};

/// 把 `src` 拷进 `dst`。
/// 合法码点原样写入。非法起始字节、校验失败的序列、以及 src 末尾的半截序列，
/// 写成一个 U+FFFD 再继续。放不下下一个码点或替换字符时停住，且不消费这段，
/// 让调用方换一块空缓冲接着写。
pub fn copyUtf8Bounded(dst: []u8, src: []const u8) Utf8Copy {
    var written: usize = 0;
    var consumed: usize = 0;
    while (consumed < src.len) {
        const seq_len_u3 = std.unicode.utf8ByteSequenceLength(src[consumed]) catch {
            if (!writeUtf8Replacement(dst, &written)) break;
            consumed += 1;
            continue;
        };
        const seq_len: usize = seq_len_u3;
        if (consumed + seq_len > src.len) {
            if (!writeUtf8Replacement(dst, &written)) break;
            consumed = src.len;
            break;
        }
        if (!utf8SequenceValid(src[consumed..][0..seq_len])) {
            if (!writeUtf8Replacement(dst, &written)) break;
            consumed += 1;
            continue;
        }
        if (written + seq_len > dst.len) break;
        @memcpy(dst[written..][0..seq_len], src[consumed..][0..seq_len]);
        written += seq_len;
        consumed += seq_len;
    }
    return .{ .written = written, .consumed = consumed };
}

fn writeUtf8Replacement(dst: []u8, written: *usize) bool {
    if (written.* + utf8_replacement.len > dst.len) return false;
    @memcpy(dst[written.*..][0..utf8_replacement.len], utf8_replacement);
    written.* += utf8_replacement.len;
    return true;
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

test "utf-8 copy stops on a codepoint boundary and replaces invalid bytes" {
    const nihao = "你好";
    var buf: [4]u8 = undefined;
    const n = copyUtf8Bounded(&buf, nihao);
    try std.testing.expectEqual(@as(usize, 3), n.written);
    try std.testing.expectEqual(@as(usize, 3), n.consumed);
    try std.testing.expectEqualStrings("你", buf[0..n.written]);

    var tight: [2]u8 = undefined;
    const tight_copy = copyUtf8Bounded(&tight, "你");
    try std.testing.expectEqual(@as(usize, 0), tight_copy.written);
    try std.testing.expectEqual(@as(usize, 0), tight_copy.consumed);

    var mid: [3]u8 = undefined;
    const n2 = copyUtf8Bounded(&mid, "a你");
    try std.testing.expectEqualStrings("a", mid[0..n2.written]);
    try std.testing.expectEqual(@as(usize, 1), n2.consumed);

    var emo: [3]u8 = undefined;
    const emo_copy = copyUtf8Bounded(&emo, "🙂");
    try std.testing.expectEqual(@as(usize, 0), emo_copy.written);
    try std.testing.expectEqual(@as(usize, 0), emo_copy.consumed);
    var emo_ok: [4]u8 = undefined;
    const n3 = copyUtf8Bounded(&emo_ok, "🙂");
    try std.testing.expectEqualStrings("🙂", emo_ok[0..n3.written]);

    var bad: [8]u8 = undefined;
    const n4 = copyUtf8Bounded(&bad, "ok\xff!");
    try std.testing.expectEqualStrings("ok" ++ utf8_replacement ++ "!", bad[0..n4.written]);
    try std.testing.expectEqual(@as(usize, 4), n4.consumed);

    // 放不下 U+FFFD 时不消费这个坏字节，下一块空缓冲还能补上。
    var bad_tight: [4]u8 = undefined;
    const n4b = copyUtf8Bounded(&bad_tight, "ok\xff!");
    try std.testing.expectEqualStrings("ok", bad_tight[0..n4b.written]);
    try std.testing.expectEqual(@as(usize, 2), n4b.consumed);

    var partial: [8]u8 = undefined;
    const partial_copy = copyUtf8Bounded(&partial, "你"[0..2]);
    try std.testing.expectEqualStrings(utf8_replacement, partial[0..partial_copy.written]);
    try std.testing.expectEqual(@as(usize, 2), partial_copy.consumed);

    var exact: [6]u8 = undefined;
    const exact_copy = copyUtf8Bounded(&exact, "你好");
    try std.testing.expectEqualStrings("你好", exact[0..exact_copy.written]);
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

test "physical pixels and logical normalization work across macOS and Windows 200%" {
    // Windows 200%：SDL 窗口坐标是 3840x2160（已是像素），pixel_density=1，content_scale=2。
    // 归一化后逻辑尺寸应为 1920x1080，交换链物理像素仍为权威的 3840x2160（绝不是 7680）。
    const windows = metricsFromPlatformSizes(.{
        .logical_width = 3840,
        .logical_height = 2160,
        .pixel_width = 3840,
        .pixel_height = 2160,
        .pixel_density = 1,
        .content_scale = 2,
    });
    try std.testing.expectEqual(@as(f32, 1920), windows.logical_width);
    try std.testing.expectEqual(@as(f32, 1080), windows.logical_height);
    try std.testing.expectEqual(@as(u32, 3840), windows.physicalWidth());
    try std.testing.expectEqual(@as(u32, 2160), windows.physicalHeight());
    try std.testing.expectEqual(@as(f32, 2), windows.scale_factor);
    try std.testing.expectEqual(@as(f32, 1), windows.pixel_density);
    const win_mouse = windowPointToLogical(3840, 2160, windows, .{ .x = 1920, .y = 1080 });
    try std.testing.expectEqual(@as(f32, 960), win_mouse.x);
    try std.testing.expectEqual(@as(f32, 540), win_mouse.y);

    // macOS + HIGH_PIXEL_DENSITY：点坐标 1920x1080，像素 3840x2160，两个 scale 都是 2。
    const mac = metricsFromPlatformSizes(.{
        .logical_width = 1920,
        .logical_height = 1080,
        .pixel_width = 3840,
        .pixel_height = 2160,
        .pixel_density = 2,
        .content_scale = 2,
    });
    try std.testing.expectEqual(@as(f32, 1920), mac.logical_width);
    try std.testing.expectEqual(@as(u32, 3840), mac.physicalWidth());
    try std.testing.expectEqual(@as(u32, 2160), mac.physicalHeight());
    const mac_mouse = windowPointToLogical(1920, 1080, mac, .{ .x = 960, .y = 540 });
    try std.testing.expectEqual(@as(f32, 960), mac_mouse.x);
    try std.testing.expectEqual(@as(f32, 540), mac_mouse.y);

    // 调用方要 800×600 逻辑尺寸。macOS 窗口坐标已经是逻辑点，不用改。
    const mac_create = windowSizeForRequestedLogical(800, 600, 800, 600, 800, 600);
    try std.testing.expectEqual(@as(i32, 800), mac_create.w);
    try std.testing.expectEqual(@as(i32, 600), mac_create.h);

    // Windows/X11 200%：SDL_CreateWindow(800, 600) 的窗口坐标就是 800×600 像素，
    // 归一化逻辑只有 400×300。窗口坐标要调到 1600×1200，逻辑尺寸才回到 800×600。
    const win_create = windowSizeForRequestedLogical(800, 600, 800, 600, 400, 300);
    try std.testing.expectEqual(@as(i32, 1600), win_create.w);
    try std.testing.expectEqual(@as(i32, 1200), win_create.h);
    const win_after = metricsFromPlatformSizes(.{
        .logical_width = win_create.w,
        .logical_height = win_create.h,
        .pixel_width = win_create.w,
        .pixel_height = win_create.h,
        .pixel_density = 1,
        .content_scale = 2,
    });
    try std.testing.expectEqual(@as(f32, 800), win_after.logical_width);
    try std.testing.expectEqual(@as(f32, 600), win_after.logical_height);
    try std.testing.expectEqual(@as(f32, 2), win_after.scale_factor);
    try std.testing.expectEqual(@as(u32, 1600), win_after.physicalWidth());

    // 分数倍缩放下，交换链像素仍以 SizeInPixels 为准。
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

fn longTextFixture() [308]u8 {
    // 11 份「8 个汉字 + 1 个 emoji」= 28×11 = 308 字节，大于单包 256。
    const unit = "你好世界测试文本😀";
    std.debug.assert(unit.len == 28);
    var src: [308]u8 = undefined;
    for (0..11) |k| {
        @memcpy(src[k * unit.len ..][0..unit.len], unit);
    }
    return src;
}

test "appendTextInputChunks preserves full >256-byte Chinese and Emoji payload" {
    const gpa = std.testing.allocator;
    const src = longTextFixture();
    try std.testing.expectEqual(@as(usize, 308), src.len);

    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);

    try appendTextInputChunks(gpa, &events, &src);
    try std.testing.expect(events.items.len >= 2);

    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(gpa);
    for (events.items) |ev| {
        const s = ev.text_input.slice();
        try std.testing.expect(std.unicode.utf8ValidateSlice(s));
        try reassembled.appendSlice(gpa, s);
    }
    try std.testing.expectEqualStrings(&src, reassembled.items);
}

test "appendTextInputChunks keeps text after an invalid byte" {
    const gpa = std.testing.allocator;
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(gpa);
    try appendTextInputChunks(gpa, &events, "ok\xff世界");

    var reassembled: std.ArrayList(u8) = .empty;
    defer reassembled.deinit(gpa);
    for (events.items) |ev| {
        try reassembled.appendSlice(gpa, ev.text_input.slice());
    }
    try std.testing.expectEqualStrings("ok" ++ utf8_replacement ++ "世界", reassembled.items);
}

test "appendTextInputChunks rolls back on OOM without leaving partial chunks" {
    const src = longTextFixture();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    // 容量精确为 1：第一片用现成的槽，第二片无论走 alloc 还是 remap 都会失败。
    try events.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });

    try std.testing.expectError(error.OutOfMemory, appendTextInputChunks(failing.allocator(), &events, &src));
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "queueTextInputChunks reports the OOM prefix and keeps earlier events" {
    const src = longTextFixture();
    var events: std.ArrayList(Event) = .empty;
    defer events.deinit(std.testing.allocator);
    try events.ensureTotalCapacityPrecise(std.testing.allocator, 1);
    events.appendAssumeCapacity(textInputFromUtf8("keep"));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    const planned = queueTextInputChunks(failing.allocator(), &events, &src);
    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqualStrings("keep", events.items[0].text_input.slice());

    switch (planned) {
        .queued => try std.testing.expect(false),
        .oom_prefix => |ev| {
            const prefix = ev.text_input.slice();
            try std.testing.expect(prefix.len > 0);
            try std.testing.expect(prefix.len <= text_byte_cap);
            try std.testing.expect(std.unicode.utf8ValidateSlice(prefix));
            try std.testing.expect(std.mem.startsWith(u8, &src, prefix));
            try std.testing.expect(prefix.len < src.len);
        },
    }
}

test "mouse button codes match SDL_BUTTON values" {
    try std.testing.expectEqual(MouseButton.left, mouseButtonFromCode(1));
    try std.testing.expectEqual(MouseButton.middle, mouseButtonFromCode(2));
    try std.testing.expectEqual(MouseButton.right, mouseButtonFromCode(3));
    try std.testing.expectEqual(MouseButton.other, mouseButtonFromCode(0));
    try std.testing.expectEqual(MouseButton.other, mouseButtonFromCode(8));
}
