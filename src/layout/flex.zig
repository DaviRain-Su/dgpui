//! 手写精简 Flex 布局引擎（参考 Yoga / Taffy 模型，不链接外部布局库）。
//!
//! 面试口径：布局最难的是「高度取决于宽度」。容器先把可用宽度约束往下传，
//! 叶子（尤其是文字）用 `measure` 回调按 `max_width` 算出折行后的宽高，
//! 再做 grow/shrink 分配和 justify/align 定位。

const std = @import("std");
const math = @import("../math.zig");

pub const AvailableSpace = union(enum) {
    definite: f32,
    max_content,
};

pub const Dimension = union(enum) {
    auto,
    px: f32,

    pub fn resolve(self: Dimension) ?f32 {
        return switch (self) {
            .auto => null,
            .px => |v| v,
        };
    }
};

pub const FlexDirection = enum { row, column };
pub const JustifyContent = enum { start, end, center, space_between };
pub const AlignItems = enum { start, end, center, stretch };

pub const Edges = struct {
    top: f32 = 0,
    right: f32 = 0,
    bottom: f32 = 0,
    left: f32 = 0,

    pub fn all(v: f32) Edges {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn horizontal(self: Edges) f32 {
        return self.left + self.right;
    }

    pub fn vertical(self: Edges) f32 {
        return self.top + self.bottom;
    }
};

pub const Style = struct {
    direction: FlexDirection = .column,
    justify: JustifyContent = .start,
    align_items: AlignItems = .stretch,
    gap: f32 = 0,
    padding: Edges = .{},
    width: Dimension = .auto,
    height: Dimension = .auto,
    flex_grow: f32 = 0,
    flex_shrink: f32 = 1,
    /// 叶子固定内容尺寸（无 measure 时使用）
    intrinsic: ?math.Size = null,
};

pub const MeasureFn = *const fn (ctx: ?*anyopaque, max_width: AvailableSpace) math.Size;

pub const Node = struct {
    style: Style = .{},
    children: []const *Node = &[_]*Node{},
    measure: ?MeasureFn = null,
    measure_ctx: ?*anyopaque = null,
    /// 相对父节点内容区原点的布局结果
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 0,
    height: f32 = 0,

    pub fn bounds(self: Node) math.Rect {
        return math.Rect.init(self.x, self.y, self.width, self.height);
    }
};

/// 对根节点做布局。`available` 通常是窗口逻辑尺寸。
pub fn layout(root: *Node, available: math.Size) void {
    // 根也走统一 measure：显式宽高优先，否则吃 available。
    const sz = measureNode(root, .{ .definite = available.width }, .{ .definite = available.height });
    root.width = root.style.width.resolve() orelse sz.width;
    root.height = root.style.height.resolve() orelse sz.height;
    // 若根高度是 auto，用内容高度；宽度同理已在 measure 中处理。
    if (root.style.height == .auto) root.height = sz.height;
    if (root.style.width == .auto) root.width = sz.width;
    // 但 Demo 的根通常显式给了窗口宽高；保持 resolve 优先：
    if (root.style.width.resolve()) |w| root.width = w;
    if (root.style.height.resolve()) |h| root.height = h;
    root.x = 0;
    root.y = 0;
    layoutChildren(root);
}

fn effectiveMaxWidth(node: *const Node, parent_max_width: AvailableSpace) AvailableSpace {
    // 关键：节点自己的显式宽度必须先变成 measure 约束，
    // 否则文字会按父级更宽的宽度折行，高度算小。
    if (node.style.width.resolve()) |w| return .{ .definite = w };
    return parent_max_width;
}

fn measureNode(node: *Node, max_width: AvailableSpace, max_height: AvailableSpace) math.Size {
    const pad_h = node.style.padding.horizontal();
    const pad_v = node.style.padding.vertical();
    const width_constraint = effectiveMaxWidth(node, max_width);

    if (node.style.width.resolve()) |w| {
        if (node.style.height.resolve()) |h| {
            // 两边都明确：仍要递归测量子树，好让子节点拿到正确 definite 宽。
            _ = measureContainerContent(node, .{ .definite = @max(0, w - pad_h) }, max_height);
            return .{ .width = w, .height = h };
        }
    }

    if (node.children.len == 0) {
        var content = math.Size{};
        if (node.measure) |m| {
            const inner: AvailableSpace = switch (width_constraint) {
                .definite => |v| .{ .definite = @max(0, v - pad_h) },
                .max_content => .max_content,
            };
            content = m(node.measure_ctx, inner);
        } else if (node.style.intrinsic) |s| {
            content = s;
        }
        var out = math.Size{
            .width = content.width + pad_h,
            .height = content.height + pad_v,
        };
        if (node.style.width.resolve()) |w| out.width = w;
        if (node.style.height.resolve()) |h| out.height = h;
        return out;
    }

    const inner_w: AvailableSpace = switch (width_constraint) {
        .definite => |v| .{ .definite = @max(0, v - pad_h) },
        .max_content => .max_content,
    };
    const content = measureContainerContent(node, inner_w, max_height);
    var out = math.Size{
        .width = content.width + pad_h,
        .height = content.height + pad_v,
    };
    if (node.style.width.resolve()) |w| out.width = w;
    if (node.style.height.resolve()) |h| out.height = h;
    return out;
}

fn measureContainerContent(node: *Node, inner_w: AvailableSpace, max_height: AvailableSpace) math.Size {
    _ = max_height;
    var total_main: f32 = 0;
    var max_cross: f32 = 0;
    const n = node.children.len;
    for (node.children, 0..) |child, i| {
        const sz = measureNode(child, inner_w, .max_content);
        child.width = sz.width;
        child.height = sz.height;
        if (node.style.direction == .row) {
            total_main += sz.width;
            max_cross = @max(max_cross, sz.height);
        } else {
            total_main += sz.height;
            max_cross = @max(max_cross, sz.width);
        }
        if (i + 1 < n) total_main += node.style.gap;
    }
    return switch (node.style.direction) {
        .row => .{ .width = total_main, .height = max_cross },
        .column => .{ .width = max_cross, .height = total_main },
    };
}

fn remeasureHeightForWidth(node: *Node, width: f32) void {
    if (node.style.height.resolve() != null) return;
    const pad_h = node.style.padding.horizontal();
    const pad_v = node.style.padding.vertical();
    if (node.children.len == 0) {
        if (node.measure) |m| {
            const content = m(node.measure_ctx, .{ .definite = @max(0, width - pad_h) });
            node.height = content.height + pad_v;
        }
        return;
    }
    // 容器：按最终宽度重新测子树，取内容高度
    const content = measureContainerContent(node, .{ .definite = @max(0, width - pad_h) }, .max_content);
    node.height = content.height + pad_v;
}

fn layoutChildren(node: *Node) void {
    const n = node.children.len;
    if (n == 0) return;

    const pad = node.style.padding;
    const inner_w = @max(0, node.width - pad.horizontal());
    const dir = node.style.direction;

    // 1) 初始测量
    for (node.children) |child| {
        const sz = measureNode(child, .{ .definite = inner_w }, .max_content);
        child.width = child.style.width.resolve() orelse sz.width;
        child.height = child.style.height.resolve() orelse sz.height;
    }

    // 2) column 的交叉轴（宽度）先 stretch 定宽，再按最终宽度重测折行高度
    if (dir == .column and node.style.align_items == .stretch) {
        for (node.children) |child| {
            if (child.style.width == .auto) child.width = inner_w;
        }
    }
    for (node.children) |child| {
        remeasureHeightForWidth(child, child.width);
    }

    // 3) 主轴 grow / shrink（此步之后：row 会改宽度，column 会改高度）
    var total_main: f32 = 0;
    var total_grow: f32 = 0;
    var total_shrink_weighted: f32 = 0;
    for (node.children) |child| {
        const main = if (dir == .row) child.width else child.height;
        total_main += main;
        total_grow += @max(0, child.style.flex_grow);
        total_shrink_weighted += @max(0, child.style.flex_shrink) * main;
    }
    if (n > 1) total_main += node.style.gap * @as(f32, @floatFromInt(n - 1));

    // 父 height=auto 时，主轴可用尺寸先按内容；fixed 则用 inner
    var inner_h = @max(0, node.height - pad.vertical());
    if (node.style.height == .auto) {
        var content_main: f32 = 0;
        for (node.children, 0..) |child, i| {
            content_main += if (dir == .row) child.height else child.height;
            if (dir == .column) {
                // column 主轴是 height
            }
            _ = i;
        }
        // 重新按方向汇总
        content_main = 0;
        for (node.children, 0..) |child, i| {
            content_main += if (dir == .row) child.width else child.height;
            if (i + 1 < n) content_main += node.style.gap;
        }
        if (dir == .column) {
            node.height = content_main + pad.vertical();
            inner_h = content_main;
        } else {
            var max_h: f32 = 0;
            for (node.children) |child| max_h = @max(max_h, child.height);
            node.height = max_h + pad.vertical();
            inner_h = max_h;
        }
    }

    const available_main = if (dir == .row) inner_w else inner_h;
    // 若上面 auto 分支重算了 total，需要同步 total_main
    total_main = 0;
    total_grow = 0;
    total_shrink_weighted = 0;
    for (node.children) |child| {
        const main = if (dir == .row) child.width else child.height;
        total_main += main;
        total_grow += @max(0, child.style.flex_grow);
        total_shrink_weighted += @max(0, child.style.flex_shrink) * main;
    }
    if (n > 1) total_main += node.style.gap * @as(f32, @floatFromInt(n - 1));

    const free = available_main - total_main;
    if (free > 0.5 and total_grow > 0) {
        for (node.children) |child| {
            if (child.style.flex_grow > 0) {
                const add = free * (child.style.flex_grow / total_grow);
                if (dir == .row) child.width += add else child.height += add;
            }
        }
    } else if (free < -0.5) {
        // 多轮 shrink：某节点缩到 0 后冻结，剩余压缩量继续分给其他可收缩节点。
        var remaining = -free;
        var guard: usize = 0;
        while (remaining > 0.5 and guard < n + 2) : (guard += 1) {
            var weight_sum: f32 = 0;
            for (node.children) |child| {
                const main = if (dir == .row) child.width else child.height;
                if (child.style.flex_shrink > 0 and main > 0) {
                    weight_sum += child.style.flex_shrink * main;
                }
            }
            if (weight_sum <= 0) break;

            var consumed: f32 = 0;
            for (node.children) |child| {
                const main = if (dir == .row) child.width else child.height;
                if (!(child.style.flex_shrink > 0 and main > 0)) continue;
                const weighted = child.style.flex_shrink * main;
                const sub = @min(main, remaining * (weighted / weight_sum));
                if (dir == .row) child.width = main - sub else child.height = main - sub;
                consumed += sub;
            }
            if (consumed <= 0.0001) break;
            remaining -= consumed;
        }
    }

    // 4) 仅 row 会在 grow/shrink 后改变宽度 -> 需要再测折行高度
    if (dir == .row) {
        for (node.children) |child| {
            remeasureHeightForWidth(child, child.width);
        }
        if (node.style.height == .auto) {
            var max_h: f32 = 0;
            for (node.children) |child| max_h = @max(max_h, child.height);
            node.height = max_h + pad.vertical();
            inner_h = max_h;
        } else {
            inner_h = @max(0, node.height - pad.vertical());
        }
    }

    // 5) row 交叉轴 stretch（不要在 column 上用重测覆盖主轴高度）
    const final_inner_h = @max(0, node.height - pad.vertical());
    if (dir == .row and node.style.align_items == .stretch) {
        for (node.children) |child| {
            if (child.style.height == .auto) child.height = final_inner_h;
        }
    }

    // 6) 定位
    var used_main: f32 = 0;
    for (node.children) |child| used_main += if (dir == .row) child.width else child.height;
    if (n > 1) used_main += node.style.gap * @as(f32, @floatFromInt(n - 1));
    const leftover = (if (dir == .row) inner_w else final_inner_h) - used_main;

    var cursor: f32 = 0;
    var between = node.style.gap;
    switch (node.style.justify) {
        .start => {},
        .end => cursor = leftover,
        .center => cursor = leftover * 0.5,
        .space_between => {
            if (n > 1 and leftover > 0) {
                between = node.style.gap + leftover / @as(f32, @floatFromInt(n - 1));
            }
        },
    }

    for (node.children, 0..) |child, i| {
        const cross_free = if (dir == .row) final_inner_h - child.height else inner_w - child.width;
        const cross_off: f32 = switch (node.style.align_items) {
            .start, .stretch => 0,
            .end => cross_free,
            .center => cross_free * 0.5,
        };
        if (dir == .row) {
            child.x = pad.left + cursor;
            child.y = pad.top + cross_off;
            cursor += child.width;
        } else {
            child.x = pad.left + cross_off;
            child.y = pad.top + cursor;
            cursor += child.height;
        }
        if (i + 1 < n) cursor += between;
        layoutChildren(child);
    }
}

/// 收集绝对坐标（相对 root 左上角）。
pub fn collectAbsolute(
    node: *const Node,
    acc_x: f32,
    acc_y: f32,
    out: *std.ArrayList(math.Rect),
    allocator: std.mem.Allocator,
) !void {
    const abs = math.Rect.init(acc_x + node.x, acc_y + node.y, node.width, node.height);
    try out.append(allocator, abs);
    for (node.children) |child| {
        try collectAbsolute(child, abs.x, abs.y, out, allocator);
    }
}

test "column flex stacks children with gap and padding" {
    var a = Node{ .style = .{ .intrinsic = .{ .width = 100, .height = 20 } } };
    var b = Node{ .style = .{ .intrinsic = .{ .width = 80, .height = 30 } } };
    const kids = [_]*Node{ &a, &b };
    var root = Node{
        .style = .{
            .direction = .column,
            .gap = 8,
            .padding = Edges.all(10),
            .width = .{ .px = 200 },
            .height = .{ .px = 78 },
        },
        .children = &kids,
    };
    layout(&root, .{ .width = 200, .height = 78 });

    try std.testing.expectEqual(@as(f32, 200), root.width);
    try std.testing.expectEqual(@as(f32, 10), a.x);
    try std.testing.expectEqual(@as(f32, 10), a.y);
    try std.testing.expectEqual(@as(f32, 10), b.x);
    try std.testing.expectEqual(@as(f32, 38), b.y); // 10 + 20 + 8
}

test "row flex grow fills leftover width" {
    var a = Node{ .style = .{ .intrinsic = .{ .width = 40, .height = 20 }, .flex_grow = 1 } };
    var b = Node{ .style = .{ .intrinsic = .{ .width = 40, .height = 20 }, .flex_grow = 1 } };
    const kids = [_]*Node{ &a, &b };
    var root = Node{
        .style = .{
            .direction = .row,
            .gap = 10,
            .width = .{ .px = 200 },
            .height = .{ .px = 20 },
        },
        .children = &kids,
    };
    layout(&root, .{ .width = 200, .height = 20 });
    try std.testing.expectApproxEqAbs(@as(f32, 95), a.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 95), b.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 0), a.x, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 105), b.x, 0.01);
}

