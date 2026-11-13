//! 渲染中间层（DisplayList）与脏区追踪（DamageRegion）
//!
//! 为什么要先生成 DisplayList，而不直接在布局/组件代码里调 Metal/GPU？
//! 1. **与 GPU 解耦**：布局和 UI 树完全不知道 Metal/Vulkan/SDL 的存在；
//!    同一份 DisplayList 既能喂给 Metal，也能喂给软件光栅化器或 Headless 测试。
//! 2. **方便合批与裁剪**：在这里按绘制顺序（Painter's Order）把嵌套 `push_clip / pop_clip`
//!    折叠成具体的裁剪矩形，把连续同裁剪区的 Quad 打包成同一批 GPU 实例数据。
//! 3. **方便算脏区**：对比上一帧与当前帧的 DisplayList，可以精确得出哪块矩形发生了变化（DamageRegion）。

const std = @import("std");
const math = @import("math.zig");

/// 单个矩形图元（同时表达：纯色矩形、圆角矩形、边框、阴影）
pub const Quad = struct {
    bounds: math.Rect,
    background: math.Color = math.Color.transparent,
    border_color: math.Color = math.Color.transparent,
    border_width: f32 = 0,
    corner_radius: f32 = 0,
    shadow_color: math.Color = math.Color.transparent,
    shadow_blur: f32 = 0,
    shadow_offset: math.Point = .{},

    /// 包含阴影外扩在内的真实覆盖包围盒（用于脏区计算和 GPU 展开四边形）
    pub fn paintBounds(self: Quad) math.Rect {
        const pad = if (self.shadow_color.a > 0 and self.shadow_blur > 0)
            self.shadow_blur * 2.0 + @max(@abs(self.shadow_offset.x), @abs(self.shadow_offset.y))
        else
            0;
        return .{
            .x = self.bounds.x - pad,
            .y = self.bounds.y - pad,
            .width = self.bounds.width + pad * 2.0,
            .height = self.bounds.height + pad * 2.0,
        };
    }

    pub fn eql(a: Quad, b: Quad) bool {
        return std.meta.eql(a, b);
    }
};

/// 与平台/GPU 无关的绘制指令
pub const DrawCommand = union(enum) {
    quad: Quad,
    /// 将新的裁剪矩形压入栈（会自动与当前栈顶裁剪区求交集）
    push_clip: math.Rect,
    /// 弹出当前裁剪矩形
    pop_clip,
};

/// 传给 GPU Storage Buffer 的紧凑实例布局。
/// 全部使用 16 字节对齐的 [4]f32，保证 Zig `extern struct` 与 Metal Shading Language (MSL) 内存布局 100% 一致。
pub const QuadInstance = extern struct {
    /// (x, y, width, height) 逻辑像素
    bounds: [4]f32,
    /// (r, g, b, a)
    background: [4]f32,
    /// (r, g, b, a)
    border_color: [4]f32,
    /// (r, g, b, a)
    shadow_color: [4]f32,
    /// (corner_radius, border_width, shadow_blur, _pad)
    style: [4]f32,
    /// (shadow_offset_x, shadow_offset_y, 0, 0)
    shadow_offset: [4]f32,

    pub fn fromQuad(q: Quad) QuadInstance {
        return .{
            .bounds = .{ q.bounds.x, q.bounds.y, q.bounds.width, q.bounds.height },
            .background = .{ q.background.r, q.background.g, q.background.b, q.background.a },
            .border_color = .{ q.border_color.r, q.border_color.g, q.border_color.b, q.border_color.a },
            .shadow_color = .{ q.shadow_color.r, q.shadow_color.g, q.shadow_color.b, q.shadow_color.a },
            .style = .{ q.corner_radius, q.border_width, q.shadow_blur, 0 },
            .shadow_offset = .{ q.shadow_offset.x, q.shadow_offset.y, 0, 0 },
        };
    }
};

comptime {
    if (@sizeOf(QuadInstance) != 96) @compileError("QuadInstance must be exactly 96 bytes for MSL alignment");
}

/// 同一裁剪区下连续可合批的 Quad 切片（保证严格按 Painter's Order 绘制，遮挡关系不错乱）
pub const QuadBatch = struct {
    clip_rect: ?math.Rect,
    instance_start: u32,
    instance_count: u32,
};

