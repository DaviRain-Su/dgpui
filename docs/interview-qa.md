# Monday 面试口述提纲（dgpui → Rust GUI 框架岗）

按「30 秒开场 → 高频追问 → 踩坑边界」准备。代码路径以 `main`（PR 1–6 已合并）为准。

---

## 30 秒开场

我用 Zig 0.17 写了一个教学向 mini-GPUI：`dgpui`。目标不是做应用级控件库，而是把框架层走通——多后端、帧内存 vs 持久 Entity、DisplayList / Damage、SDF 合批、HarfBuzz 文字、手写 Flex、Hitbox、焦点与滚动。实现是 AI 辅助的；方向、拆 PR、Codex review、合并由我负责。概念可以直接映射到 Rust 岗上的 GPUI / Slint / egui / Iced / wgpu。

仓库：https://github.com/DaviRain-Su/dgpui

---

## 五层闭环（口述骨架）

```text
DSL (chain / comptime 对比)
  → FrameArena 重建 Element 树 + EntityStore 持久状态
  → Flex layout + HarfBuzz measure
  → DisplayList / Damage / SDF Quad + GlyphAtlas
  → Platform/Renderer VTable（SDL3/Metal 或 Headless）
  → Hitbox 倒序命中 + Focus + Scroll clip → notify → 下一帧
```

---

## 高频问答（建议背结构，不背长文）

### 1. 你的框架属于哪一派？和 VDOM / Signal 有何不同？
**答：** 保留态 + 帧重建混合（GPUI 风格）。业务状态在 `EntityStore`；视图脏了从 `FrameArena` 重建轻量 Element 树，**不做 VDOM Diff**，也**不是** Slint/Leptos 那种细粒度 Signal DAG。脏标记靠显式 `observe/notify`，同一轮事件合并成一次重绘。

对照：
- egui：立即模式，几乎无持久 UI 树
- Iced：MVU，`Message → update → view`
- Slint：编译期属性依赖图

### 2. 为什么回调不能捕获 `Element*`？
**答：** Element 在 `FrameArena`，帧末 `reset`。回调跨帧存活，只能持有 `EntityId` / 持久 `DemoState*`。Rust 里这就是 `'frame` vs `'static`；Zig 里写错就是 use-after-free。

### 3. 为什么用 `EntityId {index, generation}` 而不是到处 `Rc<RefCell>`？
**答：** GUI 回调重入常见（A 改 B，B 又通知 A）。句柄 + generational arena（类似 SlotMap）集中借用，避免 `RefCell` 运行时 panic；generation 防悬垂复用。

### 4. Damage Region 你真的做了增量重绘吗？
**答（诚实边界）：** DisplayList 帧间 diff 算出 `damage_rect` 了；batch 的 Scissor 用的是 **clip 栈**。Metal 交换链仍 `LOADOP_CLEAR`，所以**不能**只按 damage scissor 跳过静态区域，否则清屏后静态内容消失。真正的增量重绘需要离屏 retained canvas + `LOADOP_LOAD`，我刻意没夸大成「完整图层缓存」。

### 5. SDF Quad 合批规则是什么？
**答：** Painter's Order 下，只有**相邻且 clip 相同**的 quad 才能合批；不同 clip 必须拆 batch，否则遮挡/裁剪错误。实例数据走 storage/instance buffer，一次 `DrawPrimitives` 画一批。

### 6. 文字宽度为什么不能 `字数 × 字号`？
**答：** 连字、kerning、中英混排、CJK 折行都要 shaping。我们用 HarfBuzz 整形 + FreeType 光栅化进 `GlyphAtlas`；布局通过 `measure_text(max_width)` 拿折行后高度撑开 Flex。

### 7. Flex 里你踩过哪些坑？（结合 Codex review）
**答：**
1. 节点有显式 `.w(480)` 时，measure 必须先用 480，不能用父级更宽约束，否则折行高度错。
2. row shrink 变窄后要**按最终宽度重测高度**。
3. column `flex_grow` 分配的高度不能被后续无条件重测改回去。
4. shrink 触零后要冻结，剩余压缩量按**原始尺寸权重**继续分。