test "measure callback wraps by max width" {
    const MeasureCtx = struct {
        fn measure(_: ?*anyopaque, max_width: AvailableSpace) math.Size {
            const total = 25.0 * 10.0;
            const mw = switch (max_width) {
                .definite => |v| v,
                .max_content => total,
            };
            const line_w = @min(total, mw);
            const lines = @ceil(total / @max(line_w, 1.0));
            return .{ .width = line_w, .height = lines * 16.0 };
        }
    };

    var text_node = Node{ .measure = MeasureCtx.measure };
    const kids = [_]*Node{&text_node};
    var root = Node{
        .style = .{
            .direction = .column,
            .width = .{ .px = 100 },
            .height = .{ .px = 48 },
        },
        .children = &kids,
    };
    layout(&root, .{ .width = 100, .height = 48 });
    try std.testing.expectEqual(@as(f32, 100), text_node.width);
    try std.testing.expectEqual(@as(f32, 48), text_node.height);
}

test "explicit child width is used before measuring wrap height" {
    const MeasureCtx = struct {
        fn measure(_: ?*anyopaque, max_width: AvailableSpace) math.Size {
            const total = 250.0;
            const mw = switch (max_width) {
                .definite => |v| v,
                .max_content => total,
            };
            const line_w = @min(total, mw);
            const lines = @ceil(total / @max(line_w, 1.0));
            return .{ .width = line_w, .height = lines * 16.0 };
        }
    };

    // 父很宽，但卡片自己宽 100；文字必须按 100 折行，而不是按父宽。
    var text_node = Node{
        .measure = MeasureCtx.measure,
        .style = .{ .width = .{ .px = 100 } },
    };
    const kids = [_]*Node{&text_node};
    var root = Node{
        .style = .{ .direction = .column, .width = .{ .px = 800 }, .height = .auto },
        .children = &kids,
    };
    layout(&root, .{ .width = 800, .height = 1000 });
    try std.testing.expectEqual(@as(f32, 100), text_node.width);
    try std.testing.expectEqual(@as(f32, 48), text_node.height); // 250/100 => 3 lines
}

