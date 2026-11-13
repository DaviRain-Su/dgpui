# dgpui — 用 Zig 做一个可理解的 mini-GPUI 框架

> 一个为**系统/语言背景开发者**打造的教育型桌面 GUI 框架（Zig 0.17.1）。
> 目标：不靠黑盒魔法，走通从 **DSL → 内存模型 → Flexbox 布局 → 文字排版 → 脏区与 Display List → GPU SDF 着色器 → 窗口与命中测试** 的完整闭环。

实现是 **AI 辅助** 的，设计、取舍和审查由本人负责。下面的五步闭环和 6 个 PR 是路线图。没有标成「已实现」的层，目前只有文档，没有对应代码。

---

## 一句话看懂：屏幕上的一个按钮是怎么“活”起来的？

如果你没做过 GUI，可以先记住这条**永远不变的 5 步闭环**：

```text
  （目标闭环。当前代码只做到了「没事件就休眠」的窗口循环，外加一个只清屏的 SDL_GPU 后端。
   第 1–4 步，以及第 5 步里的 Hitbox / Entity，都还是计划。）

  1. 写界面 (DSL)
     div().bg(blue).child(text("点我: 0"))
          │
          ▼  每帧从 FrameArena 分配一棵轻量的临时 UI 树（画完就整块释放）
  2. 算位置 (Layout + Text Shaping)
     每个盒子有多大？(x, y, width, height) —— 文字多宽多高？什么时候折行？
          │
          ▼  把树拍平成线性绘制清单，算清楚这一帧哪块区域变了 (Damage Region)
  3. 列清单 (Display List / Scene)
     [画圆角矩形, 画文字字形, 开启裁剪区域...] —— 这一步完全不知道 GPU 的存在！
          │
          ▼  把清单交给后端画出来（macOS 走 SDL_GPU/Metal；测试走 Headless 空后端）
  4. 画像素 (GPU Pipeline)
     SDF 着色器一次性画几百个圆角/边框/阴影；HarfBuzz + FreeType + 图集画字
          │
          ▼  平时 0% CPU 休眠，有鼠标/键盘事件才醒来
  5. 接事件 (Hitbox + 冒泡 + Entity)
     点中 (40, 130) → 倒序查谁被点中 → 触发 Entity 状态变化 (notify) → 标记脏区，回到第 1 步
```

---

## 这个项目为什么要这么拆分？

很多 GUI 教程上来就堆几十个文件。为了方便**边做边学、按 PR 逐个复习**，路线图拆成 **6 个 PR**。PR 1 和 PR 2 已有代码，PR 3–6 还没开始写：

| PR | 分支名 | 解决什么问题（大白话） | 对应的核心技术 / 面试高频点 |
| :--- | :--- | :--- | :--- |
| **PR 1** | `feat/step1-backend-and-window` | 怎么在屏幕上开个窗口、平时不耗 CPU、支持高清屏（Retina）？ | 多后端 Trait/VTable 抽象（Desktop vs Headless vs 嵌入式 DRM/KMS）、事件休眠循环、DPI 缩放 |
| **PR 2** | `feat/step2-scene-and-sdf-quad` | 怎么在不直接写死 GPU 的前提下，用一个着色器画圆角、边框和阴影？ | `FrameArena` 帧内存池、`DisplayList` 中间层、`DamageRegion` 脏区、SDF + Instancing 合批 + Scissor 裁剪 |
| **PR 3** | `feat/step3-text-shaping-and-atlas` | 为什么文字不能直接“字数×字号”画？CPU 怎么把字体变成 GPU 纹理？ | HarfBuzz（Text Shaping 连字/混排）+ FreeType2（光栅化）+ 自写 `GlyphAtlas`（字形图集） |
| **PR 4** | `feat/step4-dsl-and-flex-layout` | 窗口拉窄时文字怎么自动折行、把卡片撑高？链式 UI 语法怎么写？ | GPUI 风格链式 DSL、手写精简 Flex 布局引擎、`measure` 回调两阶段测量、无窗口单测 |
| **PR 5** | `feat/step5-entity-hitbox-and-events` | 点了按钮后，框架怎么知道点中了谁、怎么只重画变了的部分？ | `EntityStore`（持久状态 + `observe/notify`）、为什么回调不能指向帧 Arena、`Hitbox` 倒序命中与冒泡、Counter Demo |
| **PR 6** | `feat/step6-scroll-input-and-comptime-dsl` | 滚动条、键盘输入怎么接入？编译期声明式 DSL 和链式写法差在哪？ | Scissor 滚动裁剪、焦点与键盘分发、Todo Demo、Zig `comptime` vs Rust `proc-macro` / `.slint` 对比 |

