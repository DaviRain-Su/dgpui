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
    root.width = root.style.width.resolve() orelse available.width;
    root.height = root.style.height.resolve() orelse available.height;
    root.x = 0;
    root.y = 0;
    layoutChildren(root);
}

fn measureNode(node: *Node, max_width: AvailableSpace, max_height: AvailableSpace) math.Size {
    const pad_h = node.style.padding.horizontal();
    const pad_v = node.style.padding.vertical();

    if (node.style.width.resolve()) |w| {
        if (node.style.height.resolve()) |h| {
            return .{ .width = w, .height = h };
        }
    }

    if (node.children.len == 0) {
        var content = math.Size{};
        if (node.measure) |m| {
            const inner: AvailableSpace = switch (max_width) {
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

    // 容器：先按内容测量（用于 shrink/grow 前的假想尺寸）
    const inner_w: AvailableSpace = switch (max_width) {
        .definite => |v| .{ .definite = @max(0, v - pad_h) },
        .max_content => .max_content,
    };
    const inner_h: AvailableSpace = switch (max_height) {
        .definite => |v| .{ .definite = @max(0, v - pad_v) },
        .max_content => .max_content,
    };
    _ = inner_h;

    var total_main: f32 = 0;
    var max_cross: f32 = 0;
    const n = node.children.len;
    for (node.children, 0..) |child, i| {
        const child_max_w: AvailableSpace = switch (node.style.direction) {
            .row => inner_w,
            .column => inner_w,
        };
        const child_max_h: AvailableSpace = .max_content;
        const sz = measureNode(child, child_max_w, child_max_h);
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

    var out: math.Size = switch (node.style.direction) {
        .row => .{ .width = total_main + pad_h, .height = max_cross + pad_v },
        .column => .{ .width = max_cross + pad_h, .height = total_main + pad_v },
    };
    if (node.style.width.resolve()) |w| out.width = w;
    if (node.style.height.resolve()) |h| out.height = h;
    return out;
}

fn layoutChildren(node: *Node) void {
    const n = node.children.len;
    if (n == 0) return;

    const pad = node.style.padding;
    const inner_w = @max(0, node.width - pad.horizontal());
    const inner_h = @max(0, node.height - pad.vertical());
    const dir = node.style.direction;

    // 1) 先测量每个孩子的内容尺寸
    for (node.children) |child| {
        const max_w: AvailableSpace = .{ .definite = inner_w };
        const max_h: AvailableSpace = .{ .definite = inner_h };
        const sz = measureNode(child, max_w, max_h);
        child.width = child.style.width.resolve() orelse sz.width;
        child.height = child.style.height.resolve() orelse sz.height;
    }

    // 2) grow / shrink 主轴
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

    const available_main = if (dir == .row) inner_w else inner_h;
    const free = available_main - total_main;
    if (free > 0.5 and total_grow > 0) {
        for (node.children) |child| {
            if (child.style.flex_grow > 0) {
                const add = free * (child.style.flex_grow / total_grow);
                if (dir == .row) child.width += add else child.height += add;
            }
        }
    } else if (free < -0.5 and total_shrink_weighted > 0) {
        const need = -free;
        for (node.children) |child| {
            const main = if (dir == .row) child.width else child.height;
            if (child.style.flex_shrink > 0 and main > 0) {
                const weighted = child.style.flex_shrink * main;
                const sub = need * (weighted / total_shrink_weighted);
                if (dir == .row) child.width = @max(0, child.width - sub) else child.height = @max(0, child.height - sub);
            }
        }
    }

    // stretch 交叉轴
    if (node.style.align_items == .stretch) {
        for (node.children) |child| {
            if (dir == .row) {
                if (child.style.height == .auto) child.height = inner_h;
            } else {
                if (child.style.width == .auto) child.width = inner_w;
            }
        }
    }

    // 3) 定位
    var used_main: f32 = 0;
    for (node.children) |child| used_main += if (dir == .row) child.width else child.height;
    if (n > 1) used_main += node.style.gap * @as(f32, @floatFromInt(n - 1));
    const leftover = available_main - used_main;

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
        const cross_free = if (dir == .row) inner_h - child.height else inner_w - child.width;
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
