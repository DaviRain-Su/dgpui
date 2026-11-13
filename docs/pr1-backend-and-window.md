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
- 布局和命中测试用**归一化逻辑尺寸**：有 `SizeInPixels` 和 `content_scale` 时，`logical = 像素 / content_scale`。macOS Retina 上窗口坐标已经是点，这个除法约等于窗口坐标；Windows/X11 200% 上窗口坐标是像素，逻辑尺寸大约是窗口坐标的一半。
- 交换链 / GPU 的像素数来自 `SDL_GetWindowSizeInPixels`，不靠乘法回推。
- `scale_factor` 在这条路径上就是 `content_scale`（`SDL_GetWindowDisplayScale`）。`pixel_density`（`SDL_GetWindowPixelDensity`）单独存放。没有像素尺寸时，`scale_factor` 才退回像素密度。
- 鼠标坐标乘 `logical / 窗口坐标`，和上面的逻辑尺寸落在同一个空间。macOS 上这个乘数是 1，Windows 200% 上是 0.5。
- `init` 的宽高是期望的逻辑尺寸。建窗后如果归一化结果对不上（Windows/X11 200% 下 `SDL_CreateWindow(800, 600)` 只有 400×300），就把窗口坐标按比例放大，再 `SDL_SyncWindow`。
- 尺寸和缩放缓存在后端里，只在 resize、像素尺寸变化、display scale 变化、换屏时刷新。鼠标事件不再当场查 SDL。
- 只有没拿到 `SizeInPixels` 时，才回退到 `round(逻辑尺寸 × scale_factor)`。

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

### (3) 逻辑坐标系归一化与权威物理像素
SDL 的 high-DPI 说明把三件事分开了：窗口坐标（`SDL_GetWindowSize`）、可绘制像素（`SDL_GetWindowSizeInPixels`）、内容缩放（`SDL_GetWindowDisplayScale`）。macOS 上窗口坐标本身就是逻辑点（point）；而 Windows / X11 开启 200% 缩放时，窗口坐标与鼠标输入坐标往往已经是物理像素，`content_scale` 为 `2.0`。因此 `metricsFromPlatformSizes` 在同时拿到 `SizeInPixels` 与 `content_scale` 时，统一用 `pixel / content_scale` 推导 `logical_width/height`，并用 `windowPointToLogical` 把鼠标坐标折算进同一逻辑空间；同时 `WindowMetrics.physicalWidth()` 优先直接返回 `SizeInPixels`（不靠乘法回推），避免分数倍缩放误差与双倍缓冲区 bug。

### (4) `resize` 记下像素尺寸，但不自己重建交换链
SDL_GPU 没有 `resize(width, height)`。`SDL_SetGPUSwapchainParameters` 只改 composition 和 present mode。Vulkan 后端在 `SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED` 进入队列时把 `needsSwapchainRecreate` 设上，下一次 `SDL_WaitAndAcquireGPUSwapchainTexture` 才按那个事件里的像素重建。Metal 后端则在 acquire 时读 `CAMetalLayer.drawableSize`。所以 `resize` 不能是一声不吭的空函数：它把 `AppLoop` 传来的像素尺寸写进 `SdlBackend`，acquire 若带回非 0 的纹理尺寸再覆盖一次。交换链本身仍由 SDL 重建。

### (5) 文本按 UTF-8 码点边界完整拆分并接上 IME 预编辑
SDL 的字符串只在这次取事件期间有效，所以要拷进 `Event` 自己的缓冲（`Event` 按值进队列）。单条事件缓冲为 256 字节。`TEXT_INPUT` 超过 256 字节时按码点拆成多条，正常路径不丢后半段。非法或半截 UTF-8 换成一个 U+FFFD 再继续，不把后面的字节整段丢掉。分配失败时，分片队列回滚到调用前，打一条错误日志，只发出第一段不超过 256 字节的前缀，其余放弃——这是唯一会丢内容的路径。预编辑 `text_editing` 仍是单条 256 字节事件。`SDL_StartTextInput` 失败返回 `TextInputStartFailed`。候选词列表这次没译。

### (6) `damage_rect` 接上了，但仍然整屏清
字段原来没有任何读取方。现在 `FrameParams.damage_rect` 会写到 Headless 的 `last_damage_rect` 和 SDL 后端的 `last_damage_rect`。`null` 表示整屏。SDL 的 load op 还是 `LOADOP_CLEAR`，没有 scissor。局部重绘留到 PR 2，代码和文档里都标了 `TODO(PR2)`。

### (7) 不链接 SDL 的测试
新增的断言都在纯 Zig 里：UTF-8 截断与 U+FFFD、文本分片、OOM 回滚和截断前缀、Windows 200% 的逻辑尺寸与建窗坐标、分数倍缩放下以 `SizeInPixels` 为准、鼠标按键码、`resize` 使用归一化后的像素尺寸、脏区被记下来、重绘合并（原来就有）。SDL 事件翻译调用的是这些函数，所以翻译规则不用开窗口也能锁住。

---

## 5. 坐标归一化之后又改了什么

`08a18d2` 把逻辑尺寸改成 `像素 / content_scale`，`scale_factor` 跟着变成内容缩放。这次只补它带出来的缝，不改这个公式。

1. **注释和测试跟上新语义。** `sdl.zig` 里还写着 `scale_factor` 是像素密度；demo 日志的 `density=` 打的也是 `scale_factor`。都改成 scale / content_scale / pixel_density 分开印。`app.zig` 里那条「逻辑 3840、scale_factor 1、content_scale 2」的 resize 事件，新函数不会再造出来，测试改成建窗放大之后的真实组合：逻辑 800×600、scale_factor 2、像素 1600×1200。
2. **请求的逻辑尺寸和窗口坐标对齐。** Windows/X11 200% 下 `SDL_CreateWindow(800, 600)` 的窗口坐标就是 800×600 像素，归一化后只剩 400×300。创建后用 `windowSizeForRequestedLogical` 把窗口坐标调成 1600×1200，逻辑尺寸回到 800×600。macOS 上窗口坐标已经等于逻辑尺寸，乘数是 1，不会被放大。公式有单测，不依赖真窗口。
3. **鼠标不再每次查 5 次 SDL。** 指标和窗口坐标缓存在 `SdlBackend` 里，`metrics()` 和鼠标换算都读缓存。`RESIZED`、`PIXEL_SIZE_CHANGED`、`DISPLAY_SCALE_CHANGED`、`DISPLAY_CHANGED` 才刷新。这样同一批事件里，还没轮到缩放事件的鼠标，用的还是上一份指标，和 `AppLoop` 读到的是同一份。
4. **文本行为和文档一致。** 非法 UTF-8 换成 U+FFFD 后继续拷，不再从坏字节起把后面全丢。内存不够时，分片函数自己 `errdefer` 回滚；SDL 侧不再 shrink 第二次。回滚之后打错误日志，只发出第一段 256 字节前缀，笔记里写明这是会丢内容的。
5. **OOM 测试不再赌 ArrayList 先 remap 再 alloc。** 先用测试分配器精确留 1 个槽，再用 `FailingAllocator` 把下一次 alloc 和 resize/remap 都设成立刻失败。`queueTextInputChunks` 覆盖 SDL 那条「失败就退回前缀」的路径，并确认队列里原有的事件还在。超长样例的长度注释从 290 改成实际的 308。
