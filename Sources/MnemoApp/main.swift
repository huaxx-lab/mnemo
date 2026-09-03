import AppKit
import Carbon.HIToolbox
import Network
import Observation
import MnemoCore
import SwiftUI

private enum MnemoMenuBarIcon {
    private static let side: CGFloat = 18
    /// 菜单栏字形留 1.5pt 边距，其余全给记号——18pt 里画满才看得清缺口。
    private static let glyphHeight: CGFloat = 15

    /// 和应用图标同一套 `MnemoMark` 几何：开口朝上的磁石 + 被吸住的圆点。
    /// 模板图只有黑白，所以三套配色共用这一个字形，颜色差异只体现在 Dock 图标上。
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            let bounds = MnemoMark.contentBounds
            let scale = glyphHeight / bounds.height

            context.saveGState()
            // 把记号的外接框中心对到画布中心，再按同一比例缩放。
            context.translateBy(x: side / 2, y: side / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -bounds.midX, y: -bounds.midY)

            NSColor.black.setFill()
            NSColor.black.setStroke()
            // 平口收尾，和应用图标的磁极端面一致。
            context.setLineCap(.butt)
            context.setLineJoin(.round)
            context.setLineWidth(MnemoMark.armThickness)
            context.addPath(MnemoMark.bodyPath())
            context.strokePath()
            context.addPath(MnemoMark.itemPath())
            context.fillPath()
            context.restoreGState()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Mnemo"
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let instanceGuard: SingleInstanceGuard
    private let model = AppModel()
    private let providerSettings = ProviderSettingsModel()
    private var anchorPanel: NotchAnchorPanel!
    private var dragReceiverPanel: NotchDragReceiverPanel!
    private var workspacePanel: NotchWorkspacePanel!
    private var detailPanel: NotchDetailPanel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    /// 走没走过引导。已经能用 AI 的机器（重装 / 升级）会被静默标成已完成。
    private static let onboardingCompletedKey = "Pinland.onboardingCompleted"
    private var focusTicker: Timer?
    private var clipboardTicker: Timer?
    /// Command-G 选区抓取不是频率限制：每次按键取消上一轮抓取并启动新 token，
    /// latest-wins，避免两次异步 Cmd-C 回写互相串台。
    private var recommendationCaptureTask: Task<Void, Never>?
    private var recommendationCaptureCoordinator = SelectionCaptureCoordinator()
    /// 同一前台应用上一次由 Command-G 真正确认过的选区。回答自动写回剪贴板后，
    /// 该应用的选区仍然有效；这份记忆让两者不冲突，不设时间过期。
    private var explicitSelectionByApplication: [String: String] = [:]
    private var explicitSelectionApplicationOrder: [String] = []
    private var referenceHealthTicker: Timer?
    private var reminderTicker: Timer?
    private let reminderCenter = TodoReminderCenter()
    private let shortcutSettings = ShortcutSettingsModel()
    private var screenUpdateTask: Task<Void, Never>?
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localDragMonitor: Any?
    private var globalDragMonitor: Any?
    private var localDragEndMonitor: Any?
    private var globalDragEndMonitor: Any?
    private var dragArmingTicker: Timer?
    private var dragDisarmTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var workspaceTransitionTask: Task<Void, Never>?
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.pinland.network-state", qos: .utility)
    private var lastNetworkStatus: NWPath.Status?
    private var lastPasteboardChangeCount = NSPasteboard.general.changeCount
    private var screenFrame = CGRect.zero
    private var notchRect = CGRect.zero

    init(instanceGuard: SingleInstanceGuard) {
        self.instanceGuard = instanceGuard
        super.init()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        guard configureGeometry() else {
            NSApp.terminate(nil)
            return
        }

        model.openSettingsAction = { [weak self] in self?.showSettings() }
        observeUpdatePresentation()
        // 启动后等几秒再查：别和首屏渲染、索引恢复抢启动带宽。
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.updateCoordinatorLaunchCheck()
        }
        model.aiEnrichmentAction = { [weak self] item in
            guard let self, self.model.isFeatureUnlocked(.ai) else { return nil }
            return await self.providerSettings.enrich(item)
        }
        // 命名/分类的内容来源：图片 OCR、视觉标签、PDF 页块按序拼给模型。
        providerSettings.enrichmentContentProvider = { [weak self] item in
            guard let self else { return nil }
            let chunks = (try? await self.model.library.chunks(for: item.id)) ?? []
            let texts = chunks
                .filter { $0.source != .inlineText }
                .sorted { $0.ordinal < $1.ordinal }
                .map(\.text)
            let joined = texts.joined(separator: "\n")
            return joined.isEmpty ? nil : String(joined.prefix(6_000))
        }
        model.sceneRecommendationRouteFingerprintAction = { [weak self] in
            self?.providerSettings.sceneRecommendationRouteFingerprint
        }
        model.contextRouteFingerprintAction = { [weak self] in
            self?.providerSettings.clipboardContextRouteFingerprint
        }
        model.aiTransformAction = { [weak self] item, action in
            guard let self, self.model.isFeatureUnlocked(.ai) else { return nil }
            return await self.providerSettings.transform(item, action: action)
        }
        model.contentIndexAction = { [weak self] item in
            guard let self, self.model.isFeatureUnlocked(.ai) else {
                return IndexingRunResult(completed: false, dimensionChanged: false)
            }
            return await SemanticIndexCoordinator.index(
                item: item,
                library: self.model.library,
                settings: self.providerSettings
            )
        }
        model.clipboardContextAction = { [weak self] event, items, sourceItemID, isExplicit in
            guard let self else { return AppModel.ContextResolution() }
            return await ClipboardContextCoordinator.resolve(
                event: event,
                items: items,
                sourceItemID: sourceItemID,
                library: self.model.library,
                settings: self.providerSettings,
                isExplicitTrigger: isExplicit
            )
        }

        model.queryClassifierAction = { [weak self] text in
            guard let self, self.model.isFeatureUnlocked(.ai) else { return false }
            return await self.providerSettings.isRetrievalQuery(text)
        }

        model.contextAnswerAction = { [weak self] question, itemIDs, items in
            guard let self, self.model.isFeatureUnlocked(.ai) else { return nil }
            return await SemanticIndexCoordinator.answerRecommendation(
                question: question,
                itemIDs: itemIDs,
                items: items,
                library: self.model.library,
                settings: self.providerSettings
            )
        }

        model.contextAnswerStreamAction = { [weak self] question, itemIDs, items in
            guard let self, self.model.isFeatureUnlocked(.ai) else {
                return AsyncThrowingStream { $0.finish() }
            }
            return SemanticIndexCoordinator.streamAnswerRecommendation(
                question: question,
                itemIDs: itemIDs,
                items: items,
                library: self.model.library,
                settings: self.providerSettings
            )
        }