test "row shrink remeasures wrapped text height" {
    const MeasureCtx = struct {
        fn measure(_: ?*anyopaque, max_width: AvailableSpace) math.Size {
            const total = 250.0;
            const mw = switch (max_width) {
                .definite => |v| v,
                .max_content => total,
            };
            const line_w = @min(total, mw);
            const lines = @ceil(total / @max(line_w, 1.0));
            return .{ .width = line_w, .height = lines * 16.0 };
        }
    };

    var a = Node{ .measure = MeasureCtx.measure, .style = .{ .flex_shrink = 1 } };
    var b = Node{ .measure = MeasureCtx.measure, .style = .{ .flex_shrink = 1 } };
    const kids = [_]*Node{ &a, &b };
    var root = Node{
        .style = .{ .direction = .row, .width = .{ .px = 300 }, .height = .auto, .gap = 0 },
        .children = &kids,
    };
    layout(&root, .{ .width = 300, .height = 1000 });
    // 自然宽各 250，总 500 -> shrink 到各 150；150 宽下 250 文本 => 2 行 * 16 = 32
    try std.testing.expectApproxEqAbs(@as(f32, 150), a.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 150), b.width, 0.01);
    try std.testing.expectEqual(@as(f32, 32), a.height);
    try std.testing.expectEqual(@as(f32, 32), b.height);
}

