import CoreGraphics

public struct NotchWindowGeometry: Equatable, Sendable {
    public let screenFrame: CGRect
    public let notchRect: CGRect
    public let dragReceiverSize: CGSize
    public let workspaceSize: CGSize
    public let detailSize: CGSize

    public init(
        screenFrame: CGRect,
        notchRect: CGRect,
        dragReceiverSize: CGSize,
        workspaceSize: CGSize,
        detailSize: CGSize
    ) {
        self.screenFrame = screenFrame
        self.notchRect = notchRect
        self.dragReceiverSize = dragReceiverSize
        self.workspaceSize = workspaceSize
        self.detailSize = detailSize
    }

    // 锚点的 frame 不在这里：它按收起态的实际内容逐帧变化，由
    // NotchAnchorLayoutMetrics 给出，窗口层直接用那一个来源。
    public var dragReceiverFrame: CGRect { topCentered(size: dragReceiverSize) }
    /// 工作台顶边就是屏幕顶边：面板把菜单栏那一条一起盖住，刘海直接嵌在
    /// 面板里。顶边留在刘海下沿的话，上面还剩一条菜单栏，看起来就是两块。
    public var workspaceFrame: CGRect {
        topCentered(size: CGSize(
            width: workspaceSize.width,
            height: workspaceSize.height + notchRect.height
        ))
    }

    /// 内容区在窗口坐标里的上边距：刘海占的那一段只有底色，没有内容。
    public var workspaceContentTopInset: CGFloat { notchRect.height }
    public var detailFrame: CGRect {
        CGRect(
            x: notchRect.midX - detailSize.width / 2,
            y: workspaceFrame.minY - 10 - detailSize.height,
            width: detailSize.width,
            height: detailSize.height
        )
    }

    private func topCentered(size: CGSize, topInset: CGFloat = 0) -> CGRect {
        CGRect(
            x: notchRect.midX - size.width / 2,
            y: screenFrame.maxY - topInset - size.height,
            width: size.width,
            height: size.height
        )
    }
}
