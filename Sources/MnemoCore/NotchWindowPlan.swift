import Foundation

public struct NotchPanelPresentation: Equatable, Sendable {
    public var isOnScreen: Bool
    public var acceptsMouse: Bool

    public init(isOnScreen: Bool, acceptsMouse: Bool) {
        self.isOnScreen = isOnScreen
        self.acceptsMouse = acceptsMouse
    }
}

public struct NotchWindowPlan: Equatable, Sendable {
    public var anchor: NotchPanelPresentation
    public var dragReceiver: NotchPanelPresentation
    public var workspace: NotchPanelPresentation
    public var detail: NotchPanelPresentation

    public init(
        anchor: NotchPanelPresentation,
        dragReceiver: NotchPanelPresentation,
        workspace: NotchPanelPresentation,
        detail: NotchPanelPresentation
    ) {
        self.anchor = anchor
        self.dragReceiver = dragReceiver
        self.workspace = workspace
        self.detail = detail
    }
}

/// 哪个面板在屏幕上、哪个面板收鼠标，只由这里决定。
///
/// 之前这两件事散在二十多个赋值点里：展开时一处、收起时一处、拖拽武装一处、
/// 解除一处、启动一处。任何一条路径漏掉一个面板，输入就落到黑洞里——典型
/// 症状就是展开再收起之后刘海点不动了，因为某条路径把 anchor 置成了
/// ignoresMouseEvents 而回来的那条路径没有复位。
///
/// 纯函数，可单测。窗口层只负责把结果投影到 NSPanel 上，不允许在别处再写
/// ignoresMouseEvents 或 orderOut。
public enum NotchWindowPolicy {
    public static func plan(
        workspacePhase: NotchPresentationState.WorkspacePhase,
        isDragArmed: Bool,
        showsDetail: Bool
    ) -> NotchWindowPlan {
        let workspaceIsPresented = workspacePhase != .hidden
        // 锚点在 opening 阶段保持显示（用于 SwiftUI 淡出过渡），
        // 只有 open 阶段才彻底离屏；这样展开时刘海不会瞬间消失，
        // 而是与工作台的入场动画重叠，形成"从刘海生长出来"的连续感。
        // 收起时（closing）锚点立即回到屏上，避免 280ms 内点击落空。
        let anchorIsOnScreen = workspacePhase != .open
        // 收起的 280ms 里锚点已经在屏上，鼠标也必须已经归它——否则用户看着
        // 刘海点下去，点击却打在空气上。opening 阶段不归它：工作台正在接管。
        let anchorAcceptsMouse = (workspacePhase == .hidden || workspacePhase == .closing) && !isDragArmed
        return NotchWindowPlan(
            anchor: NotchPanelPresentation(
                isOnScreen: anchorIsOnScreen,
                acceptsMouse: anchorAcceptsMouse
            ),
            // 接收层常驻但默认点击穿透，只在拖拽武装时接管鼠标。
            dragReceiver: NotchPanelPresentation(
                isOnScreen: true,
                acceptsMouse: isDragArmed
            ),
            // 收起时必须离屏：它是覆盖菜单栏那一带的大窗口，留在屏幕上会挡住
            // 别的应用的菜单栏图标。
            workspace: NotchPanelPresentation(
                isOnScreen: workspaceIsPresented,
                acceptsMouse: workspaceIsPresented
            ),
            detail: NotchPanelPresentation(
                isOnScreen: showsDetail,
                acceptsMouse: showsDetail
            )
        )
    }
}
