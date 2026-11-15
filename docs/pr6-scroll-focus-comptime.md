# PR 6 — 滚动 / 焦点输入 / comptime DSL 对比

## 解决什么问题
1. **滚动**：列表超出 viewport → `ScrollState.offset_y` + `PushClip` + 子树平移。
2. **焦点**：键盘没有坐标 → `FocusManager.focus(id)`；`text_input`/`key_down` 派给当前焦点。
3. **DSL 对比**：运行期 Chain Builder vs 编译期静态表实例化。

## 设计要点

### Scroll
- 状态在 Entity（跨帧）
- paint：`dl.pushClip(viewport)` → `paintTreeHit(..., y - offset, clip=viewport)`
- Hitbox 带 clip，滚动出视口的条目点不到

### Focus
- `FocusManager` 保存 `{EntityId, handler}`
- 点击输入框 → `focus(...)`
- `AppLoop` 把 `key_down`/`text_input` 交给回调，回调再 `focus.dispatch`

### Chain vs comptime
| | Chain DSL | comptime 表 |
| --- | --- | --- |
| 树何时建 | 每帧运行期 | 形状编译期已知，运行期只实例化 |
| 动态列表 | 自然（for 循环 child） | 静态表难表达变长列表 |
| 调试 | 普通函数调用栈 | 接近宏展开，排错更难 |
| 对标 | GPUI builder | Rust proc-macro / Slint 编译器 |

`src/ui/comptime_dsl.zig` 只做教育向最小示例：静态 `CompNode` 表 → `instantiate` 到 FrameArena。

## Demo 操作
- 滚轮：滚动 Todo 列表
- 点击输入框：获得焦点（边框变蓝，光标 `|`）
- 打字 / Backspace / Enter：编辑并提交
- Escape：退出