pub const BuiltBatches = struct {
    instances: []QuadInstance,
    batches: []QuadBatch,

    pub fn deinit(self: *BuiltBatches, allocator: std.mem.Allocator) void {
        allocator.free(self.instances);
        allocator.free(self.batches);
    }
};

pub const DisplayList = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayList(DrawCommand) = .empty,

    pub fn init(allocator: std.mem.Allocator) DisplayList {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *DisplayList) void {
        self.commands.deinit(self.allocator);
    }

    pub fn clearRetainingCapacity(self: *DisplayList) void {
        self.commands.clearRetainingCapacity();
    }

    pub fn pushQuad(self: *DisplayList, q: Quad) !void {
        try self.commands.append(self.allocator, .{ .quad = q });
    }

    pub fn pushClip(self: *DisplayList, rect: math.Rect) !void {
        try self.commands.append(self.allocator, .{ .push_clip = rect });
    }

    pub fn popClip(self: *DisplayList) !void {
        try self.commands.append(self.allocator, .pop_clip);
    }

    /// 克隆到目标分配器（用于保存上一帧命令以计算帧间脏区）
    pub fn clone(self: *const DisplayList, allocator: std.mem.Allocator) !DisplayList {
        var copy = DisplayList.init(allocator);
        errdefer copy.deinit();
        try copy.commands.appendSlice(allocator, self.commands.items);
        return copy;
    }

    /// 按 Painter's Order 解析裁剪栈并合批：
    /// - 相邻、相同裁剪区的 Quad 合并成同一个 `QuadBatch`（1 次 draw call）
    /// - 遇到裁剪变化（或插入其他图元）时切分批次，确保前后遮挡关系 100% 正确
    pub fn buildBatches(self: *const DisplayList, allocator: std.mem.Allocator) !BuiltBatches {
        var instances: std.ArrayList(QuadInstance) = .empty;
        errdefer instances.deinit(allocator);
        var batches: std.ArrayList(QuadBatch) = .empty;
        errdefer batches.deinit(allocator);
        var clip_stack: std.ArrayList(math.Rect) = .empty;
        defer clip_stack.deinit(allocator);

        for (self.commands.items) |cmd| {
            switch (cmd) {
                .push_clip => |r| {
                    const effective = if (clip_stack.items.len > 0)
                        clip_stack.items[clip_stack.items.len - 1].intersect(r)
                    else
                        r;
                    try clip_stack.append(allocator, effective);
                },
                .pop_clip => {
                    if (clip_stack.items.len > 0) {
                        _ = clip_stack.pop();
                    }
                },
                .quad => |q| {
                    const current_clip: ?math.Rect = if (clip_stack.items.len > 0)
                        clip_stack.items[clip_stack.items.len - 1]
                    else
                        null;

                    // 完全被空裁剪区裁掉的图元直接跳过
                    if (current_clip) |c| {
                        if (c.isEmpty()) continue;
                    }

                    const inst_idx: u32 = @intCast(instances.items.len);
                    try instances.append(allocator, QuadInstance.fromQuad(q));

                    if (batches.items.len > 0 and optRectEql(batches.items[batches.items.len - 1].clip_rect, current_clip)) {
                        batches.items[batches.items.len - 1].instance_count += 1;
                    } else {
                        try batches.append(allocator, .{
                            .clip_rect = current_clip,
                            .instance_start = inst_idx,
                            .instance_count = 1,
                        });
                    }
                },
            }
        }

        return .{
            .instances = try instances.toOwnedSlice(allocator),
            .batches = try batches.toOwnedSlice(allocator),
        };
    }
};

fn optRectEql(a: ?math.Rect, b: ?math.Rect) bool {
    if (a == null and b == null) return true;
    if (a != null and b != null) return std.meta.eql(a.?, b.?);
    return false;
}

