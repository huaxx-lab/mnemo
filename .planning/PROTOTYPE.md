# UI Prototype — 刘海工作台 Phase 1

## Variations explored

| Preview name | Organizing idea | Verdict |
|--------------|-----------------|---------|
| Compact Utility | 计时与控制在上，待办单列居中，热力图为紧凑页脚 | 采用为基础方向 |
| Command Strip | 计时器压成工具条，待办占据主体 | 保留紧凑控制思路，但计时辨识度不足 |
| Single Column | 所有内容严格纵向排列 | 小屏稳健，但缺少 macOS 横向效率 |
| Split Ledger | 左计时、右待办的双栏账本 | 放弃；会重现左右空洞和视觉割裂 |
| Focus Timeline | 计时与待办按时间线串联 | 放弃；为不存在的日程功能制造隐喻 |
| Minimal Focus | 只展示计时，待办和记录折叠 | 放弃；隐藏了 P0 待办 |

## Chosen direction & remix

- 基础采用 **Compact Utility**。
- 引入 **Command Strip** 的紧凑分段时长控件，但保留清晰的圆形剩余时间。
- 工作台使用固定 640pt 宽稳定窗口，收纳与效率切换不触发 AppKit frame 动画。
- 效率页顺序为：计时控制、待办输入与列表、专注记录页脚。
- 空待办只占一行；列表最多展示三行后滚动，不为零数据预留大片空白。
- 热力图不再与计时器并列争抢主视觉。

## Edge cases

- 空态：剪贴板为空、Pin 为空、待办为空、无专注记录。
- 增长：5 条剪贴板、横向多 Pin、三行以上待办滚动。
- 长内容：文件名和待办单行截断，并通过 tooltip / 详情查看完整内容。
- 状态：计时中、暂停、索引、同步、拖拽命中、投放成功和失败。

## Tuned moments

- 锚点状态变化：只做内容过渡，不改窗口 frame。
- 工作台打开：`opening → open`，内容在固定窗口内做 0.24s 位移与透明度过渡。
- 工作台关闭：`open → closing → hidden`，固定窗口内反向过渡后 `orderOut`。
- 拖拽：`targeted → receiving → absorbed/failed → idle`，反馈窗和液体桥分别由显式阶段驱动。
- 开启「减弱动态效果」后，上述过渡全部改为直接切换。

## Carry-forward

- `NotchPresentationState` 是唯一窗口/拖拽阶段契约。
- 锚点、拖拽接收、工作台、详情和液体层各自拥有稳定窗口职责。
- 视觉实现必须保留 DEBUG 状态矩阵，发布构建不包含调参面板。
