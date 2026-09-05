import Foundation
import CoreGraphics
import Testing
@testable import MnemoCore

@Test("刘海拖拽接收区向下延伸，在系统屏幕边缘动作前接住文件")
func notchDropCaptureExtendsBelowCutout() {
    #expect(NotchInteractionPolicy.dragCaptureDepth >= 140)
    #expect(NotchInteractionPolicy.dragActivationMargin >= 80)
    #expect(NotchInteractionPolicy.dragCaptureDepth > NotchInteractionPolicy.dragActivationMargin)
    #expect(NotchInteractionPolicy.dragCaptureWidth(notchWidth: 180) >= 500)
}

@Test("拖入 URL 区分本地文件与网页链接")
func dropURLsAreRoutedByScheme() {
    let file = URL(fileURLWithPath: "/tmp/example.png")
    let link = URL(string: "https://example.com/article")!
    let routed = NotchInteractionPolicy.route(urls: [file, link])

    #expect(routed.files == [file])
    #expect(routed.links == [link])
}

@Test("工作台显式经历打开与关闭阶段，重复请求不会重复开窗")
func workspacePresentationHasStablePhases() {
    var state = NotchPresentationState()

    #expect(state.workspacePhase == .hidden)
    #expect(!state.isWorkspacePresented)
    let firstOpen = state.requestOpen()
    #expect(firstOpen)
    #expect(state.workspacePhase == .opening)
    #expect(state.isWorkspacePresented)
    let duplicateOpen = state.requestOpen()
    #expect(!duplicateOpen)

    state.completeOpen()
    #expect(state.workspacePhase == .open)
    #expect(state.acceptsWorkspaceInput)
    let firstClose = state.requestClose()
    #expect(firstClose)
    #expect(state.workspacePhase == .closing)
    #expect(!state.acceptsWorkspaceInput)
    let duplicateClose = state.requestClose()
    #expect(!duplicateClose)

    state.completeClose()
    #expect(state.workspacePhase == .hidden)
    #expect(!state.isWorkspacePresented)
}

@Test("拖拽只改变投放反馈，不得打开或关闭完整工作台")
func dragPresentationIsIndependentFromWorkspace() {
    var state = NotchPresentationState()

    state.dragEntered()
    #expect(state.dragPhase == .targeted)
    #expect(state.showsDropFeedback)
    #expect(state.workspacePhase == .hidden)

    state.dragExited()
    #expect(state.dragPhase == .idle)
    #expect(!state.showsDropFeedback)
    #expect(state.workspacePhase == .hidden)

    let opened = state.requestOpen()
    #expect(opened)
    state.completeOpen()
    state.dragEntered()
    #expect(state.workspacePhase == .open)
    #expect(state.dragPhase == .targeted)
}

@Test("投放过程有 receiving 与结果阶段，完成后显式归零")
func dragCompletionHasAnExplicitLifecycle() {
    var state = NotchPresentationState()

    state.dragEntered()
    let beganDrop = state.beginDrop()
    #expect(beganDrop)
    #expect(state.dragPhase == .receiving)
    #expect(state.showsDropFeedback)

    state.completeDrop(succeeded: true)
    #expect(state.dragPhase == .absorbed)
    #expect(!state.showsDropFeedback)

    state.settleDrag()
    #expect(state.dragPhase == .idle)

    state.dragEntered()
    let beganFailedDrop = state.beginDrop()
    #expect(beganFailedDrop)
    state.completeDrop(succeeded: false)
    #expect(state.dragPhase == .failed)
    state.settleDrag()
    #expect(state.dragPhase == .idle)
}

@Test("关闭中再次点击会反向打开，不留下半关闭窗口")
func openingDuringCloseReversesTheTransition() {
    var state = NotchPresentationState()

    let opened = state.requestOpen()
    #expect(opened)
    state.completeOpen()
    let closed = state.requestClose()
    #expect(closed)
    #expect(state.workspacePhase == .closing)

    let reopened = state.requestOpen()
    #expect(reopened)
    #expect(state.workspacePhase == .opening)
    state.completeOpen()
    #expect(state.workspacePhase == .open)
}