test "shrink redistributes leftover after a child hits zero" {
    var a = Node{ .style = .{ .intrinsic = .{ .width = 10, .height = 10 }, .flex_shrink = 100 } };
    var b = Node{ .style = .{ .intrinsic = .{ .width = 100, .height = 10 }, .flex_shrink = 1 } };
    const kids = [_]*Node{ &a, &b };
    var root = Node{
        .style = .{ .direction = .row, .width = .{ .px = 50 }, .height = .{ .px = 10 }, .gap = 0 },
        .children = &kids,
    };
    layout(&root, .{ .width = 50, .height = 10 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), a.width, 0.01);
    try std.testing.expectApproxEqAbs(@as(f32, 50), b.width, 0.01);
}

test "column flex_grow height is preserved after measure" {
    const MeasureCtx = struct {
        fn measure(_: ?*anyopaque, _: AvailableSpace) math.Size {
            return .{ .width = 50, .height = 20 };
        }
    };
    var child = Node{ .measure = MeasureCtx.measure, .style = .{ .flex_grow = 1 } };
    const kids = [_]*Node{&child};
    var root = Node{
        .style = .{ .direction = .column, .width = .{ .px = 100 }, .height = .{ .px = 100 } },
        .children = &kids,
    };
    layout(&root, .{ .width = 100, .height = 100 });
    try std.testing.expectApproxEqAbs(@as(f32, 100), child.height, 0.01);
}
