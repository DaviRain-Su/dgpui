//! 基础几何与颜色类型：全框架统一使用**逻辑像素**（Logical Pixels）描述布局，
//! 仅在提交给 GPU/字形光栅化时乘以 `scale_factor` 换算为物理像素。

const std = @import("std");

pub const Point = struct {
    x: f32 = 0,
    y: f32 = 0,

    pub fn add(self: Point, other: Point) Point {
        return .{ .x = self.x + other.x, .y = self.y + other.y };
    }

    pub fn sub(self: Point, other: Point) Point {
        return .{ .x = self.x - other.x, .y = self.y - other.y };
    }
};

pub const Size = struct {
    width: f32 = 0,
    height: f32 = 0,

    pub fn isEmpty(self: Size) bool {
        return self.width <= 0 or self.height <= 0;
    }
};

pub const Rect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn init(x: f32, y: f32, width: f32, height: f32) Rect {
        return .{ .x = x, .y = y, .width = width, .height = height };
    }

    pub fn right(self: Rect) f32 {
        return self.x + self.width;
    }

    pub fn bottom(self: Rect) f32 {
        return self.y + self.height;
    }

    pub fn contains(self: Rect, pt: Point) bool {
        return pt.x >= self.x and pt.x < self.right() and pt.y >= self.y and pt.y < self.bottom();
    }

    pub fn isEmpty(self: Rect) bool {
        return self.width <= 0 or self.height <= 0;
    }

    /// 求两个矩形的并集（用于 Damage Region 脏矩形合并）
    pub fn unionWith(self: Rect, other: Rect) Rect {
        if (self.isEmpty()) return other;
        if (other.isEmpty()) return self;
        const min_x = @min(self.x, other.x);
        const min_y = @min(self.y, other.y);
        const max_r = @max(self.right(), other.right());
        const max_b = @max(self.bottom(), other.bottom());
        return .{
            .x = min_x,
            .y = min_y,
            .width = max_r - min_x,
            .height = max_b - min_y,
        };
    }

    /// 求两个矩形的交集（用于 Scissor 裁剪栈嵌套求交）
    pub fn intersect(self: Rect, other: Rect) Rect {
        const min_x = @max(self.x, other.x);
        const min_y = @max(self.y, other.y);
        const max_r = @min(self.right(), other.right());
        const max_b = @min(self.bottom(), other.bottom());
        return .{
            .x = min_x,
            .y = min_y,
            .width = @max(0, max_r - min_x),
            .height = @max(0, max_b - min_y),
        };
    }

    /// 逻辑像素矩形乘以 DPI 缩放，转换为物理像素矩形
    pub fn toPhysical(self: Rect, scale: f32) Rect {
        return .{
            .x = self.x * scale,
            .y = self.y * scale,
            .width = self.width * scale,
            .height = self.height * scale,
        };
    }
};

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 1 };

    /// 从 0xRRGGBB 构造不透明颜色，例如 Color.fromHex(0x1e1e2e)
    pub fn fromHex(hex: u24) Color {
        const r: f32 = @floatFromInt((hex >> 16) & 0xff);
        const g: f32 = @floatFromInt((hex >> 8) & 0xff);
        const b: f32 = @floatFromInt(hex & 0xff);
        return .{
            .r = r / 255.0,
            .g = g / 255.0,
            .b = b / 255.0,
            .a = 1.0,
        };
    }

    /// 从 0xRRGGBBAA 构造带透明通道的颜色
    pub fn fromHexRgba(hex: u32) Color {
        const r: f32 = @floatFromInt((hex >> 24) & 0xff);
        const g: f32 = @floatFromInt((hex >> 16) & 0xff);
        const b: f32 = @floatFromInt((hex >> 8) & 0xff);
        const a: f32 = @floatFromInt(hex & 0xff);
        return .{
            .r = r / 255.0,
            .g = g / 255.0,
            .b = b / 255.0,
            .a = a / 255.0,
        };
    }
};

test "rect union, intersect, and physical scaling" {
    const a = Rect.init(10, 20, 100, 50);
    const b = Rect.init(60, 40, 80, 60);

    const u = a.unionWith(b);
    try std.testing.expectEqual(@as(f32, 10), u.x);
    try std.testing.expectEqual(@as(f32, 20), u.y);
    try std.testing.expectEqual(@as(f32, 130), u.width);
    try std.testing.expectEqual(@as(f32, 80), u.height);

    const inter = a.intersect(b);
    try std.testing.expectEqual(@as(f32, 60), inter.x);
    try std.testing.expectEqual(@as(f32, 40), inter.y);
    try std.testing.expectEqual(@as(f32, 50), inter.width);
    try std.testing.expectEqual(@as(f32, 30), inter.height);

    const phys = a.toPhysical(2.0);
    try std.testing.expectEqual(@as(f32, 20), phys.x);
    try std.testing.expectEqual(@as(f32, 200), phys.width);
}
