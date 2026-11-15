//! HarfBuzz 文本整形。
//!
//! 为什么不能按“字数 × 字号”画字？
//! - 英文有连字（`fi` → 一个 glyph）、字偶距（kerning）。
//! - 中英混排、阿拉伯文、印地语有复杂脚本重排 / 连写。
//! HarfBuzz 吃 UTF-8，吐出 `(glyph_id, x_advance, x_offset, y_offset)` 序列。

const std = @import("std");
const c = @import("c_text");
const font = @import("font.zig");

pub const ShapedGlyph = struct {
    glyph_id: u32,
    /// 前进宽度（物理像素，26.6 定点数已换算）
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    /// 对应 UTF-8 源文本中的 cluster 起点（字节偏移）
    cluster: u32,
};

pub const ShapedRun = struct {
    glyphs: []ShapedGlyph,
    /// 整行前进宽度（物理像素）
    width: f32,

    pub fn deinit(self: *ShapedRun, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        self.* = undefined;
    }
};

pub const TextShaper = struct {
    allocator: std.mem.Allocator,
    face: *font.FontFace,
    hb_font: *c.hb_font_t,

    pub fn init(allocator: std.mem.Allocator, face: *font.FontFace) !TextShaper {
        // hb_ft_font_create 会持有 FT_Face；我们自己仍负责 Done_Face。
        const hb_font = c.hb_ft_font_create(face.face, null) orelse return error.HbFontCreateFailed;
        return .{
            .allocator = allocator,
            .face = face,
            .hb_font = hb_font,
        };
    }

    pub fn deinit(self: *TextShaper) void {
        c.hb_font_destroy(self.hb_font);
        self.* = undefined;
    }

    /// 在调用前请先 `face.setPixelSize(physical_px)`，HarfBuzz 会读当前 FT size。
    pub fn shape(self: *TextShaper, utf8: []const u8) !ShapedRun {
        // 每次 shape 前刷新 FT size 到 hb_font（FreeType size 可能刚被改过）
        c.hb_ft_font_changed(self.hb_font);

        const buf = c.hb_buffer_create() orelse return error.HbBufferCreateFailed;
        defer c.hb_buffer_destroy(buf);

        c.hb_buffer_add_utf8(buf, utf8.ptr, @intCast(utf8.len), 0, @intCast(utf8.len));
        c.hb_buffer_guess_segment_properties(buf);
        c.hb_shape(self.hb_font, buf, null, 0);

        var glyph_count: u32 = 0;
        const info = c.hb_buffer_get_glyph_infos(buf, &glyph_count);
        const pos = c.hb_buffer_get_glyph_positions(buf, &glyph_count);

        var out = try self.allocator.alloc(ShapedGlyph, glyph_count);
        errdefer self.allocator.free(out);

        var width: f32 = 0;
        var i: u32 = 0;
        while (i < glyph_count) : (i += 1) {
            const gi = info[i];
            const gp = pos[i];
            const g = ShapedGlyph{
                .glyph_id = gi.codepoint,
                .x_advance = @as(f32, @floatFromInt(gp.x_advance)) / 64.0,
                .y_advance = @as(f32, @floatFromInt(gp.y_advance)) / 64.0,
                .x_offset = @as(f32, @floatFromInt(gp.x_offset)) / 64.0,
                .y_offset = @as(f32, @floatFromInt(gp.y_offset)) / 64.0,
                .cluster = gi.cluster,
            };
            out[i] = g;
            width += g.x_advance;
        }

        return .{ .glyphs = out, .width = width };
    }
};
