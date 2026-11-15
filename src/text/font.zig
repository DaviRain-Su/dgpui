//! FreeType 字体面封装。
//!
//! 面试口径：字体文件本身只是矢量轮廓；真正“看得见”的灰度小图由 FreeType
//! 按**物理像素字号**光栅化出来。逻辑字号 16、Retina scale=2 时，必须用 32px
//! 去栅格化，否则字会发虚。

const std = @import("std");
const c = @import("c_text");

pub const FontError = error{
    InitFailed,
    FaceCreateFailed,
    SetSizeFailed,
    LoadGlyphFailed,
    RenderGlyphFailed,
};

pub const FontLibrary = struct {
    library: c.FT_Library,

    pub fn init() FontError!FontLibrary {
        var library: c.FT_Library = undefined;
        if (c.FT_Init_FreeType(&library) != 0) return FontError.InitFailed;
        return .{ .library = library };
    }

    pub fn deinit(self: *FontLibrary) void {
        _ = c.FT_Done_FreeType(self.library);
        self.* = undefined;
    }
};

pub const GlyphBitmap = struct {
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    /// FreeType 灰度缓冲（pitch 可能带 padding），调用方自己复制/释放。
    pixels: []const u8,
    pitch: i32,
};

pub const FontFace = struct {
    face: c.FT_Face,
    /// 最近一次设置的物理像素字号（整数）。
    pixel_size: u32 = 0,

    pub fn open(library: *FontLibrary, path: [*:0]const u8, face_index: i32) FontError!FontFace {
        var face: c.FT_Face = undefined;
        if (c.FT_New_Face(library.library, path, face_index, &face) != 0) {
            return FontError.FaceCreateFailed;
        }
        return .{ .face = face };
    }

    pub fn deinit(self: *FontFace) void {
        _ = c.FT_Done_Face(self.face);
        self.* = undefined;
    }

    pub fn setPixelSize(self: *FontFace, px: u32) FontError!void {
        if (self.pixel_size == px) return;
        if (c.FT_Set_Pixel_Sizes(self.face, 0, px) != 0) return FontError.SetSizeFailed;
        self.pixel_size = px;
    }

    pub fn ascenderPx(self: *const FontFace) f32 {
        const metrics = self.face.*.size.*.metrics;
        return @as(f32, @floatFromInt(metrics.ascender)) / 64.0;
    }

    pub fn descenderPx(self: *const FontFace) f32 {
        const metrics = self.face.*.size.*.metrics;
        return @as(f32, @floatFromInt(metrics.descender)) / 64.0;
    }

    pub fn lineHeightPx(self: *const FontFace) f32 {
        const metrics = self.face.*.size.*.metrics;
        return @as(f32, @floatFromInt(metrics.height)) / 64.0;
    }

    /// 加载并光栅化指定 glyph_id，返回指向 FreeType 内部缓冲的视图。
    /// 注意：下一次 `loadRenderGlyph` / `setPixelSize` 会覆盖这块缓冲。
    pub fn loadRenderGlyph(self: *FontFace, glyph_id: u32) FontError!GlyphBitmap {
        if (c.FT_Load_Glyph(self.face, glyph_id, c.FT_LOAD_DEFAULT) != 0) {
            return FontError.LoadGlyphFailed;
        }
        if (c.FT_Render_Glyph(self.face.*.glyph, c.FT_RENDER_MODE_NORMAL) != 0) {
            return FontError.RenderGlyphFailed;
        }
        const slot = self.face.*.glyph;
        const bmp = slot.*.bitmap;
        const len: usize = @intCast(@max(0, bmp.pitch) * @as(i32, @intCast(bmp.rows)));
        const pixels: []const u8 = if (len == 0)
            &[_]u8{}
        else
            @as([*]const u8, @ptrCast(bmp.buffer))[0..len];
        return .{
            .width = bmp.width,
            .height = bmp.rows,
            .bearing_x = slot.*.bitmap_left,
            .bearing_y = slot.*.bitmap_top,
            .pixels = pixels,
            .pitch = bmp.pitch,
        };
    }
};

pub fn defaultFontPath() [:0]const u8 {
    // macOS：优先 Arial（覆盖拉丁文），中文混排时 HarfBuzz/系统字体回退会另说；
    // PR3 先用 Arial Unicode / Hiragino 做中英混排演示。
    if (fileExistsZ("/System/Library/Fonts/Supplemental/Arial Unicode.ttf")) {
        return "/System/Library/Fonts/Supplemental/Arial Unicode.ttf";
    }
    if (fileExistsZ("/System/Library/Fonts/Supplemental/Arial.ttf")) {
        return "/System/Library/Fonts/Supplemental/Arial.ttf";
    }
    if (fileExistsZ("/System/Library/Fonts/Hiragino Sans GB.ttc")) {
        return "/System/Library/Fonts/Hiragino Sans GB.ttc";
    }
    return "/System/Library/Fonts/Supplemental/Arial.ttf";
}

fn fileExistsZ(path: [:0]const u8) bool {
    // Zig 0.17: fs 访问走 std.Io，不再有 std.fs.cwd().access。
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}
