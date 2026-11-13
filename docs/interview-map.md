# 面试概念对照表：从 `dgpui` (Zig) 映射到 Rust GUI 框架岗位

这份文档帮你把在 `dgpui` 里亲手写的每一段 Zig 代码，直接对应到 Rust GUI 核心岗位面试时的高频术语与设计取舍。

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

在 `dgpui` 里你会亲手写出两个分配器，面试官问 Rust 所有权时可以直接画出来：

1. **为什么会有 `'frame` 生命周期 / 为什么回调不能指向帧 Arena？**
   - 在 `dgpui` 中，`Div` / `Text` 节点和布局节点全分配在 `FrameArena`，每一帧结束执行 `reset()`。
   - 对应的 Rust 视角：Element 树借用了帧作用域 `&'frame FrameArena`，而点击回调必须放进跨帧存活的堆或槽位池里（要求 `'static` 或只捕获 `Entity<T>` / `WeakEntity<T>` 句柄）。
   - 如果回调强行持有 `&'frame Element`，Rust Borrow Checker 会直接报错拒绝编译；在 Zig 里一旦持有悬垂指针就是 UB。
2. **为什么用 `EntityId`（index + generation）而不是到处 `Rc<RefCell<T>>`？**
   - GUI 事件经常发生“A 的回调修改了 B，同时 B 正在遍历或又通知了 A”（重入借用冲突）。
   - 用句柄 + 中央 `EntityStore`（类似 SlotMap / generational arena），可以通过 `cx.update_entity(id, |state, cx| ...)` 集中控制可重入借用，避免 `RefCell` 运行时 panic。
3. **FFI 与 `unsafe` 边界（HarfBuzz / FreeType2 / SDL3 / Yoga）**
   - 底层 C 库需要手工管理生命周期、字节切片对齐和编码格式（UTF-8 到 glyph index），在 Rust 中应当把 `unsafe` 封装在极薄的安全 wrapper 模块内部（如 `FontSystem`、`PlatformBackend`），对外只暴露安全句柄和值类型。

---

## 3. 渲染管线与多后端生态分工

面试常问：**`wgpu`、`Vello`、`Skia`、`FemtoVG` 分别干什么？为什么不止用其中一个？**

- **`wgpu`（以及 `dgpui` 里的 `SDL_GPU`）**：**底层 GPU 硬件抽象层**（类似 Vulkan/Metal/DX12 的统一安全接口）。它只管 Buffer、Texture、Pipeline、Shader 和 Draw Call，**它自己不懂什么是圆角矩形或贝塞尔曲线**。
- **`dgpui` 自写 SDF 着色器 + `GlyphAtlas`**：相当于用最精简的代码直接跑在 `wgpu` / `SDL_GPU` 上，专门解决“大量 UI 盒子 + 文本”的高性能绘制，**缺点是不擅长任意复杂矢量路径（如 SVG 复杂钢笔曲线）**。
- **`Skia`**：老牌全能 2D 图形库（CPU 光栅化 + GPU 后端），Flutter/Chrome 都在用，功能极全但体积庞大、C++ FFI 较重。
- **`FemtoVG`**：轻量级 OpenGL / wgpu 矢量绘图库（类似 HTML Canvas 2D API），把路径三角化后画在 GPU 上。
- **`Vello`**：纯 Rust 现代 GPU-first 2D 矢量渲染引擎，**核心利用 GPU Compute Shader（计算着色器）做并行路径光栅化**，跑在 `wgpu` 之上。

### 局部重绘（Damage Region）与裁剪（Scissor）
- `dgpui` 的策略：**脏视图触发重建 DisplayList -> 计算变化的 Damage Bounds（脏矩形并集）-> 渲染后端根据 Damage Region + Scissor Rect 控制重绘边界**。
- 注意表述边界：除非专门实现了离屏纹理缓存（Offscreen Layer Cache / RenderTarget Cache），否则不要把“脏矩形计算 + Scissor 裁剪”夸大成“完整的多层离屏图层缓存”。

### 桌面窗口后端 vs 嵌入式 DRM/KMS
- **桌面端（`winit` / `SDL3` / `GLFW` / 原生 AppKit `CAMetalLayer`）**：操作系统已有窗口管理器（Compositor），框架只需要向系统申请一个 Surface（矩形画布），接收系统转发的键盘鼠标事件。
- **嵌入式 Linux（`DRM/KMS` + `libinput`）**：没有 X11/Wayland 窗口管理器，程序直接通过内核 DRM 接口申请显卡帧缓冲（Framebuffer/GBM），画完后直接提交给显示控制器做 **Scanout（扫描输出）**，输入事件直接从 `/dev/input`（`libinput`）读。
- 在 `dgpui` 中，只要把 `PlatformBackend` 和 `RendererBackend` 两个抽象接口抽干净，**换后端无需改动上层 1 行布局/状态/DSL 代码**——这正是 Slint 多后端架构的核心思想。

---

## 4. 声明式 DSL 与 Rust 过程宏（`proc-macro`）的取舍

- **链式 Builder（GPUI / `dgpui`）**：无需编译器扩展，IDE 自动补全极好，动态条件渲染直接写普通 `if / for`，但嵌套深时样板代码略多。
- **Rust `proc-macro`（属性宏 / 函数式宏如 `rsx!` / `view!`）**：在编译期把类 HTML/XML 标记的 `TokenStream` 展开成 Builder 调用或直接展开成更新代码，开发体验接近前端，但报错信息定位和编译耗时是成本。
- **外部独立编译器（如 Slint 的 `.slint` -> Rust/C++）**：脱离宿主语言语法限制，可以在编译期做跨语言代码生成与**静态属性依赖图优化**，实现极小运行期开销，代价是必须维护一整套独立词法/语法分析器与 IDE 插件（LSP）。