---

## 现在做到哪了

| 层 | 状态 | 代码 |
| :--- | :--- | :--- |
| 几何（`Point` / `Rect` / `Color`） | **已实现** | `src/math.zig` |
| 平台 / 渲染 VTable、Headless、事件循环 | **已实现** | `src/backend/platform.zig`、`renderer.zig`、`headless.zig`、`src/app.zig` |
| SDL3 窗口、`SDL_GPU` 清屏、鼠标键盘、文本与 IME 事件 | **已实现**（机器上有 SDL3 开发包才编译） | `src/backend/sdl.zig` |
| `FrameArena`、`DisplayList`、脏区并集、圆角 SDF | **已实现（最小）**。`glyph` 只记录不画。着色器是 SPIR-V，MSL 还没做 | `src/frame_arena.zig`、`display_list.zig`、`damage.zig`、`sdf.zig`、`src/backend/sdl_scene.zig` |
| HarfBuzz、FreeType、Flex、`Entity`、Hitbox、滚动、焦点、无障碍 | **还没做** | 见 `docs/architecture.md` 的 Step 3–6 |

## 技术栈

- **语言**：Zig `0.17.1`
- **当前依赖**：`SDL3` + `SDL_GPU`（macOS 上 SDL_GPU 走 Metal）。没有 SDL3 时，headless 测试照样能编、能跑。
- **计划中的依赖**：HarfBuzz、FreeType2、自写 `GlyphAtlas`。布局打算自己写一个小 Flex，只参考 Yoga / Taffy 的模型，**不链接 Yoga**。
- **写法**：AI 辅助实现，本人负责设计与审查。关键路径（事件循环、像素尺寸、文本截断）留在仓库里，不包一层不透明库。

---

## 阅读导航

- [架构拆解与通俗图解 (`docs/architecture.md`)](docs/architecture.md) —— 建议先花 5 分钟读这一篇，把所有名词一次对齐。
- [GUI 框架大白话（`docs/gui-framework-plain.md`）](docs/gui-framework-plain.md) —— 面试前十分钟：五层各自干什么、代码做到哪、一帧怎么走。
- [PR 2 学习笔记（`docs/pr2-scene-and-sdf-quad.md`）](docs/pr2-scene-and-sdf-quad.md) —— 绘制清单、脏区和圆角 SDF 这一步做了什么。
- [Rust GUI 框架面试映射表 (`docs/interview-map.md`)](docs/interview-map.md) —— 把 `dgpui` 的每一行代码翻译成 Rust / Slint / egui / Iced / 渲染管线面试术语。

---

## 快速构建与测试

```bash
# headless 单测：重绘合并、几何、UTF-8 截断、像素尺寸。不需要 SDL3。
zig build test

# 即使本机装了 SDL3，也只跑不链接 SDL 的测试。
zig build test-headless

# 桌面示例。Linux 走 pkg-config sdl3；macOS Homebrew 一般也能被探测到。
# 探测失败时可以手动给路径：
#   zig build run -Dsdl-include=/opt/homebrew/include -Dsdl-lib=/opt/homebrew/lib
zig build run
```
