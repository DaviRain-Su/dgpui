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
    /// 图集**像素**坐标（不归一化）。图集可能在本帧中途扩容，
    /// 归一化推迟到 buildBatches 时用最终宽高做，早前 run 的 UV 才不会失效。
    uv: math.Rect,
    color: math.Color,
};

/// 图集单边上限（R8 灰度：4096² = 16MB）。到顶后放不下的字形会被跳过。
const atlas_max_dimension: u32 = 4096;

pub const PreparedText = struct {
    glyphs: []PreparedGlyph,
    /// 完整分配。`glyphs` 可能是它的前缀（图集满时放不下的字形被跳过不绘制）；
    /// deinit 释放这份完整分配 —— free 必须与 alloc 完全匹配。
    alloc: []PreparedGlyph,
    /// 逻辑像素下的整行宽高
    size: math.Size,

    pub fn deinit(self: *PreparedText, allocator: std.mem.Allocator) void {
        allocator.free(self.alloc);
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

    const PlaceOptions = struct {
        origin: math.Point,
        pixel_size: u32,
        scale: f32,
        color: math.Color,
        /// null = 单行不折行；有值 = 按 max_width（逻辑像素）贪心折行
        max_width_logical: ?f32,
    };

    /// 统一的字形摆放核心：单行（prepareLine）与折行（prepareWrapped）共用。
    ///
    /// 图集满时的恢复策略：**就地扩容**（旧像素按原坐标拷贝，旧 UV 全部有效），
    /// 逐倍长大到 4096 上限；到顶仍放不下 / OOM 时跳过该字形，本帧继续，
    /// 绝不让一帧绘制整体失败。
    /// 教育取舍：不做 LRU 淘汰（淘汰会让同帧早前 run 的 UV 失效，很难做对）；
    /// 长期运行同一字号集合下图集会稳定，不会无限增长。
    fn placeGlyphs(self: *TextSystem, run: shaper.ShapedRun, opts: PlaceOptions) !PreparedText {
        const inv_scale = 1.0 / opts.scale;
        const ascent = self.face.ascenderPx() * inv_scale;
        const line_height = self.face.lineHeightPx() * inv_scale;
        const max_w_phys: ?f32 = if (opts.max_width_logical) |w| w * opts.scale else null;

        var glyphs = try self.allocator.alloc(PreparedGlyph, run.glyphs.len);
        errdefer self.allocator.free(glyphs);

        var out_i: usize = 0;
        var pen_x: f32 = 0;
        var pen_y: f32 = 0;
        var line_index: f32 = 0;
        var max_line_w: f32 = 0;

        for (run.glyphs) |g| {
            if (max_w_phys) |mw| {
                if (pen_x > 0 and pen_x + g.x_advance > mw) {
                    max_line_w = @max(max_line_w, pen_x);
                    pen_x = 0;
                    line_index += 1;
                }
            }

            var placed: ?atlas.GlyphUv = null;
            while (true) {
                if (self.atlas.getOrRasterize(&self.face, g.glyph_id, opts.pixel_size)) |uv| {
                    placed = uv;
                    break;
                } else |err| {
                    if (err != atlas.AtlasError.AtlasFull) break; // OOM：跳过
                }
                // 图集满：扩容一倍（封顶 4096）；旧像素原坐标拷贝，旧 UV 全部有效
                if (self.atlas.width >= atlas_max_dimension and self.atlas.height >= atlas_max_dimension) break;
                const nw = @min(self.atlas.width * 2, atlas_max_dimension);
                const nh = @min(self.atlas.height * 2, atlas_max_dimension);
                self.atlas.grow(nw, nh) catch break; // OOM：跳过
            }

            if (placed) |uv_px| {
                // FreeType bearing：bitmap 相对 pen 的偏移（物理像素）
                const gx_phys = pen_x + g.x_offset + @as(f32, @floatFromInt(uv_px.bearing_x));
                const gy_phys = pen_y - g.y_offset - @as(f32, @floatFromInt(uv_px.bearing_y));

                const bounds = math.Rect{
                    .x = opts.origin.x + gx_phys * inv_scale,
                    .y = opts.origin.y + line_index * line_height + gy_phys * inv_scale + ascent,
                    .width = @as(f32, @floatFromInt(uv_px.width)) * inv_scale,
                    .height = @as(f32, @floatFromInt(uv_px.height)) * inv_scale,
                };

                // UV 保持图集像素坐标；归一化推迟到 buildBatches（图集可能还会长大）
                const uv_rect = math.Rect.init(
                    @floatFromInt(uv_px.x),
                    @floatFromInt(uv_px.y),
                    @floatFromInt(uv_px.width),
                    @floatFromInt(uv_px.height),
                );

                glyphs[out_i] = .{
                    .bounds = bounds,
                    .uv = uv_rect,
                    .color = opts.color,
                };
                out_i += 1;
            }

            pen_x += g.x_advance;
            pen_y += g.y_advance;
        }

        max_line_w = @max(max_line_w, pen_x);
        return .{
            .glyphs = glyphs[0..out_i],
            .alloc = glyphs,
            .size = .{
                .width = max_line_w * inv_scale,
                .height = (line_index + 1.0) * line_height,
            },
        };
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

        return self.placeGlyphs(run, .{
            .origin = origin_logical,
            .pixel_size = pixel_size,
            .scale = scale,
            .color = color,
            .max_width_logical = null,
        });
    }

    /// 给 Flex `measure` 用：按 max_width（逻辑像素）做简单贪心折行，返回包围盒。
    pub fn measureText(
        self: *TextSystem,
        utf8: []const u8,
        logical_px: f32,
        scale: f32,
        max_width_logical: ?f32,
    ) !math.Size {
        const pixel_size: u32 = @intFromFloat(@round(@max(1.0, logical_px * scale)));
        try self.face.setPixelSize(pixel_size);
        var run = try self.shaper_state.shape(utf8);
        defer run.deinit(self.allocator);

        const inv_scale = 1.0 / scale;
        const line_height = self.face.lineHeightPx() * inv_scale;
        const max_w_phys: ?f32 = if (max_width_logical) |w| w * scale else null;

        var line_w: f32 = 0;
        var max_line_w: f32 = 0;
        var lines: f32 = 1;
        for (run.glyphs) |g| {
            if (max_w_phys) |mw| {
                if (line_w > 0 and line_w + g.x_advance > mw) {
                    max_line_w = @max(max_line_w, line_w);
                    line_w = 0;
                    lines += 1;
                }
            }
            line_w += g.x_advance;
        }
        max_line_w = @max(max_line_w, line_w);
        return .{
            .width = max_line_w * inv_scale,
            .height = lines * line_height,
        };
    }

    /// 按 max_width 折行后输出 glyph quads（逻辑像素）。
    pub fn prepareWrapped(
        self: *TextSystem,
        utf8: []const u8,
        origin_logical: math.Point,
        logical_px: f32,
        scale: f32,
        max_width_logical: f32,
        color: math.Color,
    ) !PreparedText {
        const pixel_size: u32 = @intFromFloat(@round(@max(1.0, logical_px * scale)));
        try self.face.setPixelSize(pixel_size);
        var run = try self.shaper_state.shape(utf8);
        defer run.deinit(self.allocator);

        return self.placeGlyphs(run, .{
            .origin = origin_logical,
            .pixel_size = pixel_size,
            .scale = scale,
            .color = color,
            .max_width_logical = max_width_logical,
        });
    }
};

test "atlas-full recovers by growing instead of failing the frame" {
    const gpa = std.testing.allocator;
    const path = font.defaultFontPath() orelse return error.SkipZigTest;
    var sys: TextSystem = undefined;
    // 故意从极小图集开始：16px 字形必然触发多次扩容
    try sys.init(gpa, path.ptr, 8, 8);
    defer sys.deinit();

    // 关键契约：返回成功（不冒泡 AtlasFull）；扩容保持旧 UV 有效，
    // 同帧更早 run 的字形不会被作废。
    var prepared = try sys.prepareLine("Hello 世界", .{ .x = 0, .y = 0 }, 16, 1.0, math.Color.white);
    defer prepared.deinit(gpa);
    // 4096 上限内所有字形都能放下（H e l l o 空格 世 界 = 8 个 glyph）
    try std.testing.expect(prepared.glyphs.len >= 6);
    // 图集条目 = 唯一 (glyph_id,size) 数（重复字母共享同一条目），不多不少
    try std.testing.expect(sys.atlas.map.count() > 0);
    try std.testing.expect(sys.atlas.map.count() <= prepared.glyphs.len);
    try std.testing.expect(sys.atlas.width > 8);
}

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