/// 脏区追踪器：把本帧所有发生变化的矩形并集起来
pub const DamageRegion = struct {
    rect: ?math.Rect = null,

    pub fn merge(self: *DamageRegion, r: math.Rect) void {
        if (r.isEmpty()) return;
        self.rect = if (self.rect) |existing| existing.unionWith(r) else r;
    }

    pub fn mergeQuad(self: *DamageRegion, q: Quad) void {
        self.merge(q.paintBounds());
    }

    pub fn clear(self: *DamageRegion) void {
        self.rect = null;
    }

    /// 对比前后两帧 DisplayList，找出所有增删或属性变化命令的影响包围盒并集。
    /// 若完全一致则返回 null（无需重绘任何区域）。
    pub fn fromDisplayListDiff(prev: *const DisplayList, next: *const DisplayList) DamageRegion {
        var dmg = DamageRegion{};
        const min_len = @min(prev.commands.items.len, next.commands.items.len);

        for (0..min_len) |i| {
            const a = prev.commands.items[i];
            const b = next.commands.items[i];
            if (!std.meta.eql(a, b)) {
                mergeCommandBounds(&dmg, a);
                mergeCommandBounds(&dmg, b);
            }
        }
        for (min_len..prev.commands.items.len) |i| {
            mergeCommandBounds(&dmg, prev.commands.items[i]);
        }
        for (min_len..next.commands.items.len) |i| {
            mergeCommandBounds(&dmg, next.commands.items[i]);
        }
        return dmg;
    }

    fn mergeCommandBounds(dmg: *DamageRegion, cmd: DrawCommand) void {
        switch (cmd) {
            .quad => |q| dmg.mergeQuad(q),
            .push_clip => |r| dmg.merge(r),
            .pop_clip => {},
        }
    }
};

/// 计算某批次最终在物理像素上的裁剪矩形（将批裁剪区与可选脏区求交，再夹紧到帧缓冲范围）。
/// 返回 null 表示不需要额外裁剪（整屏绘制）；返回 width==0 或 height==0 表示完全在可视区外可跳过绘制。
pub const PhysicalScissor = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    pub fn isEmpty(self: PhysicalScissor) bool {
        return self.w <= 0 or self.h <= 0;
    }
};

pub fn computePhysicalScissor(
    batch_clip: ?math.Rect,
    damage_rect: ?math.Rect,
    logical_size: math.Size,
    physical_w: u32,
    physical_h: u32,
) ?PhysicalScissor {
    const effective_logical: math.Rect = if (batch_clip) |bc| blk: {
        break :blk if (damage_rect) |dr| bc.intersect(dr) else bc;
    } else if (damage_rect) |dr|
        dr
    else
        return null;

    if (effective_logical.isEmpty() or logical_size.width <= 0 or logical_size.height <= 0) {
        return .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    }

    const sx = @as(f32, @floatFromInt(physical_w)) / logical_size.width;
    const sy = @as(f32, @floatFromInt(physical_h)) / logical_size.height;

    const min_x_f = @floor(effective_logical.x * sx);
    const min_y_f = @floor(effective_logical.y * sy);
    const max_x_f = @ceil(effective_logical.right() * sx);
    const max_y_f = @ceil(effective_logical.bottom() * sy);

    const pw_i: i32 = @intCast(physical_w);
    const ph_i: i32 = @intCast(physical_h);

    const x0 = std.math.clamp(@as(i32, @intFromFloat(min_x_f)), 0, pw_i);
    const y0 = std.math.clamp(@as(i32, @intFromFloat(min_y_f)), 0, ph_i);
    const x1 = std.math.clamp(@as(i32, @intFromFloat(max_x_f)), 0, pw_i);
    const y1 = std.math.clamp(@as(i32, @intFromFloat(max_y_f)), 0, ph_i);

    return .{
        .x = x0,
        .y = y0,
        .w = @max(0, x1 - x0),
        .h = @max(0, y1 - y0),
    };
}