@Test("锚点、拖拽、工作台与详情使用稳定且分离的窗口几何")
func notchWindowsHaveStableSeparatedFrames() {
    let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let notch = CGRect(x: 666, y: 950, width: 180, height: 32)
    let layout = NotchWindowGeometry(
        screenFrame: screen,
        notchRect: notch,
        dragReceiverSize: CGSize(width: 520, height: 148),
        workspaceSize: CGSize(width: 640, height: 311),
        detailSize: CGSize(width: 616, height: 272)
    )

    #expect(layout.dragReceiverFrame.maxY == screen.maxY)
    // 工作台顶边就是屏幕顶边，刘海嵌在面板里，上面不再剩一条菜单栏。
    #expect(layout.workspaceFrame.maxY == screen.maxY)
    #expect(layout.workspaceContentTopInset == notch.height)
    #expect(layout.detailFrame.maxY == layout.workspaceFrame.minY - 10)
    #expect(layout.workspaceFrame.midX == notch.midX)
    #expect(layout.workspaceFrame.size == CGSize(width: 640, height: 311 + notch.height))
}

@Test("上一次投放还在结算时拖入第二个，内容不得被静默丢弃")
func dragReentersDuringAbsorbSettling() {
    var state = NotchPresentationState()

    state.dragEntered()
    let firstDrop = state.beginDrop()
    #expect(firstDrop)
    state.completeDrop(succeeded: true)
    #expect(state.dragPhase == .absorbed)

    // 结算窗口（420ms）内第二次拖拽到达：必须重新进入 targeted，
    // 否则 beginDrop 返回 false，DragSupport 直接丢掉这次投放。
    state.dragEntered()
    #expect(state.dragPhase == .targeted)
    let secondDrop = state.beginDrop()
    #expect(secondDrop)

    // 正在接收的那一次不能被打断。
    state.dragEntered()
    #expect(state.dragPhase == .receiving)
}

@Test("面板的可见性与鼠标归属只由一处推导，展开收起来回切不会留下死区")
func windowPlanKeepsAnchorClickableAfterCollapse() {
    let collapsed = NotchWindowPolicy.plan(
        workspacePhase: .hidden, isDragArmed: false, showsDetail: false
    )
    #expect(collapsed.anchor.acceptsMouse)
    #expect(!collapsed.workspace.isOnScreen, "收起时工作台必须离屏，否则挡住菜单栏图标")
    #expect(!collapsed.dragReceiver.acceptsMouse, "没在拖拽时接收层必须点击穿透")

    // 展开：锚点让位给工作台
    let opened = NotchWindowPolicy.plan(
        workspacePhase: .open, isDragArmed: false, showsDetail: false
    )
    #expect(!opened.anchor.isOnScreen, "展开后高层级锚点必须离屏，不能遮住工作台第一排")
    #expect(!opened.anchor.acceptsMouse)
    #expect(opened.workspace.acceptsMouse)

    // 收起动画那 280ms 里锚点必须已经回到屏幕上，否则点刘海打在空气上
    let closing = NotchWindowPolicy.plan(
        workspacePhase: .closing, isDragArmed: false, showsDetail: false
    )
    #expect(closing.anchor.isOnScreen)
    #expect(closing.anchor.acceptsMouse)

    // 再收起：必须回到和第一次完全一样的状态，不能残留死区
    let recollapsed = NotchWindowPolicy.plan(
        workspacePhase: .hidden, isDragArmed: false, showsDetail: false
    )
    #expect(recollapsed == collapsed)

    // 拖拽期间锚点让位，结束后立刻恢复
    let dragging = NotchWindowPolicy.plan(
        workspacePhase: .hidden, isDragArmed: true, showsDetail: false
    )
    #expect(!dragging.anchor.acceptsMouse)
    #expect(dragging.dragReceiver.acceptsMouse)
    let afterDrag = NotchWindowPolicy.plan(
        workspacePhase: .hidden, isDragArmed: false, showsDetail: false
    )
    #expect(afterDrag == collapsed)
}

