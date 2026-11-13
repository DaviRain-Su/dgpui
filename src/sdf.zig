//! 圆角矩形的有向距离。片元着色器和这里用同一公式：
//! 点在矩形里面是负数，边上接近 0，外面是正数。
//! 填充、描边、阴影都看这个数，不另写三套几何。

const std = @import("std");

pub fn sdRoundedBox(px: f32, py: f32, half_w: f32, half_h: f32, radius: f32) f32 {
    const limit = @min(half_w, half_h);
    const r = std.math.clamp(radius, 0, @max(limit, 0));
    const qx = @abs(px) - half_w + r;
    const qy = @abs(py) - half_h + r;
    const ox = @max(qx, 0);
    const oy = @max(qy, 0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0) - r;
}

test "rounded box distance is negative inside and positive outside" {
    const half_w: f32 = 50;
    const half_h: f32 = 20;
    const radius: f32 = 8;
    const inside = sdRoundedBox(0, 0, half_w, half_h, radius);
    try std.testing.expect(inside < 0);
    const outside = sdRoundedBox(80, 40, half_w, half_h, radius);
    try std.testing.expect(outside > 0);
    const on_side = sdRoundedBox(half_w, 0, half_w, half_h, 0);
    try std.testing.expect(@abs(on_side) < 0.001);
}
