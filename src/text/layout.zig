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
    /// 图集满时的恢复策略：
    /// 1. 第一次撞满 → `atlas.clear()` 后**从头重排整个 run**。已放置字形的 UV
    ///    会因 clear 作废，绝不能和新 UV 混用，所以必须整轮重来。
    /// 2. 重排后再撞满（或 OOM）→ 逐个跳过放不下的字形，本帧继续，绝不让
    ///    一帧绘制整体失败。
    /// 教育取舍：真实框架会做图集扩容 / LRU 淘汰，这里用 clear 换实现简单。
    fn placeGlyphs(self: *TextSystem, run: shaper.ShapedRun, opts: PlaceOptions) !PreparedText {
        const inv_scale = 1.0 / opts.scale;
        const ascent = self.face.ascenderPx() * inv_scale;
        const line_height = self.face.lineHeightPx() * inv_scale;
        const max_w_phys: ?f32 = if (opts.max_width_logical) |w| w * opts.scale else null;

        var glyphs = try self.allocator.alloc(PreparedGlyph, run.glyphs.len);
        errdefer self.allocator.free(glyphs);

        var restarts: usize = 0;
        while (true) {
            var out_i: usize = 0;
            var pen_x: f32 = 0;
            var pen_y: f32 = 0;
            var line_index: f32 = 0;
            var max_line_w: f32 = 0;
            var need_restart = false;

            for (run.glyphs) |g| {
                if (max_w_phys) |mw| {
                    if (pen_x > 0 and pen_x + g.x_advance > mw) {
                        max_line_w = @max(max_line_w, pen_x);
                        pen_x = 0;
                        line_index += 1;
                    }
                }

                var placed: ?atlas.GlyphUv = null;
                if (self.atlas.getOrRasterize(&self.face, g.glyph_id, opts.pixel_size)) |uv| {
                    placed = uv;
                } else |err| {
                    if (err == atlas.AtlasError.AtlasFull and restarts < 1) {
                        std.log.warn("glyph atlas full ({d}x{d}), clearing glyph cache and re-placing run", .{ self.atlas.width, self.atlas.height });
                        self.atlas.clear();
                        restarts += 1;
                        need_restart = true;
                    }
                    // 重启后仍放不下 / OOM：跳过该字形（不绘制），pen 照常前进
                }
                if (need_restart) break;

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

                    const aw: f32 = @floatFromInt(self.atlas.width);
                    const ah: f32 = @floatFromInt(self.atlas.height);
                    const uv_left = @as(f32, @floatFromInt(uv_px.x)) / aw;
                    const uv_top = @as(f32, @floatFromInt(uv_px.y)) / ah;
                    const uv_right = @as(f32, @floatFromInt(uv_px.x + uv_px.width)) / aw;
                    const uv_bottom = @as(f32, @floatFromInt(uv_px.y + uv_px.height)) / ah;

                    glyphs[out_i] = .{
                        .bounds = bounds,
                        .uv = math.Rect.init(uv_left, uv_top, uv_right - uv_left, uv_bottom - uv_top),
                        .color = opts.color,
                    };
                    out_i += 1;
                }

                pen_x += g.x_advance;
                pen_y += g.y_advance;
            }

            if (!need_restart) {
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
        }
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

test "atlas-full recovers by clearing instead of failing the frame" {
    const gpa = std.testing.allocator;
    const path = font.defaultFontPath() orelse return error.SkipZigTest;
    var sys: TextSystem = undefined;
    // 故意用极小图集：16px 字形（加 1px padding）放不进 8x8，
    // 只有空格这类空字形（1x1）能进 —— 触发一次 clear 重排。
    try sys.init(gpa, path.ptr, 8, 8);
    defer sys.deinit();

    // 关键契约：返回成功（不冒泡 AtlasFull），放不下的字形被逐个跳过
    var prepared = try sys.prepareLine("Hello 世界", .{ .x = 0, .y = 0 }, 16, 1.0, math.Color.white);
    defer prepared.deinit(gpa);
    try std.testing.expect(prepared.glyphs.len < 7);
    // 重排后留下的字形必须和图集条目一一对应（clear 作废的 UV 不允许残留）
    try std.testing.expectEqual(prepared.glyphs.len, sys.atlas.map.count());
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
