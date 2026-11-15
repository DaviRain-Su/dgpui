# 一页作弊条（面试前 5 分钟）

> 详细版见 `interview-qa.md`；代码速查在文末。

## 一句话定位
用 Zig 写的教学 mini-GPUI：**Entity 持久状态 + FrameArena 帧重建 + DisplayList/SDF + 手写 Flex + HarfBuzz 文字 + Hitbox/Focus/Scroll**，6 个 PR 全部合并在 `main`，headless 测试覆盖事件闭环。

## 五层一行版
| 层 | 关键词 | 文件 |
| --- | --- | --- |
| DSL | 链式主路径；comptime 表对比 | `ui/element.zig` `ui/comptime_dsl.zig` |
| 状态 | Entity(generation)+notify；FrameArena reset | `entity.zig` `arena.zig` |
| 布局 | Flex 两阶段；measure 折行撑高 | `layout/flex.zig` `text/layout.zig` |
| 绘制 | DisplayList→合批→SDF/Atlas；Damage diff | `scene.zig` `shader/*.metal` |
| 窗口/输入 | VTable 双后端；倒序命中+冒泡；Focus；Scroll clip | `backend/*` `hitbox.zig` `input.zig` `ui/scroll.zig` |

## 必背 8 句
1. **流派**：保留态+帧重建（GPUI 派）；不是 VDOM diff，不是 Signal DAG。
2. **回调纪律**：只拿 `EntityId`/持久指针；拿 `Element*` = 帧末 use-after-free（Rust 里是 `'frame` vs `'static`）。
3. **EntityId**：index+generation 防 slot 复用；`observe/notify` 脏标记同轮合并一帧。
4. **Damage 边界**：diff 算了脏区；swapchain 仍 `LOADOP_CLEAR`，**不能**按 damage scissor 跳过静态区；真增量要离屏 retained canvas。
5. **合批**：仅相邻且 clip 相同的 quad 合；遮挡顺序不能破。
6. **文字**：宽度≠字数×字号；HarfBuzz shaping + FreeType 光栅化进 GlyphAtlas；`measure(max_width)` 出折行高度。
7. **命中**：Paint 登记 Hitbox，**倒序**遍历；可见叶子也登记防点穿；clip 外拒绝；子不处理冒泡到父。
8. **键盘**：没有坐标→先有焦点；点击 `focus(id)`，`text_input/key_down` 派给焦点 Entity。

## 三个「讲出细节」的加分点
- **Flex 踩坑**（来自 Codex review）：显式宽度优先测量；shrink 后按最终宽度重测高度；column grow 高度不被重测冲掉；shrink 触零冻结后按**原始尺寸**权重重分。
- **headless smoke**：`src/demo.zig` 用 Headless 后端跑完整闭环——画一帧取输入框 hitbox 中心→点击聚焦→输入"买牛奶"→Enter 提交→滚轮 120px→断言 9 条 + offset=120 + 焦点保持。证明窗口逻辑可在 CI 无窗口复现。
- **性能预算**：图集满→就地扩容保 UV；shaped-run LRU 缓存 → 稳态每帧 0 次 HarfBuzz / 0 次光栅化（`sys.shape_calls` 可断言）。
- **DRM/KMS**：换后端只动两个 VTable，上层 DSL/布局/Entity 零改动。

## 诚实边界（被问就认）
| 没做 | 一句话 |
| --- | --- |
| 真·增量重绘 | 需要 offscreen retained layer + `LOADOP_LOAD` |
| IME 候选框/预编辑 UI | 事件已翻译，界面未画 |
| AccessKit | 不在 6 PR；需稳定树+焦点后再接 |
| 复杂矢量（SVG） | SDF+Atlas 不擅长；那层是 Skia/Vello |
| AI 辅助 | 实现 AI 辅助，设计/审查/验收归我 |

## 30 秒开场
我用 Zig 0.17 写教学向 mini-GPUI `dgpui`，把框架层五层走通并全部合入 main；AI 辅助实现，我负责设计、PR 拆分、Codex review 和验收。概念可一一映射到 Rust 岗位的 GPUI/Slint/egui/Iced/wgpu。仓库：github.com/DaviRain-Su/dgpui
