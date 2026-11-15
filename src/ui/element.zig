//! GPUI 风格链式 DSL（运行期 Builder）。
//!
//! `div().flexCol().p(16).gap(8).child(text("标题"))`
//! 节点分配在 `FrameArena`：帧末 reset，禁止回调持有这些指针。

const std = @import("std");
const math = @import("../math.zig");
const flex = @import("../layout/flex.zig");
const scene = @import("../scene.zig");

pub const TextContent = struct {
    bytes: []const u8,
    font_size: f32 = 16,
    color: math.Color = math.Color.white,
};

pub const ElementKind = enum { box, text };

pub const Element = struct {
    kind: ElementKind = .box,
    style: flex.Style = .{},
    background: math.Color = math.Color.transparent,
    border_color: math.Color = math.Color.transparent,
    border_width: f32 = 0,
    corner_radius: f32 = 0,
    shadow_color: math.Color = math.Color.transparent,
    shadow_blur: f32 = 0,
    shadow_offset: math.Point = .{},
    text: ?TextContent = null,
    children: std.ArrayList(*Element) = .empty,
    /// 布局结果（相对父内容区）
    layout_node: flex.Node = .{},

    pub fn deinitChildrenOnly(self: *Element, allocator: std.mem.Allocator) void {
        // FrameArena 会整帧回收；这里仅在测试用 GPA 时需要
        self.children.deinit(allocator);
    }
};

pub const ElementBuilder = struct {
    allocator: std.mem.Allocator,
    elem: *Element,

    pub fn flexCol(self: ElementBuilder) ElementBuilder {
        self.elem.style.direction = .column;
        return self;
    }

    pub fn flexRow(self: ElementBuilder) ElementBuilder {
        self.elem.style.direction = .row;
        return self;
    }

    pub fn gap(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.gap = v;
        return self;
    }

    pub fn p(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.padding = flex.Edges.all(v);
        return self;
    }

    pub fn px(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.padding.left = v;
        self.elem.style.padding.right = v;
        return self;
    }

    pub fn py(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.padding.top = v;
        self.elem.style.padding.bottom = v;
        return self;
    }

    pub fn w(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.width = .{ .px = v };
        return self;
    }

    pub fn h(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.height = .{ .px = v };
        return self;
    }

    pub fn grow(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.flex_grow = v;
        return self;
    }

    pub fn shrink(self: ElementBuilder, v: f32) ElementBuilder {
        self.elem.style.flex_shrink = v;
        return self;
    }

    pub fn justify(self: ElementBuilder, v: flex.JustifyContent) ElementBuilder {
        self.elem.style.justify = v;
        return self;
    }

    pub fn items(self: ElementBuilder, v: flex.AlignItems) ElementBuilder {
        self.elem.style.align_items = v;
        return self;
    }

    pub fn bg(self: ElementBuilder, color: math.Color) ElementBuilder {
        self.elem.background = color;
        return self;
    }

    pub fn border(self: ElementBuilder, color: math.Color, width: f32) ElementBuilder {
        self.elem.border_color = color;
        self.elem.border_width = width;
        return self;
    }

    pub fn rounded(self: ElementBuilder, r: f32) ElementBuilder {
        self.elem.corner_radius = r;
        return self;
    }

    pub fn shadow(self: ElementBuilder, color: math.Color, blur: f32, offset: math.Point) ElementBuilder {
        self.elem.shadow_color = color;
        self.elem.shadow_blur = blur;
        self.elem.shadow_offset = offset;
        return self;
    }

    pub fn child(self: ElementBuilder, other: ElementBuilder) !ElementBuilder {
        try self.elem.children.append(self.allocator, other.elem);
        return self;
    }

    pub fn finish(self: ElementBuilder) *Element {
        return self.elem;
    }
};

pub fn div(allocator: std.mem.Allocator) !ElementBuilder {
    const e = try allocator.create(Element);
    e.* = .{};
    return .{ .allocator = allocator, .elem = e };
}

pub fn text(allocator: std.mem.Allocator, bytes: []const u8) !ElementBuilder {
    const e = try allocator.create(Element);
    e.* = .{
        .kind = .text,
        .text = .{ .bytes = bytes },
    };
    return .{ .allocator = allocator, .elem = e };
}

pub fn textStyled(allocator: std.mem.Allocator, bytes: []const u8, font_size: f32, color: math.Color) !ElementBuilder {
    const e = try allocator.create(Element);
    e.* = .{
        .kind = .text,
        .text = .{ .bytes = bytes, .font_size = font_size, .color = color },
    };
    return .{ .allocator = allocator, .elem = e };
}

pub const MeasureTextFn = *const fn (
    ctx: ?*anyopaque,
    bytes: []const u8,
    font_size: f32,
    max_width: flex.AvailableSpace,
) math.Size;

const TextMeasureCtx = struct {
    elem: *Element,
    measure_text: MeasureTextFn,
    user_ctx: ?*anyopaque,

    fn measure(ctx: ?*anyopaque, max_width: flex.AvailableSpace) math.Size {
        const self: *TextMeasureCtx = @ptrCast(@alignCast(ctx.?));
        const t = self.elem.text orelse return .{};
        return self.measure_text(self.user_ctx, t.bytes, t.font_size, max_width);
    }
};