@Test("推荐行、关闭区与展开唇互不重叠，一次点击只有一个动作")
func anchorActionRegionsNeverOverlap() {
    let metrics = NotchAnchorLayoutMetrics(
        notchSize: CGSize(width: 180, height: 32),
        wingWidth: 44,
        clickLipHeight: 26,
        suggestionRowHeight: 32,
        suggestionListPadding: 10,
        suggestionCount: 2
    )

    // 右翼整格就是"关闭推荐"：它和展开唇、推荐行都不相交，
    // 所以点复制永远不会变成展开，点关闭也不会误触推荐。
    #expect(metrics.trailingWingRegion == CGRect(x: 224, y: 0, width: 44, height: 32))
    #expect(!metrics.trailingWingRegion.intersects(metrics.openRegion))
    for row in metrics.suggestionRowFrames {
        #expect(!row.intersects(metrics.trailingWingRegion))
        #expect(!row.intersects(metrics.openRegion))
    }
    #expect(Set(metrics.suggestionRowFrames.map(\.minY)).count == 2, "两行不能叠在一起")
}

@Test("剪贴板推荐的每一行都在物理刘海与展开唇下方，不会被第一排遮住")
func recommendationRowsDoNotOverlapNotchOrOpenLip() {
    let metrics = NotchAnchorLayoutMetrics(
        notchSize: CGSize(width: 180, height: 32),
        wingWidth: 72,
        clickLipHeight: 26,
        suggestionRowHeight: 32,
        suggestionListPadding: 10,
        suggestionCount: 3
    )

    #expect(metrics.panelSize == CGSize(width: 324, height: 174))
    #expect(metrics.suggestionRowFrames.count == 3)
    #expect(metrics.suggestionRowFrames.first?.minY == metrics.openRegion.maxY + 10)
    #expect(metrics.suggestionRowFrames.allSatisfy { !$0.intersects(metrics.openRegion) })
    #expect(metrics.suggestionRowFrames.last?.maxY == metrics.panelSize.height - 10)
}

@Test("一条推荐也占一整行，且仍在物理刘海与展开唇下方")
func singleRecommendationStillGetsAFullRow() throws {
    let metrics = NotchAnchorLayoutMetrics(
        notchSize: CGSize(width: 180, height: 32),
        wingWidth: 44,
        clickLipHeight: 26,
        suggestionRowHeight: 32,
        suggestionListPadding: 10,
        suggestionCount: 1
    )

    // 两翼只放状态图标和关闭；标题与理由写在下面整宽的一行里，
    // 塞回两翼只剩五十来点，图标和对号都在，唯独看不出推荐的是哪一条。
    #expect(metrics.panelSize == CGSize(width: 268, height: 110))
    #expect(metrics.openRegion == CGRect(x: 44, y: 32, width: 180, height: 26))
    let row = try #require(metrics.suggestionRowFrames.first)
    #expect(row.minY >= metrics.openRegion.maxY)
    #expect(row.width > 200, "一行要有足够宽度显示标题与理由")

    // 没有推荐时不长出任何一行
    let quiet = NotchAnchorLayoutMetrics(
        notchSize: CGSize(width: 180, height: 32),
        wingWidth: 0,
        clickLipHeight: 26,
        suggestionRowHeight: 32,
        suggestionListPadding: 10,
        suggestionCount: 0
    )
    #expect(quiet.suggestionListHeight == 0)
    #expect(quiet.panelSize == CGSize(width: 180, height: 58))
}