### 8. 点击如何命中？会穿透吗？
**答：** Paint 时登记 Hitbox；点击**倒序**遍历（后画在上）。命中后沿 parent 冒泡。可见叶子即使无 `onClick` 也要登记，避免挡住下层却点穿到被遮住的兄弟。clip 外直接拒绝（滚动容器靠这个）。

### 9. 键盘为什么需要 Focus？
**答：** 鼠标有坐标 → Hitbox；键盘没有坐标 → 必须先有 `focus_id`。点击输入框 `FocusManager.focus`；`text_input` / `key_down` 派给当前焦点 Entity。

### 10. 多后端怎么换到 DRM/KMS？
**答：** 上层只认 `PlatformBackend` + `RendererBackend` VTable。桌面用 SDL3/Metal 拿 Surface；嵌入式可换成 DRM/KMS + libinput 直接 scanout。布局/Entity/DSL **不用改**。这是和 Slint 多后端同一思想。

### 11. Chain DSL vs comptime / proc-macro？
**答：**
| | Chain | comptime / proc-macro / `.slint` |
| --- | --- | --- |
| 树何时定 | 每帧运行期 | 形状可编译期已知 |
| 动态列表 | 自然 | 更别扭 |
| 调试 | 普通调用栈 | 宏展开/编译器报错更难 |
| 收益 | 简单直观 | 更强静态检查 / 更小运行时 |

`dgpui` 主路径是 Chain；PR 6 用静态 `CompNode` 表做了教育向对比，不是另做完整编译器。

### 12. 和 wgpu / Vello / Skia 怎么分工？
**答：** `SDL_GPU`/`wgpu` 是 GPU 抽象，不懂 UI 原语。我们自写 SDF + GlyphAtlas 解决盒子和字；复杂矢量路径才需要 Skia/Vello/FemtoVG。别把「用了 wgpu」说成「有了 UI 渲染器」。

---

## 一分钟 Demo 故事

1. 启动 Todo Demo：预置列表超出 viewport → 滚轮改 `ScrollState.offset_y`，`PushClip` + 平移，Hitbox 带 clip。
2. 点输入框 → Focus；打字 / Backspace / Enter 改 Entity 里的 draft/items 并 `notify`。
3. 同批事件多次 notify → dirty set 去重 → 一帧重绘。
4. 卡片/按钮来自 Chain DSL；列表下方还有一张 comptime 表实例化的静态卡，用来对比两种 DSL。

---

## 被问到「没做完」时怎么说

| 话题 | 说法 |
| --- | --- |
| 真·增量重绘 / 图层缓存 | damage 算了；swapchain 仍 CLEAR；完整 retained layer 未做 |
| IME 候选框 / 预编辑绘制 | 事件已翻译；UI 未画 |
| AccessKit 无障碍 | 不在 6 PR 内；要有稳定树和焦点后再接 |
| Yoga/Taffy | 故意不链接，手写教育向 Flex |
| 代码是否全手写 | AI 辅助实现；设计/审查/测试归我 |

---

## 对应代码速查

| 话题 | 文件 |
| --- | --- |
| 事件循环合并重绘 | `src/app.zig` |
| 后端 VTable | `src/backend/platform.zig` `renderer.zig` |
| FrameArena / DisplayList / Damage | `src/arena.zig` `src/scene.zig` |
| SDF / Glyph shader | `src/shader/quad.metal` `glyph.metal` |
| 文字 | `src/text/*` |
| Flex / DSL | `src/layout/flex.zig` `src/ui/element.zig` |
| Entity / Hitbox / Focus / Scroll | `src/entity.zig` `src/hitbox.zig` `src/input.zig` `src/ui/scroll.zig` |
| comptime 对比 | `src/ui/comptime_dsl.zig` |
