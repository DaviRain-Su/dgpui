//! comptime DSL 对比实验（教育版）。
//!
//! 面试口径：
//! - **Chain DSL（本项目主路径）**：运行期 `div().p(8).child(...)`，每帧重建轻量树。
//!   优点：动态列表/条件分支自然；调试直观；类型推导靠普通方法。
//! - **comptime DSL（本文件）**：在编译期把声明式描述变成静态元数据。
//!   接近 Rust `proc-macro` / Slint 编译器思路：运行期可少建树，但动态结构更难。
//!
//! 这里不做完整 UI 宏，只展示：编译期描述 → 静态节点表 → 运行期按表“实例化”到 FrameArena。

const std = @import("std");
const math = @import("../math.zig");
const element = @import("element.zig");

pub const CompKind = enum { box, text };

pub const CompNode = struct {
    kind: CompKind = .box,
    padding: f32 = 0,
    gap: f32 = 0,
    width: ?f32 = null,
    height: ?f32 = null,
    bg: u24 = 0,
    text: ?[]const u8 = null,
    font_size: f32 = 16,
    /// 子节点在静态表中的下标区间 [child_start, child_end)
    child_start: u16 = 0,
    child_end: u16 = 0,
};

/// 声明式描述：编译期展开成 CompNode 表。
pub fn describeCounterCard() []const CompNode {
    // 手工模拟宏展开后的静态表：root(column) -> title, body, counter
    const table = [_]CompNode{
        .{ .kind = .box, .padding = 16, .gap = 8, .width = 320, .bg = 0x24273a, .child_start = 1, .child_end = 4 },
        .{ .kind = .text, .text = "comptime card", .font_size = 20 },
        .{ .kind = .text, .text = "static table, runtime instantiate", .font_size = 14 },
        .{ .kind = .text, .text = "clicks = ?", .font_size = 16 },
    };
    return &table;
}

/// 把静态表实例化到 FrameArena（仍会分配 Element，但结构形状在编译期已知）。
pub fn instantiate(
    allocator: std.mem.Allocator,
    table: []const CompNode,
    root_index: usize,
) !*element.Element {
    const node = table[root_index];
    var b = if (node.kind == .text)
        try element.textStyled(allocator, node.text orelse "", node.font_size, math.Color.white)
    else
        try element.div(allocator);

    if (node.padding != 0) b = b.p(node.padding);
    if (node.gap != 0) b = b.gap(node.gap);
    if (node.width) |w| b = b.w(w);
    if (node.height) |h| b = b.h(h);
    if (node.bg != 0) b = b.bg(math.Color.fromHex(node.bg));
    if (node.kind == .box) b = b.flexCol();

    var i: u16 = node.child_start;
    while (i < node.child_end) : (i += 1) {
        const child = try instantiate(allocator, table, i);
        // 已 finish 的 child Element* 需要包回 builder——这里直接挂到 children。
        try b.elem.children.append(allocator, child);
    }
    return b.finish();
}

test "comptime table instantiates a column with 3 children" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const table = describeCounterCard();
    const root = try instantiate(arena.allocator(), table, 0);
    try std.testing.expectEqual(@as(usize, 3), root.children.items.len);
    try std.testing.expect(root.children.items[0].kind == .text);
}
