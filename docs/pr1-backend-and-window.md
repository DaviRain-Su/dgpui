# PR 1 学习笔记：多后端抽象、DPI 缩放与空闲休眠事件循环

## 1. 这个 PR 解决了什么问题？

在写任何按钮、布局或文字之前，GUI 框架必须先回答三个最底层的问题：
1. **代码怎么做到不绑死操作系统？**（今天跑在 macOS Metal，明天能跑无窗口测试、甚至嵌入式 Linux DRM/KMS）
2. **为什么桌面 GUI 放在后台 CPU 占用是 0%，而游戏却一直在跑？**
3. **同样写 400 宽的卡片，为什么 Mac Retina 屏上不会变成邮票大小？**

---

## 2. 本 PR 的文件结构与职责

- `src/math.zig`：全框架的几何底座（`Point`、`Size`、`Rect`、`Color`）。
- `src/backend/platform.zig`：**平台抽象接口（`PlatformBackend`）**，相当于 Rust 的 `trait PlatformBackend`。只管“等事件、取缩放比、改光标、请求重绘”。
- `src/backend/renderer.zig`：**渲染抽象接口（`RendererBackend`）**，只管“吃进一帧参数/指令并画出来”。
- `src/backend/headless.zig`：**无头测试后端**，同时实现上面两个接口，零窗口、可在单元测试里注入假鼠标点击与假 Resize。
- `src/backend/sdl.zig`：**桌面端后端**，用 `SDL3 + SDL_GPU`（在 macOS 自动跑 Metal）真正弹出原生窗口并完成 GPU 清屏。
- `src/app.zig`：**主事件循环（`AppLoop`）**，实现“空闲休眠 + 队列排空 + 重绘合并”。

---

## 3. 三个必须记住的核心机制

### (1) 逻辑像素 vs 物理像素（Retina DPI）
- 框架内部（布局、命中测试）**永远只用逻辑像素**，比如窗口宽 `800`。
- `WindowMetrics` 同时记录 `scale_factor`（Retina 屏上是 `2.0`）。
- 只有提交给 GPU 渲染或光栅化字体时，才调用 `physicalWidth()` 换算成 `1600` 物理像素，防止高分屏发虚。

### (2) 空闲休眠 + 重绘合并（Coalescing）
打开 `src/app.zig` 看 `AppLoop.run()`：
```text
waitEvent()   <-- 没事件时线程在这里阻塞睡觉，CPU ≈ 0%
    │ (操作系统推来第 1 个事件)
    ▼
while (pollEvent())  <-- 醒来后把队列里积压的 Resize / Move 全吃掉
    │
    ▼
if (needs_redraw) drawOnce()  <-- 不管中间触发了多少次 requestRedraw，本轮只画 1 次！
```
`test "event loop sleeps on idle and coalesces..."` 用 `HeadlessBackend` 塞了两次连续 `resized` + 一次 `redraw_requested`，断言总绘制帧数严格等于 2（首帧 + 合并后的 1 帧）。

### (3) 映射到面试问题：桌面 `winit/SDL3` vs 嵌入式 `DRM/KMS`
因为我们把 `PlatformBackend` 和 `RendererBackend` 从主循环里拆出来了：
- 桌面端是 OS 窗口系统分配画布（SDL3 / winit / AppKit `CAMetalLayer`）。
- 如果未来要支持**嵌入式 Linux（无 X11/Wayland）**，只需要新建 `src/backend/drm.zig`，通过内核 `DRM/KMS` 申请显存帧缓冲做直接 `scanout`，用 `libinput` 读触控/键盘事件，**`AppLoop` 和上层所有布局/组件代码一行不用改**。这就是 Slint 等多后端框架的本质架构。
