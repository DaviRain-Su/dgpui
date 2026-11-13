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
- 框架内部（布局、命中测试）**只用窗口坐标**，来源是 `SDL_GetWindowSize`。在 macOS 上这是点（point），800 宽的卡片在普通屏和 Retina 上物理大小接近。
- 交换链 / GPU 要用的像素数来自 `SDL_GetWindowSizeInPixels`，不是“逻辑尺寸 × `SDL_GetWindowDisplayScale`”。
- `scale_factor` 是 `SDL_GetWindowPixelDensity`：1 个窗口坐标对应多少像素。macOS 打开 `SDL_WINDOW_HIGH_PIXEL_DENSITY` 时 Retina 通常是 `2.0`，这时它和 display scale 碰巧一样，`physicalWidth()` 得到 `1600`。
- `content_scale` 是 `SDL_GetWindowDisplayScale`：系统希望内容放大多少。它**不**参与交换链尺寸。Windows 200% 时窗口坐标本身已经是像素，pixel density 是 `1.0`，display scale 是 `2.0`。若用 display scale 去乘，3840 会变成 7680，比真实像素大一倍。
- 只有没拿到 `SizeInPixels` 时，才回退到 `round(逻辑尺寸 × scale_factor)`。拿到了就以它为准，避免 1.5 倍缩放下四舍五入差 1 个像素。
- `SDL_EVENT_WINDOW_RESIZED` 和 `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` 都会重新查询上面这组数。跨屏或分数倍缩放时，像素尺寸可以在窗口坐标没变的情况下单独变。

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
- 如果未来要支持**嵌入式 Linux（无 X11/Wayland）**，只需要新建 `src/backend/drm.zig`，通过内核 `DRM/KMS` 申请显存帧缓冲做直接 `scanout`，用 `libinput` 读触控/键盘事件，**`AppLoop` 和上层所有布局/组件代码一行不用改**。这就是 Slint 等多后端框架的本质架构。上层布局目前还是计划，见 `docs/architecture.md`。

---

## 4. 审查之后改了什么，为什么

下面每条都先对照 SDL 文档或现有代码核实过，再改。

### (1) 文档和代码对齐
README 原来写「100% 自己用 Zig 手写」。这个仓库是 AI 辅助实现，设计、取舍和审查由本人负责，那句删掉了。`FrameArena`、`DisplayList`、SDF、HarfBuzz、Flex、`Entity`、Hitbox 都还没有源文件，文档里保留计划，但标成「计划中」。`docs/interview-map.md` 把 Yoga 列进了 FFI 依赖，项目并不链接 Yoga，Flex 只是打算参考它的模型，已经改掉。

### (2) 不装 SDL 也能测
`build.zig` 以前把头文件和库路径写死成 `/opt/homebrew`，`src/root.zig` 又无条件 `@import` SDL。结果 `zig build test` 在没有 Homebrew SDL 的 Linux 上编不过。现在按这个顺序找 SDL3：手动 `-Dsdl-include` / `-Dsdl-lib`、`pkg-config sdl3`、常见前缀（含 `/opt/homebrew`）。找不到时 headless 模块不导入 `sdl.zig`。`zig build test` 跑 headless 测试；本机有 SDL3 时同一条命令还会把桌面 demo 编译链接进去。`zig build test-headless` 永远不链接 SDL。配置阶段会把构建缓存标脏，避免装上或卸掉 SDL 之后还沿用上一次的探测结果。

### (3) 物理像素不再乘 display scale
SDL 的 high-DPI 说明把三件事分开了：窗口坐标（`SDL_GetWindowSize`）、可绘制像素（`SDL_GetWindowSizeInPixels`）、内容缩放（`SDL_GetWindowDisplayScale`）。像素密度是后两者之外的 `SDL_GetWindowPixelDensity`。macOS Retina 上 density 和 display scale 常常都是 2，旧公式碰巧正确。Windows 200% 上窗口坐标已经是像素，density 是 1，display scale 是 2，旧公式会把交换链算大一倍。`WindowMetrics.physicalWidth()` 现在优先返回 `SizeInPixels`。`PIXEL_SIZE_CHANGED` 本来就会重新查询，查询函数改对之后这条事件拿到的就是真实像素。

### (4) `resize` 记下像素尺寸，但不自己重建交换链
SDL_GPU 没有 `resize(width, height)`。`SDL_SetGPUSwapchainParameters` 只改 composition 和 present mode。Vulkan 后端在 `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` 进入队列时把 `needsSwapchainRecreate` 设上，下一次 `SDL_WaitAndAcquireGPUSwapchainTexture` 才按那个事件里的像素重建。Metal 后端则在 acquire 时读 `CAMetalLayer.drawableSize`。所以 `resize` 不能是一声不吭的空函数：它把 `AppLoop` 传来的像素尺寸写进 `SdlBackend`，acquire 若带回非 0 的纹理尺寸再覆盖一次。交换链本身仍由 SDL 重建。

### (5) 文本不再从码点中间截断，并接上 IME 预编辑
SDL 的字符串只在这次取事件期间有效，所以要拷进 `Event` 自己的缓冲（`Event` 按值进队列）。缓冲从 32 字节加到 256 字节。更长的输入在 UTF-8 码点边界停下，不会把一个汉字或 emoji 切成两半。`SDL_StartTextInput` 的返回值现在会检查，失败走原来就声明了但没用到的 `TextInputStartFailed`。`SDL_EVENT_TEXT_EDITING` 译成 `text_editing`（组合串、光标起点、选区长度）。界面还不画它。候选词列表（`TEXT_EDITING_CANDIDATES`）这次没译。

### (6) `damage_rect` 接上了，但仍然整屏清
字段原来没有任何读取方。现在 `FrameParams.damage_rect` 会写到 Headless 的 `last_damage_rect` 和 SDL 后端的 `last_damage_rect`。`null` 表示整屏。SDL 的 load op 还是 `LOADOP_CLEAR`，没有 scissor。局部重绘留到 PR 2，代码和文档里都标了 `TODO(PR2)`。

### (7) 不链接 SDL 的测试
新增的断言都在纯 Zig 里：UTF-8 截断、文本事件装进定长缓冲、Windows 200% 那种「display scale 不能拿来乘」的像素数学、分数倍缩放下差 1 像素时以 `SizeInPixels` 为准、鼠标按键码、`resize` 把显式像素尺寸传给渲染器、脏区被记下来、重绘合并（原来就有）。SDL 事件翻译调用的是这些函数，所以翻译规则不用开窗口也能锁住。