@Test("快捷回答加宽正文但刘海两翼与展开唇仍保持居中且互不重叠")
func contextAnswerMetricsKeepTopHitRegionsCentered() {
    let metrics = NotchAnchorLayoutMetrics(
        notchSize: CGSize(width: 180, height: 32),
        wingWidth: 44,
        clickLipHeight: 26,
        suggestionRowHeight: 32,
        suggestionListPadding: 10,
        suggestionCount: 1,
        supplementalContentSize: CGSize(width: 430, height: 188)
    )

    #expect(metrics.panelSize == CGSize(width: 430, height: 298))
    #expect(metrics.openRegion == CGRect(x: 125, y: 32, width: 180, height: 26))
    #expect(metrics.trailingWingRegion == CGRect(x: 305, y: 0, width: 44, height: 32))
    #expect(metrics.supplementalContentFrame == CGRect(x: 0, y: 110, width: 430, height: 188))
    #expect(!metrics.openRegion.intersects(metrics.trailingWingRegion))
    #expect(metrics.suggestionRowFrames.allSatisfy { !$0.intersects(metrics.openRegion) })
}

@Test("Command-G 连续触发没有冷却期，只有最新一次可以发布")
func repeatedSelectionCaptureIsLatestWinsWithoutRateLimit() {
    var coordinator = SelectionCaptureCoordinator()
    let first = coordinator.begin()
    #expect(coordinator.isCurrent(first))

    let second = coordinator.begin()
    #expect(second == first + 1)
    #expect(!coordinator.isCurrent(first))
    #expect(coordinator.isCurrent(second))

    // 连续快速触发也逐次产生 token，没有频率阈值或“第二次拒绝”。
    var previous = second
    for _ in 0..<100 {
        let current = coordinator.begin()
        #expect(current == previous + 1)
        #expect(coordinator.isCurrent(current))
        previous = current
    }
}

@Test("Command-G 区分新写入、自动复制基线与 Mnemo 自写")
func selectionCaptureAcceptsAutoCopiedAppsButRejectsOwnAnswer() {
    #expect(SelectionCaptureObservationPolicy.source(
        hasAccessibilitySelection: true,
        changeCount: 10,
        baseline: 10,
        currentWriteIsMnemoOwned: false,
        baselineWriteWasMnemoOwned: false,
        hasCurrentText: false,
        hasBaselineText: false
    ) == .accessibilitySelection)

    #expect(SelectionCaptureObservationPolicy.source(
        hasAccessibilitySelection: false,
        changeCount: 11,
        baseline: 10,
        currentWriteIsMnemoOwned: false,
        baselineWriteWasMnemoOwned: false,
        hasCurrentText: true,
        hasBaselineText: false
    ) == .newPasteboardWrite)

    #expect(SelectionCaptureObservationPolicy.source(
        hasAccessibilitySelection: false,
        changeCount: 10,
        baseline: 10,
        currentWriteIsMnemoOwned: false,
        baselineWriteWasMnemoOwned: false,
        hasCurrentText: true,
        hasBaselineText: true
    ) == .existingAutoCopiedSelection, "选中时已自动复制的应用不要求 Command-C 再变一次")

    #expect(SelectionCaptureObservationPolicy.source(
        hasAccessibilitySelection: false,
        changeCount: 10,
        baseline: 10,
        currentWriteIsMnemoOwned: true,
        baselineWriteWasMnemoOwned: true,
        hasCurrentText: true,
        hasBaselineText: true
    ) == nil, "Mnemo 上一轮自动写入的回答不能作为自动复制基线")

    #expect(SelectionCaptureObservationPolicy.source(
        hasAccessibilitySelection: false,
        changeCount: 11,
        baseline: 10,
        currentWriteIsMnemoOwned: true,
        baselineWriteWasMnemoOwned: false,
        hasCurrentText: true,
        hasBaselineText: true
    ) == nil, "等待期间到达的上一轮回答不能当新选区")

    #expect(SelectionCaptureObservationPolicy.source(
        hasAccessibilitySelection: false,
        changeCount: 12,
        baseline: 10,
        currentWriteIsMnemoOwned: false,
        baselineWriteWasMnemoOwned: false,
        hasCurrentText: false,
        hasBaselineText: false
    ) == nil)

    #expect(SelectionCaptureObservationPolicy.source(
        hasAccessibilitySelection: false,
        changeCount: 10,
        baseline: 10,
        currentWriteIsMnemoOwned: true,
        baselineWriteWasMnemoOwned: true,
        hasCurrentText: true,
        hasBaselineText: false,
        hasRememberedSelectionForApplication: true
    ) == .rememberedExplicitSelection,
    "回答覆盖剪贴板后，同一应用仍保持的 Command-G 选区不能被说成过期")
}

