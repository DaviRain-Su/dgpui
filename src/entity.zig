//! 持久状态池（EntityStore）与 observe/notify。
//!
//! 面试口径：
//! - `FrameArena` 里的 Element 每帧重建，**不能**被点击回调长期持有。
//! - 业务状态放这里，用 `EntityId { index, generation }` 引用；generation 防止悬垂复用。
//! - `notify(id)` 把订阅了该实体的视图标脏；同一轮事件多次 notify 合并成一次重绘。

const std = @import("std");

pub const EntityId = struct {
    index: u32,
    generation: u32,

    pub fn eql(a: EntityId, b: EntityId) bool {
        return a.index == b.index and a.generation == b.generation;
    }
};

const Slot = struct {
    generation: u32 = 0,
    occupied: bool = false,
    /// 教育版：用 type-erased 指针存放状态；调用方保证生命周期。
    ptr: ?*anyopaque = null,
};

pub const EntityStore = struct {
    allocator: std.mem.Allocator,
    slots: std.ArrayList(Slot) = .empty,
    free_list: std.ArrayList(u32) = .empty,
    /// entity -> 订阅它的 view keys（教育版用 u64 代替复杂 ViewId）
    observers: std.AutoHashMapUnmanaged(u64, std.ArrayList(u64)) = .empty,
    /// 本轮被 notify 弄脏的 view keys
    dirty_views: std.AutoHashMapUnmanaged(u64, void) = .empty,

    pub fn init(allocator: std.mem.Allocator) EntityStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *EntityStore) void {
        var it = self.observers.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
        self.observers.deinit(self.allocator);
        self.dirty_views.deinit(self.allocator);
        self.free_list.deinit(self.allocator);
        self.slots.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn insert(self: *EntityStore, ptr: *anyopaque) !EntityId {
        if (self.free_list.items.len > 0) {
            const index = self.free_list.pop().?;
            const slot = &self.slots.items[index];
            slot.occupied = true;
            slot.ptr = ptr;
            return .{ .index = index, .generation = slot.generation };
        }
        const index: u32 = @intCast(self.slots.items.len);
        try self.slots.append(self.allocator, .{ .generation = 1, .occupied = true, .ptr = ptr });
        return .{ .index = index, .generation = 1 };
    }

    pub fn remove(self: *EntityStore, id: EntityId) void {
        if (id.index >= self.slots.items.len) return;
        const slot = &self.slots.items[id.index];
        if (!slot.occupied or slot.generation != id.generation) return;
        slot.occupied = false;
        slot.ptr = null;
        slot.generation +%= 1;
        self.free_list.append(self.allocator, id.index) catch {};
        // 清观察者
        const key = entityKey(id);
        if (self.observers.fetchRemove(key)) |entry| {
            var list = entry.value;
            list.deinit(self.allocator);
        }
    }

    pub fn get(self: *EntityStore, id: EntityId) ?*anyopaque {
        if (id.index >= self.slots.items.len) return null;
        const slot = self.slots.items[id.index];
        if (!slot.occupied or slot.generation != id.generation) return null;
        return slot.ptr;
    }

    pub fn observe(self: *EntityStore, entity: EntityId, view_key: u64) !void {
        const key = entityKey(entity);
        const gop = try self.observers.getOrPut(self.allocator, key);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        // 去重
        for (gop.value_ptr.items) |v| if (v == view_key) return;
        try gop.value_ptr.append(self.allocator, view_key);
    }

    pub fn notify(self: *EntityStore, entity: EntityId) !void {
        const key = entityKey(entity);
        if (self.observers.get(key)) |list| {
            for (list.items) |view_key| {
                try self.dirty_views.put(self.allocator, view_key, {});
            }
        }
    }

    pub fn takeDirtyViews(self: *EntityStore, out: *std.ArrayList(u64)) !void {
        var it = self.dirty_views.keyIterator();
        while (it.next()) |k| try out.append(self.allocator, k.*);
        self.dirty_views.clearRetainingCapacity();
    }

    pub fn anyDirty(self: *const EntityStore) bool {
        return self.dirty_views.count() > 0;
    }

    pub fn clearDirty(self: *EntityStore) void {
        self.dirty_views.clearRetainingCapacity();
    }
};

fn entityKey(id: EntityId) u64 {
    return (@as(u64, id.generation) << 32) | id.index;
}

test "entity generation prevents stale handles" {
    const gpa = std.testing.allocator;
    var store = EntityStore.init(gpa);
    defer store.deinit();

    var value: i32 = 7;
    const id = try store.insert(&value);
    try std.testing.expect(store.get(id) != null);

    store.remove(id);
    try std.testing.expect(store.get(id) == null);

    var value2: i32 = 9;
    const id2 = try store.insert(&value2);
    try std.testing.expectEqual(id.index, id2.index);
    try std.testing.expect(id.generation != id2.generation);
    try std.testing.expect(store.get(id) == null);
    try std.testing.expect(store.get(id2) != null);
}

test "notify marks observers dirty and coalesces" {
    const gpa = std.testing.allocator;
    var store = EntityStore.init(gpa);
    defer store.deinit();

    var value: i32 = 0;
    const id = try store.insert(&value);
    try store.observe(id, 42);
    try store.observe(id, 42); // dedupe
    try store.notify(id);
    try store.notify(id);
    try std.testing.expect(store.anyDirty());
    try std.testing.expectEqual(@as(u32, 1), store.dirty_views.count());

    var views: std.ArrayList(u64) = .empty;
    defer views.deinit(gpa);
    try store.takeDirtyViews(&views);
    try std.testing.expectEqual(@as(usize, 1), views.items.len);
    try std.testing.expectEqual(@as(u64, 42), views.items[0]);
    try std.testing.expect(!store.anyDirty());
}
