pub const font = @import("font.zig");
pub const shaper = @import("shaper.zig");
pub const atlas = @import("atlas.zig");
pub const layout = @import("layout.zig");

pub const FontLibrary = font.FontLibrary;
pub const FontFace = font.FontFace;
pub const TextShaper = shaper.TextShaper;
pub const GlyphAtlas = atlas.GlyphAtlas;
pub const TextSystem = layout.TextSystem;
pub const PreparedText = layout.PreparedText;
pub const PreparedGlyph = layout.PreparedGlyph;

test {
    _ = @import("atlas.zig");
    _ = @import("font.zig");
    _ = @import("shaper.zig");
    _ = @import("layout.zig");
}
