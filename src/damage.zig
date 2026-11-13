//! 脏区：把这一帧真正要重画的矩形并成一个。
//! `null` 表示整屏（和 PR 1 的 `damage_rect` 约定一样）。
//! 没有组件树，所以框架不会自动 diff 两帧；调用方把变了的矩形交进来。

const std = @import("std");
const math = @import("math.zig");
const platform = @import("backend/platform.zig");

pub const DamageRegion = struct {
    bounds: ?math.Rect = null,

    pub fn add(self: *DamageRegion, rect: math.Rect) void {
        if (rect.isEmpty()) return;
        self.bounds = if (self.bounds) |have| have.unionWith(rect) else rect;
    }

    /// 交给 `FrameParams.damage_rect`。没有脏矩形时返回 null，渲染端整屏清。
    pub fn frameRect(self: DamageRegion) ?math.Rect {
        const rect = self.bounds orelse return null;
        if (rect.isEmpty()) return null;
        return rect;
    }
};

pub const PresentPlan = struct {
    /// 真：整屏 `LOADOP_CLEAR`。假：保留屏外像素，只在剪刀矩形里画。
    clear_full: bool,
    /// 物理像素。空矩形表示这一帧不用画。
    scissor: math.Rect,
};

pub fn presentPlan(damage: ?math.Rect, logical_w: f32, logical_h: f32, scale: f32) PresentPlan {
    const safe_scale: f32 = if (scale > 0 and std.math.isFinite(scale)) scale else 1;
    const view = math.Rect{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(platform.logicalToPhysicalPixels(logical_w, safe_scale)),
        .height = @floatFromInt(platform.logicalToPhysicalPixels(logical_h, safe_scale)),
    };
    const dirty = damage orelse return .{ .clear_full = true, .scissor = view };
    if (dirty.isEmpty()) return .{ .clear_full = false, .scissor = .{ .width = 0, .height = 0 } };
    const snapped = snapOut(dirty.toPhysical(safe_scale)).intersect(view);
    const covers = snapped.x <= 0.5 and snapped.y <= 0.5 and snapped.right() >= view.width - 0.5 and snapped.bottom() >= view.height - 0.5;
    return .{ .clear_full = covers, .scissor = snapped };
}

fn snapOut(rect: math.Rect) math.Rect {
    const x0 = @floor(rect.x);
    const y0 = @floor(rect.y);
    const x1 = @ceil(rect.right());
    const y1 = @ceil(rect.bottom());
    return .{ .x = x0, .y = y0, .width = @max(0, x1 - x0), .height = @max(0, y1 - y0) };
}

test "damage region unions rects and partial damage does not clear the whole window" {
    var region = DamageRegion{};
    region.add(math.Rect.init(10, 10, 20, 20));
    region.add(math.Rect.init(20, 15, 30, 10));
    const merged = region.frameRect().?;
    try std.testing.expectEqual(@as(f32, 10), merged.x);
    try std.testing.expectEqual(@as(f32, 10), merged.y);
    try std.testing.expectEqual(@as(f32, 40), merged.width);
    try std.testing.expectEqual(@as(f32, 20), merged.height);

    const full = presentPlan(null, 800, 600, 2);
    try std.testing.expect(full.clear_full);
    try std.testing.expectEqual(@as(f32, 1600), full.scissor.width);

    const partial = presentPlan(math.Rect.init(10, 20, 30, 40), 800, 600, 2);
    try std.testing.expect(!partial.clear_full);
    try std.testing.expectEqual(@as(f32, 20), partial.scissor.x);
    try std.testing.expectEqual(@as(f32, 40), partial.scissor.y);
    try std.testing.expectEqual(@as(f32, 60), partial.scissor.width);
    try std.testing.expectEqual(@as(f32, 80), partial.scissor.height);
}
