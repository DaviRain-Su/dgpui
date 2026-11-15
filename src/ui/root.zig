pub const element = @import("element.zig");
pub const scroll = @import("scroll.zig");
pub const comptime_dsl = @import("comptime_dsl.zig");

pub const Element = element.Element;
pub const ElementBuilder = element.ElementBuilder;
pub const div = element.div;
pub const text = element.text;
pub const textStyled = element.textStyled;
pub const layoutTree = element.layoutTree;
pub const paintTree = element.paintTree;
pub const paintTreeHit = element.paintTreeHit;
pub const paintScroll = scroll.paintScroll;
pub const ScrollState = scroll.ScrollState;

test {
    _ = @import("element.zig");
    _ = @import("scroll.zig");
    _ = @import("comptime_dsl.zig");
}
