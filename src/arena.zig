//! FrameArena — 帧级线性内存池
//!
//! 为什么 GUI 框架要用 FrameArena？
//! 每一帧都需要构造大量的临时对象（Div 节点、布局结果、DisplayList 指令、合批数组）。
//! 如果每帧 malloc/free 成百上千次，不仅慢，还会造成内存碎片。
//!
//! FrameArena 的做法（对应 Rust 里的 `'frame` 生命周期 / CUI 里的 `frame_alloc`）：
//!   1. 一整帧里的临时分配只往后拨指针（O(1)）；
//!   2. 一帧画完后调用 `reset()`（retain_capacity），底层的内存块不还给系统，下一帧直接复用；
//!   3. ⚠️ 绝对铁律：点击回调、持久状态**绝对不能持有 FrameArena 里的指针**，
//!      因为下一帧 reset() 之后这些地址全都会被覆盖（Rust 编译期直接用 `'frame` 生命周期禁止这一点）。

const std = @import("std");

pub const FrameArena = struct {
    inner: std.heap.ArenaAllocator,
    frame_count: usize = 0,
    bytes_this_frame: usize = 0,

    pub fn init(backing_allocator: std.mem.Allocator) FrameArena {
        return .{
            .inner = std.heap.ArenaAllocator.init(backing_allocator),
        };
    }

    pub fn deinit(self: *FrameArena) void {
        self.inner.deinit();
    }

    pub fn allocator(self: *FrameArena) std.mem.Allocator {
        return self.inner.allocator();
    }

    pub fn create(self: *FrameArena, comptime T: type) !*T {
        const ptr = try self.inner.allocator().create(T);
        self.bytes_this_frame += @sizeOf(T);
        return ptr;
    }

    pub fn alloc(self: *FrameArena, comptime T: type, n: usize) ![]T {
        const slice = try self.inner.allocator().alloc(T, n);
        self.bytes_this_frame += @sizeOf(T) * n;
        return slice;
    }

    pub fn dupe(self: *FrameArena, comptime T: type, m: []const T) ![]T {
        const slice = try self.inner.allocator().dupe(T, m);
        self.bytes_this_frame += @sizeOf(T) * m.len;
        return slice;
    }

    /// 帧末重置：保留底层已经向系统申请过的容量，下一帧零系统调用直接复用
    pub fn reset(self: *FrameArena) void {
        _ = self.inner.reset(.retain_capacity);
        self.frame_count += 1;
        self.bytes_this_frame = 0;
    }
};

test "FrameArena resets with retain_capacity and never leaks across frames" {
    var arena = FrameArena.init(std.testing.allocator);
    defer arena.deinit();

    for (0..20) |frame| {
        const nums = try arena.alloc(u64, 64);
        nums[0] = frame;
        const copy = try arena.dupe(u8, "temporary frame string");
        try std.testing.expectEqualStrings("temporary frame string", copy);
        try std.testing.expect(arena.bytes_this_frame > 0);
        arena.reset();
        try std.testing.expectEqual(@as(usize, 0), arena.bytes_this_frame);
        try std.testing.expectEqual(frame + 1, arena.frame_count);
    }
}
