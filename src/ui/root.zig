pub const element = @import("element.zig");

pub const Element = element.Element;
pub const ElementBuilder = element.ElementBuilder;
pub const div = element.div;
pub const text = element.text;
pub const textStyled = element.textStyled;
pub const layoutTree = element.layoutTree;
pub const paintTree = element.paintTree;
pub const paintTreeHit = element.paintTreeHit;

test {
    _ = @import("element.zig");
}
