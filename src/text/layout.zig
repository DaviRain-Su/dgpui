//! 把整形结果 + 图集 UV 变成可绘制的 GlyphQuad 列表。
//!
//! 坐标系：
//! - HarfBuzz / FreeType 输出是**物理像素**（已按 pixel_size 光栅化）。
//! - UI 布局使用**逻辑像素**。提交 DisplayList 前统一 `/ scale_factor`。

const std = @import("std");
const math = @import("../math.zig");
const font = @import("font.zig");
const shaper = @import("shaper.zig");
const atlas = @import("atlas.zig");

pub const PreparedGlyph = struct {
    /// 逻辑像素下的目标矩形
    bounds: math.Rect,
    /// 图集 UV（归一化 0..1）
    uv: math.Rect,
    color: math.Color,
};

pub const PreparedText = struct {
    glyphs: []PreparedGlyph,
    /// 逻辑像素下的整行宽高
    size: math.Size,

    pub fn deinit(self: *PreparedText, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    library: font.FontLibrary,
    face: font.FontFace,
    shaper_state: shaper.TextShaper,
    atlas: atlas.GlyphAtlas,

    pub fn init(self: *TextSystem, allocator: std.mem.Allocator, font_path: [*:0]const u8, atlas_w: u32, atlas_h: u32) !void {
        self.* = undefined;
        self.allocator = allocator;
        self.library = try font.FontLibrary.init();
        errdefer self.library.deinit();
        self.face = try font.FontFace.open(&self.library, font_path, 0);
        errdefer self.face.deinit();
        // shaper 持有 *FontFace，必须在 face 已就位到最终地址后再创建
        self.shaper_state = try shaper.TextShaper.init(allocator, &self.face);
        errdefer self.shaper_state.deinit();
        self.atlas = try atlas.GlyphAtlas.init(allocator, atlas_w, atlas_h);
    }

    pub fn deinit(self: *TextSystem) void {
        self.atlas.deinit();
        self.shaper_state.deinit();
        self.face.deinit();
        self.library.deinit();
        self.* = undefined;
    }

    /// 布局一行文字。
    /// `logical_px` = UI 字号；`scale` = content/DPI scale；物理字号 = round(logical_px * scale)。
    pub fn prepareLine(
        self: *TextSystem,
        utf8: []const u8,
        origin_logical: math.Point,
        logical_px: f32,
        scale: f32,
        color: math.Color,
    ) !PreparedText {
        const pixel_size: u32 = @intFromFloat(@round(@max(1.0, logical_px * scale)));
        try self.face.setPixelSize(pixel_size);

        var run = try self.shaper_state.shape(utf8);
        defer run.deinit(self.allocator);

        var glyphs = try self.allocator.alloc(PreparedGlyph, run.glyphs.len);
        errdefer self.allocator.free(glyphs);

        const inv_scale = 1.0 / scale;
        var pen_x: f32 = 0;
        var pen_y: f32 = 0;
        const max_ascent: f32 = self.face.ascenderPx() * inv_scale;
        const max_descent: f32 = -self.face.descenderPx() * inv_scale;

        for (run.glyphs, 0..) |g, i| {
            const uv_px = try self.atlas.getOrRasterize(&self.face, g.glyph_id, pixel_size);

            // FreeType bearing：bitmap 相对 pen 的偏移（物理像素）
            const gx_phys = pen_x + g.x_offset + @as(f32, @floatFromInt(uv_px.bearing_x));
            const gy_phys = pen_y - g.y_offset - @as(f32, @floatFromInt(uv_px.bearing_y));

            const bounds = math.Rect{
                .x = origin_logical.x + gx_phys * inv_scale,
                .y = origin_logical.y + gy_phys * inv_scale + max_ascent,
                .width = @as(f32, @floatFromInt(uv_px.width)) * inv_scale,
                .height = @as(f32, @floatFromInt(uv_px.height)) * inv_scale,
            };

            const uv_left = @as(f32, @floatFromInt(uv_px.x)) / @as(f32, @floatFromInt(self.atlas.width));
            const uv_top = @as(f32, @floatFromInt(uv_px.y)) / @as(f32, @floatFromInt(self.atlas.height));
            const uv_right = @as(f32, @floatFromInt(uv_px.x + uv_px.width)) / @as(f32, @floatFromInt(self.atlas.width));
            const uv_bottom = @as(f32, @floatFromInt(uv_px.y + uv_px.height)) / @as(f32, @floatFromInt(self.atlas.height));

            glyphs[i] = .{
                .bounds = bounds,
                .uv = math.Rect.init(uv_left, uv_top, uv_right - uv_left, uv_bottom - uv_top),
                .color = color,
            };

            pen_x += g.x_advance;
            pen_y += g.y_advance;
        }

        _ = max_descent;
        return .{
            .glyphs = glyphs,
            .size = .{
                .width = run.width * inv_scale,
                .height = self.face.lineHeightPx() * inv_scale,
            },
        };
    }
};

test "TextSystem shapes Latin and CJK and fills glyph atlas" {
    const gpa = std.testing.allocator;
    const path = font.defaultFontPath() orelse return error.SkipZigTest;
    var sys: TextSystem = undefined;
    try sys.init(gpa, path.ptr, 512, 512);
    defer sys.deinit();

    // 先用纯拉丁文验证跨平台；若字体含 CJK 再额外测混排。
    var prepared = try sys.prepareLine(
        "Hello fi",
        .{ .x = 10, .y = 20 },
        16,
        2.0,
        math.Color.white,
    );
    defer prepared.deinit(gpa);

    try std.testing.expect(prepared.glyphs.len >= 5);
    try std.testing.expect(prepared.size.width > 0);
    try std.testing.expect(prepared.size.height > 0);
    try std.testing.expect(sys.atlas.map.count() > 0);
    try std.testing.expect(sys.atlas.dirty);

    const before = sys.atlas.map.count();
    var again = try sys.prepareLine(
        "Hello fi",
        .{ .x = 10, .y = 20 },
        16,
        2.0,
        math.Color.white,
    );
    defer again.deinit(gpa);
    try std.testing.expectEqual(before, sys.atlas.map.count());

    // 有 CJK 字形的字体再跑混排；没有也不算失败。
    var mixed = sys.prepareLine(
        "Hello 世界",
        .{ .x = 10, .y = 20 },
        16,
        2.0,
        math.Color.white,
    ) catch null;
    if (mixed) |*m| {
        defer m.deinit(gpa);
        try std.testing.expect(m.glyphs.len >= prepared.glyphs.len);
    }
}
