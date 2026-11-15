# 面试概念对照表：从 `dgpui` (Zig) 映射到 Rust GUI 框架岗位

这份文档把 `dgpui` 的设计对应到 Rust GUI 岗位面试里的高频术语。

> **现状（PR 1–6 已合并到 `main`）**：多后端、`FrameArena`、`DisplayList`/Damage、SDF Quad、HarfBuzz/FreeType/`GlyphAtlas`、链式 DSL + 手写 Flex、`EntityStore`/`Hitbox`、滚动/焦点、以及 comptime DSL 对比都已有代码。口述提纲见 [`docs/interview-qa.md`](interview-qa.md)。实现是 AI 辅助的，设计与审查由本人负责。

---

## 1. 四大 GUI 架构流派对比（必考）

| 框架 | 模式分类 | 状态放哪？ | 树与更新机制 | 核心优势 / 代价 |
| :--- | :--- | :--- | :--- | :--- |
| **GPUI / `dgpui`** | **保留状态 + 帧重建混合模式** | `Entity<T>`（句柄 + 持久池） | 视图变脏时，从 `FrameArena` 重建轻量 Element 树，**不做 VDOM Diff**，直接 Layout -> DisplayList | 兼顾代码直觉和高性能；没有繁重 VDOM，但需要开发者分清 `Entity` 和每帧临时 `Element` |
| **Slint** | **声明式 + 编译期绑定** | `.slint` 组件属性（编译成属性图） | `.slint` 编译器提前生成 Rust 代码与**响应式属性依赖 DAG**，改一个属性精确失效相关绑定 | 内存占用极低（适合嵌入式/桌面多后端），但需要独立 DSL 编译器与语言绑定 |
| **egui** | **立即模式 (Immediate Mode)** | 全在用户代码结构体里 | 每帧（有输入时）从头到尾跑一遍 UI 函数，当场算位置当场画，**没有持久树** | 极其简单、零状态同步 bug；但复杂两阶段布局（后元素影响前元素）、动画、无障碍支持很吃力 |
| **Iced** | **Elm 架构 (MVU)** | 单一不可变/集中 `State` | 用户操作产生 `Message` -> `update(state, msg)` -> `view(state)` 重建树 | 数据流单向可预测；大型应用 `Message` 路由繁琐，跨组件局部状态较重 |

> **关键区分（面试踩坑提醒）**：
> `dgpui` / GPUI **不是** Slint 或 Leptos 那种“细粒度响应式数据绑定（Signal/DAG）”，而是 **受控/非受控状态 + 显式 `Entity.notify` 标记脏视图 + 帧级重建 Element 树**。

---

## 2. Rust 所有权与内存模型（把 Zig 翻译成 Rust）

在 `dgpui` 里有两个分配世界，面试官问 Rust 所有权时可以直接画出来：

1. **为什么会有 `'frame` 生命周期 / 为什么回调不能指向帧 Arena？**
   - `Div` / `Text` 与布局节点分配在 `FrameArena`，帧末 `reset()`（见 `src/arena.zig`、`src/ui/element.zig`）。
   - Rust 视角：Element 树借用 `&'frame FrameArena`；点击回调必须 `'static` 或只捕获 `EntityId`。
   - Zig 里若回调持有 `Element*`，下一帧就是悬垂指针。
2. **为什么用 `EntityId`（index + generation）而不是到处 `Rc<RefCell<T>>`？**
   - 已实现：`src/entity.zig`。generation 防 slot 复用；`observe/notify` 把脏 view 放进 set，同轮合并。
   - 对应 Rust：SlotMap / generational arena + `cx.update_entity`，规避重入 `RefCell` panic。
3. **FFI 与 `unsafe` 边界（SDL3 + HarfBuzz + FreeType2）**
   - Flex 是手写的（`src/layout/flex.zig`），不链接 Yoga/Taffy。
   - SDL 事件译成值类型 `platform.Event`；文本按码点拷进定长缓冲，不把 C 指针漏出事件循环。

---

## 3. 渲染管线与多后端生态分工

面试常问：**`wgpu`、`Vello`、`Skia`、`FemtoVG` 分别干什么？为什么不止用其中一个？**

- **`wgpu`（以及 `dgpui` 里的 `SDL_GPU`）**：**底层 GPU 硬件抽象层**。管 Buffer/Texture/Pipeline/Draw Call，**不懂**圆角矩形或贝塞尔。
- **`dgpui` 自写 SDF 着色器 + `GlyphAtlas`**：跑在 `SDL_GPU`/Metal 上，专门画大量 UI 盒子 + 文本；不擅长任意复杂矢量路径。
- **`Skia` / `FemtoVG` / `Vello`**：分别是全能 2D、轻量路径、GPU compute 路径光栅——需要复杂矢量时再引入，不是「有了 wgpu 就有 UI」。

### 局部重绘（Damage Region）与裁剪（Scissor）
- **已实现**：`DamageRegion.fromDisplayListDiff`；batch 按 clip 分批并 `SDL_SetGPUScissor`。
- **诚实边界**：swapchain 仍 `LOADOP_CLEAR`。因此 **不能**只按 `damage_rect` 做 scissor 跳过静态区，否则 clear 后静态内容消失。真增量重绘需要离屏 retained canvas + `LOADOP_LOAD`（未做）。

### 桌面窗口后端 vs 嵌入式 DRM/KMS
- 桌面：`SDL3` 申请 Surface，收系统事件。
- 嵌入式：`DRM/KMS` + `libinput` 直接 scanout。
- `PlatformBackend` + `RendererBackend` 抽干净后，上层 DSL/布局/Entity **不用改**——Slint 多后端同一思想。

---

## 4. 声明式 DSL 与 Rust 过程宏（`proc-macro`）的取舍

- **链式 Builder（已实现，主路径）**：`src/ui/element.zig` — `div().flexCol().p(16).child(text(...))`。动态列表/条件自然。
- **comptime 静态表（PR 6 教育对比）**：`src/ui/comptime_dsl.zig` — 编译期形状 → 运行期实例化到 FrameArena。
- **Rust `proc-macro` / `.slint` 编译器**：更强静态检查与依赖分析，代价是宏/编译器复杂度与报错体验。

---

## 5. 事件闭环（已实现）

| 步骤 | 代码 |
| --- | --- |
| Paint 登记 Hitbox | `ui.paintTreeHit` |
| 倒序命中 + 冒泡 | `hitbox.HitList.dispatchClick` |
| 改持久状态 + notify | `entity.EntityStore` |
| 键盘进焦点 | `input.FocusManager` |
| 滚动裁剪 | `ui.paintScroll` + `ScrollState` |

详见各 PR 文档与 [`interview-qa.md`](interview-qa.md)。
