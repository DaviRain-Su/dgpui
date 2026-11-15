# PR 5 — EntityStore + Hitbox + 事件闭环

## 解决什么问题
点击屏幕坐标 `(x, y)` 时：
1. 找到哪个组件被点中（后画的在上）
2. 修改**持久状态**（不能改 FrameArena 里的临时树）
3. 通知订阅者，合并成一次重绘

## 关键设计

### EntityStore（持久世界）
- `EntityId { index, generation }`：generation 防悬垂（slot 复用后旧句柄失效）
- `observe(entity, view_key)` / `notify(entity)`：同一轮多次 notify 合并为一个 dirty view
- 业务状态（Counter）放这里；回调只持有 `EntityId` / 持久 `DemoState*`

### Hitbox（瞬时世界，每帧重建）
- Paint 时 `paintTreeHit` 登记 `(bounds, clip, handler, parent)`
- `dispatchClick` **倒序**遍历（Painter's Order 逆序 = 最上层优先）
- 命中后沿 `parent` **冒泡**；子节点 `return false` 可让父按钮处理
- clip 外的坐标直接拒绝（为滚动/遮罩打基础）

### 为什么回调不能捕获 Element*
`FrameArena` 帧末 `reset`，下一帧指针全部失效。这是 GPUI / 保留态框架最常见的 use-after-free 坑。

## Demo
卡片上的 **Bump Counter** 按钮：
- `.onClick(DemoState.onBump, self)` 登记 Hitbox
- 回调里 `entities.get(counter_id)` → `clicks += 1` → `notify`
- `AppLoop` 在 `mouse_down` 时用上一帧 HitList 命中，成功则 `requestRedraw`

## 面试口径
| 话题 | 一句话 |
| --- | --- |
| Arena vs Entity | 树每帧重建；状态跨帧存活 |
| Hit testing | 倒序 + clip；不是射线检测 |
| Bubbling | 子未处理 → parent handler |
| notify coalescing | dirty set 去重，一批事件一帧 |
