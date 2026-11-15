# PR 3 学习笔记：文字整形、光栅化与 GlyphAtlas

## 1. 这个 PR 解决了什么问题？

GPU 不认识 `.ttf`。一行字也不能按“字数 × 字号”画：英文有连字/字偶距，中英混排宽度也不均匀。现代自绘框架的标准拆法是三条流水线：

1. **Shaping（HarfBuzz）**：UTF-8 → `(glyph_id, x_advance, x_offset, y_offset)`
2. **Rasterization（FreeType2）**：按 **物理像素字号**（逻辑字号 × DPI scale）把轮廓变成灰度小位图
3. **Atlas（自写 Shelf 分配器）**：把常用字形拼进一张大纹理，`(glyph_id, px_size) → UV`，整屏文字尽量 1 次绑定纹理画完

---

## 2. 本 PR 的文件导读

- `src/text/font.zig`：FreeType `FT_Library` / `FT_Face` 封装；强调物理像素字号。
- `src/text/shaper.zig`：`hb_ft_font_create` + `hb_shape`，输出 `ShapedGlyph` 序列。
- `src/text/atlas.zig`：CPU 侧 R8 图集 + Shelf packing；`dirty` 标记驱动 GPU 纹理上传。
- `src/text/layout.zig`：`TextSystem.prepareLine` 把整形结果换成逻辑像素 `PreparedGlyph`（bounds + UV + color）。
- `src/shader/glyph.metal`：实例化贴图着色器；片元用 atlas 的 R 通道当 alpha。
- `src/scene.zig`：新增 `GlyphQuad` / `GlyphInstance`；`buildBatches` 按 `kind`（quad/glyph）切批，保证 Painter's Order。
- `src/backend/sdl.zig`：Glyph 管线 + Storage Buffer + R8 atlas texture/sampler；按批切换 SDF Quad / Glyph 管线。

---

## 3. 面试容易问到的点

### (1) 为什么必须按物理像素光栅化？
Retina `scale=2`、逻辑 16px 时，要用 32px 栅格化。否则把低分辨率字形拉伸到高分屏，文字发虚。

### (2) 为什么 Atlas 命中要带上 `pixel_size`？
同一个 `glyph_id` 在 16px 与 32px 下的位图完全不同；键必须是 `(glyph_id, pixel_size)`。

### (3) Quad 与 Glyph 为什么不能合进同一 Draw Call？
管线不同：Quad 走 SDF 无纹理；Glyph 要绑定 atlas sampler。遮挡顺序仍靠 DisplayList 的批切分保持。

### (4) 本 PR 还没做什么？
- 多字体 fallback（中英分别选字体）
- 自动折行 / `measure_text(max_width)`（留给 PR 4 Flex）
- Atlas 淘汰/扩容策略（满了直接 `AtlasFull`）
