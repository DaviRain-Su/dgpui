//! 滚动容器：Entity 里存 offset，paint 时 PushClip + 平移子节点。

const std = @import("std");
const math = @import("../math.zig");
const scene = @import("../scene.zig");
const hitbox = @import("../hitbox.zig");
const element = @import("element.zig");

pub const ScrollState = struct {
    offset_y: f32 = 0,
    content_height: f32 = 0,
    viewport_height: f32 = 0,

    pub fn maxOffset(self: ScrollState) f32 {
        return @max(0, self.content_height - self.viewport_height);
    }

    pub fn applyDelta(self: *ScrollState, dy: f32) void {
        self.offset_y = std.math.clamp(self.offset_y - dy, 0, self.maxOffset());
    }
};

/// 在 viewport 内绘制 child，应用 scroll_offset 并登记 clip 到 Hitbox。
pub fn paintScroll(
    viewport: math.Rect,
    offset_y: f32,
    child: *const element.Element,
    dl: *scene.DisplayList,
    paint_text: ?element.PaintTextFn,
    paint_text_ctx: ?*anyopaque,
    hits: ?*hitbox.HitList,
    parent_hit: ?u32,
) !void {
    try dl.pushClip(viewport);
    defer dl.popClip() catch {};

    // 子树相对 viewport 左上角布局；滚动时整体上移 offset。
    try element.paintTreeHit(
        child,
        dl,
        viewport.x,
        viewport.y - offset_y,
        paint_text,
        paint_text_ctx,
        hits,
        parent_hit,
        viewport,
    );
}

test "scroll clamps offset to content" {
    var st = ScrollState{ .content_height = 300, .viewport_height = 100 };
    // SDL wheel: 正 dy = 向上滚 = 看更上面的内容 = offset 减小。
    // 负 dy = 向下滚 = offset 增大。
    st.applyDelta(-50);
    try std.testing.expectApproxEqAbs(@as(f32, 50), st.offset_y, 0.01);
    st.applyDelta(-1000);
    try std.testing.expectApproxEqAbs(@as(f32, 200), st.offset_y, 0.01);
    st.applyDelta(999);
    try std.testing.expectApproxEqAbs(@as(f32, 0), st.offset_y, 0.01);
}