test "DisplayList batches consecutive quads with same clip and preserves painter order" {
    const gpa = std.testing.allocator;
    var dl = DisplayList.init(gpa);
    defer dl.deinit();

    // Batch 0: 两个无裁剪的矩形
    try dl.pushQuad(.{ .bounds = math.Rect.init(0, 0, 100, 100), .background = math.Color.white });
    try dl.pushQuad(.{ .bounds = math.Rect.init(10, 10, 80, 80), .background = math.Color.black });

    // Batch 1: 嵌套裁剪区 (10,10,50,50) ∩ (20,20,60,60) = (20,20,40,40)
    try dl.pushClip(math.Rect.init(10, 10, 50, 50));
    try dl.pushClip(math.Rect.init(20, 20, 60, 60));
    try dl.pushQuad(.{ .bounds = math.Rect.init(0, 0, 100, 100), .background = math.Color.fromHex(0xff0000) });
    try dl.popClip();
    try dl.popClip();

    // Batch 2: 弹出裁剪后回到无裁剪，不能和 Batch 0 合并，因为要盖在 Batch 1 上面！
    try dl.pushQuad(.{ .bounds = math.Rect.init(5, 5, 20, 20), .background = math.Color.fromHex(0x00ff00) });

    var built = try dl.buildBatches(gpa);
    defer built.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 4), built.instances.len);
    try std.testing.expectEqual(@as(usize, 3), built.batches.len);

    try std.testing.expectEqual(@as(?math.Rect, null), built.batches[0].clip_rect);
    try std.testing.expectEqual(@as(u32, 0), built.batches[0].instance_start);
    try std.testing.expectEqual(@as(u32, 2), built.batches[0].instance_count);

    const expected_clip = math.Rect.init(20, 20, 40, 40);
    try std.testing.expectEqual(expected_clip, built.batches[1].clip_rect.?);
    try std.testing.expectEqual(@as(u32, 2), built.batches[1].instance_start);
    try std.testing.expectEqual(@as(u32, 1), built.batches[1].instance_count);

    try std.testing.expectEqual(@as(?math.Rect, null), built.batches[2].clip_rect);
    try std.testing.expectEqual(@as(u32, 3), built.batches[2].instance_start);
    try std.testing.expectEqual(@as(u32, 1), built.batches[2].instance_count);
}

test "DamageRegion computes union of changed quads including shadow padding" {
    const gpa = std.testing.allocator;
    var prev = DisplayList.init(gpa);
    defer prev.deinit();
    var next = DisplayList.init(gpa);
    defer next.deinit();

    const static_bg = Quad{ .bounds = math.Rect.init(0, 0, 800, 600), .background = math.Color.black };
    const btn_before = Quad{
        .bounds = math.Rect.init(100, 100, 80, 32),
        .background = math.Color.fromHex(0x313244),
        .shadow_color = math.Color.fromHexRgba(0x00000080),
        .shadow_blur = 5,
    };
    var btn_after = btn_before;
    btn_after.background = math.Color.fromHex(0x89b4fa);

    try prev.pushQuad(static_bg);
    try prev.pushQuad(btn_before);

    try next.pushQuad(static_bg);
    try next.pushQuad(btn_after);

    const dmg = DamageRegion.fromDisplayListDiff(&prev, &next);
    try std.testing.expect(dmg.rect != null);
    // shadow_blur = 5 -> 外扩 pad = 10 -> (90, 90, 100, 52)，static_bg 没变不应被算进脏区
    try std.testing.expectEqual(@as(f32, 90), dmg.rect.?.x);
    try std.testing.expectEqual(@as(f32, 90), dmg.rect.?.y);
    try std.testing.expectEqual(@as(f32, 100), dmg.rect.?.width);
    try std.testing.expectEqual(@as(f32, 52), dmg.rect.?.height);

    // 完全相同两帧的脏区为空
    const same = DamageRegion.fromDisplayListDiff(&next, &next);
    try std.testing.expectEqual(@as(?math.Rect, null), same.rect);
}

test "computePhysicalScissor intersects clip and damage and scales to framebuffer pixels" {
    const sc = computePhysicalScissor(
        math.Rect.init(10, 20, 100, 80),
        math.Rect.init(50, 40, 100, 100),
        .{ .width = 800, .height = 600 },
        1600,
        1200,
    ).?;
    // 交集逻辑坐标 (50, 40, 60, 60) -> 2x 物理坐标 (100, 80, 120, 120)
    try std.testing.expectEqual(@as(i32, 100), sc.x);
    try std.testing.expectEqual(@as(i32, 80), sc.y);
    try std.testing.expectEqual(@as(i32, 120), sc.w);
    try std.testing.expectEqual(@as(i32, 120), sc.h);
    try std.testing.expect(!sc.isEmpty());

    // 无裁剪也无脏区时返回 null
    try std.testing.expectEqual(@as(?PhysicalScissor, null), computePhysicalScissor(null, null, .{ .width = 800, .height = 600 }, 1600, 1200));
}
