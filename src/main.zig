const std = @import("std");
const dgpui = @import("dgpui");

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("dgpui {s} — 骨架已就绪，准备进入 PR 1！\n", .{dgpui.version});
}

test "main module sanity check" {
    try std.testing.expect(dgpui.version.len > 0);
}
