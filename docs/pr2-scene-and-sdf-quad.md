# PR 2 学习笔记：帧内存池（`FrameArena`）、`DisplayList` 与 GPU SDF 合批

## 1. 这个 PR 解决了什么问题？

在 PR 1 我们只做了“清屏”。要真正把卡片、按钮、圆角、阴影画出来，而且跑得飞快、代码又好测，核心靠三件基础设施（几乎所有现代自绘框架如 GPUI、CUI、nanoui 都长这样）：
1. **怎么每帧分配大量临时 UI 数据又不慢、不泄漏？** -> `FrameArena`
2. **怎么让框架核心代码不写死 Metal/Vulkan，还能无窗口测试？** -> `DisplayList`
3. **怎么不用画几百个小三角形去拼圆角，而是 1 个着色器、1 次 Draw Call 搞定矩形 + 圆角 + 边框 + 阴影？** -> **SDF + Instancing**

---

## 2. 本 PR 的文件导读

- `src/arena.zig`：**帧级线性内存池（`FrameArena`）**
  - 一帧内所有临时对象往后拨指针分配；帧末调用 `reset()`（`retain_capacity`），底层内存不归还系统，下一帧直接复用。
  - ⚠️ **面试重点**：正因为 `FrameArena` 每帧会清零，**点击回调或长寿状态绝对不能保存指向帧内对象的指针**（Rust 编译器用 `'frame` 生命周期直接堵死这个 bug）。
- `src/scene.zig`：**与 GPU 无关的中间层 `DisplayList` & `DamageRegion`**
  - `Quad`：用逻辑像素描述矩形、圆角半径、边框、阴影。
  - `buildBatches`：按 **Painter's Order（先画的在底下，后画的盖上面）** 解析嵌套的 `pushClip / popClip`（矩形交集），把**连续且相同裁剪区**的 `Quad` 合并成一个 `QuadBatch`。
  - `DamageRegion.fromDisplayListDiff`：对比上一帧和当前帧的命令列表，算出变化矩形（包含阴影外扩 `paintBounds`）的并集，即“脏区”。
- `src/shader/quad.metal`：**Metal SDF 着色器**
  - `quad_vs`：只画 6 个顶点（2 个三角形），直接从 Storage Buffer 读 `QuadInstance`，按 `shadow_blur` 自动外扩顶点包围盒，转换成 Metal NDC 坐标。
  - `quad_fs`：用 `sdfRoundedBox(p, half_size, radius)` 算每个像素离圆角边界的距离 `d`：
    - `d < 0`：矩形内部（填充色）；
    - `-border_width <= d <= 0`：边框；
    - `d > 0`：外部柔和衰减投影，或完全透明（角被“切”圆）。
- `src/backend/sdl.zig`：一次 CopyPass 把整帧所有 `QuadInstance` 传进 GPU Storage Buffer，再逐批设置物理 `SDL_SetGPUScissor` 调用 `SDL_DrawGPUPrimitives`。

---

## 3. 两个容易踩坑的工程细节（面试加分项）

### (1) 为什么合并 Draw Call 必须尊重裁剪和顺序？
假如绘制顺序是：`矩形 A（无裁剪） -> 矩形 B（裁剪区 C） -> 矩形 D（无裁剪）`。
- 如果为了省 Draw Call 把 `A` 和 `D` 强行合进同一批先画，那么 `B` 就会压在 `D` 上面，**遮挡关系就错了**！
- 所以 `buildBatches` 只合并**相邻且裁剪区完全一致**的图元（本例产生 3 个 Batch）。

### (2) 为什么桌面交换链上做 `LOADOP_CLEAR` 时不能拿 `damage_rect` 直接做 Scissor？
在 macOS Metal 下，交换链是一个 3 帧环形缓冲（Triple Buffering）。这一帧拿到的 `swapchain_tex` 很可能是 2 帧前的旧纹理，如果直接 `LOADOP_LOAD` 会出现旧帧残影，所以目前采用 `LOADOP_CLEAR` 整帧清屏。
而一旦做了全屏 `LOADOP_CLEAR`，渲染阶段就**绝对不能**再拿仅包含变化按钮的 `damage_rect` 当 Scissor 去跳过静态卡片，否则静态卡片被清掉后不会重画而直接消失！
因此本 PR 的分工是：
- `DamageRegion` 精确算出帧间脏矩形并透传给后端（Headless 测试可断言）；
- `SDL_SetGPUScissor` 严格执行组件自身的 `pushClip / popClip` 裁剪栈；
- 真正的基于脏区的跳过重绘，留待未来接入**离屏持久画布（Offscreen Retained Canvas / Layer Cache）**时配合 `LOADOP_LOAD` 启用（这正是面试时区分“脏区计算 + 裁剪”和“完整 Layer Cache”的关键细节）。
