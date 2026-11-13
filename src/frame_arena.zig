//! 帧内存：一块只往后拨的缓冲区。这一帧的显示列表从这里分配，帧末 `reset` 只把游标拨回 0，容量留着。
//! 这里不放跨帧的业务状态。UI 树和 `Entity` 还没做。

const std = @import("std");

pub const FrameArena = struct {
    allocator: std.mem.Allocator,
    buf: []u8,
    used: usize = 0,

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !FrameArena {
        const cap = @max(capacity, 64);
        return .{
            .allocator = allocator,
            .buf = try allocator.alloc(u8, cap),
        };
    }

    pub fn deinit(self: *FrameArena) void {
        self.allocator.free(self.buf);
        self.buf = &.{};
        self.used = 0;
    }

    /// 保留已分配的容量，下一帧从头写。
    pub fn reset(self: *FrameArena) void {
        self.used = 0;
    }

    pub fn alloc(self: *FrameArena, comptime T: type, n: usize) ![]T {
        if (n == 0) return &.{};
        const alignment = @alignOf(T);
        const start = std.mem.alignForward(usize, self.used, alignment);
        const bytes = std.math.mul(usize, n, @sizeOf(T)) catch return error.OutOfMemory;
        const end = std.math.add(usize, start, bytes) catch return error.OutOfMemory;
        if (end > self.buf.len) try self.grow(end);
        const ptr: [*]T = @ptrCast(@alignCast(self.buf.ptr + start));
        self.used = end;
        return ptr[0..n];
    }

    fn grow(self: *FrameArena, need: usize) !void {
        var cap = self.buf.len;
        while (cap < need) {
            cap = std.math.mul(usize, cap, 2) catch return error.OutOfMemory;
        }
        const next = try self.allocator.alloc(u8, cap);
        @memcpy(next[0..self.used], self.buf[0..self.used]);
        self.allocator.free(self.buf);
        self.buf = next;
    }
};

test "frame arena reset keeps capacity and reuses the buffer" {
    var arena = try FrameArena.init(std.testing.allocator, 128);
    defer arena.deinit();
    const cap = arena.buf.len;
    const first = try arena.alloc(u32, 4);
    first[0] = 7;
    arena.reset();
    try std.testing.expectEqual(cap, arena.buf.len);
    try std.testing.expectEqual(@as(usize, 0), arena.used);
    const second = try arena.alloc(u32, 4);
    second[0] = 9;
    try std.testing.expectEqual(@as(u32, 9), second[0]);
}
