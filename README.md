# dgpui — 用 Zig 从零手写一个可理解的 mini-GPUI 框架

> 一个为**系统/语言背景开发者**打造的教育型桌面 GUI 框架（Zig 0.17.1）。
> 目标：不靠黑盒魔法，亲手走通从 **DSL → 内存模型 → Flexbox 布局 → 文字排版 → 脏区与 Display List → GPU SDF 着色器 → 窗口与命中测试** 的完整闭环。

---

## 一句话看懂：屏幕上的一个按钮是怎么“活”起来的？

如果你没做过 GUI，可以先记住这条**永远不变的 5 步闭环**：

```text
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

很多 GUI 教程上来就堆几十个文件。为了方便**边做边学、按 PR 逐个复习**，我们把整个框架拆成了 **6 个独立、可运行的 PR**，每个 PR 只解决一个核心问题：

| PR | 分支名 | 解决什么问题（大白话） | 对应的核心技术 / 面试高频点 |
| :--- | :--- | :--- | :--- |
| **PR 1** | `feat/step1-backend-and-window` | 怎么在屏幕上开个窗口、平时不耗 CPU、支持高清屏（Retina）？ | 多后端 Trait/VTable 抽象（Desktop vs Headless vs 嵌入式 DRM/KMS）、事件休眠循环、DPI 缩放 |
| **PR 2** | `feat/step2-scene-and-sdf-quad` | 怎么在不直接写死 GPU 的前提下，用一个着色器画圆角、边框和阴影？ | `FrameArena` 帧内存池、`DisplayList` 中间层、`DamageRegion` 脏区、SDF + Instancing 合批 + Scissor 裁剪 |
| **PR 3** | `feat/step3-text-shaping-and-atlas` | 为什么文字不能直接“字数×字号”画？CPU 怎么把字体变成 GPU 纹理？ | HarfBuzz（Text Shaping 连字/混排）+ FreeType2（光栅化）+ 自写 `GlyphAtlas`（字形图集） |
| **PR 4** | `feat/step4-dsl-and-flex-layout` | 窗口拉窄时文字怎么自动折行、把卡片撑高？链式 UI 语法怎么写？ | GPUI 风格链式 DSL、手写精简 Flex 布局引擎、`measure` 回调两阶段测量、无窗口单测 |
| **PR 5** | `feat/step5-entity-hitbox-and-events` | 点了按钮后，框架怎么知道点中了谁、怎么只重画变了的部分？ | `EntityStore`（持久状态 + `observe/notify`）、为什么回调不能指向帧 Arena、`Hitbox` 倒序命中与冒泡、Counter Demo |
| **PR 6** | `feat/step6-scroll-input-and-comptime-dsl` | 滚动条、键盘输入怎么接入？编译期声明式 DSL 和链式写法差在哪？ | Scissor 滚动裁剪、焦点与键盘分发、Todo Demo、Zig `comptime` vs Rust `proc-macro` / `.slint` 对比 |

---

## 技术栈（全部本机原生零臃肿依赖）

- **语言**：Zig `0.17.1`
- **窗口与 GPU 抽象**：`SDL3` + `SDL_GPU`（macOS 自动跑 Metal，也可轻松替换成 `winit`/`wgpu` 或嵌入式 `DRM/KMS`）
- **文本排版与光栅化**：`HarfBuzz` + `FreeType2` + 自写 Shelf `GlyphAtlas`
- **布局与渲染核心**：100% 自己用 Zig 手写（`FrameArena`、`EntityStore`、Flex 引擎、`DisplayList`、SDF 着色器），不隐藏任何关键逻辑。

---

## 阅读导航

- [架构拆解与通俗图解 (`docs/architecture.md`)](docs/architecture.md) —— 建议先花 5 分钟读这一篇，把所有名词一次对齐。
- [Rust GUI 框架面试映射表 (`docs/interview-map.md`)](docs/interview-map.md) —— 把 `dgpui` 的每一行代码翻译成 Rust / Slint / egui / Iced / 渲染管线面试术语。

---

## 快速构建与测试

```bash
# 运行所有无窗口单元测试（内存池、布局、脏区、命中测试等）
zig build test

# 运行桌面 GUI 示例程序
zig build run
```