@Test("预览窗不跟着刘海收：收起工作台之后它仍在屏幕上并且收鼠标")
func detailPanelSurvivesWorkspaceCollapse() {
    #expect(DetailPresentationPolicy.isPresented(hasDetailItem: true, isStashMode: true))
    #expect(!DetailPresentationPolicy.isPresented(hasDetailItem: false, isStashMode: true))
    // 专注模式没有预览这回事。
    #expect(!DetailPresentationPolicy.isPresented(hasDetailItem: true, isStashMode: false))

    // 工作台已经收干净，预览仍然要能看、能点关闭键。
    let collapsed = NotchWindowPolicy.plan(
        workspacePhase: .hidden,
        isDragArmed: false,
        showsDetail: DetailPresentationPolicy.isPresented(hasDetailItem: true, isStashMode: true)
    )
    #expect(!collapsed.workspace.isOnScreen)
    #expect(collapsed.detail.isOnScreen)
    #expect(collapsed.detail.acceptsMouse)
    // 收起后刘海本体必须回来，否则用户没有入口再展开。
    #expect(collapsed.anchor.isOnScreen)
}

@Test("详情是否显示只看条目和模式，不受工作台开合与编辑状态支配")
func detailPresentationIsIndependentOfWorkspaceLifecycle() {
    #expect(DetailPresentationPolicy.isPresented(hasDetailItem: true, isStashMode: true))
    #expect(!DetailPresentationPolicy.isPresented(hasDetailItem: false, isStashMode: true))
    #expect(!DetailPresentationPolicy.isPresented(hasDetailItem: true, isStashMode: false))
}

@Test("多结果推荐的视觉抽屉与 AppKit 点击框使用同一显式宽度")
func suggestionDrawerAndHitFramesShareWidth() throws {
    let metrics = NotchAnchorLayoutMetrics(
        notchSize: CGSize(width: 180, height: 32),
        wingWidth: 44,
        clickLipHeight: 26,
        suggestionRowHeight: 40,
        suggestionListPadding: 10,
        suggestionCount: 3,
        suggestionListWidth: 300
    )
    #expect(metrics.panelSize.width == 300)
    #expect(metrics.suggestionRowFrames.count == 3)
    let row = try #require(metrics.suggestionRowFrames.first)
    #expect(row.minX == 10)
    #expect(row.width == 280, "30pt 复制按钮必须完整落在 280pt 行命中框里")
    #expect(row.maxX == metrics.panelSize.width - 10)
}

@Test("临时剪贴板处理开关只授权切换后的新捕获，不改变既有条目资格")
func temporaryClipboardProcessingIsProspective() {
    // 捕获当时开关决定这一条的授权；开关本身不是日后查询资格的实时输入。

    // 关闭期间捕获的临时项：不处理。
    #expect(!ClipboardContentProcessingPolicy.shouldProcess(
        origin: .clipboard,
        isPinned: false,
        wasAuthorizedAtCapture: false
    ))
    // 开启期间捕获的临时项：后来即使关开关，这份捕获时授权仍然成立。
    #expect(ClipboardContentProcessingPolicy.shouldProcess(
        origin: .clipboard,
        isPinned: false,
        wasAuthorizedAtCapture: true
    ))
    // 固定后永远处理，与捕获时开关无关。
    #expect(ClipboardContentProcessingPolicy.shouldProcess(
        origin: .clipboard,
        isPinned: true,
        wasAuthorizedAtCapture: false
    ))
    // 人工拖入 / 显式收纳永远立即处理。
    #expect(ClipboardContentProcessingPolicy.shouldProcess(
        origin: .manual,
        isPinned: false,
        wasAuthorizedAtCapture: false
    ))
}
