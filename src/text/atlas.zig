//! CPU 侧 Glyph Atlas（Shelf 分配器）。
//!
//! GPU 不认识 `.ttf`。我们把每个 `(glyph_id, pixel_size)` 光栅化成灰度小图，
//! 像拼图一样塞进一张大纹理。同一字形只上传一次，一屏几千个字只需 1 次
//! 绑定纹理 + 1 次（或少量）draw call。
//!
//! Shelf packing：按行（shelf）从左到右塞；当前行装不下就开新行。
//! 简单、可预测，适合高度相近的字形。

const std = @import("std");
const font = @import("font.zig");

pub const AtlasError = error{
    AtlasFull,
    OutOfMemory,
};

pub const GlyphKey = struct {
    glyph_id: u32,
    pixel_size: u32,

    pub fn hash(self: GlyphKey) u64 {
        var h: u64 = self.glyph_id;
        h = h *% 0x9E3779B97F4A7C15 +% self.pixel_size;
        return h;
    }

    pub fn eql(a: GlyphKey, b: GlyphKey) bool {
        return a.glyph_id == b.glyph_id and a.pixel_size == b.pixel_size;
    }
};

pub const GlyphUv = struct {
    /// 图集像素坐标（左上角）
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
};

const Shelf = struct {
    y: u32,
    height: u32,
    x: u32,
};

pub const GlyphAtlas = struct {
    allocator: std.mem.Allocator,
    width: u32,
    height: u32,
    /// R8 灰度像素
    pixels: []u8,
    shelves: std.ArrayList(Shelf) = .empty,
    /// glyph_id+size -> UV
    map: std.AutoHashMapUnmanaged(u64, GlyphUv) = .empty,
    /// 本帧是否有新字形写入（需要重新上传 GPU 纹理）
    dirty: bool = true,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !GlyphAtlas {
        const pixels = try allocator.alloc(u8, width * height);
        @memset(pixels, 0);
        return .{
            .allocator = allocator,
            .width = width,
            .height = height,
            .pixels = pixels,
        };
    }

    pub fn deinit(self: *GlyphAtlas) void {
        self.map.deinit(self.allocator);
        self.shelves.deinit(self.allocator);
        self.allocator.free(self.pixels);
        self.* = undefined;
    }

    pub fn clear(self: *GlyphAtlas) void {
        @memset(self.pixels, 0);
        self.shelves.clearRetainingCapacity();
        self.map.clearRetainingCapacity();
        self.dirty = true;
    }

    fn keyHash(k: GlyphKey) u64 {
        return k.hash();
    }

    pub fn getOrRasterize(self: *GlyphAtlas, face: *font.FontFace, glyph_id: u32, pixel_size: u32) AtlasError!GlyphUv {
        const key = GlyphKey{ .glyph_id = glyph_id, .pixel_size = pixel_size };
        const hk = keyHash(key);
        if (self.map.get(hk)) |uv| return uv;

        face.setPixelSize(pixel_size) catch return AtlasError.AtlasFull;
        const bmp = face.loadRenderGlyph(glyph_id) catch return AtlasError.AtlasFull;

        // 空字形（空格等）仍占一个 1×1 透明像素，方便统一走贴图路径
        const gw: u32 = @max(1, bmp.width);
        const gh: u32 = @max(1, bmp.height);
        const rect = try self.allocShelf(gw, gh);

        if (bmp.width > 0 and bmp.height > 0) {
            var row: u32 = 0;
            while (row < bmp.height) : (row += 1) {
                const src_off: usize = @as(usize, row) * @as(usize, @intCast(@max(bmp.pitch, 0)));
                const dst_off: usize = @as(usize, (rect.y + row) * self.width + rect.x);
                const n: usize = bmp.width;
                @memcpy(self.pixels[dst_off .. dst_off + n], bmp.pixels[src_off .. src_off + n]);
            }
        }

        const uv = GlyphUv{
            .x = rect.x,
            .y = rect.y,
            .width = gw,
            .height = gh,
            .bearing_x = bmp.bearing_x,
            .bearing_y = bmp.bearing_y,
        };
        try self.map.put(self.allocator, hk, uv);
        self.dirty = true;
        return uv;
    }

    const AllocRect = struct { x: u32, y: u32 };

    pub fn allocShelf(self: *GlyphAtlas, gw: u32, gh: u32) AtlasError!AllocRect {
        // 1px padding，避免线性采样串色
        const pad: u32 = 1;
        const need_w = gw + pad;
        const need_h = gh + pad;

        for (self.shelves.items) |*shelf| {
            if (shelf.height >= need_h and shelf.x + need_w <= self.width) {
                const x = shelf.x;
                shelf.x += need_w;
                return .{ .x = x, .y = shelf.y };
            }
        }

        const y: u32 = if (self.shelves.items.len == 0)
            0
        else blk: {
            const last = self.shelves.items[self.shelves.items.len - 1];
            break :blk last.y + last.height;
        };
        if (y + need_h > self.height) return AtlasError.AtlasFull;
        try self.shelves.append(self.allocator, .{ .y = y, .height = need_h, .x = need_w });
        return .{ .x = 0, .y = y };
    }
};

test "shelf atlas packs glyphs without overlap" {
    const gpa = std.testing.allocator;
    var atlas = try GlyphAtlas.init(gpa, 64, 64);
    defer atlas.deinit();

    // 手工塞几个固定尺寸矩形，验证分配器本身
    const a = try atlas.allocShelf(10, 10);
    const b = try atlas.allocShelf(10, 10);
    try std.testing.expectEqual(@as(u32, 0), a.x);
    try std.testing.expectEqual(@as(u32, 0), a.y);
    try std.testing.expectEqual(@as(u32, 11), b.x); // 10 + 1 padding
    try std.testing.expectEqual(@as(u32, 0), b.y);

    // 塞满第一行后应开新 shelf
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = atlas.allocShelf(10, 10) catch break;
    }
    const c = try atlas.allocShelf(10, 10);
    try std.testing.expect(c.y > 0);
}
