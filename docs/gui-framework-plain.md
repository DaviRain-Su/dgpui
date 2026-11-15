# 用大白话讲 GUI 框架

给周一面试用。十分钟能读完。对照的是 AKR 那篇《vibe 一个你自己的 GUI 框架》的五层切法，例子换成这个仓库里真有的代码。

先记住一句：GUI 框架就是一台翻译机。你用比较好写的方式描述界面，它算出每个盒子在屏幕上的位置，再把「画什么」交给显卡，最后听操作系统说鼠标点在哪。

`dgpui` 的 6 个 PR 已经全部合并到 `main`。实现是 AI 辅助的：方向、拆任务、审代码、跑例子是我的。口述提纲见 [`interview-qa.md`](interview-qa.md)。

---

## 第 1 层：怎么写界面

**一句话讲清：** 让人用几行代码说出「这里有个按钮」，而不是手写每个像素的坐标。

**dgpui 做到哪。** 主路径是 GPUI 风格链式 DSL：`div().flexCol().p(24).child(text(...))`（`src/ui/element.zig`）。PR 6 另有一份 comptime 静态表实例化（`src/ui/comptime_dsl.zig`），用来对比「运行期建树」和「编译期定形状」。

---

## 第 2 层：记住什么，什么时候重算

**一句话讲清：** 按钮上的数字要活过很多帧，这一帧的界面树画完就可以扔掉。

**dgpui 做到哪。**
- 持久：`EntityStore`（`src/entity.zig`）— `EntityId` + `observe/notify`。
- 瞬时：`FrameArena`（`src/arena.zig`）— 每帧 Element 树，帧末 reset。
- 事件循环：`AppLoop` 用 `needs_redraw` 把一批事件合并成一帧。

回调只许拿 EntityId / 持久指针，不许拿 FrameArena 里的 `Element*`。

---

## 第 3 层：盒子放哪，字有多宽

**一句话讲清：** 你只说「横着排、间距 8」，框架算出矩形；字宽要问字体。

**dgpui 做到哪。** 手写 Flex（`src/layout/flex.zig`）+ HarfBuzz `measure_text` 回调折行撑高。文字真正画出来走 FreeType → `GlyphAtlas` → Metal glyph shader。

---

## 第 4 层：画到屏幕上

**一句话讲清：** 先列一张和显卡无关的清单，再让 GPU 按清单画。

**dgpui 做到哪。** `DisplayList`（quad / glyph / push_clip/pop_clip）→ 合批 → SDF quad 着色器 + glyph 贴图。帧间 diff 得到 Damage；batch scissor 用 clip。交换链仍 `LOADOP_CLEAR`，所以还不是完整的离屏增量图层缓存——面试时要说清这条边界。

---

## 第 5 层：窗口、点击、输入法

**一句话讲清：** 没人操作时线程睡觉；有事件时把坐标翻成逻辑坐标，再决定重画。

**dgpui 做到哪。**
- `PlatformBackend` / `RendererBackend` VTable；SDL3/Metal 与 Headless。
- Hitbox 倒序命中 + 冒泡；Focus 收键盘；Scroll = offset + PushClip。
- IME：`text_input` / `text_editing` 已翻译；预编辑 UI / 候选框未画。

---

## 一帧是怎么走的

1. `waitEvent` 阻塞；醒来 `pollEvent` 排空。
2. 左键 → 上一帧 `HitList` 倒序命中；滚轮/键盘 → Scroll / Focus。
3. 回调改 Entity 并 `notify`；脏标记合并成一次 `requestRedraw`。
4. `drawOnce`：reset FrameArena → 回调建 DSL 树 → Flex 布局 → `paintTreeHit` 填 DisplayList + Hitbox → Damage diff → GPU 提交。

---

## 流派对比

| 做法 | 一句话 | 好处 | 代价 |
| :--- | :--- | :--- | :--- |
| 每帧重建（egui） | 每帧重跑 UI 函数 | 好懂 | 两阶段布局/无障碍更难 |
| Diff（React VDOM） | 新旧树比较 | 局部更新直观 | 两棵树 + diff 成本 |
| Signal | 改一格通知订户 | 更新面可以很小 | 依赖/重入更绕 |
| 编译期（Slint） | 编译时算依赖 | 运行时瘦 | 要养编译器 |

`dgpui`：Entity 持久 + 脏了重建帧树；主 DSL 是链式；comptime 只做对比实验。

---

## 面试怎么聊

详见 [`interview-qa.md`](interview-qa.md)。这里只留 30 秒开场：

我在用 Zig 写教学向 mini-GPUI（dgpui），把框架层五层走通：DSL、Entity/Arena、Flex+文字、DisplayList/SDF、窗口与命中。6 个 PR 都在 main。实现 AI 辅助，设计审查归我。概念可映射到 Rust 的 GPUI / Slint / egui / Iced / wgpu。
