//! 命中测试（Hitbox）与事件冒泡。
//!
//! Paint 时登记 `(bounds, clip, handler, parent)`；点击时倒序遍历（后画在上），
//! 未处理则沿 parent 冒泡。回调只应持有 EntityId / 持久指针，绝不持有 FrameArena 指针。

const std = @import("std");
const math = @import("math.zig");

pub const HitHandler = *const fn (ctx: ?*anyopaque, pos: math.Point) bool;

pub const Hitbox = struct {
    bounds: math.Rect,
    clip: ?math.Rect = null,
    handler: ?HitHandler = null,
    ctx: ?*anyopaque = null,
    parent: ?u32 = null,
    /// 可选：关联实体，方便调试
    tag: u64 = 0,
};

pub const HitList = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Hitbox) = .empty,

    pub fn init(allocator: std.mem.Allocator) HitList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *HitList) void {
        self.items.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *HitList) void {
        self.items.clearRetainingCapacity();
    }

    pub fn push(self: *HitList, hb: Hitbox) !u32 {
        const idx: u32 = @intCast(self.items.items.len);
        try self.items.append(self.allocator, hb);
        return idx;
    }

    /// 倒序命中 + 冒泡。返回是否有人处理。
    pub fn dispatchClick(self: *const HitList, pos: math.Point) bool {
        if (self.items.items.len == 0) return false;
        var i: isize = @intCast(self.items.items.len);
        while (i > 0) {
            i -= 1;
            const idx: usize = @intCast(i);
            const hb = self.items.items[idx];
            if (!containsClipped(hb, pos)) continue;
            // 从命中节点开始冒泡
            var cur: ?u32 = @intCast(idx);
            while (cur) |c| {
                const node = self.items.items[c];
                if (node.handler) |h| {
                    if (h(node.ctx, pos)) return true;
                }
                cur = node.parent;
            }
            // 点到了某个几何体但整条链都没处理，继续找更下面的？
            // 教育版：已命中最上层几何，即使未处理也不再穿透到被完全遮挡的下层。
            return false;
        }
        return false;
    }
};

fn containsClipped(hb: Hitbox, pos: math.Point) bool {
    if (!hb.bounds.contains(pos)) return false;
    if (hb.clip) |c| {
        if (!c.contains(pos)) return false;
    }
    return true;
}

test "hit testing prefers later paint and bubbles to parent" {
    const gpa = std.testing.allocator;
    var list = HitList.init(gpa);
    defer list.deinit();

    const State = struct {
        hits: usize = 0,
        fn onParent(ctx: ?*anyopaque, _: math.Point) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.hits += 1;
            return true;
        }
        fn onChildIgnore(_: ?*anyopaque, _: math.Point) bool {
            return false; // 不处理，冒泡
        }
    };
    var st = State{};

    const parent = try list.push(.{
        .bounds = math.Rect.init(0, 0, 100, 40),
        .handler = State.onParent,
        .ctx = &st,
    });
    _ = try list.push(.{
        .bounds = math.Rect.init(10, 5, 30, 20),
        .handler = State.onChildIgnore,
        .ctx = &st,
        .parent = parent,
    });
    // 后画的遮罩在上，但点在 parent 空白处
    _ = try list.push(.{
        .bounds = math.Rect.init(200, 200, 10, 10),
        .handler = null,
    });

    try std.testing.expect(list.dispatchClick(.{ .x = 12, .y = 10 }));
    try std.testing.expectEqual(@as(usize, 1), st.hits);

    // 点在上层无 handler 且无 parent 的方块上：命中后停止穿透
    try std.testing.expect(!list.dispatchClick(.{ .x = 201, .y = 201 }));
}

test "clip rejects hits outside scissor" {
    const gpa = std.testing.allocator;
    var list = HitList.init(gpa);
    defer list.deinit();
    const State = struct {
        fn onClick(_: ?*anyopaque, _: math.Point) bool {
            return true;
        }
    };
    _ = try list.push(.{
        .bounds = math.Rect.init(0, 0, 100, 100),
        .clip = math.Rect.init(0, 0, 20, 20),
        .handler = State.onClick,
    });
    try std.testing.expect(list.dispatchClick(.{ .x = 10, .y = 10 }));
    try std.testing.expect(!list.dispatchClick(.{ .x = 50, .y = 50 }));
}
