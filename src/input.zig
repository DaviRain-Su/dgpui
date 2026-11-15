//! 焦点与键盘分发（教育版）。
//!
//! 鼠标有坐标 → Hitbox；键盘没有坐标 → 必须先有 `focus_id`。
//! 点击输入框时 `focus(id)`；`key_down` / `text_input` 直接派给当前焦点。
//! 挂上 `EntityStore` 后，派发前会校验焦点实体还活着（generation 防悬垂）。

const std = @import("std");
const entity = @import("entity.zig");
const platform = @import("backend/platform.zig");

pub const FocusHandler = *const fn (ctx: ?*anyopaque, ev: platform.Event) bool;

pub const FocusTarget = struct {
    id: entity.EntityId,
    handler: FocusHandler,
    ctx: ?*anyopaque = null,
};

pub const FocusManager = struct {
    /// 可选：提供后 dispatch 会先用 `EntityStore.get` 校验焦点实体仍然有效，
    /// 防止「实体已 remove、焦点还挂着旧 handler」的悬垂调用。
    store: ?*entity.EntityStore = null,
    focused: ?FocusTarget = null,

    pub fn init(store: ?*entity.EntityStore) FocusManager {
        return .{ .store = store };
    }

    pub fn focus(self: *FocusManager, target: FocusTarget) void {
        self.focused = target;
    }

    pub fn blur(self: *FocusManager) void {
        self.focused = null;
    }

    pub fn focusedId(self: *const FocusManager) ?entity.EntityId {
        return if (self.focused) |f| f.id else null;
    }

    /// 把键盘/文本事件派给当前焦点。返回是否被处理。
    pub fn dispatch(self: *FocusManager, ev: platform.Event) bool {
        return switch (ev) {
            .key_down, .text_input, .text_editing => blk: {
                if (self.focused) |f| {
                    if (self.store) |s| {
                        if (s.get(f.id) == null) {
                            // 实体已被移除：焦点失效，自动 blur
                            self.focused = null;
                            break :blk false;
                        }
                    }
                    break :blk f.handler(f.ctx, ev);
                }
                break :blk false;
            },
            else => false,
        };
    }
};

test "focus routes text events to the focused target" {
    const State = struct {
        got: usize = 0,
        fn onEv(ctx: ?*anyopaque, ev: platform.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (ev == .text_input) {
                self.got += 1;
                return true;
            }
            return false;
        }
    };
    var st = State{};
    var fm = FocusManager.init(null);
    try std.testing.expect(!fm.dispatch(.{ .text_input = platform.TextBytes.fromUtf8("a") }));

    fm.focus(.{ .id = .{ .index = 1, .generation = 1 }, .handler = State.onEv, .ctx = &st });
    try std.testing.expect(fm.dispatch(.{ .text_input = platform.TextBytes.fromUtf8("b") }));
    try std.testing.expectEqual(@as(usize, 1), st.got);
}

test "focus invalidates itself when the focused entity is removed" {
    const gpa = std.testing.allocator;
    const State = struct {
        got: usize = 0,
        fn onEv(ctx: ?*anyopaque, _: platform.Event) bool {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.got += 1;
            return true;
        }
    };
    var st = State{};
    var store = entity.EntityStore.init(gpa);
    defer store.deinit();

    var value: i32 = 0;
    const id = try store.insert(&value);
    var fm = FocusManager.init(&store);
    fm.focus(.{ .id = id, .handler = State.onEv, .ctx = &st });
    try std.testing.expect(fm.dispatch(.{ .text_input = platform.TextBytes.fromUtf8("a") }));
    try std.testing.expectEqual(@as(usize, 1), st.got);

    // 实体销毁后：旧句柄失效，dispatch 自动 blur 且不再调用 handler
    store.remove(id);
    try std.testing.expect(!fm.dispatch(.{ .text_input = platform.TextBytes.fromUtf8("b") }));
    try std.testing.expectEqual(@as(usize, 1), st.got);
    try std.testing.expect(fm.focusedId() == null);
}