/// 把 Element 树同步成 flex.Node 树（children 切片也落在同一 allocator）。
pub fn syncLayoutTree(
    elem: *Element,
    allocator: std.mem.Allocator,
    measure_text: ?MeasureTextFn,
    measure_text_ctx: ?*anyopaque,
) !void {
    elem.layout_node = .{
        .style = elem.style,
        .measure = null,
        .measure_ctx = null,
        .children = &[_]*flex.Node{},
    };

    if (elem.kind == .text) {
        if (measure_text) |mfn| {
            const ctx = try allocator.create(TextMeasureCtx);
            ctx.* = .{ .elem = elem, .measure_text = mfn, .user_ctx = measure_text_ctx };
            elem.layout_node.measure = TextMeasureCtx.measure;
            elem.layout_node.measure_ctx = ctx;
        } else if (elem.text) |t| {
            elem.layout_node.style.intrinsic = .{
                .width = @as(f32, @floatFromInt(t.bytes.len)) * t.font_size * 0.5,
                .height = t.font_size * 1.25,
            };
        }
        return;
    }

    if (elem.children.items.len == 0) return;

    const child_nodes = try allocator.alloc(*flex.Node, elem.children.items.len);
    for (elem.children.items, 0..) |child, i| {
        try syncLayoutTree(child, allocator, measure_text, measure_text_ctx);
        child_nodes[i] = &child.layout_node;
    }
    elem.layout_node.children = child_nodes;
}

pub fn layoutTree(
    root: *Element,
    available: math.Size,
    allocator: std.mem.Allocator,
    measure_text: ?MeasureTextFn,
    measure_text_ctx: ?*anyopaque,
) !void {
    try syncLayoutTree(root, allocator, measure_text, measure_text_ctx);
    flex.layout(&root.layout_node, available);
    copyLayoutResults(root);
}

fn copyLayoutResults(elem: *Element) void {
    // layout_node 已就地写好；子节点也是同一对象
    for (elem.children.items) |child| copyLayoutResults(child);
}

pub const PaintTextFn = *const fn (
    ctx: ?*anyopaque,
    dl: *scene.DisplayList,
    text: TextContent,
    origin: math.Point,
    max_width: f32,
) anyerror!void;

pub fn paintTree(
    elem: *const Element,
    dl: *scene.DisplayList,
    abs_x: f32,
    abs_y: f32,
    paint_text: ?PaintTextFn,
    paint_text_ctx: ?*anyopaque,
) !void {
    const x = abs_x + elem.layout_node.x;
    const y = abs_y + elem.layout_node.y;
    const bounds = math.Rect.init(x, y, elem.layout_node.width, elem.layout_node.height);

    if (elem.kind == .box) {
        if (elem.background.a > 0 or elem.border_width > 0 or elem.shadow_color.a > 0) {
            try dl.pushQuad(.{
                .bounds = bounds,
                .background = elem.background,
                .border_color = elem.border_color,
                .border_width = elem.border_width,
                .corner_radius = elem.corner_radius,
                .shadow_color = elem.shadow_color,
                .shadow_blur = elem.shadow_blur,
                .shadow_offset = elem.shadow_offset,
            });
        }
    } else if (elem.kind == .text) {
        if (elem.text) |t| {
            const pad = elem.style.padding;
            const content_origin = math.Point{ .x = x + pad.left, .y = y + pad.top };
            const content_w = @max(0, bounds.width - pad.horizontal());
            if (paint_text) |f| {
                try f(paint_text_ctx, dl, t, content_origin, content_w);
            } else {
                // Headless / 无文字系统时：用一条占位矩形表示文字内容盒
                try dl.pushQuad(.{
                    .bounds = math.Rect.init(content_origin.x, content_origin.y, content_w, @max(0, bounds.height - pad.vertical())),
                    .background = t.color,
                    .corner_radius = 2,
                });
            }
        }
    }

    for (elem.children.items) |child| {
        try paintTree(child, dl, x, y, paint_text, paint_text_ctx);
    }
}

test "dsl builds column tree and layouts children" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var root_b = (try div(a)).flexCol().p(12).gap(8).w(240).h(120);
    root_b = try root_b.child((try div(a)).bg(math.Color.fromHex(0xff0000)).h(20));
    root_b = try root_b.child((try textStyled(a, "hi", 16, math.Color.white)).h(20));
    const root = root_b.finish();

    try layoutTree(root, .{ .width = 240, .height = 120 }, a, null, null);

    try std.testing.expectEqual(@as(f32, 240), root.layout_node.width);
    try std.testing.expect(root.children.items.len == 2);
    const c0 = root.children.items[0];
    try std.testing.expectEqual(@as(f32, 12), c0.layout_node.x);
    try std.testing.expectEqual(@as(f32, 12), c0.layout_node.y);
}
