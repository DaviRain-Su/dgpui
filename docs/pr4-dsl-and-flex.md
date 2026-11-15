# PR 4 学习笔记：链式 DSL 与手写 Flex

## 1. 解决什么问题？

开发者不想手写 `x=16,y=48,w=368`。他们想写：

```zig
div().flexCol().p(16).gap(8).child(text("标题"))
```

框架必须自动算出每个盒子的矩形。最难的一点是：**高度往往取决于宽度**——窗口变窄时文字折行变高，下面的按钮必须下移。

---

## 2. 文件导读

- `src/layout/flex.zig`：精简 Flex（row/column、gap、padding、grow/shrink、justify、align、`measure` 回调）。
- `src/ui/element.zig`：GPUI 风格链式 Builder；节点分配在 `FrameArena`。
- `src/text/layout.zig`：新增 `measureText` / `prepareWrapped`，供 Flex 折行量高与绘制复用。
- `src/main.zig`：Demo 改为 DSL 描述卡片；拖窄窗口可看到折行撑高。

---

## 3. 面试口径

1. **AvailableSpace**：容器把 `definite / max_content` 往下传；文字叶子用 `measure(max_width)` 返回折行后尺寸。
2. **grow/shrink**：主轴剩余空间按 `flex_grow` 分；不够则按 `flex_shrink * main_size` 加权压缩。
3. **为什么节点在 FrameArena**：每帧重建轻量树，帧末 reset；持久状态（点击数）仍在 DemoState / 未来 EntityStore。
4. **Chain DSL vs comptime/proc-macro**：链式 Builder 直观、易调试；编译期宏可做更强静态检查与依赖分析，但复杂度更高（PR 6 对比）。