        model.prefersAnswerInFocusedInputAction = { [weak self] in
            self?.providerSettings.streamsAnswerIntoFocusedInput ?? true
        }

        model.searchAnswerStreamAction = { [weak self] query, candidates, recency in
            guard let self, self.model.isFeatureUnlocked(.ai) else {
                // 空流会静默结束：没文字、没报错、界面上什么都不显示。
                return AsyncThrowingStream { $0.finish(throwing: AIExecutionError.routeNotConfigured(.retrievalRecommendation)) }
            }
            return self.providerSettings.streamSearchAnswer(
                query: query,
                candidates: candidates,
                recency: recency
            )
        }

        model.semanticSearchAction = { [weak self] query, items, allowsNetwork in
            guard let self, self.model.isFeatureUnlocked(.ai) else {
                let understood = QueryUnderstanding.localParse(query)
                return SemanticSearchRun(hits: [], understoodQuery: understood)
            }
            return await SemanticIndexCoordinator.search(
                query: query,
                items: items,
                library: self.model.library,
                settings: self.providerSettings,
                allowsNetwork: allowsNetwork
            )
        }
        model.pdfQuestionAction = { [weak self] item, question in
            guard let self, self.model.isFeatureUnlocked(.ai) else { return nil }
            return await SemanticIndexCoordinator.answerPDF(
                item: item,
                question: question,
                library: self.model.library,
                settings: self.providerSettings
            )
        }
        providerSettings.resumeIndexingAction = { [weak self] in
            self?.model.resumeIndexing()
        }
        model.aiRoutingFingerprintAction = { [weak providerSettings] in
            // 只有"命名 / 分类"这两条路由影响自动整理该不该重跑。
            // 把整份设置拿来做指纹的话，改个图标都会让全库重新过一遍模型。
            guard let providerSettings else { return "" }
            return [AIFeature.automaticNaming, .automaticClassification]
                .map { feature -> String in
                    guard let route = providerSettings.routing.route(for: feature) else {
                        return "\(feature.rawValue)=off"
                    }
                    return "\(feature.rawValue)=\(route.providerID)/\(route.modelID)"
                }
                .joined(separator: "|")
        }
        providerSettings.resumeAIEnrichmentAction = { [weak self] in
            self?.model.resumeAIEnrichment()
        }
        model.todoRevisionAction = { [weak providerSettings] text, candidates in
            guard let providerSettings else { return .unavailable }
            return await providerSettings.reviseTodos(text: text, candidates: candidates)
        }
        providerSettings.iconChangeAction = { [weak self] _ in
            // 菜单栏是模板图，三套配色共用同一字形；换色只影响 Dock 图标。
            self?.updateStatusItemIcon()
        }

        let environment = ProcessInfo.processInfo.environment

        configureNotchPanels()
        installMainMenu()
        installStatusItem()
        installHotKeys()
        installOutsideClickHandling()
        installDragReceiverArming()
        observeLayout()
        startClipboardMonitor()
        startReferenceHealthMonitor()
        startReminderMonitor()
        observeFocusClock()
        observeScreenChanges()
        startNetworkRecoveryMonitor()
        presentOnboardingIfNeeded()

        if environment["MNEMO_DEBUG_MODE"] == "focus" { model.setMode(.focus) }
        if environment["MNEMO_DEBUG_MODE"] == "stash" { model.setMode(.stash) }
        if environment["MNEMO_DEBUG_EXPANDED"] == "1" { model.expand() }

