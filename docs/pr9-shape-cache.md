# PR 9 — Shaped-Text 缓存（LRU）

## 解决什么问题
PR 6 的 Todo demo 每帧对每个文本节点：
1. Flex `measure` → `TextSystem.measureText` → **HarfBuzz shape**
2. `paintTreeHit` → `paintText` → `prepareWrapped` → **HarfBuzz shape（再来一次）**

同一 (文本字节, 物理字号) 的 shape 结果在字体不变时**永远相同**——每帧重复 shape 是纯浪费。

## 实现（`src/text/layout.zig` + `src/text/shaper.zig`）
- `ShapeCache`：线性扫描（预计算 64 位 key 哈希先行比较）+ LRU clock（`last_used`），默认上限 256 条，满了驱逐最久未用。
- `TextSystem.shapeCached(utf8, pixel_size)`：命中返回只读 `ShapedRunView`（零拷贝）；未命中才 `setPixelSize + hb_shape`，glyphs 所有权移交缓存。
- `measureText` / `prepareLine` / `prepareWrapped` 全部改走缓存；`placeGlyphs` 改收 `ShapedRunView`。
- `sys.shape_calls` 计数真实 HarfBuzz 调用——测试断言「第二次 measure 不再 +1」。

## 为什么缓存 shape 而不是缓存 measure 结果
measure 结果还依赖 `max_width`（折行约束），key 维度翻倍且收益小；真正贵的 shaping 只有 (bytes, pixel_size) 一个维度。折行本身是 O(glyphs) 的纯算术，不值得缓存。

## 为什么 LRU 而不是无限缓存
键盘输入每敲一个字就是一个新 key，无限缓存 = 内存泄漏。上限 + 最久未用驱逐保证稳态内存有界（256 × (64B 文本 + 几十字形 × 24B) ≈ 几百 KB）。

## 面试口径
- 稳态一帧：0 次 HarfBuzz、0 次光栅化（atlas 命中）、只有布局算术与 GPU 提交。
- 真实框架（GPUI/parley、Slint）还多一层：整段布局树缓存 + 字体回退链缓存；`dgpui` 教育版只做最贵的那一刀。
