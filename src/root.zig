//! dgpui — 一个用于学习 GUI 框架核心原理的 Zig 精简 GPUI 实现。
//!
//! 随着 6 个 PR 逐步推进，这里会依次导出：
//! - PR 1: platform / renderer 多后端抽象与 SDL3(Metal) / Headless 后端
//! - PR 2: FrameArena + DisplayList + DamageRegion + SDF Quad 管线
//! - PR 3: HarfBuzz + FreeType2 + GlyphAtlas 文字管线
//! - PR 4: 链式 DSL (div/text) + 手写 Flex 布局引擎
//! - PR 5: EntityStore (notify/observe) + Hitbox 命中测试与事件冒泡
//! - PR 6: 滚动裁剪 + 键盘焦点输入 + comptime 声明式 DSL 实验

const std = @import("std");

pub const version = "0.1.0-dev";

test "starter sanity check" {
    try std.testing.expectEqualStrings("0.1.0-dev", version);
}
