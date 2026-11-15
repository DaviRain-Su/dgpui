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

/// HarfBuzz shaping 结果的 LRU 缓存。
///
/// 为什么值得缓存：每帧布局会对每个文本节点 `measure` 一次、绘制时再 prepare
/// 一次，两次都要跑 HarfBuzz。同一个 (文本字节, 物理字号) 的 shape 结果在字体
/// 不变的前提下永远相同 —— 缓存后稳态一帧 0 次 shaping，只有字形光栅化/贴图。
///
/// 教育版实现：线性扫描（先比预计算哈希再比字节）+ LRU clock；默认上限 256 条。
/// 真实框架用 hash map + 双向链表做 O(1) LRU，并常带字体回退链的整树缓存。
pub const ShapeCache = struct {
    const CacheEntry = struct {
        /// 拥有的文本字节拷贝（key 的一部分）
        bytes: []u8,
        pixel_size: u32,
        /// 预计算 key 哈希：先比整数，命中才比对字节
        hash: u64,
        /// HarfBuzz 输出（所有权在缓存）
        glyphs: []shaper.ShapedGlyph,
        width: f32,
        last_used: u64,
    };

    allocator: std.mem.Allocator,
    entries: std.ArrayList(CacheEntry) = .empty,
    /// 上限；测试可以调小验证淘汰
    max_entries: usize = 256,
    /// LRU 时钟：每次命中/写入自增
    accesses: u64 = 0,

    pub fn init(allocator: std.mem.Allocator) ShapeCache {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ShapeCache) void {
        for (self.entries.items) |e| {
            self.allocator.free(e.bytes);
            self.allocator.free(e.glyphs);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn hashKey(bytes: []const u8, pixel_size: u32) u64 {
        var h = std.hash.Wyhash.init(0x9e3779b97f4a7c15);
        h.update(bytes);
        h.update(std.mem.asBytes(&pixel_size));
        return h.final();
    }

    /// 命中并刷新 LRU。
    pub fn find(self: *ShapeCache, bytes: []const u8, pixel_size: u32) ?*CacheEntry {
        const hk = hashKey(bytes, pixel_size);
        for (self.entries.items) |*e| {
            if (e.hash == hk and e.pixel_size == pixel_size and std.mem.eql(u8, e.bytes, bytes)) {
                self.accesses += 1;
                e.last_used = self.accesses;
                return e;
            }
        }
        return null;
    }

    /// 写入并**接管 glyphs 所有权**。满了就驱逐 LRU 最老的一条（原地覆盖）。
    pub fn put(self: *ShapeCache, bytes: []const u8, pixel_size: u32, glyphs: []shaper.ShapedGlyph, width: f32) !*CacheEntry {
        const cap = @max(self.max_entries, 1);
        var slot: ?usize = null;
        if (self.entries.items.len >= cap) {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |e, i| {
                if (e.last_used < self.entries.items[oldest].last_used) oldest = i;
            }
            const victim = &self.entries.items[oldest];
            self.allocator.free(victim.bytes);
            self.allocator.free(victim.glyphs);
            slot = oldest;
        }

        const owned = try self.allocator.dupe(u8, bytes);
        errdefer self.allocator.free(owned);
        self.accesses += 1;

        const entry = CacheEntry{
            .bytes = owned,
            .pixel_size = pixel_size,
            .hash = hashKey(bytes, pixel_size),
            .glyphs = glyphs,
            .width = width,
            .last_used = self.accesses,
        };
        if (slot) |i| {
            self.entries.items[i] = entry;
            return &self.entries.items[i];
        }
        try self.entries.append(self.allocator, entry);
        return &self.entries.items[self.entries.items.len - 1];
    }
};

pub const TextSystem = struct {
    allocator: std.mem.Allocator,
    library: font.FontLibrary,
    face: font.FontFace,
    shaper_state: shaper.TextShaper,
    atlas: atlas.GlyphAtlas,
    /// HarfBuzz shaping 结果缓存（LRU）。同一个 (文本, 物理字号) 每帧会被
    /// measure 和 paint 各取一次，缓存后稳态每帧 0 次 shaping。
    cache: ShapeCache = undefined,
    /// 实际走到 HarfBuzz 的次数（= 缓存 miss 数）。测试 / 面试演示用。
    shape_calls: usize = 0,

    pub fn init(self: *TextSystem, allocator: std.mem.Allocator, font_path: [*:0]const u8, atlas_w: u32, atlas_h: u32) !void {
        self.* = undefined;
        self.allocator = allocator;
        self.cache = ShapeCache.init(allocator);
        self.shape_calls = 0;
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
        self.cache.deinit();
        self.* = undefined;
    }

    /// shape（带缓存）：命中则零成本返回只读视图；未命中才走 HarfBuzz，
    /// 并把结果（glyphs 所有权）搬进缓存。返回的视图由缓存持有，调用方不释放。
    pub fn shapeCached(self: *TextSystem, utf8: []const u8, pixel_size: u32) !shaper.ShapedRunView {
        if (self.cache.find(utf8, pixel_size)) |e| {
            return .{ .glyphs = e.glyphs, .width = e.width };
        }
        self.shape_calls += 1;
        try self.face.setPixelSize(pixel_size);
        var run = try self.shaper_state.shape(utf8);
        const entry = self.cache.put(utf8, pixel_size, run.glyphs, run.width) catch |err| {
            run.deinit(self.allocator);
            return err;
        };
        // glyphs 所有权已移交缓存；置空防止后续误双重释放
        run.glyphs = &.{};
        return .{ .glyphs = entry.glyphs, .width = entry.width };
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
    fn placeGlyphs(self: *TextSystem, run: shaper.ShapedRunView, opts: PlaceOptions) !PreparedText {
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
        const view = try self.shapeCached(utf8, pixel_size);

        return self.placeGlyphs(view, .{
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
        const run = try self.shapeCached(utf8, pixel_size);

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
        const view = try self.shapeCached(utf8, pixel_size);

        return self.placeGlyphs(view, .{
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

test "shape cache avoids repeated HarfBuzz shaping" {
    const gpa = std.testing.allocator;
    const path = font.defaultFontPath() orelse return error.SkipZigTest;
    var sys: TextSystem = undefined;
    try sys.init(gpa, path.ptr, 512, 512);
    defer sys.deinit();

    _ = try sys.measureText("Hello 世界", 16, 1.0, 100);
    const after_first = sys.shape_calls;
    try std.testing.expect(after_first > 0);

    // 同 (文本, 字号) 再次 measure：命中缓存，shape_calls 不变
    _ = try sys.measureText("Hello 世界", 16, 1.0, 100);
    try std.testing.expectEqual(after_first, sys.shape_calls);

    // paint 路径（prepareLine）命中同一份缓存 —— 这就是“measure+paint 各一次”
    // 从每帧 2 次 shaping 变成 0 次的机制
    var prepared = try sys.prepareLine("Hello 世界", .{ .x = 0, .y = 0 }, 16, 1.0, math.Color.white);
    defer prepared.deinit(gpa);
    try std.testing.expectEqual(after_first, sys.shape_calls);

    // 不同字号 → 不同缓存 key → 一次新 shape
    _ = try sys.measureText("Hello 世界", 24, 1.0, 100);
    try std.testing.expectEqual(after_first + 1, sys.shape_calls);
}

test "shape cache evicts least recently used entry" {
    const gpa = std.testing.allocator;
    const path = font.defaultFontPath() orelse return error.SkipZigTest;
    var sys: TextSystem = undefined;
    try sys.init(gpa, path.ptr, 512, 512);
    defer sys.deinit();
    sys.cache.max_entries = 2;

    _ = try sys.measureText("AAAA", 16, 1.0, null);
    _ = try sys.measureText("BBBB", 16, 1.0, null);
    _ = try sys.measureText("CCCC", 16, 1.0, null); // 满 -> 驱逐最久未用的 A
    try std.testing.expectEqual(@as(usize, 3), sys.shape_calls);

    _ = try sys.measureText("AAAA", 16, 1.0, null); // A 已被驱逐 -> 再 shape，驱逐 B
    try std.testing.expectEqual(@as(usize, 4), sys.shape_calls);

    _ = try sys.measureText("CCCC", 16, 1.0, null); // C 仍在 -> 命中
    try std.testing.expectEqual(@as(usize, 4), sys.shape_calls);
    try std.testing.expectEqual(@as(usize, 2), sys.cache.entries.items.len);
}
