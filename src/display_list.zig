//! 和 GPU 无关的绘制清单。布局以后把树拍成这些命令；现在没有布局，调用方直接往里塞矩形。
//! `glyph` 只占一个位置，PR 3 才画。连续的、裁剪矩形相同的 `quad` 合成一批，一批一次实例化绘制。

const std = @import("std");
const math = @import("math.zig");
const FrameArena = @import("frame_arena.zig").FrameArena;

pub const max_clip_depth = 8;

pub const Quad = struct {
    rect: math.Rect,
    radius: f32 = 0,
    fill: math.Color,
    border_width: f32 = 0,
    border_color: math.Color = math.Color.transparent,
    shadow_blur: f32 = 0,
    shadow_color: math.Color = math.Color.transparent,
    /// 记录时已经和裁剪栈求过交。null 表示没有裁剪。
    clip: ?math.Rect = null,
};

pub const GlyphQuad = struct {
    rect: math.Rect,
    color: math.Color,
};

pub const Command = union(enum) {
    quad: Quad,
    push_clip: math.Rect,
    pop_clip,
    glyph: GlyphQuad,
};

pub const DrawBatch = struct {
    clip: ?math.Rect,
    first: usize,
    count: usize,
};

pub const DrawPlan = struct {
    quads: []const Quad,
    batches: []const DrawBatch,
    glyph_count: usize,
};

pub const BuiltFrame = struct {
    list: DisplayList,
    /// null = 整屏。有值 = 只重画这一块（逻辑像素）。
    damage: ?math.Rect,
};

pub const DisplayList = struct {
    arena: *FrameArena,
    commands: []Command = &.{},
    len: usize = 0,
    clip_stack: [max_clip_depth]math.Rect = undefined,
    clip_len: usize = 0,

    pub fn init(arena: *FrameArena) DisplayList {
        return .{ .arena = arena };
    }

    pub fn currentClip(self: *const DisplayList) ?math.Rect {
        if (self.clip_len == 0) return null;
        return self.clip_stack[self.clip_len - 1];
    }

    pub fn pushClip(self: *DisplayList, rect: math.Rect) !void {
        if (self.clip_len >= max_clip_depth) return error.ClipStackOverflow;
        const resolved = if (self.currentClip()) |outer| outer.intersect(rect) else rect;
        self.clip_stack[self.clip_len] = resolved;
        self.clip_len += 1;
        try self.append(.{ .push_clip = resolved });
    }

    pub fn popClip(self: *DisplayList) !void {
        if (self.clip_len == 0) return error.ClipStackUnderflow;
        self.clip_len -= 1;
        try self.append(.pop_clip);
    }

    pub fn addQuad(self: *DisplayList, quad: Quad) !void {
        var stored = quad;
        stored.clip = self.currentClip();
        try self.append(.{ .quad = stored });
    }

    pub fn addGlyph(self: *DisplayList, glyph: GlyphQuad) !void {
        try self.append(.{ .glyph = glyph });
    }

    /// 阴影和抗锯齿都会画出矩形外一圈。脏区至少要盖住这一圈。
    pub fn visualBounds(quad: Quad) math.Rect {
        const pad = @max(quad.shadow_blur, 1);
        return quad.rect.inflate(pad);
    }

    pub fn buildDraw(self: *const DisplayList) !DrawPlan {
        var quad_count: usize = 0;
        var glyph_count: usize = 0;
        for (self.commands[0..self.len]) |cmd| {
            switch (cmd) {
                .quad => quad_count += 1,
                .glyph => glyph_count += 1,
                .push_clip, .pop_clip => {},
            }
        }
        const quads = try self.arena.alloc(Quad, quad_count);
        const batches = try self.arena.alloc(DrawBatch, @max(quad_count, 1));
        var qi: usize = 0;
        var bi: usize = 0;
        var open = false;
        var open_clip: ?math.Rect = null;
        for (self.commands[0..self.len]) |cmd| {
            switch (cmd) {
                .quad => |quad| {
                    if (!open or !clipSame(open_clip, quad.clip)) {
                        if (open) batches[bi - 1].count = qi - batches[bi - 1].first;
                        if (bi >= batches.len) return error.OutOfMemory;
                        batches[bi] = .{ .clip = quad.clip, .first = qi, .count = 0 };
                        bi += 1;
                        open = true;
                        open_clip = quad.clip;
                    }
                    quads[qi] = quad;
                    qi += 1;
                },
                .glyph, .push_clip, .pop_clip => {},
            }
        }
        if (open) batches[bi - 1].count = qi - batches[bi - 1].first;
        return .{
            .quads = quads[0..qi],
            .batches = batches[0..bi],
            .glyph_count = glyph_count,
        };
    }

    fn append(self: *DisplayList, cmd: Command) !void {
        if (self.len == self.commands.len) {
            const next_cap = @max(self.commands.len * 2, 4);
            const next = try self.arena.alloc(Command, next_cap);
            @memcpy(next[0..self.len], self.commands[0..self.len]);
            self.commands = next;
        }
        self.commands[self.len] = cmd;
        self.len += 1;
    }
};

fn clipSame(a: ?math.Rect, b: ?math.Rect) bool {
    if (a == null and b == null) return true;
    const left = a orelse return false;
    const right = b orelse return false;
    return left.x == right.x and left.y == right.y and left.width == right.width and left.height == right.height;
}

test "clips nest, glyphs stay out of quad batches, same clip is one batch" {
    var arena = try FrameArena.init(std.testing.allocator, 4096);
    defer arena.deinit();
    var list = DisplayList.init(&arena);
    try list.addQuad(.{ .rect = math.Rect.init(0, 0, 100, 40), .fill = math.Color.white });
    try list.addQuad(.{ .rect = math.Rect.init(10, 10, 20, 20), .radius = 4, .fill = math.Color.black });
    try list.pushClip(math.Rect.init(0, 0, 50, 50));
    try list.pushClip(math.Rect.init(10, 10, 80, 80));
    try list.addQuad(.{ .rect = math.Rect.init(0, 0, 30, 30), .fill = math.Color.white });
    try list.addGlyph(.{ .rect = math.Rect.init(1, 1, 8, 8), .color = math.Color.black });
    try list.addQuad(.{ .rect = math.Rect.init(4, 4, 10, 10), .fill = math.Color.white });
    try list.popClip();
    try list.popClip();

    const inner = list.commands[4].quad;
    try std.testing.expectEqual(@as(f32, 10), inner.clip.?.x);
    try std.testing.expectEqual(@as(f32, 40), inner.clip.?.width);

    const plan = try list.buildDraw();
    try std.testing.expectEqual(@as(usize, 4), plan.quads.len);
    try std.testing.expectEqual(@as(usize, 2), plan.batches.len);
    try std.testing.expectEqual(@as(usize, 2), plan.batches[0].count);
    try std.testing.expectEqual(@as(usize, 2), plan.batches[1].count);
    try std.testing.expectEqual(@as(usize, 1), plan.glyph_count);
    try std.testing.expect(plan.batches[0].clip == null);
}
