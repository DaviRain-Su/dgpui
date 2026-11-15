//! 焦点与键盘分发（教育版）。
//!
//! 鼠标有坐标 → Hitbox；键盘没有坐标 → 必须先有 `focus_id`。
//! 点击输入框时 `focus(id)`；`key_down` / `text_input` 直接派给当前焦点。

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
    focused: ?FocusTarget = null,

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
                if (self.focused) |f| break :blk f.handler(f.ctx, ev);
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
    var fm = FocusManager{};
    try std.testing.expect(!fm.dispatch(.{ .text_input = platform.TextBytes.fromUtf8("a") }));

    fm.focus(.{ .id = .{ .index = 1, .generation = 1 }, .handler = State.onEv, .ctx = &st });
    try std.testing.expect(fm.dispatch(.{ .text_input = platform.TextBytes.fromUtf8("b") }));
    try std.testing.expectEqual(@as(usize, 1), st.got);
}