        Task {
            await model.startupMaintenance()
            // 待办读进来之后才排得出通知；启动这一次不能等用户去改设置。
            model.rescheduleReminders()
            if environment["MNEMO_DEBUG_CLEAN_SEED"] == "1" {
                await cleanupPreviewContent()
            }
            if environment["MNEMO_DEBUG_SEED"] == "1" {
                if model.items.isEmpty { await seedPreviewContent() }
                await seedFocusPreviewContent()
            }
            if environment["MNEMO_DEBUG_DETAIL"] == "1", let item = model.items.first {
                model.preview(item)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        focusTicker?.invalidate()
        clipboardTicker?.invalidate()
        recommendationCaptureTask?.cancel()
        referenceHealthTicker?.invalidate()
        reminderTicker?.invalidate()
        dragArmingTicker?.invalidate()
        dragDisarmTask?.cancel()
        screenUpdateTask?.cancel()
        workspaceTransitionTask?.cancel()
        networkMonitor.cancel()
        HotKeyCenter.shared.unregisterAll()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localDragMonitor { NSEvent.removeMonitor(localDragMonitor) }
        if let globalDragMonitor { NSEvent.removeMonitor(globalDragMonitor) }
        if let localDragEndMonitor { NSEvent.removeMonitor(localDragEndMonitor) }
        if let globalDragEndMonitor { NSEvent.removeMonitor(globalDragEndMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    // MARK: - Geometry and presentation

    @discardableResult
    private func configureGeometry() -> Bool {
        guard let screen = NotchGeometry.preferredScreen else { return false }
        screenFrame = screen.frame
        notchRect = NotchGeometry.notchRect(on: screen)
        NotchLayout.notchWidth = max(notchRect.width, 180)
        NotchLayout.notchHeight = max(notchRect.height, 30)
        // 640 在刘海下面偏宽，但收到 560 又显局促：600 正好让三张 176pt 的卡片
        // 铺满一行，右边不再空一大片。
        NotchLayout.panelWidth = min(600, max(500, screen.visibleFrame.width - 32))
        return true
    }

    private var windowGeometry: NotchWindowGeometry {
        NotchWindowGeometry(
            screenFrame: screenFrame,
            notchRect: notchRect,
            dragReceiverSize: CGSize(
                width: NotchLayout.dragCaptureWidth,
                height: NotchLayout.dragCaptureHeight
            ),
            workspaceSize: CGSize(width: NotchLayout.panelWidth, height: NotchLayout.workspaceHeight),
            detailSize: detailPanelSize
        )
    }

    /// 锚点窗口的大小必须**等于**它当前真正要占的那块，不能"开大了再用
    /// hitTest 过滤"。
    ///
    /// 窗口只要覆盖在那儿就会吃掉点击——hitTest 返回 nil 只是"没有视图处理"，
    /// 并不会把事件透给下层应用，只有 ignoresMouseEvents 才会。所以面板一涨到
    /// 452×138，整片菜单栏的图标就全点不动了。
    private var showsContextAnswer: Bool {
        model.contextAnswer != nil || model.contextAnswerError != nil
    }

    private func anchorMetrics() -> NotchAnchorLayoutMetrics {
        NotchLayout.anchorMetrics(
            for: model.barState,
            suggestionCount: model.contextSuggestions.count,
            supplement: model.notchSupplement,
            supplementActionCount: model.notchSupplementActionCount
        )
    }

    private func anchorFrame() -> CGRect {
        let size = anchorMetrics().panelSize
        return CGRect(
            x: notchRect.midX - size.width / 2,
            y: screenFrame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }
    private func dragReceiverFrame() -> CGRect { windowGeometry.dragReceiverFrame }
    private func workspaceFrame() -> CGRect { windowGeometry.workspaceFrame }

    private func configureNotchPanels() {
        anchorPanel = NotchAnchorPanel(contentRect: anchorFrame())
        let anchorHost = NotchAnchorHostingView(
            rootView: NotchAnchorRootView(model: model),
            openAction: { [weak self] in
                guard let self, self.model.expandTrigger.allowsClick else { return }
                self.model.expand()
            }
        )
        // NSHostingView 默认会把自己的理想尺寸反推给宿主窗口。锚点的窗口大小
        // 必须由我们按状态算，不能被 SwiftUI 内容撑大——撑大一圈就等于多吃
        // 一圈菜单栏的点击。
        anchorHost.sizingOptions = []
        // 透明窗口里**完全透明的区域收不到点击**。展开唇一旦不画底色就点不动，
        // 而画成黑色又会在刘海下面多出一条舌头。早先的折中是给整块锚点铺一层
        // 2% 的黑——代价是推荐卡之间的空隙也会吃掉落在后面应用上的点击（点别的
        // 页面"误触"就是这么来的）。现在 2% 黑由 SwiftUI 只画在状态带 + 展开唇
        // 那一块（NotchRootView.CollapsedBar），其余像素保持完全透明，窗口服务器
        // 会直接跳过它们，点击真正落到下层应用。
        anchorPanel.acceptsMouseMovedEvents = true
        // 物理刘海本身点不到；只让它正下方的接触唇打开工作台。推荐行位于
        // 接触唇下面，拥有自己的 SwiftUI 按钮，不再和展开动作重叠。
        anchorHost.openRegion = { [weak self] in
            guard let self else { return .zero }
            return self.anchorMetrics().openRegion
        }
        // 推荐行与"关闭推荐"的命中同样由 AppKit 负责：锚点面板永远不是 key
        // window，别的应用在前台时 SwiftUI Button 收不到那一下点击。
        anchorHost.actionRegions = { [weak self] in
            guard let self else { return [] }
            let metrics = self.anchorMetrics()
            typealias HitRegion = NotchAnchorHostingView<NotchAnchorRootView>.HitRegion
            let actionFrames = metrics.supplementalActionFrames

            // 待办候选卡与提醒卡的对号 / 叉 / 时钟。顺序和 SwiftUI 卡片里
            // 那一排小圆按钮完全一致，两边读的是同一份 metrics。
            switch self.model.barState {
            case .todoDraft:
                guard let prompt = self.model.todoPrompt else { return [] }
                switch prompt {
                case .asking:
                    guard actionFrames.count == 2 else { return [] }
                    return [
                        HitRegion(rect: actionFrames[0]) { [weak self] in
                            self?.model.confirmTodoPrompt()
                        },
                        HitRegion(rect: actionFrames[1]) { [weak self] in
                            self?.model.rejectTodoPrompt()
                        },
                    ]
                case .created:
                    guard let only = actionFrames.first else { return [] }
                    return [HitRegion(rect: only) { [weak self] in self?.model.rejectTodoPrompt() }]
                }
            case .reminding:
                guard actionFrames.count == 2 else { return [] }
                return [
                    HitRegion(rect: actionFrames[0]) { [weak self] in
                        self?.model.completeActiveReminder()
                    },
                    HitRegion(rect: actionFrames[1]) { [weak self] in
                        self?.model.snoozeActiveReminder()
                    },
                ]
            case .suggesting:
                break
            case .idle, .syncing, .indexing, .paused, .timing, .dropTargeted:
                return []
            }

            let suggestions = self.model.contextSuggestions
            var regions = zip(metrics.suggestionRowFrames, suggestions).map { frame, suggestion in
                HitRegion(rect: frame) { [weak self] in
                    self?.model.acceptContextSuggestion(suggestion)
                }
            }
            // 回答卡没有叉号，点击面板外自动收起；只有文件 / 值候选才保留
            // 右翼关闭区。这样回答态顶部不会出现一个没有必要的关闭按钮。
            if !self.showsContextAnswer {
                regions.append(
                    .init(rect: metrics.trailingWingRegion) { [weak self] in
                        self?.model.dismissContextSuggestion()
                    }
                )
            }
            return regions
        }
        anchorHost.visibleSize = { [weak self] in
            guard let self else { return .zero }
            return self.anchorMetrics().panelSize
        }
        anchorHost.hoverExpandRegion = { [weak self] in
            guard let self else { return .zero }
            let metrics = self.anchorMetrics()
            // 状态带 + 展开唇，和点击唇那一带完全重合：指针悬停或点下去，同一语义。
            let statusWidth = metrics.notchSize.width + metrics.wingWidth * 2
            return CGRect(
                x: (metrics.panelSize.width - statusWidth) / 2,
                y: 0,
                width: statusWidth,
                height: metrics.notchSize.height + metrics.clickLipHeight
            )
        }
        anchorHost.canHoverExpand = { [weak self] in
            guard let self, self.model.expandTrigger.allowsHover else { return false }
            // 工作台开着、正在拖拽时一律不许悬停展开——那时展开是帮倒忙。
            return self.model.workspacePhase == .hidden && !self.isDragArmed
        }
        anchorHost.onHoverExpand = { [weak self] in self?.model.expand() }
        anchorHost.visibleRegions = { [weak self] in
            guard let self else { return [] }
            let metrics = self.anchorMetrics()
            let statusWidth = metrics.notchSize.width + metrics.wingWidth * 2
            let statusX = (metrics.panelSize.width - statusWidth) / 2
            var regions = [
                CGRect(x: statusX, y: 0, width: statusWidth, height: metrics.notchSize.height),
                metrics.openRegion,
            ]
            // 推荐行与回答正文位于菜单栏以下，可以安全占用完整正文宽度；顶部
            // 仍只命中状态带，不让透明窗口角挡住别的应用菜单。
            regions.append(contentsOf: metrics.suggestionRowFrames)
            if let supplemental = metrics.supplementalContentFrame {
                regions.append(supplemental)
            }
            return regions
        }
        anchorPanel.contentView = anchorHost

        dragReceiverPanel = NotchDragReceiverPanel(contentRect: dragReceiverFrame())
        dragReceiverPanel.contentView = NotchDragReceiverView(model: model)


        workspacePanel = NotchWorkspacePanel(contentRect: workspaceFrame())
        workspacePanel.onCancel = { [weak self] in self?.model.requestClose() }
        workspacePanel.contentView = NSHostingView(rootView: NotchWorkspaceRootView(model: model))

        configureDetailPanel()

        // 启动时也走同一条投影：否则 .hidden 不算"变化"，观察回调不会触发，
        // 640×343 的工作台窗口就一直挂在屏幕顶部挡住菜单栏图标。
        applyWindowPlan()
    }

    private func positionStablePanels() {
        anchorPanel.setFrame(anchorFrame(), display: true)
        dragReceiverPanel.setFrame(dragReceiverFrame(), display: true)
        workspacePanel.setFrame(workspaceFrame(), display: true)
        detailPanel.setFrame(detailFrame(), display: true)
    }

    private func detailFrame() -> CGRect {
        // 用户摆过就按他摆的来；没摆过（或换了屏幕）才锚回刘海正下方。
        DetailPanelFrame.load() ?? windowGeometry.detailFrame
    }

    /// 详情窗尺寸：用户拉过就用他拉的，没拉过用默认值。两者都钳进屏幕。
    private var detailPanelSize: CGSize {
        let fallback = CGSize(
            width: NotchLayout.panelWidth - 24,
            height: NotchLayout.detailHeight
        )
        let saved = UserDefaults.standard.dictionary(forKey: NotchDetailPanel.sizeDefaultsKey)
        let width = (saved?["w"] as? NSNumber)?.doubleValue ?? fallback.width
        let height = (saved?["h"] as? NSNumber)?.doubleValue ?? fallback.height
        let limit = screenFrame.isEmpty ? CGSize(width: 1_200, height: 800) : CGSize(
            width: screenFrame.width - 40,
            height: screenFrame.height - notchRect.height - 60
        )
        return CGSize(
            width: min(max(width, NotchDetailPanel.minimumSize.width), limit.width),
            height: min(max(height, NotchDetailPanel.minimumSize.height), limit.height)
        )
    }

    private func configureDetailPanel() {
        detailPanel = NotchDetailPanel(contentRect: detailFrame())
        detailPanel.onCancel = { [weak self] in self?.model.requestDismissDetail() }
        detailPanel.contentView = NSHostingView(rootView: DetachedDetailWindow(model: model))
    }

    /// 上一次投影出去的结论，用来判断这次要不要真的动窗口。
    private var appliedPlan: NotchWindowPlan?

    private var showsDetailPanel: Bool {
        DetailPresentationPolicy.isPresented(
            hasDetailItem: model.detailItem != nil,
            isStashMode: model.mode == .stash
        )
    }

    /// 面板的可见性与是否收鼠标只在这里写。别处一律不许再碰
    /// `ignoresMouseEvents` / `orderOut` / `orderFrontRegardless`。
    private func applyWindowPlan() {
        let plan = NotchWindowPolicy.plan(
            workspacePhase: model.workspacePhase,
            isDragArmed: isDragArmed,
            showsDetail: showsDetailPanel
        )
        // 锚点每一拍都跟着状态重算：刘海按内容长宽长高，窗口必须同步，
        // 多出来的部分会吃掉菜单栏的点击。
        let anchorTarget = anchorFrame()
        if anchorPanel.frame != anchorTarget { anchorPanel.setFrame(anchorTarget, display: true) }
        if plan.workspace.isOnScreen { workspacePanel.setFrame(workspaceFrame(), display: true) }
        // 只在详情**刚显示出来**的那一拍摆位。每次投影都 setFrame 的话，
        // 任何无关状态变化（推荐到达、计时跳秒）都会把用户拖走的窗口拽回原处，
        // 表现就是"拖不到任意位置""拉大后又变回去"。
        if plan.detail.isOnScreen, appliedPlan?.detail.isOnScreen != true {
            detailPanel.setFrame(detailFrame(), display: true)
        }

        // 幂等：只在结论真的变了的时候动窗口，所以可以被高频反复调用。
        guard plan != appliedPlan else { return }
        appliedPlan = plan
        apply(plan.anchor, to: anchorPanel)
        apply(plan.dragReceiver, to: dragReceiverPanel)
        apply(plan.workspace, to: workspacePanel)
        apply(plan.detail, to: detailPanel)
    }

    private func apply(_ presentation: NotchPanelPresentation, to panel: NSPanel) {
        panel.ignoresMouseEvents = !presentation.acceptsMouse
        if presentation.isOnScreen {
            panel.orderFrontRegardless()
        } else {
            panel.orderOut(nil)
        }
    }

    private func observeLayout() {
        withObservationTracking {
            _ = model.workspacePhase
            _ = model.dragPhase
            _ = model.barState
            _ = model.contextSuggestions.map(\.itemID)
            _ = model.contextAnswer
            _ = model.contextAnswerError
            // 候选卡在"已建好"和"问一句"之间切换时按钮数会变（一个 vs 两个），
            // 而 barState 都是 .todoDraft。不追踪它的话窗口宽高不重算，
            // 对号就落在命中框外面。
            _ = model.todoPrompt
            _ = model.activeReminder
            _ = model.mode
            _ = model.detailItem?.id
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 重注册必须同步：放进异步块的话，这中间发生的修改不会被追踪。
                self.observeLayout()
                // onChange 在属性真正写入前触发，下一拍再投影。相位推进函数内部会
                // 去重，推荐/计时等无关变化不会再取消并重启开合计时器。
                DispatchQueue.main.async {
                    self.updateWorkspacePresentationIfNeeded()
                    self.applyWindowPlan()
                }
            }
        }
    }

    /// 只负责相位推进和键盘焦点；窗口的可见性与鼠标归属交给 applyWindowPlan。
    private var projectedWorkspacePhase: NotchPresentationState.WorkspacePhase?

    private func updateWorkspacePresentationIfNeeded() {
        let phase = model.workspacePhase
        guard phase != projectedWorkspacePhase else { return }
        projectedWorkspacePhase = phase
        workspaceTransitionTask?.cancel()
        switch phase {
        case .hidden, .open:
            break
        case .opening:
            // 不成为 key window 的话，搜索框、待办输入、文字编辑都收不到
            // 键盘事件，cancelOperation 也不会被调用——Esc 收起等于不存在。
            NSApp.activate(ignoringOtherApps: true)
            workspacePanel.makeKeyAndOrderFront(nil)
            workspaceTransitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 280
                ))
                guard !Task.isCancelled else { return }
                self?.model.completeWorkspaceOpen()
            }
        case .closing:
            workspaceTransitionTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 280
                ))
                guard !Task.isCancelled, let self else { return }
                self.model.completeWorkspaceClose()
            }
        }
    }

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.screenUpdateTask?.cancel()
                self.screenUpdateTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled, let self else { return }
                    let previousScreen = self.screenFrame
                    let previousNotch = self.notchRect
                    guard self.configureGeometry(),
                          self.screenFrame != previousScreen || self.notchRect != previousNotch else {
                        return
                    }
                    self.positionStablePanels()
                    self.detailPanel.contentView = NSHostingView(
                        rootView: DetachedDetailWindow(model: self.model)
                    )
                    self.applyWindowPlan()
                }
            }
        }
    }

    // MARK: - Click behavior

    private func installOutsideClickHandling() {
        // 本地和全局分开处理。
        //
        // 本地事件带着 `event.window`——它直接告诉我们这一下点在我们自己的
        // 哪扇窗上，弹出层、右键菜单、设置窗都不例外。靠矩形去猜是猜不全的：
        // 每加一种弹出层就要补一次名单，而漏掉的那次表现为"点弹出层里的按钮，
        // 整个面板当场收起"。
        //
        // 全局事件只会来自别的应用、桌面和菜单栏，那些一律该收起。
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            let window = event.window
            Task { @MainActor in self?.closeForOutsideClickIfNeeded(ownWindow: window) }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] _ in
            Task { @MainActor in self?.closeForOutsideClickIfNeeded(ownWindow: nil) }
        }
    }

    /// - Parameter ownWindow: 本地事件落在我们哪扇窗上；全局事件传 nil。
    private func closeForOutsideClickIfNeeded(ownWindow: NSWindow?) {
        if ProcessInfo.processInfo.environment["MNEMO_DEBUG_KEEP_OPEN"] == "1" { return }
        let point = NSEvent.mouseLocation

        // Command-G 回答住在收起态 anchor，不属于 workspacePhase=.open。旧逻辑只收
        // 工作台，所以点外面回答永远不消失，只能点叉。现在先按 anchor 的实际 frame
        // 判断：点正文 / 复制按钮不动，点任何外部应用或桌面立即收起回答 / 推荐。
        if model.workspacePhase == .hidden,
           (showsContextAnswer || !model.contextSuggestions.isEmpty),
           !anchorPanel.frame.contains(point) {
            model.dismissContextSuggestion()
            return
        }
        // 候选卡和提醒卡同样住在收起态 anchor 里。点到别处就是"这次先不管"，
        // 和等它自己超时收起是同一个意思，只是不用等。
        if model.workspacePhase == .hidden,
           model.todoPrompt != nil || model.activeReminder != nil,
           !anchorPanel.frame.contains(point) {
            model.dismissNotchCards()
            return
        }

        // 只有工作台自己那一块算"里面"。
        //
        // 预览窗**不算**。它是一个独立窗口，自带关闭键，还能被拖到屏幕中间、
        // 拉到多大。把它算成"里面"会同时坏掉两头，两头用户都点过名：
        // 点预览窗时刘海赖着不收（视线明明已经离开刘海了），而点桌面时又要
        // 先牺牲掉预览窗才轮到刘海——一次点击被拆成两次，还每次都关错那个。
        //
        // 现在只有一条规则：点工作台以外的任何地方，收工作台。预览窗自始至终
        // 只由它自己的关闭键结束，绝不因为点了别处而消失。
        guard !isInsideWorkspaceSurface(ownWindow, at: point) else { return }

        guard model.workspacePhase == .open else { return }
        model.requestOutsideClose()
    }

    /// 这一下算不算"点在工作台自己身上"。
    ///
    /// 规则只有一句：**工作台，以及从它身上长出来的临时窗，算里面；其余一律
    /// 算外面。** 长出来的是什么不用枚举——popover、右键菜单、下拉，都是没有
    /// 长期引用的临时窗，而我们自己的长期窗一共就这么几扇，全都握在手里。
    /// 反过来列（"哪些算里面"）永远会漏掉下一种弹出层，而漏掉的表现是用户点
    /// 弹出层里的按钮时整个面板当场收起，动作还没做完就没了。
    ///
    /// | 点在哪 | 收不收 | 为什么 |
    /// | --- | --- | --- |
    /// | 工作台本身 | 不收 | 就是在用它 |
    /// | 工作台长出来的 popover / 菜单 | 不收 | 是同一个动作的一部分 |
    /// | 预览窗 | **收** | 它是独立窗口，只由自己的叉关闭；看它就是离开了刘海 |
    /// | 设置窗 / 引导窗 | **收** | 同上，它们是各自独立的界面 |
    /// | 锚点 / 拖拽接收层 | 收 | 覆盖在菜单栏那一带的透明窗，点菜单栏必须能收 |
    /// | 别的应用、桌面 | 收 | 全局事件走这条 |
    private func isInsideWorkspaceSurface(_ ownWindow: NSWindow?, at point: CGPoint) -> Bool {
        guard let ownWindow else {
            // 全局事件：只可能来自别的应用、桌面和菜单栏，一律算外面。
            // 仍然按矩形兜一次底，避免某些代理事件误伤正在用的工作台。
            return workspacePanel.frame.contains(point)
        }
        if ownWindow === workspacePanel { return true }
        return !standaloneWindows.contains { $0 === ownWindow }
    }

    /// 我们自己的**独立**窗口。它们不属于工作台，点它们该收起工作台。
    private var standaloneWindows: [NSWindow] {
        [anchorPanel, dragReceiverPanel, detailPanel, settingsWindow, onboardingWindow]
            .compactMap { $0 }
    }

    /// The wide drag receiver is armed only while the pointer is actively dragging
    /// inside its frame. Ordinary mouse events therefore keep reaching the app below.
    private func installDragReceiverArming() {
        let arm: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.updateDragReceiverArming() }
        }
        let disarm: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.scheduleDragReceiverDisarm() }
        }
        localDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { event in
            arm(event); return event
        }
        globalDragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: arm)
        localDragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            disarm(event); return event
        }
        globalDragEndMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp, handler: disarm)

        // Global drag monitors are not reliable across every source app and permission
        // state. Polling only the mouse-button bit and cursor point is permission-free,
        // cheap, and arms the destination before the cursor reaches the notch.
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateDragReceiverArming()
                // 持续对账。投影是纯函数加幂等写入，所以哪条路径万一漏了，
                // 窗口层最多脱节一拍，不会像以前那样永久留下一块死区。
                self?.applyWindowPlan()
            }
        }
        timer.tolerance = 0.01
        dragArmingTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 按下但还没移动时的起点。用来把"点击"和"拖拽"分开。
    private var pressOrigin: CGPoint?
    /// 拖拽是否正在接管输入。它是 NotchWindowPolicy 的输入之一，不再由各处
    /// 各自去改面板属性。
    private var isDragArmed = false

    private func updateDragReceiverArming() {
        // 展开后的按钮、模式横滑和卡片外拖都属于工作台，宽接收层不得抢所有权。
        guard model.workspacePhase == .hidden else {
            pressOrigin = nil
            disarmDragReceiverNow()
            return
        }
        let cursor = NSEvent.mouseLocation
        let primaryButtonIsDown = NSEvent.pressedMouseButtons & 1 != 0

        guard primaryButtonIsDown else {
            pressOrigin = nil
            disarmDragReceiverNow()
            return
        }

        let origin = pressOrigin ?? cursor
        if pressOrigin == nil { pressOrigin = origin }

        // 只有按住并且移动过，才算拖拽。
        //
        // 旧判据是"按键按下 + 光标在框内"——而这个框是 712×340 的顶部中央带，
        // 刘海本身就在里面。于是在刘海上按下鼠标的那一刻接收层就被武装，
        // anchor 变成 ignoresMouseEvents，mouseUp 根本到不了 anchor，
        // 点击直接丢失。
        let moved = hypot(cursor.x - origin.x, cursor.y - origin.y) > 6
        let activationFrame = dragReceiverPanel.frame.insetBy(
            dx: -NotchInteractionPolicy.dragActivationMargin,
            dy: -NotchInteractionPolicy.dragActivationMargin
        )
        guard moved, activationFrame.contains(cursor) else {
            disarmDragReceiverNow()
            return
        }

        dragDisarmTask?.cancel()
        dragDisarmTask = nil
        setDragArmed(true)
    }

    /// 立即解除。轮询已经确认按键抬起了，没有再等 140ms 的理由。
    ///
    /// 之前这里带一句 `guard !dragReceiverPanel.ignoresMouseEvents else { return }`：
    /// 接收层本来就没武装时直接 return，于是**永远不会**把 anchor 恢复成可点。
    /// 展开再收起之后刘海点不动，就是这条路径漏掉的。
    private func disarmDragReceiverNow() {
        dragDisarmTask?.cancel()
        dragDisarmTask = nil
        setDragArmed(false)
        if model.dragPhase == .targeted { model.setDropTargeted(false) }
    }

    private func setDragArmed(_ armed: Bool) {
        guard isDragArmed != armed else { return }
        isDragArmed = armed
        applyWindowPlan()
    }

    private func scheduleDragReceiverDisarm() {
        guard isDragArmed, dragDisarmTask == nil else { return }
        dragDisarmTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            self.dragDisarmTask = nil
            self.disarmDragReceiverNow()
        }
    }

    // MARK: - Menu and global shortcuts

    /// 装一条真正的主菜单。
    ///
    /// 展开时会 NSApp.activate 抢焦点让键盘可用，而 LSUIElement 应用默认
    /// 没有 mainMenu——菜单栏于是归属给一个没有菜单的应用，整条都不响应，
    /// 表现就是"展开后右边的图标点不动"。顺带这也是所有文本框能用
    /// Cmd-C/V/A/Z 的前提（粘贴 API Key 就靠它）。
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Mnemo")
        appMenu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 Mnemo",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 Mnemo",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        let commands: [(String, Selector, String)] = [
            ("撤销", Selector(("undo:")), "z"),
            ("重做", Selector(("redo:")), "Z"),
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("拷贝", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a"),
        ]
        for (index, command) in commands.enumerated() {
            if index == 2 { editMenu.addItem(.separator()) }
            editMenu.addItem(withTitle: command.0, action: command.1, keyEquivalent: command.2)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func installStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusItemIcon()
        let menu = NSMenu()
        let searchItem = NSMenuItem(
            title: "推荐与选中文字相关的内容",
            action: #selector(searchSelection),
            keyEquivalent: ""
        )
        searchItem.target = self
        searchItem.toolTip = "⌘G：拿选中的文字直接出推荐，不记进剪贴板"
        let toggleItem = NSMenuItem(title: "打开或收起 Mnemo", action: #selector(toggle), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(searchItem)
        let accessItem = NSMenuItem(
            title: "完全磁盘访问权限…",
            action: #selector(openFullDiskAccess),
            keyEquivalent: ""
        )
        accessItem.target = self
        accessItem.toolTip = "从微信等应用的聊天里拖文件需要这项权限；授权后要重启 Mnemo"
        menu.addItem(accessItem)
        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        let guideItem = NSMenuItem(
            title: "配置引导…",
            action: #selector(showOnboarding),
            keyEquivalent: ""
        )
        guideItem.target = self
        guideItem.toolTip = "重新查看权限、模型与快捷键的配置现状"
        menu.addItem(guideItem)
        menu.addItem(.separator())
        let versionItem = NSMenuItem(
            title: "版本 \(MnemoBuildIdentity.display) — 检查更新",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        versionItem.target = self
        versionItem.toolTip = "当前 \(MnemoBuildIdentity.display)。点开看有没有新版本。"
        menu.addItem(versionItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 Mnemo", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
        statusItem.menu = menu
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem?.button else { return }
        button.image = MnemoMenuBarIcon.image()
        button.imagePosition = .imageOnly
        button.toolTip = "Mnemo"
    }

    private func installHotKeys() {
        shortcutSettings.didChange = { [weak self] in self?.installHotKeys() }
        // 全量重注册。改一个组合就把四个一起重来，比起维护"哪个变了"的
        // 增量逻辑，代价只是四次 Carbon 调用，而且不会留下状态不一致。
        HotKeyCenter.shared.unregisterAll()

        var failed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard shortcutSettings.isEnabled(action) else { continue }
            let combination = shortcutSettings.combination(for: action)
            guard combination.isValid else { continue }
            let handler = self.handler(for: action)
            let registered = HotKeyCenter.shared.register(
                key: combination.keyCode,
                modifiers: combination.carbonModifiers,
                action: handler
            )
            // 注册失败几乎总是"这个组合已经被系统或别的应用占了"。
            // 静默失败的话，用户按了没反应又查不出原因，所以要能在设置里看到。
            if !registered { failed.insert(action) }
        }
        shortcutSettings.markUnavailable(failed)
    }

    private func handler(for action: ShortcutAction) -> () -> Void {
        switch action {
        case .togglePanel:
            return { [weak self] in self?.model.togglePanel() }
        case .ingestClipboard:
            return { [weak self] in Task { await self?.model.ingestClipboard() } }
        case .captureSelection:
            return { [weak self] in self?.captureFrontmostSelection() }
        case .recommendSelection:
            return { [weak self] in self?.recommendFrontmostSelection() }
        }
    }

    /// 拿前台应用当前选中的文字直接出推荐。
    ///
    /// 取内容仍要代按一次 Cmd-C（系统没有别的公开途径读别人的选区），但这一次
    /// 变化会被登记成自写：不入库，也不会被当成一次新的复制。
    private func frontmostApplicationIdentity() -> String {
        guard let application = NSWorkspace.shared.frontmostApplication else { return "unknown" }
        return application.bundleIdentifier ?? "pid:\(application.processIdentifier)"
    }

    private func rememberExplicitSelection(_ text: String, applicationID: String) {
        if explicitSelectionByApplication[applicationID] == nil {
            explicitSelectionApplicationOrder.append(applicationID)
        }
        explicitSelectionByApplication[applicationID] = text
        while explicitSelectionApplicationOrder.count > 8 {
            explicitSelectionByApplication[
                explicitSelectionApplicationOrder.removeFirst()
            ] = nil
        }
    }

    private func recommendFrontmostSelection() {
        recommendationCaptureTask?.cancel()
        let generation = recommendationCaptureCoordinator.begin()
        let applicationID = frontmostApplicationIdentity()
        // 必须在刘海出现之前取：之后再问"谁在前台"可能已经是 Mnemo 自己。
        let ownerPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        model.beginExplicitRecommendationCapture()

        // 最可靠且不破坏用户剪贴板：应用暴露 AXSelectedText 时直接使用。
        if let text = Clipboard.selectedTextFromFrontmostApp() {
            // 先拿到选区，再抓输入框目标：这一步的 AX 查询绝不能挡在检索前面。
            model.confirmExplicitRecommendationSelection(
                text,
                insertionTarget: FocusedInputTarget.capture(ownerPID: ownerPID),
                isCurrentSelection: true
            )
            rememberExplicitSelection(text, applicationID: applicationID)
            AppModel.ContextTrace.log(
                "Command-G #\(generation) 通过辅助功能直接取得当前选区，提交推荐"
            )
            model.recommendForSelection(text)
            return
        }

        let capture = Clipboard.beginSelectionCapture()
        AppModel.ContextTrace.log("Command-G #\(generation) 开始 Command-C / 自动复制回退")
        guard Clipboard.copySelectionFromFrontmostApp() else {
            Clipboard.promptForAccessibility()
            recommendationCaptureTask = nil
            model.failExplicitRecommendationCapture("读取选中内容需要辅助功能权限")
            return
        }
        recommendationCaptureTask = Task { @MainActor [weak self] in
            defer {
                if let self, self.recommendationCaptureCoordinator.isCurrent(generation) {
                    self.recommendationCaptureTask = nil
                }
            }
            // 前五次只接受 Command-C 后的真实新写入；最后一次允许“选中时已自动复制”
            // 的基线文字。基线若是 Mnemo 上轮回答则策略层拒绝，避免自己问自己。
            for attempt in 0..<6 {
                if attempt > 0 { try? await Task.sleep(for: .milliseconds(100)) }
                guard let self, !Task.isCancelled,
                      self.recommendationCaptureCoordinator.isCurrent(generation) else { return }
                if let captured = Clipboard.finishSelectionCapture(
                    capture,
                    allowsBaselineFallback: attempt == 5,
                    rememberedText: self.explicitSelectionByApplication[applicationID]
                ) {
                    self.lastPasteboardChangeCount = captured.changeCount
                    self.model.confirmExplicitRecommendationSelection(
                        captured.text,
                        insertionTarget: FocusedInputTarget.capture(ownerPID: ownerPID),
                        isCurrentSelection: captured.source != .rememberedExplicitSelection
                    )
                    self.rememberExplicitSelection(
                        captured.text,
                        applicationID: applicationID
                    )
                    AppModel.ContextTrace.log(
                        "Command-G #\(generation) 取得选区 source=\(captured.source)，提交推荐"
                    )
                    self.model.recommendForSelection(captured.text)
                    return
                }
            }
            guard let self, !Task.isCancelled,
                  self.recommendationCaptureCoordinator.isCurrent(generation) else { return }
            AppModel.ContextTrace.log("Command-G #\(generation) 600ms 内没有可验证文字选区")
            self.model.failExplicitRecommendationCapture(
                "没有读取到选中文字，请重新选中后再按 Command-G"
            )
        }
    }

    private func captureFrontmostSelection() {
        guard Clipboard.copySelectionFromFrontmostApp() else {
            Clipboard.promptForAccessibility()
            model.lastError = "复制所选内容需要辅助功能权限"
            model.expand()
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            await model.ingestClipboard()
        }
    }

    @objc private func toggle() { model.togglePanel() }
    @objc private func searchSelection() { recommendFrontmostSelection() }
    @objc private func openFullDiskAccess() { model.openFullDiskAccessSettings() }
    @objc private func openSettings() { showSettings() }
    private func updateCoordinatorLaunchCheck() { UpdateCoordinator.shared.checkOnLaunch() }

    @objc private func quit() { NSApp.terminate(nil) }

    /// 首次安装才弹；已经配好的机器直接记成已完成，不拦人。
    private func presentOnboardingIfNeeded() {
        Task { @MainActor [weak self] in
            // 凭据存在与否要等钥匙串那一轮异步读取回来，否则会把"有 Key"误判成没有。
            try? await Task.sleep(for: .milliseconds(1_200))
            guard let self else { return }
            // 调试钩子：截图和验收时强制打开，不动用户的真实"已看过"标记。
            if ProcessInfo.processInfo.environment["MNEMO_DEBUG_ONBOARDING"] == "1" {
                self.showOnboarding()
                return
            }
            let completed = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
            let readiness = self.onboardingReadiness()
            if OnboardingPresentation.canSilentlyMarkCompleted(
                hasCompletedOnboarding: completed,
                readiness: readiness
            ) {
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
                return
            }
            guard OnboardingPresentation.shouldPresentAutomatically(
                hasCompletedOnboarding: completed,
                readiness: readiness
            ) else { return }
            self.showOnboarding()
        }
    }

    private func onboardingReadiness() -> OnboardingReadiness {
        let providerID = providerSettings.chatProviderID ?? providerSettings.selectedProviderID
        let modelID = providerSettings.routing.route(for: .retrievalRecommendation)?.modelID ?? ""
        let embeddingModel = providerSettings.embeddingModelID
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return OnboardingReadiness(
            hasAccessibilityPermission: AXIsProcessTrusted(),
            hasChatCredential: providerSettings.keyPresence[providerID] == true,
            hasChatModel: !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            hasEmbeddingModel: providerSettings.embeddingProviderID?.isEmpty == false
                && !embeddingModel.isEmpty
        )
    }

    @objc private func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Mnemo 配置引导"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            // 无边框内容区默认是透明的，不显式铺底会从侧栏透出桌面。
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.center()
            window.contentView = NSHostingView(
                rootView: OnboardingView(
                    settings: providerSettings,
                    finish: { [weak self] in self?.completeOnboarding() }
                )
            )
            // 用红点关掉也算看过了，否则每次启动都再拦一次。
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
            }
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private var updateWindow: NSWindow?

    @objc private func checkForUpdates() { UpdateCoordinator.shared.checkNow() }

    private func presentUpdateWindowIfNeeded() {
        guard UpdateCoordinator.shared.isWindowPresented else {
            updateWindow?.close()
            updateWindow = nil
            return
        }
        if updateWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Mnemo 更新"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(rootView: UpdateWindow())
            window.isReleasedWhenClosed = false
            updateWindow = window
            // 用户点叉 = 只是收起窗口，不等于拒绝更新；状态保留在协调器里。
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { _ in
                Task { @MainActor in UpdateCoordinator.shared.dismiss() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        updateWindow?.makeKeyAndOrderFront(nil)
    }

    private func observeUpdatePresentation() {
        withObservationTracking {
            _ = UpdateCoordinator.shared.isWindowPresented
        } onChange: { [weak self] in
            MainActor.assumeIsolated {
                self?.observeUpdatePresentation()
                self?.presentUpdateWindowIfNeeded()
            }
        }
    }

    private func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
        onboardingWindow?.close()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Mnemo 设置"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 820, height: 560)
            window.center()
            window.contentView = NSHostingView(
                rootView: ProviderSettingsView(
                    settings: providerSettings,
                    appModel: model,
                    shortcuts: shortcutSettings
                )
            )
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Adaptive background work

    private func observeFocusClock() {
        withObservationTracking {
            _ = model.focusTimer.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.configureFocusTicker()
                self.observeFocusClock()
            }
        }
        configureFocusTicker()
    }

    /// 墙钟结束时间保证休眠后仍准确；UI 只需要按秒刷新，空闲和暂停时不保留 Timer。
    private func configureFocusTicker() {
        focusTicker?.invalidate()
        focusTicker = nil
        guard model.focusTimer.phase == .running else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refreshFocusTimer() }
        }
        timer.tolerance = 0.12
        focusTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// macOS 没有通用剪贴板变更通知；这里只轮询轻量 changeCount，内容读取只在变化后发生。
    private func startClipboardMonitor() {
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // 主动选区抓取会让前台应用异步改 pasteboard；等抓取 token 精确登记
                // changeCount 后再继续轮询，不能抢先把查询文字收进最近五条。
                guard self.recommendationCaptureTask == nil else { return }
                let change = NSPasteboard.general.changeCount
                guard change != self.lastPasteboardChangeCount else { return }
                self.lastPasteboardChangeCount = change
                guard !Clipboard.wasLastChangeWrittenByMnemo(change) else { return }
                Task { @MainActor in
                    await self.model.captureClipboardHistory(changeCount: change)
                }
            }
        }
        timer.tolerance = 0.10
        clipboardTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 提醒的刘海通路。
    ///
    /// 系统通知由 `TodoReminderCenter` 提前排好，那条路即使应用没在跑也会响；
    /// 这条只负责"进程在跑时顺手在刘海上弹一张卡"。30 秒一拍足够——提醒的
    /// 粒度本来就是分钟，秒级精度只会白白唤醒 CPU。
    private func startReminderMonitor() {
        reminderCenter.attach(to: model)
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.tickReminders() }
        }
        timer.tolerance = 6
        reminderTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 文件删除检查不属于交互帧关键路径。低频巡检带容差，让系统合并唤醒。
    private func startReferenceHealthMonitor() {
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.model.refreshReferenceHealth() }
        }
        timer.tolerance = 12
        referenceHealthTicker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 只在网络从不可用变为可用时唤醒持久化队列。它不轮询、不主动发起
    /// 模型请求，也不会让无效 Key 形成重试风暴。
    private func startNetworkRecoveryMonitor() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            let status = path.status
            Task { @MainActor [weak self] in
                guard let self else { return }
                let recovered = self.lastNetworkStatus != nil
                    && self.lastNetworkStatus != .satisfied
                    && status == .satisfied
                self.lastNetworkStatus = status
                guard recovered else { return }
                self.model.resumeAIEnrichment()
                self.model.resumeIndexing()
                // 网络断开时失败的待办理解在这里补跑；不重新识别，只重发模型请求。
                self.model.resumePendingTodoScans()
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    private func seedPreviewContent() async {
        await model.ingest(text: "公司抬头：某某科技有限公司\n税号：91330100MA2XXXXX\n开户行：招商银行杭州分行")
        await model.ingest(text: "https://developer.apple.com/design/human-interface-guidelines/")
        await model.ingest(text: "常用邮箱 hi@example.com")
    }

    /// 效率模式的预览数据：待办与专注记录。只在对应集合为空时写入，
    /// 供隔离数据目录下的 UI 验收使用。
    private func seedFocusPreviewContent() async {
        do {
            if try await model.library.todos().isEmpty {
                for title in [
                    "把周报初稿发给团队",
                    "回复税务的发票抬头邮件",
                    "读完 HIG 里 Liquid Glass 的章节",
                    "整理这周的截图收纳",
                    "预约下周一的设备维修",
                ] {
                    _ = try await model.library.addTodo(title: title)
                }
            }
            if try await model.library.focusSessions().isEmpty {
                let calendar = Calendar.current
                for offset in 0..<30 where offset % 3 != 1 {
                    guard let day = calendar.date(byAdding: .day, value: -offset, to: .now) else { continue }
                    for index in 0..<((offset % 4) + 1) {
                        let duration = TimeInterval(25 * 60)
                        let completedAt = day.addingTimeInterval(TimeInterval(index) * 3_600)
                        try await model.library.recordFocusSession(
                            FocusSession(
                                startedAt: completedAt.addingTimeInterval(-duration),
                                completedAt: completedAt,
                                plannedDuration: duration
                            )
                        )
                    }
                }
            }
            await model.reload()
            let calendar = Calendar.current
            let endOfToday = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: .now))?
                .addingTimeInterval(-1)
            let ids = model.todoItems.map(\.id)
            if let first = ids.first {
                await model.setTodoDueDate(first, date: endOfToday)
            }
            if ids.count > 1 {
                await model.setTodoDueDate(ids[1], date: endOfToday?.addingTimeInterval(-86_400))
            }
            if ids.count > 2 {
                await model.toggleTodoCompleted(ids[2])
            }
        } catch {
            NSLog("seedFocusPreviewContent failed: %@", error.localizedDescription)
        }
    }

    private func cleanupPreviewContent() async {
        let previewValues: Set<String> = [
            "公司抬头：某某科技有限公司\n税号：91330100MA2XXXXX\n开户行：招商银行杭州分行",
            "https://developer.apple.com/design/human-interface-guidelines/",
            "常用邮箱 hi@example.com",
        ]
        for item in model.items {
            if case .inline(let value) = item.holding, previewValues.contains(value) {
                await model.trash(item.id)
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

let app = NSApplication.shared
guard let instanceGuard = SingleInstanceGuard() else { exit(EXIT_SUCCESS) }
let delegate = AppDelegate(instanceGuard: instanceGuard)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
