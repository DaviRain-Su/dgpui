//! 帧内存：只往后拨的缓冲区。这一帧的显示列表从这里分配，帧末 `reset` 把游标拨回 0。
//! 中途不够用时另开一块，旧块留到 `reset` / `deinit` 再释放，已经交出去的切片在本帧内仍然有效。
//! 这里不放跨帧的业务状态。UI 树和 `Entity` 还没做。

const std = @import("std");

pub const FrameArena = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList([]u8) = .empty,
    used: usize = 0,

    pub fn init(allocator: std.mem.Allocator, bytes_cap: usize) !FrameArena {
        var self = FrameArena{ .allocator = allocator };
        try self.addChunk(@max(bytes_cap, 64));
        return self;
    }

    pub fn deinit(self: *FrameArena) void {
        for (self.chunks.items) |chunk| self.allocator.free(chunk);
        self.chunks.deinit(self.allocator);
        self.used = 0;
    }

    /// 保留最大的那一块，其余块释放。下一帧从头写。
    pub fn reset(self: *FrameArena) void {
        if (self.chunks.items.len == 0) {
            self.used = 0;
            return;
        }
        var keep: usize = 0;
        for (self.chunks.items, 0..) |chunk, i| {
            if (chunk.len > self.chunks.items[keep].len) keep = i;
        }
        var i: usize = 0;
        while (i < self.chunks.items.len) {
            if (i == keep) {
                i += 1;
                continue;
            }
            self.allocator.free(self.chunks.swapRemove(i));
            if (keep > i) keep -= 1;
        }
        self.used = 0;
    }

    pub fn capacity(self: *const FrameArena) usize {
        if (self.chunks.items.len == 0) return 0;
        return self.chunks.items[self.chunks.items.len - 1].len;
    }

    pub fn alloc(self: *FrameArena, comptime T: type, n: usize) ![]T {
        if (n == 0) return &.{};
        const alignment = @alignOf(T);
        const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
        var start = std.mem.alignForward(usize, self.used, alignment);
        var end = std.math.add(usize, start, bytes) catch return error.OutOfMemory;
        if (self.chunks.items.len == 0 or end > self.chunks.items[self.chunks.items.len - 1].len) {
            const prev = if (self.chunks.items.len == 0) 64 else self.chunks.items[self.chunks.items.len - 1].len;
            const need = std.math.add(usize, bytes, alignment) catch return error.OutOfMemory;
            const cap = @max(need, prev * 2);
            try self.addChunk(cap);
            self.used = 0;
            start = std.mem.alignForward(usize, 0, alignment);
            end = std.math.add(usize, start, bytes) catch return error.OutOfMemory;
        }
        const buf = self.chunks.items[self.chunks.items.len - 1];
        if (end > buf.len) return error.OutOfMemory;
        const ptr: [*]T = @ptrCast(@alignCast(buf.ptr + start));
        self.used = end;
        return ptr[0..n];
    }

    fn addChunk(self: *FrameArena, cap: usize) !void {
        const chunk = try self.allocator.alloc(u8, cap);
        self.chunks.append(self.allocator, chunk) catch |err| {
            self.allocator.free(chunk);
            return err;
        };
    }
};

test "frame arena reset keeps capacity and reuses the buffer" {
    var arena = try FrameArena.init(std.testing.allocator, 128);
    defer arena.deinit();
    const cap = arena.capacity();
    const first = try arena.alloc(u32, 4);
    first[0] = 7;
    arena.reset();
    try std.testing.expectEqual(cap, arena.capacity());
    try std.testing.expectEqual(@as(usize, 0), arena.used);
    const second = try arena.alloc(u32, 4);
    second[0] = 9;
    try std.testing.expectEqual(@as(u32, 9), second[0]);
}

test "frame arena growth keeps earlier slices alive until reset" {
    var arena = try FrameArena.init(std.testing.allocator, 64);
    defer arena.deinit();
    const first = try arena.alloc(u32, 4);
    first[0] = 42;
    const big = try arena.alloc(u8, 4096);
    big[0] = 1;
    try std.testing.expectEqual(@as(u32, 42), first[0]);
    try std.testing.expect(arena.chunks.items.len >= 2);
    arena.reset();
    try std.testing.expectEqual(@as(usize, 1), arena.chunks.items.len);
    try std.testing.expect(arena.capacity() >= 4096);
}
