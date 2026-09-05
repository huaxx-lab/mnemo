import AppKit
import PDFKit
import UniformTypeIdentifiers
import WebKit
import SwiftUI
import MnemoCore

enum Style {
    static let ink = Color.black
    static let liquid = Color(red: 0.035, green: 0.038, blue: 0.043).opacity(0.99)
    static let shell = liquid
    static let surface = Color.white.opacity(0.065)
    static let surfaceHover = Color.white.opacity(0.105)
    static let surfacePressed = Color.white.opacity(0.145)
    static let contentElevated = Color.white.opacity(0.08)
    static let stroke = Color.white.opacity(0.105)
    static let hairline = Color.white.opacity(0.085)
    static let strongStroke = Color.white.opacity(0.16)
    static let primary = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.67)
    static let tertiary = Color.white.opacity(0.43)
    static let accent = Color(nsColor: .systemOrange)
    static let accentMuted = accent.opacity(0.17)
    static let cool = Color(red: 0.38, green: 0.82, blue: 0.76)
    static let warning = Color(red: 0.98, green: 0.70, blue: 0.27)
    static let panelRadius: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 7
}

@MainActor
enum NotchLayout {
    static var notchWidth: CGFloat = 180
    static var notchHeight: CGFloat = 32
    static var panelWidth: CGFloat = 640
    static let headerHeight: CGFloat = 48
    /// 效率模式的表盘 + 控制行 + 统计条决定了这个下限；收纳模式用两行卡片
    /// 把同一块空间填满，而不是让它空着。
    static let workspaceContentHeight: CGFloat = 212
    static let detailHeight: CGFloat = 272

    static var dragCaptureWidth: CGFloat {
        NotchInteractionPolicy.dragCaptureWidth(notchWidth: notchWidth)
    }

    static var dragCaptureHeight: CGFloat { NotchInteractionPolicy.dragCaptureDepth }

    /// 每种状态下刘海要往两侧各长出多少。
    ///
    /// 刘海本体是物理挖孔，画不进去也点不到。所以做法是：需要显示东西时，
    /// 在挖孔两侧补一块**纯黑、和挖孔等高、贴着屏幕顶边**的形体，看起来就是
    /// 刘海自己变宽了；图标长在这块里面，而不是飘在菜单栏上。没东西显示时
    /// 一点都不长，刘海保持原样。
    static let suggestionRowHeight: CGFloat = 40
    static let suggestionListPadding: CGFloat = 10
    /// 显式宽度：SwiftUI 抽屉、AppKit 命中框、宿主窗口共用同一数字。
    static let suggestionListWidth: CGFloat = 300
    static let contextAnswerWidth: CGFloat = 430
    static let contextAnswerHeight: CGFloat = 188

    /// 形态跟着数量走：
    ///
    /// - 只有一条：就在刘海那一条里横着说完，两翼长宽一点放下标题和对号，
    ///   不往下掉一个面板——为一条结果弹个抽屉太重了。
    /// - 两条以上：两翼只留"库里有 N 个"和关闭，候选竖着排在刘海下面。
    ///   横向摊开三条会宽得离谱。
    static func wingWidth(for state: AppModel.BarState, suggestionCount: Int = 1) -> CGFloat {
        switch state {
        case .idle: 0
        case .indexing, .syncing: 38
        case .dropTargeted: 42
        case .timing, .paused: 56
        // 往两侧长要有节制：刘海居中，长太宽就压到菜单栏右侧的应用图标上。
        // 竖排时行本身有整宽可用，两翼只需要放下"库里有 N 个"和关闭。
        // 推荐本身在下面整宽的行里，两翼只放一个状态图标和关闭，
        // 因此不需要很宽——长出去的每一点都压在菜单栏图标上。
        case .suggesting: 44
        // 候选卡和提醒卡的正文都在下面整宽的卡片里，两翼只放一个状态图标，
        // 和推荐保持同一个克制尺度。
        case .todoDraft: 42
        case .reminding: 46
        }
    }

    /// 挖孔正下方那条唯一真实可点的带子。挖孔本身没有像素，点不到。
    static let clickLipHeight: CGFloat = 26

    static func anchorMetrics(
        for state: AppModel.BarState,
        suggestionCount: Int = 1
    ) -> NotchAnchorLayoutMetrics {
        NotchAnchorLayoutMetrics(
            notchSize: CGSize(width: notchWidth, height: notchHeight),
            wingWidth: wingWidth(for: state, suggestionCount: suggestionCount),
            clickLipHeight: clickLipHeight,
            suggestionRowHeight: suggestionRowHeight,
            suggestionListPadding: suggestionListPadding,
            suggestionCount: state == .suggesting ? suggestionCount : 0,
            suggestionListWidth: state == .suggesting && suggestionCount > 0
                ? suggestionListWidth : 0
        )
    }

    /// 待办候选卡 / 提醒卡的尺寸。
    ///
    /// 只有一行：图标、一句话、右端一两个小圆按钮。它出现的频率必须低、
    /// 占的地方必须小——真正重要的事有系统通知，刘海这一条是顺手的那一下。
    static let actionCardWidth: CGFloat = 330
    static let actionCardHeight: CGFloat = 52

    static func supplementSize(_ supplement: AppModel.NotchSupplement) -> CGSize {
        switch supplement {
        case .none: .zero
        case .answer: CGSize(width: contextAnswerWidth, height: contextAnswerHeight)
        case .todoPrompt, .reminder: CGSize(width: actionCardWidth, height: actionCardHeight)
        }
    }

    static func anchorMetrics(
        for state: AppModel.BarState,
        suggestionCount: Int,
        supplement: AppModel.NotchSupplement,
        supplementActionCount: Int = 0
    ) -> NotchAnchorLayoutMetrics {
        var metrics = anchorMetrics(for: state, suggestionCount: suggestionCount)
        metrics.supplementalContentSize = supplementSize(supplement)
        metrics.supplementalActionCount = supplementActionCount
        return metrics
    }

    static func suggestionListHeight(count: Int) -> CGFloat {
        anchorMetrics(for: .suggesting, suggestionCount: count).suggestionListHeight
    }

    static func collapsedWidth(for state: AppModel.BarState, suggestionCount: Int = 1) -> CGFloat {
        anchorMetrics(for: state, suggestionCount: suggestionCount).panelSize.width
    }

    static func collapsedHitSize(
        for state: AppModel.BarState,
        suggestionCount: Int = 1
    ) -> CGSize {
        anchorMetrics(for: state, suggestionCount: suggestionCount).panelSize
    }

    static var workspaceHeight: CGFloat { headerHeight + 1 + workspaceContentHeight }



    static func expandedHeight(mode: AppModel.Mode) -> CGFloat { workspaceHeight }

    /// 刘海占据的那一段：只有底色，内容从它下面开始。
    static var contentTopInset: CGFloat { notchHeight }
    static var shellHeight: CGFloat { notchHeight + workspaceHeight }
}

struct NotchAnchorRootView: View {
    @Bindable var model: AppModel

    var body: some View {
        // 原来外面还包了一层 GlassEffectContainer：macOS 26 会把容器里的黑块
        // 渲染成 Liquid Glass，透出壁纸颜色还带一圈玻璃光晕——就是那条被
        // 吐槽的蓝色胶囊。收起态保持纯黑即可，玻璃留给以后真正需要的场景。
        CollapsedBar(model: model)
        // 内容尺寸和窗口尺寸用同一个来源，两边不会互相拉扯。
        .frame(
            width: NotchLayout.anchorMetrics(
                for: model.barState,
                suggestionCount: model.contextSuggestions.count,
                supplement: model.notchSupplement,
                supplementActionCount: model.notchSupplementActionCount
            ).panelSize.width,
            height: NotchLayout.anchorMetrics(
                for: model.barState,
                suggestionCount: model.contextSuggestions.count,
                supplement: model.notchSupplement,
                supplementActionCount: model.notchSupplementActionCount
            ).panelSize.height,
            alignment: .top
        )
    }
}

struct NotchWorkspaceRootView: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presented: Bool {
        model.workspacePhase == .opening || model.workspacePhase == .open
    }

    /// 展开用 spring：遮罩从刘海大小长到完整面板，有一点"浮出来"的弹性；
    /// 收起用平滑曲线干净缩回，不弹。
    private var transitionAnimation: Animation {
        model.workspacePhase == .closing
            ? .smooth(duration: 0.22)
            : .spring(response: 0.4, dampingFraction: 0.78)
    }

    var body: some View {
        let isClosing = model.workspacePhase == .closing
        WorkspaceShell(model: model)
            // 布局始终按完整尺寸排——展开不是把内容"拉大"，是把面板"揭开"，
            // 文字和控件全程不变形，这就是和旧 scaleY 压扁方案的本质区别。
            .mask(alignment: .top) { revealMask }
            // 揭开的同时整体从 0.94 回到 1，配合 spring 有轻微浮出感。
            .scaleEffect(presented ? 1 : 0.94, anchor: .top)
            .opacity(presented ? 1 : 0)
            .blur(radius: presented ? 0 : 8)
            // 面板可见后才允许命中；closing 阶段也要屏蔽，避免动画期间误触。
            .allowsHitTesting(presented && !isClosing)
            .animation(reduceMotion ? nil : transitionAnimation, value: model.workspacePhase)
        .onDeleteCommand {
            Task { await model.trashSelected() }
        }
    }

    /// 揭示遮罩：从刘海那块小圆角 pill（≈200×32）长到完整面板（600×317）。
    /// 顶边贴上沿所以上角始终直角；下角的圆角让起始态和刘海本体同形，
    /// 看起来就是刘海自己向下"生长"成面板。
    private var revealMask: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: Style.panelRadius,
            bottomTrailingRadius: Style.panelRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .frame(
            width: presented ? NotchLayout.panelWidth : 200,
            height: presented ? NotchLayout.shellHeight : NotchLayout.notchHeight
        )
    }
}

private struct WorkspaceShell: View {
    @Bindable var model: AppModel
    @State private var showsActions = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var presented: Bool {
        model.workspacePhase == .opening || model.workspacePhase == .open
    }

    /// Toast 里的标题只是"指认是哪一条"，不是内容展示。
    ///
    /// 自动命名还没跑完的截图标题是 `pinland-clipboard-<UUID>`——四十多个字符，
    /// 整条横幅会被它撑到贴着面板两边。首尾各留一段、中间省略：既认得出是哪一条，
    /// 横幅宽度也不再随标题长短跳来跳去。
    static func toastTitle(_ raw: String?) -> String {
        let value = (raw ?? "Pin").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count > 14 else { return value.isEmpty ? "Pin" : value }
        return value.prefix(8) + "…" + value.suffix(4)
    }

    /// 顶边贴着屏幕上沿，所以上面两个角不圆——圆了会漏出后面的桌面。
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: Style.panelRadius,
            bottomTrailingRadius: Style.panelRadius,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            // 刘海那一段只有底色。两者同色，所以刘海看起来就是面板的一部分。
            Color.clear.frame(height: NotchLayout.contentTopInset)
                .opacity(presented ? 1 : 0)

            PanelHeader(model: model, showsActions: $showsActions)
                .frame(height: NotchLayout.headerHeight)
                .opacity(presented ? 1 : 0)
                .offset(y: presented ? 0 : -5)

            Hairline()
                .opacity(presented ? 1 : 0)

            Group {
                switch model.mode {
                case .stash:
                    StashWorkspace(model: model).frame(height: NotchLayout.workspaceContentHeight)
                case .focus:
                    FocusWorkspace(model: model).frame(height: NotchLayout.workspaceContentHeight)
                }
            }
            .opacity(presented ? 1 : 0)
            .offset(y: presented ? 0 : 10)
            .transition(.blurReplace)
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.24).delay(0.05), value: presented)
        .frame(width: NotchLayout.panelWidth, height: NotchLayout.shellHeight)
        .background { shape.fill(Style.shell) }
        .overlay {
            ZStack {
                if model.isDropTargeted {
                    shape.strokeBorder(Style.accent.opacity(0.75), lineWidth: 1.5)
                }
                // 工作台展开时只亮顶部刘海轮廓，不给整张面板描边。
                if model.edgeStatusEffectsEnabled, model.isRecognizingTodos {
                    TodoRecognitionEdge(
                        shape: UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
                    )
                    .frame(width: NotchLayout.notchWidth + 24, height: NotchLayout.notchHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                } else if model.edgeStatusEffectsEnabled, let signal = model.edgeStatusSignal {
                    EdgeStatusGlow(
                        shape: UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11),
                        signal: signal
                    )
                    .frame(width: NotchLayout.notchWidth + 24, height: NotchLayout.notchHeight)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .id(signal)
                }
            }
        }
        .onChange(of: model.mode) { _, _ in showsActions = false }
        .animation(.snappy(duration: 0.18), value: showsActions)
        .overlay(alignment: .bottom) {
            Group {
                if let error = model.lastError {
                    StatusToast(message: error, isError: true, dismiss: { model.dismissError() })
                } else if model.recentlyTrashedID != nil {
                    StatusToast(
                        message: "已删除 “\(Self.toastTitle(model.recentlyTrashedTitle))”",
                        actionTitle: "撤销",
                        action: { Task { await model.undoLastTrash() } }
                    )
                } else if let feedback = model.feedbackMessage {
                    StatusToast(message: feedback)
                }
            }
            .padding(.bottom, 48)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        // 下拉放在整条修饰链的最后并显式抬高层级：放在中间时，卡片轨道会连同
        // 缩略图一起盖在它上面（截图里"设置"那一行被论文封面压住就是这样）。
        .overlay(alignment: .topTrailing) {
            if showsActions {
                ZStack(alignment: .topTrailing) {
                    // 只画一层不收鼠标的背景。旧实现让它盖住整扇工作台并
                    // 消费第一次点击：点分页箭头时第一下只关菜单、第二下才翻页。
                    Color.black.opacity(0.001).allowsHitTesting(false)
                    PanelActionsSheet(model: model, isExpanded: $showsActions)
                        .padding(.trailing, 12)
                        .padding(.top, NotchLayout.contentTopInset + NotchLayout.headerHeight - 2)
                }
                .transition(.opacity)
            }
        }
        // 菜单开着时，子按钮的点击照常执行；同一次手势顺便把菜单收起。
        // simultaneous 不会像全屏 overlay 那样抢掉子控件的第一次点击。
        .simultaneousGesture(
            TapGesture().onEnded { if showsActions { showsActions = false } },
            including: showsActions ? .all : .subviews
        )
        .zIndex(3)
    }
}

/// 顶部中间那条握把。
///
/// 无边框窗口没有标题栏，"这块能拖"完全没有视觉线索；而且网页、图片这些内容
/// 视图会自己吃掉拖拽，按背景拖也不总是生效。这里给一条看得见的握把，
/// 并把拖拽直接交给窗口。
private struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { HandleView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class HandleView: NSView {
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

        override func mouseDown(with event: NSEvent) {
            // 交给系统去拖：跟着的是真正的窗口移动，不是我们自己算坐标。
            window?.performDrag(with: event)
        }
    }
}

/// 右下角的缩放把手。
///
/// 详情是无边框窗口：没有标题栏可抓，边缘那一两个像素也很难对准，
/// 于是"能拉大"实际上等于不能。这里给一个看得见、抓得住的角。
private struct WindowResizeGrip: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { GripView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class GripView: NSView {
        private var startPoint: NSPoint?
        private var startFrame: NSRect?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .crosshair)
        }

        override func mouseDown(with event: NSEvent) {
            startPoint = NSEvent.mouseLocation
            startFrame = window?.frame
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startPoint, let startFrame, let window else { return }
            let now = NSEvent.mouseLocation
            var frame = startFrame
            // 窗口原点在左下：往下拖是变高，所以要同时下移原点。
            frame.size.width = max(window.minSize.width, startFrame.width + now.x - startPoint.x)
            frame.size.height = max(window.minSize.height, startFrame.height + startPoint.y - now.y)
            frame.origin.y = startFrame.maxY - frame.size.height
            window.setFrame(frame, display: true)
        }

        override func mouseUp(with event: NSEvent) {
            defer { startPoint = nil; startFrame = nil }
            guard let frame = window?.frame else { return }
            DetailPanelFrame.save(frame)
            UserDefaults.standard.set(
                ["w": frame.width, "h": frame.height],
                forKey: NotchDetailPanel.sizeDefaultsKey
            )
        }
    }
}

struct DetachedDetailWindow: View {
    @Bindable var model: AppModel

    var body: some View {
        Group {
            if let item = model.detailItem, model.mode == .stash {
                DetailPanel(item: item, model: model)
                    .id(item.id)
                    .transition(.blurReplace)
            }
        }
        // 尺寸由窗口决定：详情窗现在可以拉大，内容跟着长。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Style.shell)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Style.strongStroke, lineWidth: 1)
        }
        .overlay(alignment: .top) {
            ZStack {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(width: 38, height: 4)
                WindowDragHandle()
            }
            .frame(width: 76, height: 16)
            .padding(.top, 5)
            .help("拖动移动位置")
        }
        .overlay(alignment: .bottomTrailing) {
            ZStack {
                Image(systemName: "arrow.down.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Style.tertiary)
                WindowResizeGrip()
            }
            .frame(width: 18, height: 18)
            .padding(4)
            .help("拖动调整大小")
        }
        .animation(.snappy(duration: 0.24), value: model.detailItem?.id)
        .alert(
            "放弃未保存的修改？",
            isPresented: Binding(
                get: { model.isShowingDiscardConfirmation },
                set: { if !$0 { model.cancelDiscard() } }
            )
        ) {
            Button("继续编辑", role: .cancel) { model.cancelDiscard() }
            Button("放弃修改", role: .destructive) { model.confirmDiscard() }
        } message: {
            Text("这段文字尚未确认保存。")
        }
    }
}

private struct CollapsedBar: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 状态就长在刘海两侧那一条里，和专注计时用的是同一块地方。
        // 不再在刘海下面单独长出一块——那才是"凭空多出一个区域"的来源。
        let wing = NotchLayout.wingWidth(
            for: model.barState,
            suggestionCount: model.contextSuggestions.count
        )
        let isQuiet = model.barState == .idle
        let supplement = model.notchSupplement
        let metrics = NotchLayout.anchorMetrics(
            for: model.barState,
            suggestionCount: model.contextSuggestions.count,
            supplement: supplement,
            supplementActionCount: model.notchSupplementActionCount
        )
        // 候选竖排时，刘海、展开唇和列表连成同一块黑；没有列表时黑色到刘海
        // 下沿为止——再往下多一截就是那条被吐槽的"舌头"。
        let showsList = model.barState == .suggesting && !model.contextSuggestions.isEmpty
        // 只有下面两个角是圆的：上边贴着屏幕顶边，和挖孔连成一块。
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 11, bottomTrailingRadius: 11)
        // 工作台正在展开时，收起态刘海淡出，形成连续过渡。
        let isFadingOut = model.workspacePhase == .opening

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leadingStatus.frame(width: wing)
                Color.clear.frame(width: NotchLayout.notchWidth)
                trailingStatus.frame(width: wing)
            }
            .frame(
                width: NotchLayout.notchWidth + wing * 2,
                height: NotchLayout.notchHeight
            )

            // 物理挖孔点不到，正下方保留一条展开唇。它只负责展开，推荐按钮统一
            // 从它下面开始，所以一个点击永远只有一个语义所有者。
            //
            // 这条唇只负责展开，本身不画东西；可点性由宿主视图那层看不见的
            // 底色保证。有推荐时它落在整块黑里，是刘海到列表之间的连接段。
            Color.clear
                .frame(width: NotchLayout.notchWidth, height: NotchLayout.clickLipHeight)

            if showsList {
                VStack(spacing: 0) {
                    ForEach(model.contextSuggestions) { suggestion in
                        SuggestionRow(
                            suggestion: suggestion,
                            item: model.items.first { $0.id == suggestion.itemID },
                            model: model
                        ) {
                            model.acceptContextSuggestion(suggestion)
                        }
                    }
                }
                .padding(NotchLayout.suggestionListPadding)
                .frame(width: NotchLayout.suggestionListWidth)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            switch supplement {
            case .none:
                EmptyView()
            case .answer:
                ContextAnswerCard(
                    answer: model.contextAnswer,
                    error: model.contextAnswerError,
                    delivery: model.contextAnswerDelivery,
                    isStreaming: model.isStreamingContextAnswer,
                    copy: { model.copyContextAnswer() }
                )
                .frame(
                    width: NotchLayout.contextAnswerWidth,
                    height: NotchLayout.contextAnswerHeight
                )
                .transition(.opacity.combined(with: .move(edge: .top)))
            case .todoPrompt:
                if let prompt = model.todoPrompt {
                    TodoPromptCard(
                        prompt: prompt,
                        fromNearbyDevice: model.todoDraftCameFromNearbyDevice,
                        deviceKind: model.todoDraftDeviceKind,
                        busy: model.isMutatingTodoPrompt,
                        remaining: model.remainingTodoPromptCount
                    )
                    .id(prompt.transitionID)
                    .frame(
                        width: NotchLayout.actionCardWidth,
                        height: NotchLayout.actionCardHeight
                    )
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            case .reminder:
                if let reminder = model.activeReminder {
                    TodoReminderCard(reminder: reminder)
                        .frame(
                            width: NotchLayout.actionCardWidth,
                            height: NotchLayout.actionCardHeight
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .frame(width: metrics.panelSize.width, height: metrics.panelSize.height, alignment: .top)
        // 交互底：刘海状态带 + 展开唇这一带必须始终收得到指针——点击展开和
        // 悬停展开全靠它。铺一层 2% 的黑：肉眼分辨不出，窗口服务器却认它是
        // 非透明像素。只画这一小块，面板上其余像素保持完全透明——落在卡片
        // 之间空隙里的点击才能真正透到后面的应用，而不是被一块看不见的底板
        // 无声吞掉（以前整块锚点都铺这层底，点别的页面"误触"就源于此）。
        .background(alignment: .top) {
            Color.black.opacity(0.02)
                .frame(
                    width: metrics.notchSize.width + metrics.wingWidth * 2,
                    height: metrics.notchSize.height + metrics.clickLipHeight
                )
        }
        // 整块只有一层底色，两翼、唇和推荐行连成同一个形体。没有推荐时黑色
        // 到刘海下沿为止，下面那截透明命中区不能被画出来——那就是"多一条舌头"。
        .background(alignment: .top) {
            if !isQuiet {
                shape.fill(Color.black)
                    .frame(
                        height: showsList || supplement != .none
                            ? metrics.panelSize.height
                            : NotchLayout.notchHeight
                    )
            }
        }
        .overlay(alignment: .top) {
            // 这一圈光不依赖黑底：待办创建成功时刘海往往刚好已经收回安静态
            // （识别结束、卡片已收掉），原来挂在 `!isQuiet` 后面导致这一下
            // 反馈从来没真正显示过。识别中的轻光同样不依赖黑底，两者待遇
            // 保持一致。
            //
            // 宽度必须严丝合缝等于 notchWidth，不能像工作台那份一样再加
            // 24——安静态的窗口本身就只有 notchWidth 那么宽（没有两翼），
            // 比这圈光的取景框还窄，多出来的部分会被窗口边界整段裁掉：
            // 剩下的不是一整圈，而是贴着顶边的一小段线，两侧竖线全没了。
            // 这正是"刘海外部多出一圈、看着像一条线"的真实成因。
            if model.edgeStatusEffectsEnabled, model.isRecognizingTodos {
                TodoRecognitionEdge(shape: shape)
                    .frame(width: NotchLayout.notchWidth, height: NotchLayout.notchHeight)
            } else if model.edgeStatusEffectsEnabled, let signal = model.edgeStatusSignal {
                EdgeStatusGlow(shape: shape, signal: signal)
                    .frame(width: NotchLayout.notchWidth, height: NotchLayout.notchHeight)
                    .id(signal)
            }
        }
        // 工作台展开时刘海缩进淡出（像被面板"吸收"）；收起时等面板缩过一半
        // 再淡回来，两边交接不重不漏。
        .opacity(isFadingOut ? 0 : 1)
        .scaleEffect(isFadingOut ? 0.9 : 1, anchor: .top)
        .animation(
            reduceMotion ? nil : (isFadingOut
                ? .easeOut(duration: 0.16)
                : .easeIn(duration: 0.2).delay(0.1)),
            value: isFadingOut
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.26), value: model.barState)
        .animation(.snappy(duration: 0.26), value: model.contextSuggestions.map(\.itemID))
        .animation(reduceMotion ? nil : .snappy(duration: 0.26), value: supplement)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: model.todoPrompt?.transitionID)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var didAutoCopyFirstSuggestion: Bool {
        model.contextSuggestions.first?.didAutoCopy == true
    }

    private var leadingSuggestionLabel: String {
        if didAutoCopyFirstSuggestion { return "已放进剪贴板" }
        if model.contextSuggestions.count > 1 { return "库里有 \(model.contextSuggestions.count) 个相关内容" }
        return "库里有相关内容"
    }

    @ViewBuilder
    private var leadingStatus: some View {
        switch model.barState {
        case .idle:
            Color.clear
        case .suggesting:
            // 两翼只剩一个状态图标：推荐是什么、复制没复制，都在下面那一行里
            // 写得清清楚楚，这里再写一遍只会把刘海撑到菜单栏图标上。
            Image(systemName: didAutoCopyFirstSuggestion ? "checkmark.circle.fill" : "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(didAutoCopyFirstSuggestion ? Style.cool : Style.accent)
                .help(leadingSuggestionLabel)
        case .indexing, .syncing:
            // 待办识别不会走到这个分支：barState 在识别期间统一是 .idle，
            // 两翼的点只留给真正的索引/AI 处理。
            ProcessingDots(tint: Style.cool, dotSize: 3)
        case .dropTargeted:
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Style.accent)
        case .timing:
            Image(systemName: "timer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Style.accent)
        case .paused:
            Image(systemName: "pause.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Style.warning)
        case .todoDraft:
            Image(systemName: model.todoDraftCameFromNearbyDevice
                  ? model.todoDraftDeviceKind.symbol : "checklist")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Style.cool)
                .help(model.todoDraftCameFromNearbyDevice
                      ? "来自你的 \(model.todoDraftDeviceKind.displayName)" : "待办候选")
        case .reminding:
            // 铃铛自己晃一下就够了：提醒本来就该被注意到，但不该像报警。
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Style.accent)
                .symbolEffect(.bounce, options: reduceMotion ? .nonRepeating : .repeat(.periodic(2, delay: 1.4)))
                .help("待办提醒")
        }
    }

    @ViewBuilder
    private var trailingStatus: some View {
        switch model.barState {
        case .idle:
            Color.clear
        case .suggesting:
            if model.contextAnswer != nil || model.contextAnswerError != nil {
                // 回答态点面板外自动收起，不再显示叉号。
                Color.clear
            } else {
                Button { model.dismissContextSuggestion() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Style.tertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("关闭推荐")
            }
        case .indexing, .syncing:
            ProcessingDots(tint: Style.cool, dotSize: 3)
        case .dropTargeted:
            Image(systemName: model.inboundPayloadKind.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Style.cool)
        case .timing, .paused:
            Text(TimeFormat.mmss(model.timerRemaining ?? 0))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Style.primary)
                .contentTransition(.numericText())
        case .todoDraft, .reminding:
            // 对号和叉都在下面那张卡上，两翼这里再放一个关闭只会有两个语义
            // 相同的按钮，用户永远在猜点哪个。
            Color.clear
        }
    }

    private var trailingLabel: String {
        switch model.barState {
        case .timing, .paused: TimeFormat.mmss(model.timerRemaining ?? 0)
        case .indexing, .syncing, .dropTargeted, .idle, .suggesting,
             .todoDraft, .reminding: ""
        }
    }

    private var accessibilityLabel: String {
        switch model.barState {
        case .idle: "打开 Mnemo"
        case .dropTargeted: "松手即可收纳"
        case .timing: "专注剩余 \(trailingLabel)"
        case .paused: "专注已暂停，剩余 \(trailingLabel)"
        case .indexing:
            model.isRecognizingTodos
                ? "正在识别待办"
                : model.isAIProcessing ? "正在智能整理" : "正在建立索引"
        case .syncing: "正在同步"
        case .suggesting:
            if let first = model.contextSuggestions.first, first.didAutoCopy {
                "已把「\(first.title)」放进剪贴板"
            } else if model.contextSuggestions.count > 1 {
                "库里有 \(model.contextSuggestions.count) 个相关内容，选一个复制"
            } else if let first = model.contextSuggestions.first {
                "库里有相关内容：\(first.title)，点按复制"
            } else {
                "库里有相关内容"
            }
        case .todoDraft:
            model.todoPrompt.map { "要\($0.plan.summary)吗：\($0.plan.title)" } ?? "待办候选"
        case .reminding:
            if let reminder = model.activeReminder {
                "待办提醒：\(reminder.title)，"
                    + TodoReminderPolicy.relativeDescription(of: reminder.dueAt)
            } else {
                "待办提醒"
            }
        }
    }
}

/// 待办候选卡。
///
/// 只有一行：一个图标、一句"这是什么"、右端一到两个小圆按钮。
/// 拿不准时是对号和叉；已经替你建好时只有一个叉，意思是撤销。
///
/// 按钮真正的点击由 AppKit 按 `NotchAnchorLayoutMetrics.supplementalActionFrames`
/// 命中——锚点面板永远不是 key window，SwiftUI 的 Button 在别的应用在前台时
/// 收不到那一下。这里画的是同一套几何的视觉部分。
private struct TodoPromptCard: View {
    let prompt: AppModel.TodoPrompt
    let fromNearbyDevice: Bool
    var deviceKind: NearbyDeviceKind = .unknown
    var busy = false
    var remaining = 0
    var confirm: (() -> Void)?
    var reject: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var plan: TodoRevisionPlan { prompt.plan }
    private var presentation: TodoPresentationMetadata { TodoPresentationMetadata(plan: plan) }



    var body: some View {
        HStack(spacing: 10) {
            if presentation.isMeaningful {
                ServiceBrandIcon(metadata: presentation, size: 30)
            } else {
                ZStack {
                    Circle().fill(tint.opacity(0.16))
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 30, height: 30)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(plan.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Style.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Style.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: NotchAnchorLayoutMetrics.supplementalActionSpacing) {
                if busy {
                    ProgressView().controlSize(.small).frame(width: 24, height: 24)
                } else {
                    if case .asking = prompt {
                        if let confirm {
                            Button(action: confirm) { CircleGlyphButton(symbol: "checkmark", tint: Style.cool) }
                                .buttonStyle(.plain).help("确认加入待办")
                        } else { CircleGlyphButton(symbol: "checkmark", tint: Style.cool) }
                    }
                    if let reject {
                        Button(action: reject) { CircleGlyphButton(symbol: "xmark", tint: Style.tertiary) }
                            .buttonStyle(.plain).help("忽略 / 撤销")
                    } else { CircleGlyphButton(symbol: "xmark", tint: Style.tertiary) }
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: busy)
        .padding(.leading, 12)
        .padding(.trailing, NotchAnchorLayoutMetrics.supplementalActionInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var dueDate: Date? {
        switch plan.revision {
        case .create(let draft): draft.dueAt
        case .reschedule(_, _, _, let to): to
        case .rename(_, _, _, let due, _): due
        case .complete, .cancel: nil
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if busy { parts.append("正在保存…") }
        else { parts.append("需要确认") }
        if let due = dueDate {
            parts.append(due.formatted(.dateTime.month().day().hour().minute()))
        }
        if remaining > 0 { parts.append("后续 \(remaining) 项") }
        if fromNearbyDevice { parts.append("来自\(deviceKind.displayName)") }
        if let code = plan.code, !plan.title.contains(code) { parts.append("编号 \(code)") }
        if dueDate == nil { parts.append(plan.summary) }
        return parts.joined(separator: " · ")
    }

    /// 图标只回答一件事：这一下要**做什么**。
    ///
    /// 之前是按待办的来源分（取餐码 / 快递 / 截止），但卡片上现在承载的是
    /// 一次改动，不是一条待办——"取消组会"配一个日历图标只会让人以为要加日程。
    private var symbol: String {
        return switch plan.revision {
        case .create(let draft):
            switch draft.source {
            case .pickupCode: "takeoutbag.and.cup.and.straw.fill"
            case .delivery: "shippingbox.fill"
            case .deadline: "calendar.badge.plus"
            case .appointment: "calendar"
            }
        case .reschedule: "calendar.badge.clock"
        case .rename: "pencil"
        case .complete: "checkmark.circle"
        case .cancel: "trash"
        }
    }

    private var tint: Color {
        return switch plan.revision {
        case .create(let draft): draft.source == .delivery ? Style.warning : Style.accent
        case .reschedule: Style.accent
        case .rename: Style.secondary
        case .complete: Style.cool
        case .cancel: Style.warning
        }
    }
}

/// 待办提醒卡。对号是"完成"，时钟是"十分钟后再说"。
private struct TodoReminderCard: View {
    let reminder: TodoReminder
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: reminder.trigger == .overdue
                      ? "exclamationmark.circle.fill" : "bell.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(reminder.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Style.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(TodoReminderPolicy.relativeDescription(of: reminder.dueAt))
                    .font(.system(size: 9.5))
                    .foregroundStyle(reminder.trigger == .overdue ? Style.warning : Style.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            HStack(spacing: NotchAnchorLayoutMetrics.supplementalActionSpacing) {
                CircleGlyphButton(symbol: "checkmark", tint: Style.cool)
                CircleGlyphButton(symbol: "clock.arrow.circlepath", tint: Style.tertiary)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, NotchAnchorLayoutMetrics.supplementalActionInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var tint: Color {
        reminder.trigger == .overdue ? Style.warning : Style.accent
    }
}

/// 卡片右端那个小圆按钮的**外观**。命中由 AppKit 负责，所以这里没有 Button。
private struct CircleGlyphButton: View {
    let symbol: String
    let tint: Color

    var body: some View {
        ZStack {
            Circle().fill(Style.surface)
            Circle().strokeBorder(Style.stroke)
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)
        }
        .frame(
            width: NotchAnchorLayoutMetrics.supplementalActionHeight,
            height: NotchAnchorLayoutMetrics.supplementalActionHeight
        )
    }
}

/// Command-G 的解释答案。它仍从刘海本体长出来，但正文有独立可滚动区域；
/// 长答案不会把面板无限向下撑，也不会像旧 copyText 一样只露出半句。
private struct ContextAnswerCard: View {
    fileprivate struct ScrollMetrics: Equatable {
        var offset: CGFloat = 0
        var contentHeight: CGFloat = 0
        var viewportHeight: CGFloat = 0

        var isScrollable: Bool { contentHeight > viewportHeight + 1 }
    }

    let answer: String?
    let error: String?
    let delivery: AnswerDeliveryRoute?
    let isStreaming: Bool
    let copy: () -> Void
    @State private var scrollMetrics = ScrollMetrics()

    private var statusSymbol: String {
        if error != nil { return "exclamationmark.triangle" }
        if isStreaming { return "text.cursor" }
        return delivery != nil || answer?.isEmpty == false ? "checkmark.circle.fill" : "sparkles"
    }

    /// 出了岔子就直接把那句话摆出来——它本身已经说清了回答在哪、要不要再点复制，
    /// 再套一层“回答未完成”只会挡住真正有用的一行。
    private var statusLabel: String {
        if let error { return error }
        switch delivery {
        case .focusedInput: return isStreaming ? "正在写进输入框" : "已写进输入框"
        case .clipboard: return "已放进剪贴板"
        case nil: return "快捷回答"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(error != nil ? Style.warning : Style.cool)
                Text(statusLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Style.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if answer?.isEmpty == false {
                    Button(action: copy) {
                        Label("复制", systemImage: "doc.on.doc")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Style.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(error == nil ? "复制完整回答" : "复制当前已生成内容")
                }
            }

            // 系统滚动条在 nonactivating panel 里会画出一整条深色滚动槽。这里隐藏
            // 它，只在正文右边界浮一枚细滑块。正文保持裁剪，滚动后绝不能越界盖住
            // 顶部状态图标和复制按钮（旧 `.scrollClipDisabled()` 正是重叠根因）。
            ScrollView(.vertical, showsIndicators: false) {
                if let answer, !answer.isEmpty {
                    MarkdownText(raw: answer, font: .system(size: 11.5))
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.trailing, 12)
                } else {
                    Text(error ?? "正在读取本地证据…")
                        .font(.system(size: 11.5))
                        .foregroundStyle(error == nil ? Style.tertiary : Style.secondary)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.trailing, 12)
                }
            }
            .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                ScrollMetrics(
                    offset: max(0, geometry.contentOffset.y + geometry.contentInsets.top),
                    contentHeight: geometry.contentSize.height,
                    viewportHeight: geometry.containerSize.height
                )
            } action: { _, metrics in
                scrollMetrics = metrics
            }
            .overlay(alignment: .trailing) {
                FloatingScrollThumb(metrics: scrollMetrics)
                    .padding(.vertical, 4)
                    .padding(.trailing, 1)
            }
            .clipped()
            .background(Color.clear)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        // 一层轻微明度区分即可，不再给滚动正文套边框。
        .background(Style.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
    }
}

/// 无滚动槽、无描边的悬浮滑块。尺寸表示当前可见比例，位置表示阅读进度；
/// 它只是反馈，不另外抢手势，滚轮 / 触控板事件仍全部交给正文 ScrollView。
private struct FloatingScrollThumb: View {
    let metrics: ContextAnswerCard.ScrollMetrics

    var body: some View {
        GeometryReader { proxy in
            if metrics.isScrollable {
                let availableHeight = max(1, proxy.size.height)
                let thumbHeight = min(
                    availableHeight,
                    max(30, availableHeight * metrics.viewportHeight / metrics.contentHeight)
                )
                let scrollRange = max(1, metrics.contentHeight - metrics.viewportHeight)
                let travel = max(0, availableHeight - thumbHeight)
                let progress = min(1, max(0, metrics.offset / scrollRange))

                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 7, height: thumbHeight)
                    .offset(y: travel * progress)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 9)
        .accessibilityHidden(true)
    }
}

/// 候选列表里的一行。
///
/// 唯一确定时只有一行，并且内容已经替用户放进剪贴板——给一个对号表示
/// "可以直接粘了"。有歧义时给几行，点哪行复制哪行，绝不替他决定。
private struct SuggestionRow: View {
    let suggestion: AppModel.ContextSuggestion
    let item: Item?
    @Bindable var model: AppModel
    let action: () -> Void
    @State private var hovering = false
    @State private var pressing = false
    @State private var confirmed = false
    @State private var preview: NSImage?

    fileprivate static func symbol(for kind: ItemKind) -> String {
        switch kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .link: "link"
        case .file: "doc"
        case .binary: "shippingbox"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                SuggestionPreview(item: item, kind: suggestion.kind, image: preview)
                VStack(alignment: .leading, spacing: 0) {
                    Text(suggestion.title)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Style.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let error = suggestion.copyError {
                        Text(error)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Style.warning)
                            .lineLimit(1)
                    } else if !suggestion.reason.isEmpty {
                        Text(suggestion.reason)
                            .font(.system(size: 9.5))
                            .foregroundStyle(Style.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                Group {
                    if suggestion.isCopying {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: suggestion.didAutoCopy
                              ? "checkmark.circle.fill"
                              : (suggestion.copyError == nil ? "doc.on.doc" : "exclamationmark.circle"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(suggestion.didAutoCopy
                                             ? Style.cool
                                             : (suggestion.copyError == nil ? Style.accent : Style.warning))
                    }
                }
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
                .background(hovering && !suggestion.didAutoCopy
                            ? Style.accentMuted : .clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .scaleEffect(confirmed ? 1 : 0.5)
                .opacity(confirmed ? 1 : 0)
            }
            .padding(.horizontal, 8)
            .frame(height: NotchLayout.suggestionRowHeight)
            .background(hovering ? Style.surfaceHover : .clear,
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(pressing ? 0.97 : 1.0)
            .animation(.spring(response: 0.16, dampingFraction: 0.78), value: pressing)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in pressing = false }
        )
        .help(suggestion.reason)
        .accessibilityLabel(
            suggestion.didAutoCopy
                ? "已把 \(suggestion.title) 放进剪贴板"
                : "复制 \(suggestion.title)"
        )
        .onAppear {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.6).delay(0.12)) {
                confirmed = true
            }
        }
        .task(id: suggestion.itemID) {
            guard let item else { return }
            if item.kind == .link {
                preview = LinkCoverStore.cachedImage(for: item.id)
                return
            }
            let url = try? await model.library.resolvedFileURL(for: item)
            preview = await ThumbnailStore.shared.image(
                item: item,
                url: url,
                logicalSize: 32
            )
        }
    }
}

/// 推荐行的小预览。图片 / PDF / 文件直接复用卡片缩略图缓存；链接优先用网页封面，
/// 没抓到封面时显示域名徽标，最后才退回类型图标。
private struct SuggestionPreview: View {
    let item: Item?
    let kind: ItemKind
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if let host = linkHost {
                DomainBadge(host: host, fontSize: 11)
            } else {
                Image(systemName: SuggestionRow.symbol(for: kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Style.cool)
            }
        }
        .frame(width: 30, height: 30)
        .background(Style.surfacePressed, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Style.stroke) }
    }

    private var linkHost: String? {
        guard kind == .link, let item, case .inline(let text) = item.holding else { return nil }
        return URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines))?.host()
    }
}

private struct PanelHeader: View {
    @Bindable var model: AppModel
    @Binding var showsActions: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            ModeControl(model: model)
            Spacer(minLength: 12)
            if model.mode == .stash && model.isSearching {
                SearchField(model: model, focused: $searchFocused)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                if model.mode == .stash {
                    IconButton("magnifyingglass", help: "搜索") {
                        model.beginSearch(); searchFocused = true
                    }
                }
                PanelActionsMenu(model: model, isExpanded: $showsActions)
            }
        }
        .padding(.horizontal, 12)
    }
}

/// 「更多」的下拉。
///
/// 用系统 `Menu` 时弹层由 AppKit 决定位置，会溢出面板、盖到刘海和菜单栏上。
/// 这里改成画在面板自己的层里：位置我们说了算，永远在轮廓之内。
private struct PanelActionsMenu: View {
    @Bindable var model: AppModel
    @Binding var isExpanded: Bool

    var body: some View {
        Button { isExpanded.toggle() } label: {
            Label("更多", systemImage: "ellipsis")
                .font(.subheadline.weight(.medium))
                .frame(height: 32)
                .padding(.horizontal, 8)
                .background(isExpanded ? Style.surfacePressed : Style.surface,
                            in: RoundedRectangle(cornerRadius: Style.controlRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .tint(Style.secondary)
        .foregroundStyle(Style.secondary)
        .help("更多操作")
    }
}

private struct PanelActionsSheet: View {
    @Bindable var model: AppModel
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.mode == .stash {
                row("收纳剪贴板", systemImage: "tray.and.arrow.down") {
                    Task { await model.ingestClipboard() }
                }
                if model.detailItem != nil {
                    row("移到回收站", systemImage: "trash", tint: Style.warning) {
                        Task { await model.trashSelected() }
                    }
                }
                Divider().overlay(Style.hairline).padding(.vertical, 3)
            }
            row(
                model.isPinnedOpen ? "取消保持展开" : "保持展开",
                systemImage: model.isPinnedOpen ? "pin.fill" : "pin"
            ) {
                model.isPinnedOpen.toggle()
            }
            row("设置", systemImage: "gearshape") { model.openSettings() }
        }
        .padding(6)
        .frame(width: 168)
        // 底色必须是实心的。之前用的是 14% 白的表面色——它是"叠在内容上的一层"，
        // 于是后面的卡片和缩略图直接透过来，看着像卡片压在菜单上面。
        .background {
            RoundedRectangle(cornerRadius: 10)
                .fill(Style.shell)
                .overlay {
                    RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.07))
                }
        }
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Style.strongStroke) }
        .shadow(color: .black.opacity(0.55), radius: 16, y: 6)
    }

    private func row(
        _ title: String,
        systemImage: String,
        tint: Color = Style.primary,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            isExpanded = false
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ModeControl: View {
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppModel.Mode.allCases) { mode in
                Button { model.setMode(mode) } label: {
                    Label(mode.rawValue, systemImage: mode.symbol)
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 76, height: 30)
                        .foregroundStyle(model.mode == mode ? Style.primary : Style.secondary)
                        .background(model.mode == mode ? Style.surfacePressed : .clear,
                                    in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Style.surface, in: RoundedRectangle(cornerRadius: Style.controlRadius))
        .overlay { RoundedRectangle(cornerRadius: Style.controlRadius).strokeBorder(Style.stroke) }
        .gesture(
            DragGesture(minimumDistance: 24).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) * 1.4 else { return }
                model.moveMode(horizontalDirection: value.translation.width)
            }
        )
        .help("点击或横向滑动切换模式")
    }
}

private struct SearchField: View {
    @Bindable var model: AppModel
    var focused: FocusState<Bool>.Binding

    var body: some View {
        Group {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .medium))
                TextField("描述要找的内容，回车检索", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused(focused)
                    .onSubmit {
                        model.submitSemanticSearch()
                        focused.wrappedValue = false
                    }
                Group {
                    if model.isPerformingSemanticSearch {
                        ProcessingDots(tint: Style.cool, dotSize: 3)
                            .frame(width: 18, height: 18)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    } else {
                        Button { model.endSearch() } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                        .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: model.isPerformingSemanticSearch)
            }
        }
        .foregroundStyle(Style.secondary)
        .padding(.horizontal, 10)
        .frame(width: 300, height: 34)
        .background(Style.surface, in: RoundedRectangle(cornerRadius: Style.controlRadius, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Style.controlRadius, style: .continuous).strokeBorder(Style.stroke) }
        .onAppear { focused.wrappedValue = true }
    }
}

private struct IconButton: View {
    let name: String
    let helpText: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pressing = false

    init(_ name: String, help: String, action: @escaping () -> Void) {
        self.name = name; self.helpText = help; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(hovering ? Style.surfaceHover : .clear,
                            in: RoundedRectangle(cornerRadius: Style.controlRadius, style: .continuous))
                .contentShape(Rectangle())
                .scaleEffect(pressing ? 0.88 : 1.0)
                .animation(.spring(response: 0.18, dampingFraction: 0.75), value: pressing)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Style.secondary)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in pressing = false }
        )
        .help(helpText)
    }
}

// MARK: - Stash

/// 卡片重排的 drop 代理。
///
/// 被拖的是哪张卡不读拖拽板——自定义 UTI 在 SwiftUI 的 drop 类型转换里
/// 不一定存活。拖动开始时 AppModel.draggingItemID 已经记下了，同一进程
/// 里的共享状态百分之百可靠；拖拽板只负责把内容拖出到别的应用。
/// 「拖到这儿就离开当前的区」的提示。
private struct DetachHint: View {
    let active: Bool

    var body: some View {
        if active {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    Style.warning.opacity(0.7),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                )
                .overlay {
                    Label("拖到这里移出分组", systemImage: "folder.badge.minus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Style.warning)
                }
                .padding(4)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }
}

/// 松手就会并进去的那个目标的高亮。
///
/// 单独拆出来不是为了复用——是因为把这一整串 overlay 内联在 ForEach 里会让
/// Swift 的类型检查器在那条表达式上直接超时。视图嵌套一深就要拆，这是硬约束。
private struct MergeHalo: View {
    let active: Bool
    var radius: CGFloat = Style.cardRadius
    var label: String = "并成一组"

    var body: some View {
        if active {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            shape
                .fill(Style.cool.opacity(0.14))
                .overlay { shape.strokeBorder(Style.cool, lineWidth: 2) }
                .overlay(alignment: .top) { badge }
                .allowsHitTesting(false)
        }
    }

    private var badge: some View {
        Label(label, systemImage: "folder.badge.plus")
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(Style.cool)
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(Style.ink.opacity(0.85), in: Capsule())
            .padding(.top, 6)
    }
}

/// 轨道最前面那道看不见的边界：拖过来就钉住。
///
/// 平时完全透明、不占宽度感知——它是一条"意图"而不是一个控件。只有当手里
/// 真的拖着一张还没钉住的卡时才亮起来（蓝色），因为只有那时候它才有事可做。
private struct PinBoundaryDropDelegate: DropDelegate {
    @Bindable var model: AppModel
    @Binding var isTargeted: Bool

    private var draggedItem: UUID? {
        guard case .item(let id) = model.outboundDrag,
              !model.isPinnedToFront(id) else { return nil }
        return id
    }

    func validateDrop(info: DropInfo) -> Bool { draggedItem != nil }

    func dropEntered(info: DropInfo) {
        guard draggedItem != nil else { return }
        withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
            isTargeted = true
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedItem != nil else { return nil }
        // dropEntered 在 SwiftUI 重排时偶尔丢；updated 是持续对账的最终权威。
        if !isTargeted {
            withAnimation(.spring(response: 0.26, dampingFraction: 0.84)) {
                isTargeted = true
            }
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        withAnimation(.easeOut(duration: 0.14)) { isTargeted = false }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedItem else {
            isTargeted = false
            return false
        }
        isTargeted = false
        model.completeOutboundDrop()
        // 边界紧挨钉住区的末尾，卡片落在这格就应追加到末尾；不是跳到
        // 整个钉住区第一张之前。
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            model.pinToFront(id)
        }
        return true
    }
}

/// 钉住区和普通区之间的分界。
///
/// 关键是不让**命中目标跟着空位一起移动**：旧实现把空位放在线左侧，边界一亮
/// 就向右逃离鼠标，立刻触发 dropExited；收回后鼠标又进入，形成进/出振荡，
/// 所以蓝线难触发、卡片不让位、松手后还可能留在半开状态。
///
/// 现在蓝线始终钉在本格左缘，28pt 的透明命中带也始终不动；只有它右边的
/// 幽灵卡位从 0 展开，把普通区卡片平滑推向右边。
private struct PinBoundary: View {
    @Bindable var model: AppModel
    @Binding var isTargeted: Bool
    let leavingZone: Bool
    let hasVisiblePinnedItems: Bool
    let height: CGFloat

    private var state: BoundaryHighlight {
        guard model.outboundDrag != nil else { return .none }
        if isTargeted { return .pinning }
        return leavingZone ? .unpinning : .none
    }

    private var showsLine: Bool {
        state != .none || hasVisiblePinnedItems
    }

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(lineColor)
                .frame(width: showsLine ? (state == .none ? 2 : 4) : 0)
                // 鼠标松开后 state 立即回 none，长蓝线直接缩成 26pt 的分界；
                // 不再依赖 outboundDrag 晚一拍清身份。
                .frame(height: state == .none ? (hasVisiblePinnedItems ? 26 : 0) : height * 0.9)
                .overlay {
                    if state == .pinning {
                        Capsule().fill(Style.cool).blur(radius: 5).opacity(0.55)
                    }
                }

            // 幽灵卡位永远在命中线的右边。线和命中带原地不动，只有普通区
            // 向右让开；避免目标自己逃离鼠标造成的 enter/exit 振荡。
            PinSlotPlaceholder(active: state == .pinning, height: height)
                .frame(width: state == .pinning ? PinCard.width * 0.66 : 0)
                .clipped()
        }
        .frame(height: height)
        .overlay(alignment: .leading) {
            Color.black.opacity(0.001)
                .frame(width: 28, height: height)
                .contentShape(Rectangle())
                .allowsHitTesting(model.outboundDrag?.itemID != nil)
                .onDrop(
                    of: [UTType.data],
                    delegate: PinBoundaryDropDelegate(model: model, isTargeted: $isTargeted)
                )
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: state)
        .help("拖到蓝线，钉在前面")
    }

    private var lineColor: Color {
        switch state {
        case .none: Style.cool.opacity(hasVisiblePinnedItems ? 0.38 : 0)
        case .pinning: Style.cool
        case .unpinning: Style.warning
        }
    }
}

/// 蓝线展开时出现的落点，不是一块无意义的透明空白。
private struct PinSlotPlaceholder: View {
    let active: Bool
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
            .fill(Style.cool.opacity(active ? 0.08 : 0))
            .overlay {
                RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                    .strokeBorder(
                        Style.cool.opacity(active ? 0.62 : 0),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])
                    )
            }
            .overlay {
                if active {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Style.cool)
                }
            }
            .frame(height: height)
    }
}

/// 边界此刻在说什么。蓝＝拖进来会被钉住，红＝拖出去会取消钉住。
enum BoundaryHighlight: Equatable {
    case none
    case pinning
    case unpinning
}

/// 组在轨道上的那一格。
///
/// 单独拆出来不只是为了类型检查器（那条修饰链在 ForEach 里直接超时）——
/// 组是**一个**格子：投放在格子上、拖拽的是格子、插入竖线画在格子两侧。
/// 成员卡只是它展开时的内部陈设，不是独立的轨道公民。
private struct GroupTrackCell: View {
    let group: CardGroup
    let members: [Item]
    @Bindable var model: AppModel
    let availableHeight: CGFloat
    @Binding var mergeTargetID: UUID?
    @Binding var reorderTargetID: UUID?
    @Binding var reorderInsertAfter: Bool

    /// 这次拖拽组接不接：别的卡（能合并或排序）或别的组（只排序）都接；
    /// 本组成员拖过自己组上空时不接——那是"拖出来"，要穿透到成员卡和轨道背景。
    private var acceptsCurrentDrag: Bool {
        switch model.outboundDrag {
        case .group(let id): return id != group.id
        case .item(let id): return !group.itemIDs.contains(id)
        case nil: return false
        }
    }

    var body: some View {
        CardGroupAccordion(
            group: group,
            members: members,
            model: model,
            availableHeight: availableHeight
        )
        .id(group.id)
        // 组的投放目标必须是最顶层的 overlay。
        //
        // 直接挂在单元上的话，展开态会被成员卡盖住：成员自己的 delegate 在
        // 视图树里更靠上、先接住指针，"放进这个组"永远轮不到。overlay 盖住
        // 整个单元；不接这次拖拽时完全不挡，成员卡照常工作。
        .overlay {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .allowsHitTesting(acceptsCurrentDrag)
                .onDrop(
                    of: [UTType.data],
                    delegate: CardGroupDropDelegate(
                        group: group,
                        model: model,
                        mergeTargetID: $mergeTargetID,
                        reorderTargetID: $reorderTargetID,
                        insertAfter: $reorderInsertAfter
                    )
                )
        }
        .overlay {
            MergeHalo(
                active: mergeTargetID == group.id,
                radius: Style.cardRadius + 4,
                label: "放进「\(group.name)」"
            )
        }
        .scaleEffect(mergeTargetID == group.id ? 1.03 : 1)
        .animation(
            .spring(response: 0.24, dampingFraction: 0.72),
            value: mergeTargetID == group.id
        )
        .overlay(alignment: .leading) {
            if reorderTargetID == group.id, !reorderInsertAfter {
                insertionIndicatorShape.offset(x: -5.5)
            }
        }
        .overlay(alignment: .trailing) {
            if reorderTargetID == group.id, reorderInsertAfter {
                insertionIndicatorShape.offset(x: 5.5)
            }
        }
    }

    private var insertionIndicatorShape: some View {
        Capsule()
            .fill(Style.accent)
            .frame(width: 3)
            .padding(.vertical, 6)
            .allowsHitTesting(false)
    }
}

/// 往一个已有分组里拖卡片。
///
/// 分组卡片自己也得能接住拖放，否则第一次合并之后就再也加不进第三张——
/// 组渲染成了另一种视图，而排序用的那个 delegate 只挂在普通卡片上。
private struct CardGroupDropDelegate: DropDelegate {
    let group: CardGroup
    @Bindable var model: AppModel
    @Binding var mergeTargetID: UUID?
    @Binding var reorderTargetID: UUID?
    @Binding var insertAfter: Bool

    private static let mergeZone: ClosedRange<CGFloat> = 0.3...0.7
    private var memberCount: Int { group.itemIDs.count }
    private var sheetCount: Int { min(2, max(1, memberCount - 1)) }
    private var isExpanded: Bool { model.expandedCardGroups.contains(group.id) }
    private var width: CGFloat {
        guard isExpanded else { return PinCard.width + CGFloat(sheetCount) * 7 }
        return 12 + 28 + 8 + CGFloat(memberCount) * PinCard.width
            + 8 * CGFloat(max(0, memberCount - 1))
    }

    private var drag: AppModel.OutboundDrag? { model.outboundDrag }

    private var accepts: Bool {
        switch drag {
        case .item(let id): !group.itemIDs.contains(id)
        case .group(let id): id != group.id
        case nil: false
        }
    }

    private func merges(at x: CGFloat) -> Bool {
        guard case .item = drag else { return false }
        if isExpanded {
            // 展开后每一张成员卡的正文都意味着"放进这个组"；只有整组最外侧
            // 各 34pt 是 before/after 换位。按整组 30%...70% 算会让第一张、
            // 最后一张的中心落在合并区外——明明放在组里面，结果插到了旁边。
            return x >= 34 && x <= width - 34
        }
        return Self.mergeZone.contains(x / max(width, 1))
    }

    func validateDrop(info: DropInfo) -> Bool { accepts }

    func dropEntered(info: DropInfo) {
        guard accepts else { return }
        insertAfter = info.location.x > width / 2
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard accepts else { return nil }
        if merges(at: info.location.x) {
            if mergeTargetID != group.id { mergeTargetID = group.id }
            if reorderTargetID != nil { reorderTargetID = nil }
            return DropProposal(operation: .copy)
        }
        if mergeTargetID == group.id { mergeTargetID = nil }
        if reorderTargetID != group.id { reorderTargetID = group.id }
        let next = info.location.x > width / 2
        if next != insertAfter { insertAfter = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if mergeTargetID == group.id { mergeTargetID = nil }
        if reorderTargetID == group.id { reorderTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard accepts, let drag else { return false }
        let merge = merges(at: info.location.x)
        let after = insertAfter
        mergeTargetID = nil
        reorderTargetID = nil
        model.completeOutboundDrop()

        switch drag {
        case .item(let id):
            guard let anchor = after ? group.itemIDs.last : group.itemIDs.first else { return false }
            if merge, let first = group.itemIDs.first {
                model.mergeCards(id, into: first)
            } else {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                    model.moveCard(id, anchor: anchor, after: after)
                }
            }
        case .group(let id):
            guard let anchor = after ? group.itemIDs.last : group.itemIDs.first else { return false }
            // 组和组只换位，永远不合并、不拆分。
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                model.moveGroup(id, anchor: anchor, after: after)
            }
        }
        return true
    }
}

/// 把卡片拖到轨道空白处 = 移出分组。
///
/// 这一层铺在所有卡片**后面**，只有落空的投放才会到它这里：拖到别的卡片上是
/// 合并或排序，那些 delegate 会先接住。所以"拖出来"和"拖到别处"用的是同一个
/// 动作，区别只在松手的位置——和手机上把图标从文件夹里拖到桌面完全一致。
private struct GroupDetachDropDelegate: DropDelegate {
    @Bindable var model: AppModel
    @Binding var isDetaching: Bool
    @Binding var boundary: BoundaryHighlight
    /// 边缘感应带用同一个 delegate，只是额外驱动自动翻页。共用一份"落到空白
    /// 处等于离开当前区"的解释——两处各写一份，必然有一处漏掉。
    var edgeScroll: ((Bool) -> Void)?
    var edgeForward = false

    func validateDrop(info: DropInfo) -> Bool {
        // 边缘带即使这次投放没有语义也要接住：不接的话它上面的投放会掉进
        // 下面的目标，用户在边缘松手就变成一次意外的换位。
        edgeScroll != nil || model.leaveZoneIntent() != .none
    }

    func dropEntered(info: DropInfo) {
        edgeScroll?(true)
        switch model.leaveZoneIntent() {
        case .none: break
        case .detachGroup: isDetaching = true
        case .unpin, .unpinGroup: boundary = .unpinning
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        edgeScroll?(false)
        isDetaching = false
        if boundary == .unpinning { boundary = .none }
    }

    func performDrop(info: DropInfo) -> Bool {
        edgeScroll?(false)
        isDetaching = false
        boundary = .none
        return model.applyLeaveZoneDrop()
    }
}

private struct PinReorderDropDelegate: DropDelegate {
    let targetID: UUID
    let canReorder: Bool
    @Bindable var model: AppModel
    @Binding var reorderTargetID: UUID?
    @Binding var insertAfter: Bool
    /// 松手就会合并的那张卡。指针停在中段时点亮它。
    @Binding var mergeTargetID: UUID?
    /// 版本合集只排序不合并——它代表的是"同一份文档的几版"，再往里塞一张
    /// 别的东西没有意义。
    var allowsMerge = true
    /// 这一格的**真实**宽度。分区判定按比例算，写死一个数就会算错位置。
    var width: CGFloat = PinCard.width
    let perform: (UUID, UUID, Bool) -> Void

    private var drag: AppModel.OutboundDrag? { model.outboundDrag }

    func validateDrop(info: DropInfo) -> Bool {
        guard canReorder, let drag else { return false }
        switch drag {
        case .item(let id): return id != targetID
        case .group(let id):
            // 组不能进钉住区：PinnedLaneStore 只认识 item id，给出插入竖线却
            // 永远无法落到那个位置，会看起来像换位失效。
            guard !model.isPinnedToFront(targetID) else { return false }
            return model.cardGroupByID(id)?.itemIDs.contains(targetID) != true
        }
    }

    /// 卡片中段这一块是"合并"，两侧是"排序"。
    ///
    /// 用位置分区而不是 iOS 那种"悬停一会儿才成组"：横向轨道上拖一张卡去
    /// 远处，路上必然扫过好几张卡，靠停留计时会一路误触发。而按位置分区时，
    /// **只有松手的那一刻才算数**——路过多少张都无所谓。
    private static let mergeZone: ClosedRange<CGFloat> = 0.34...0.66

    private func isMergePosition(_ x: CGFloat) -> Bool {
        allowsMerge && Self.mergeZone.contains(x / width)
    }

    /// 能不能合。整组不能被拖进别的组，见 `AppModel.mergeCards`。
    private var canMerge: Bool {
        if case .item = drag { return true }
        return false
    }

    /// 翻面的迟滞死区。
    ///
    /// 原来是拿中线直接比：指针停在中线附近时，几个像素的手抖就让插入点在
    /// 左右之间反复翻转，那根竖线看着就是在抽搐。改成"越过中线还要再走一段
    /// 才算数"——已经在左边就得过 62% 才翻到右边，反之要退到 38%，
    /// 中间那 24% 是稳定带。
    private static let flipForward: CGFloat = 0.62
    private static let flipBackward: CGFloat = 0.38

    private func resolvedInsertAfter(_ x: CGFloat) -> Bool {
        let ratio = x / width
        return insertAfter
            ? ratio >= Self.flipBackward      // 已经在右边，退够了才回左边
            : ratio > Self.flipForward        // 已经在左边，进够了才去右边
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        reorderTargetID = targetID
        // 刚进来时还没有"上一次"可参考，用中线定初值。
        insertAfter = info.location.x > width / 2
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else { return nil }
        let merging = canMerge && isMergePosition(info.location.x)
        if merging {
            if mergeTargetID != targetID { mergeTargetID = targetID }
            // 合并时不画插入竖线：那根线说的是"插到这两张中间"，
            // 和"并进这一张里"是相反的意思，同时出现会互相拆台。
            if reorderTargetID != nil { reorderTargetID = nil }
            return DropProposal(operation: .copy)
        }
        if mergeTargetID == targetID { mergeTargetID = nil }
        if reorderTargetID != targetID { reorderTargetID = targetID }
        let next = resolvedInsertAfter(info.location.x)
        // dropUpdated 每秒调用几十次。值没变就别写回去——写一次就是一次
        // 视图刷新，那本身也是抖动的来源之一。
        if next != insertAfter { insertAfter = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        if reorderTargetID == targetID { reorderTargetID = nil }
        if mergeTargetID == targetID { mergeTargetID = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard canReorder, let drag else { return false }
        let after = insertAfter
        let merging = canMerge && isMergePosition(info.location.x)
        reorderTargetID = nil
        mergeTargetID = nil
        model.completeOutboundDrop()

        switch drag {
        case .group(let groupID):
            withAnimation(.spring(response: 0.3, dampingFraction: 0.84)) {
                model.moveGroup(groupID, anchor: targetID, after: after)
            }
        case .item(let id):
            guard id != targetID else { return false }
            if merging {
                model.mergeCards(id, into: targetID)
            } else {
                perform(id, targetID, after)
            }
        }
        return true
    }
}

/// 卡片轨道只有一个滚动权威：底层 NSScrollView。
///
/// SwiftUI 的 ScrollPosition 是双向状态，用户每滚一像素都会让包含所有卡片的
/// StashWorkspace 重算；再叠 `.viewAligned` 更会和箭头争抢位置。这个控制器
/// 直接读写真实 NSClipView，触控板和箭头共享同一个 offset，没有第二套状态。
@MainActor
private final class CardTrackScrollController: NSObject {
    weak var scrollView: NSScrollView?
    var onAvailability: ((Bool, Bool) -> Void)?
    private var connectionOwner: ObjectIdentifier?
    private var isPaging = false

    func connect(_ scrollView: NSScrollView?, owner: ObjectIdentifier) {
        if self.scrollView === scrollView {
            connectionOwner = owner
            publishAvailability()
            return
        }
        disconnect()
        self.scrollView = scrollView
        connectionOwner = owner
        guard let scrollView else { return }
        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(geometryChanged),
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        if let document = scrollView.documentView {
            document.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(geometryChanged),
                name: NSView.frameDidChangeNotification,
                object: document
            )
        }
        publishAvailability()
    }

    func disconnect(owner: ObjectIdentifier? = nil) {
        if let owner, connectionOwner != owner { return }
        NotificationCenter.default.removeObserver(self)
        scrollView = nil
        connectionOwner = nil
        isPaging = false
    }

    @objc private func geometryChanged() { publishAvailability() }

    private var range: (current: CGFloat, minimum: CGFloat, maximum: CGFloat, viewport: CGFloat)? {
        guard let scrollView, let document = scrollView.documentView else { return nil }
        let clip = scrollView.contentView
        let minimum = document.bounds.minX
        let maximum = max(minimum, document.bounds.maxX - clip.bounds.width)
        return (clip.bounds.origin.x, minimum, maximum, clip.bounds.width)
    }

    private func publishAvailability() {
        guard let range else { onAvailability?(false, false); return }
        onAvailability?(
            range.current > range.minimum + 2,
            range.current < range.maximum - 2
        )
    }

    func scrollToStart() {
        guard let scrollView, let range else { return }
        scrollView.contentView.scroll(to: NSPoint(x: range.minimum, y: scrollView.contentView.bounds.origin.y))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        publishAvailability()
    }

    @discardableResult
    func page(forward: Bool, fraction: CGFloat = 1, duration: Double = 0.2) -> Bool {
        guard !isPaging, let scrollView, let range else { return false }
        let step = max(120, range.viewport - 48) * fraction
        let target = min(
            max(range.minimum, range.current + (forward ? step : -step)),
            range.maximum
        )
        guard abs(target - range.current) > 1 else { return false }
        let clip = scrollView.contentView
        isPaging = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            clip.animator().setBoundsOrigin(NSPoint(x: target, y: clip.bounds.origin.y))
        } completionHandler: { [weak self] in
            self?.isPaging = false
            self?.publishAvailability()
        }
        return true
    }
}

private struct CardTrackScrollProbe: NSViewRepresentable {
    let controller: CardTrackScrollController
    let onAvailability: (Bool, Bool) -> Void

    final class ProbeView: NSView {
        weak var controller: CardTrackScrollController?
        weak var connectedScrollView: NSScrollView?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            connectLater()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connectLater()
        }

        private func connectLater() {
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, superview != nil else { return }
                connectedScrollView = enclosingScrollView
                controller?.connect(connectedScrollView, owner: ObjectIdentifier(self))
            }
        }
    }

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView(frame: .zero)
        view.controller = controller
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        controller.onAvailability = onAvailability
        view.controller = controller
        Task { @MainActor [weak view] in
            await Task.yield()
            guard let view, view.superview != nil else { return }
            view.connectedScrollView = view.enclosingScrollView
            controller.connect(view.connectedScrollView, owner: ObjectIdentifier(view))
        }
    }

    static func dismantleNSView(_ view: ProbeView, coordinator: ()) {
        view.controller?.disconnect(owner: ObjectIdentifier(view))
    }
}

private struct StashWorkspace: View {
    @Bindable var model: AppModel
    @State private var hoveringTrack = false
    /// AppKit 单一滚动权威；引用对象内部 offset 变化不触发 SwiftUI 卡片树重算。
    @State private var scrollController = CardTrackScrollController()
    /// 只有越过左右端点时才变化，箭头因此只重绘两次，不是每像素一次。
    @State private var canPageBackward = false
    @State private var canPageForward = false
    /// 正在拖动的卡片当前悬在哪个目标上、插到它前面还是后面。
    @State private var reorderTargetID: UUID?
    @State private var reorderInsertAfter = false
    @State private var privacyDropTargeted = false
    @State private var mergeTargetID: UUID?
    @State private var isDetachingFromGroup = false
    @State private var boundaryHighlight: BoundaryHighlight = .none
    @State private var isOverPinBoundary = false
    /// 页签切换过渡用的透明度。1 是常态；切页签那一瞬间先压到 0.35 再弹回。
    @State private var trackFade: Double = 1
    @State private var tabTransitionTask: Task<Void, Never>?
    @State private var platformRowExpanded = false
    @State private var folderRowExpanded = false
    @State private var edgeScrollTask: Task<Void, Never>?

    /// 搜索出结果时上半屏是模型的回答，下半屏是它推荐的真实 Pin。
    /// 此时不显示分类页签——分类会把命中的条目悄悄过滤掉。
    private var isAnswering: Bool {
        model.isSearching
            && (model.isStreamingSearchAnswer
                || !model.searchAnswer.isEmpty
                || model.searchAnswerError != nil)
    }

    private var answerViewportHeight: CGFloat {
        if model.searchAnswerError != nil { return 90 }
        return switch model.searchAnswer.count {
        case 0..<160: 90
        case 160..<480: 106
        default: 120
        }
    }

    private var cardTrackHeight: CGFloat {
        max(91, NotchLayout.workspaceContentHeight - answerViewportHeight - 1)
    }

    // MARK: - 拖拽结束

    /// 所有投放视觉状态一次清干净。
    ///
    /// 鼠标监听只有 AppModel 一套：local + global 两个句柄都保存、都能移除；
    /// 这里订阅它在 mouseUp 当下发出的 signal。旧实现自己又装一套监听，还用
    /// `local ?? global` 只保存其中一个——另一个永久泄漏；多拖几次就有多份
    /// 回调互相抢状态，也是蓝条时收时不收的原因之一。
    private func clearDragFeedback() {
        isOverPinBoundary = false
        isDetachingFromGroup = false
        boundaryHighlight = .none
        mergeTargetID = nil
        reorderTargetID = nil
    }

    /// 这一格属于钉住区吗。组和版本合集不参与钉住（钉住会先把卡从组里拿出来）。
    private func isPinnedEntry(_ entry: AppModel.DisplayEntry) -> Bool {
        if case .item(let item) = entry { return model.isPinnedToFront(item.id) }
        return false
    }

    /// 检索结果按相关度排序，在那里重排没有意义——只允许浏览态下拖。
    private var canReorderCards: Bool {
        model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.isPerformingSemanticSearch
    }

    var body: some View {
        VStack(spacing: 0) {
            if isAnswering {
                // 滚动能力本来就有；问题只是可视窗口长期只剩八十来点高。
                // 按回答长度分三档分配高度，短回答不占空，中长回答优先看更多，
                // 到 148pt 后才依靠既有滚动。
                SearchAnswerBlock(model: model)
                    .frame(maxWidth: .infinity)
                    .frame(height: answerViewportHeight)
                Hairline()
            } else {
                // 标题 + 筛选行始终占同样高度。旧实现只有链接 / 有分组时才插入
                // 26pt 的 platformRow，还把 tabs 高度从 36 改成 30；切页签时卡片
                // 整排瞬移 26–32pt，再叠上淡入，看起来就是抖。
                // 页签的任何状态都不再改变尺寸（高亮只是描边+底色），
                // 所以这一行按静止态给高度就够，不必为放大态留余量。
                tabs.frame(height: 30)
                platformRow.frame(height: 26)
            }

            if model.visibleItems.isEmpty {
                EmptyStash(model: model)
                    .frame(maxWidth: .infinity, maxHeight: isAnswering ? cardTrackHeight : .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            // 一次取好，循环里查表。原来每张卡都调一次
                            // `model.versionSlots`，而它内部要按可见列表重算
                            // 缓存键——一屏几十张卡就是几十遍全表扫描。
                            let slots = model.versionSlots
                            let entries = model.displayEntries
                            // 分界线画在**两区之间**，不是轨道最前面。
                            //
                            // 一开始把它焊在了队首，钉住区一有卡片就不对了：
                            // 那条线跑到了钉住的卡片前面，而它要分开的两拨东西
                            // 都在它右边。它标的是"这儿往左是钉住区"，所以
                            // 位置只能是钉住区最后一张之后。
                            let firstLoose = entries.firstIndex { !isPinnedEntry($0) }
                                ?? entries.count
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                if index == firstLoose {
                                    PinBoundary(
                                        model: model,
                                        isTargeted: $isOverPinBoundary,
                                        leavingZone: boundaryHighlight == .unpinning,
                                        hasVisiblePinnedItems: firstLoose > 0,
                                        height: isAnswering
                                            ? max(78, cardTrackHeight - 16) : PinCard.height
                                    )
                                }
                                switch entry {
                                case .family(let collection, let members):
                                    VersionAccordion(
                                        collection: collection,
                                        members: members,
                                        model: model,
                                        availableHeight: isAnswering
                                            ? max(78, cardTrackHeight - 16)
                                            : PinCard.height
                                    )
                                    .id(collection.id)
                                    .transition(.opacity)
                                    // 版本合集也得接住投放。没有这一句时，
                                    // 落在它身上的拖拽会穿过去砸到轨道背景那层
                                    // "离开当前区"上——用户想把卡片插到版本堆
                                    // 旁边，实际发生的却是"移出分组"或"取消钉住"，
                                    // 而且卡片纹丝不动。
                                    .onDrop(
                                        of: [UTType.data],
                                        delegate: PinReorderDropDelegate(
                                            targetID: collection.id,
                                            canReorder: canReorderCards,
                                            model: model,
                                            reorderTargetID: $reorderTargetID,
                                            insertAfter: $reorderInsertAfter,
                                            mergeTargetID: $mergeTargetID,
                                            allowsMerge: false,
                                            width: PinCard.width + 14,
                                            perform: { draggedID, anchorID, after in
                                                withAnimation(
                                                    .spring(response: 0.3, dampingFraction: 0.8)
                                                ) {
                                                    model.moveCard(
                                                        draggedID, anchor: anchorID, after: after
                                                    )
                                                }
                                            }
                                        )
                                    )
                                    .overlay(alignment: .leading) {
                                        if reorderTargetID == collection.id, !reorderInsertAfter {
                                            insertionIndicator.offset(x: -5.5)
                                        }
                                    }
                                    .overlay(alignment: .trailing) {
                                        if reorderTargetID == collection.id, reorderInsertAfter {
                                            insertionIndicator.offset(x: 5.5)
                                        }
                                    }
                                case .cardGroup(let group, let members):
                                    GroupTrackCell(
                                        group: group,
                                        members: members,
                                        model: model,
                                        availableHeight: isAnswering
                                            ? max(78, cardTrackHeight - 16)
                                            : PinCard.height,
                                        mergeTargetID: $mergeTargetID,
                                        reorderTargetID: $reorderTargetID,
                                        reorderInsertAfter: $reorderInsertAfter
                                    )
                                    .transition(.opacity)
                                case .item(let item):
                                let isLiftedSource = reorderTargetID != nil && model.draggingItemID == item.id
                                let slot = slots[item.id]
                                PinCard(
                                    item: item,
                                    model: model,
                                    availableHeight: isAnswering
                                        ? max(78, cardTrackHeight - 16)
                                        : PinCard.height,
                                    versionSlot: slot
                                )
                                    .id(item.id)
                                    .transition(.opacity)
                                    // 松手就会并进这张卡：整张亮起来 + 微微放大，
                                    // 和"插到旁边"那根竖线是两种完全不同的反馈，
                                    // 用户在松手之前就知道会发生哪一件事。
                                    // 只让光环和这一下放大参与动画。
                                    //
                                    // `.animation(_:value:)` 作用于整棵子树：
                                    // 挂在卡片上时，合并高亮一变，卡片里所有
                                    // 可动的属性（缩略图、文字、底栏图标）都被
                                    // 一起卷进这条 spring，那是抖动的来源。
                                    .overlay { MergeHalo(active: mergeTargetID == item.id) }
                                    .scaleEffect(mergeTargetID == item.id ? 1.04 : 1)
                                    // 放大和光环要在**同一个**作用域里。上一版把
                                    // 动画塞进了 overlay 的闭包，只罩住光环，
                                    // 而放大在外面——于是它是硬跳的。
                                    .animation(
                                        .spring(response: 0.24, dampingFraction: 0.72),
                                        value: mergeTargetID == item.id
                                    )
                                    // 残影修复：拖拽副本跟着指针走时，原位那张保持全亮，
                                    // 两张叠着看就是"残影"。拖进列表范围后把原位压暗。
                                    // 0.25 太狠：拖拽一开始原位卡就像"消失"了，
                                    // 用户以为拖丢了。0.62 足够和跟随指针的拖拽
                                    // 预览区分开，又明显还在原位。
                                    .opacity(isLiftedSource ? 0.62 : 1)
                                    .animation(.easeOut(duration: 0.15), value: isLiftedSource)
                                    .overlay(alignment: .leading) {
                                        if reorderTargetID == item.id && !reorderInsertAfter {
                                            insertionIndicator.offset(x: -5.5)
                                        }
                                    }
                                    .overlay(alignment: .trailing) {
                                        if reorderTargetID == item.id && reorderInsertAfter {
                                            insertionIndicator.offset(x: 5.5)
                                        }
                                    }
                                    .onDrop(
                                        // public.data 是所有拖拽内容的公共父类型：自家卡片的
                                        // 文本/文件表示都落在它下面，外部 Finder 拖拽也会命中——
                                        // 但 validateDrop 只认 draggingItemID，外部拖入进不来。
                                        of: [UTType.data],
                                        delegate: PinReorderDropDelegate(
                                            targetID: item.id,
                                            canReorder: canReorderCards,
                                            model: model,
                                            reorderTargetID: $reorderTargetID,
                                            insertAfter: $reorderInsertAfter,
                                            mergeTargetID: $mergeTargetID,
                                            allowsMerge: model.activeTab == .all,
                                            perform: { draggedID, anchorID, after in
                                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                                    model.moveCard(draggedID, anchor: anchorID, after: after)
                                                }
                                            }
                                        )
                                    )
                                }
                            }
                            // 全都钉住了的话，分界线在队尾。
                            if firstLoose == entries.count, !entries.isEmpty {
                                PinBoundary(
                                    model: model,
                                    isTargeted: $isOverPinBoundary,
                                    leavingZone: boundaryHighlight == .unpinning,
                                    hasVisiblePinnedItems: true,
                                    height: isAnswering
                                        ? max(78, cardTrackHeight - 16) : PinCard.height
                                )
                            }
                        }
                        .padding(.vertical, 8)
                        // 探针必须住在 documentView 内部，才能稳定拿到
                        // enclosingScrollView；挂在 ScrollView 外层 background 上时
                        // 某些 SwiftUI 层级会得到 nil，箭头就“看得到但点不动”。
                        .background {
                            CardTrackScrollProbe(
                                controller: scrollController,
                                onAvailability: { backward, forward in
                                    if backward != canPageBackward { canPageBackward = backward }
                                    if forward != canPageForward { canPageForward = forward }
                                }
                            )
                            .frame(width: 0, height: 0)
                        }
                        // 这里**不挂**隐式动画。
                        //
                        // 投放的每一条路径都已经用 withAnimation 显式包住了换位，
                        // 再挂一条 `.animation(value:)` 就是同一次位移被两个事务
                        // 同时插值：格子按 A 曲线走，滚动内容按 B 曲线走，中途那
                        // 几帧画在互相错开的位置上——换位之后翻页会重叠闪烁，
                        // 就是这么来的。一次变化只能有一个动画驱动者。
                        // 异步来的重排（归组、折叠）由各自的调用点自己包动画。
                        // 内容顶部对齐贴着页签往下排；剩余空间留在底部是"生长空间"，
                        // 上下居中则会读出两道无意义的黑边。
                        .frame(maxHeight: .infinity, alignment: .top)
                    }
                    // 左右留白用 contentMargins 而不是给内容加 padding。
                    //
                    // 两者画出来一样，但 scrollTo 只认前者：用 padding 时，
                    // "滚到第一张"会把那 12pt 一起滚出视野，第一张直接贴住左边，
                    // 和平时的间距对不上——双击标题栏跳回开头就会看到这个。
                    .contentMargins(.horizontal, 12, for: .scrollContent)

                    // 「拖到空白处 = 离开当前的区」这一层必须铺满整条轨道，
                    // 而不是贴在卡片那一排的背景上——那个背景正好就是卡片本身
                    // 的大小，右边那片真正的空白根本不在它的范围里，怎么拖都
                    // 落不进来。
                    .background {
                        Color.black.opacity(0.001)
                            .contentShape(Rectangle())
                            .onDrop(
                                of: [UTType.data],
                                delegate: GroupDetachDropDelegate(
                                    model: model,
                                    isDetaching: $isDetachingFromGroup,
                                    boundary: $boundaryHighlight
                                )
                            )
                            .overlay { DetachHint(active: isDetachingFromGroup) }
                    }
                    .onChange(of: model.scrollToFirstCardRequest) {
                        scrollController.scrollToStart()
                    }
                    // 一行只看得到三张，后面还有多少全靠猜。悬停时在两边给出
                    // 把手：横向滚动照常可用，但不再是唯一入口。
                    .overlay(alignment: .leading) { pager(forward: false) }
                    .overlay(alignment: .trailing) { pager(forward: true) }
                    // 拖到边缘自动翻页。没有这一下，一次拖动只能在眼前这三张
                    // 之间换位——想把第一张挪到第十张后面，得先手动滚过去、
                    // 再回来重新拿起它。
                    .overlay(alignment: .leading) { edgeScroller(forward: false) }
                    .overlay(alignment: .trailing) { edgeScroller(forward: true) }
                .opacity(trackFade)
                .frame(height: isAnswering ? cardTrackHeight : nil)
                .frame(maxHeight: isAnswering ? nil : CGFloat.infinity)
                // 拖拽一结束就把所有投放态的残留清掉。
                //
                // `dropExited` 只在指针**离开某个目标**时才来；如果用户在目标
                // 之外松手、或者把卡片拖出了面板，最后停留的那个目标不会收到
                // 任何通知，它的高亮就永久留在那儿——界面上表现为"什么都没做，
                // 边界却一直撑着一个空位"。
                .onChange(of: model.dragEndSignal) { clearDragFeedback() }
                .onChange(of: model.outboundDrag) { _, drag in
                    if drag == nil { clearDragFeedback() }
                }
                // 展开/折叠动画只留在对应 Accordion 内部。这里不能给整条
                // ScrollView 挂隐式动画——它会把程序化滚动偏移也卷进去，
                // 点击箭头时卡片和滚动容器用两条曲线移动，产生粘滞感。
            }
        }
        .onHover { hoveringTrack = $0 }
        .animation(.smooth(duration: 0.26), value: isAnswering)
    }

    /// 往前 / 往后翻一屏。每次挪三张，正好是一屏的宽度。
    /// 插入位置指示：目标卡片左/右缘的一根亮色竖线，跟 Finder 列表重排同款。
    private var insertionIndicator: some View {
        Capsule()
            .fill(Style.accent)
            .frame(width: 3)
            .padding(.vertical, 6)
            .transition(.opacity.combined(with: .scale(scale: 0.6)))
            .allowsHitTesting(false)
    }

    private func canPage(forward: Bool) -> Bool {
        forward ? canPageForward : canPageBackward
    }

    /// 边缘自动滚动的感应带。
    ///
    /// 做成透明的投放区而不是监听指针位置：拖拽期间 SwiftUI 不派发 hover，
    /// 只有 drop 目标能知道"指针正悬在我上面"。它永远返回 false，不消费这次
    /// 投放——真正的落点判定仍然归卡片上的 `PinReorderDropDelegate`。
    @ViewBuilder
    private func edgeScroller(forward: Bool) -> some View {
        // pager 和拖拽边缘感应带互斥：普通浏览只有 pager 收事件；拖拽时换成
        // 边缘带。两层叠在同一批像素上时，顶层的 drop strip 会截胡底下的按钮。
        if model.outboundDrag != nil, canPage(forward: forward) {
            Color.clear
                .frame(width: forward ? 28 : 8)
                .contentShape(Rectangle())
                .onDrop(
                    of: [UTType.data],
                    delegate: GroupDetachDropDelegate(
                        model: model,
                        isDetaching: $isDetachingFromGroup,
                        boundary: $boundaryHighlight,
                        edgeScroll: { active in
                            if active { startEdgeScroll(forward: forward) }
                            else { stopEdgeScroll() }
                        },
                        edgeForward: forward
                    )
                )
        }
    }

    private func startEdgeScroll(forward: Bool) {
        stopEdgeScroll()
        edgeScrollTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            while !Task.isCancelled, model.outboundDrag != nil {
                guard page(forward: forward, fraction: 0.28, duration: 0.16) else { return }
                try? await Task.sleep(for: .milliseconds(230))
            }
        }
    }

    private func stopEdgeScroll() {
        edgeScrollTask?.cancel()
        edgeScrollTask = nil
    }

    @ViewBuilder
    private func pager(forward: Bool) -> some View {
        // 可见性只看"这个方向还有没有东西"。挂在 outboundDrag 上是错的：
        // 拖拽身份万一没清（投放被拒、拖到应用外取消），箭头就再也不回来。
        // 走不动就**不画**，而不是画一个暗掉的。
        // 一个按不动的按钮摆在那儿，用户只会反复去点它。
        if canPage(forward: forward) {
            let dragging = model.outboundDrag != nil
            let enabled = true
            Button { _ = page(forward: forward) } label: {
                Image(systemName: forward ? "chevron.right" : "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(enabled ? Style.secondary : Style.tertiary.opacity(0.35))
                    // 命中框在 Button label **里面**，不是靠外面的 padding 假装。
                    .frame(width: 30, height: 42)
                    .background(.black.opacity(enabled ? 0.58 : 0.22), in: Capsule())
                    .overlay { Capsule().strokeBorder(Style.stroke.opacity(enabled ? 1 : 0.3)) }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled || dragging)
            // 看得见就能点：旧实现常显却要等 hover 才开 hit-testing，
            // 第一次点击先让 hover 生效、第二次才真按到按钮。
            .allowsHitTesting(enabled && !dragging)
            .opacity(dragging ? 0.28 : (hoveringTrack ? 0.96 : 0.62))
            .animation(.easeOut(duration: 0.14), value: hoveringTrack)
            .animation(.easeOut(duration: 0.14), value: dragging)
            .help(forward ? "看后面的" : "看前面的")
        }
    }

    /// 按真实视口距离翻页。展开/折叠/普通卡都只是连续内容；控制器直接
    /// 操作 NSClipView，不经过 SwiftUI 双向 ScrollPosition，不重建卡片树。
    @discardableResult
    private func page(forward: Bool, fraction: CGFloat = 1, duration: Double = 0.2) -> Bool {
        scrollController.page(forward: forward, fraction: fraction, duration: duration)
    }

    /// 先让旧内容淡下去，再换页签，再让新内容浮上来。直接在 activeTab 的
    /// onChange 里做淡入，会先闪出一帧新内容、再突然变暗，那不是过渡。
    ///
    /// 90ms 出场 + 160ms 入场：够眼睛看见连续性，又比一次普通点击短。
    /// Task latest-wins，快速连点只落到最后一页。
    private func selectTab(_ tab: AppModel.Tab) {
        guard tab != model.activeTab else { return }
        tabTransitionTask?.cancel()
        tabTransitionTask = Task { @MainActor in
            withAnimation(.easeOut(duration: 0.09)) { trackFade = 0.18 }
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else {
                // 被下一次点击取消也要把亮度还回去，否则整条轨道永远停在 0.18。
                withAnimation(.easeOut(duration: 0.12)) { trackFade = 1 }
                return
            }
            if tab == .privateSpace, !model.isPrivateSpaceUnlocked {
                model.unlockPrivateSpace()
            }
            model.activeTab = tab
            // 新布局下一拍才生成。先让它布好局，再淡入，避免边算布局边动。
            await Task.yield()
            withAnimation(.easeOut(duration: 0.16)) { trackFade = 1 }
            tabTransitionTask = nil
        }
    }

    private func tabTint(_ tab: AppModel.Tab) -> Color {
        if tab == .privateSpace, model.isPrivateSpaceUnlocked { return Style.accent }
        return model.activeTab == tab ? Style.primary : Style.tertiary
    }

    private func tabBackground(_ tab: AppModel.Tab) -> Color {
        if tab == .privateSpace, model.isPrivateSpaceUnlocked { return Style.accentMuted }
        return model.activeTab == tab ? Style.surfaceHover : .clear
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                ForEach(model.tabs, id: \.self) { tab in
                    Button {
                        selectTab(tab)
                    } label: {
                        HStack(spacing: 4) {
                            if tab == .privateSpace {
                                Image(systemName: model.isPrivateSpaceUnlocked ? "lock.open.fill" : "lock.fill")
                                    .font(.system(size: 9.5, weight: .semibold))
                            }
                            Text(tab.label)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(tabTint(tab))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background {
                            let targeted = privacyDropTargeted && tab == .privateSpace
                            RoundedRectangle(cornerRadius: 6)
                                .fill(targeted ? Style.accentMuted : tabBackground(tab))
                                .overlay {
                                    // 高亮**不改变尺寸**，只加一圈描边和底色。
                                    //
                                    // 之前用 scaleEffect(1.12) 把整个页签放大：
                                    // 一行里的页签是紧挨着的，放大就会压到邻居身上，
                                    // 上下也会顶出这一行被裁掉。一个"能放这儿"的
                                    // 提示不该靠改变布局尺寸来表达。
                                    RoundedRectangle(cornerRadius: 6)
                                        .strokeBorder(Style.accent, lineWidth: targeted ? 1.5 : 0)
                                }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    // 拖一张卡到锁上就是收进隐私空间。复用已有的拖拽管道，
                    // 不需要任何新按钮——这是"不影响布局"最直接的办法。
                    .onDrop(of: [UTType.data], isTargeted: tab == .privateSpace ? $privacyDropTargeted : .constant(false)) { _ in
                        guard tab == .privateSpace, let dragged = model.draggingItemID else { return false }
                        let targets = model.privacyTargets(anchor: dragged)
                        Task { await model.setPrivate(targets, isPrivate: true) }
                        return true
                    }
                    .animation(.easeOut(duration: 0.16), value: privacyDropTargeted)
                }
            }
            .padding(.horizontal, 12)
        }
        // 双击这一条回到第一张卡，和 macOS 点标题栏回到顶部是同一个约定。
        // 挂在整条上而不是每个页签上：页签本身单击已经有语义（切换分类），
        // 双击要落在"这一条"这个整体上，空白处双击同样管用。
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.requestScrollToFirstCard() }
        .help("双击回到第一张")
    }

    /// 链接页签下的平台 / 域名归类。
    ///
    /// 默认叠成一摞，点开才展开。面板一共 600 点宽，摊开四五个带名字的胶囊
    /// 就把整行占满了，而多数时候用户并不在按平台找——让它平时只占一小摞
    /// 图标的宽度，需要时再弹开。
    @ViewBuilder
    private var platformRow: some View {
        // 这行只有两种明确用途，不能混：
        // - 「全部」只显示用户自己整理的手动分组；
        // - 「链接」只显示平台 / 域名。
        // 旧实现两份都无条件读取，所以链接页上会出现「剪贴板截图」「2027 校招」
        // 这种分组胶囊；而这些组在链接页过滤后可能一张成员卡都没有，点进去
        // 只剩空白——界面在承诺一个根本不存在的入口。
        let groups: [AppModel.LinkGroup] = model.activeTab == .kind(.link)
            ? model.availableLinkGroups : []
        let folders: [CardGroup] = CardGroupProjection.shouldShowManualFilters(tabKind: model.activeTab.kind)
            ? model.availableCardGroups : []
        return ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    // 手动分组排在最前：那是用户自己起的名字，比按平台自动
                    // 归的类更接近他此刻脑子里的分类。
                    //
                    // 和平台那一排同一套折叠语言：默认收成一摞图标，点开才摊成
                    // 带名字的胶囊。分组名字都不短（"名企进校园"），一字排开时
                    // 两三个就把整条轨道占满了。
                    if folderRowExpanded {
                        ForEach(folders) { folderChip($0) }
                    } else if !folders.isEmpty {
                        collapsedFolderStack(folders)
                    }
                    if !folders.isEmpty, groups.count > 1 {
                        Divider().frame(height: 12).padding(.horizontal, 2)
                    }
                    if groups.count > 1 {
                        if platformRowExpanded {
                            platformChip(nil)
                            ForEach(groups, id: \.self) { platformChip($0) }
                        } else {
                            collapsedPlatformStack(groups)
                        }
                    }
                }
                .padding(.horizontal, 12)
            }
        .frame(height: 26)
        .opacity(groups.count > 1 || !folders.isEmpty ? 1 : 0)
        .allowsHitTesting(groups.count > 1 || !folders.isEmpty)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: platformRowExpanded)
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: folderRowExpanded)
        .onChange(of: model.platformRowShouldCollapse) {
            platformRowExpanded = false
            folderRowExpanded = false
        }
    }

    /// 折叠态：图标互相压着排成一摞，像一副收拢的扇子。
    private func collapsedPlatformStack(_ groups: [AppModel.LinkGroup]) -> some View {
        Button {
            platformRowExpanded = true
        } label: {
            HStack(spacing: -7) {
                ForEach(Array(groups.prefix(6).enumerated()), id: \.element) { index, group in
                    groupGlyph(group, size: 18)
                        // 加一圈底色描边，叠着时才分得出是几枚而不是一团。
                        .overlay { Circle().strokeBorder(Style.shell, lineWidth: 2) }
                        .clipShape(Circle())
                        .zIndex(Double(groups.count - index))
                        // 展开时从这一摞里散开，收拢时再叠回去。
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if groups.count > 6 {
                    Text("+\(groups.count - 6)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Style.tertiary)
                        .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Style.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Style.stroke) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("按平台筛选")
    }

    @ViewBuilder
    private func groupGlyph(_ group: AppModel.LinkGroup, size: CGFloat) -> some View {
        switch group {
        case .platform(let platform):
            PlatformGlyph(platform: platform, size: size)
        case .domain(let host):
            DomainBadge(host: host, fontSize: size * 0.5)
                .frame(width: size, height: size)
        }
    }

    /// 折叠态：分组图标叠成一摞，点开才摊出名字。和平台那一排同款。
    private func collapsedFolderStack(_ folders: [CardGroup]) -> some View {
        Button { folderRowExpanded = true } label: {
            HStack(spacing: -7) {
                ForEach(Array(folders.prefix(6).enumerated()), id: \.element.id) { index, _ in
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Style.cool)
                        .frame(width: 18, height: 18)
                        .background(Style.cool.opacity(0.22), in: Circle())
                        // 加一圈底色描边，叠着时才分得出是几枚而不是一团。
                        .overlay { Circle().strokeBorder(Style.shell, lineWidth: 2) }
                        .zIndex(Double(folders.count - index))
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if folders.count > 6 {
                    Text("+\(folders.count - 6)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Style.tertiary)
                        .padding(.leading, 10)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Style.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Style.stroke) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("按分组筛选")
    }

    /// 顶部那排里的分组胶囊。点一下只看这一组，再点回到全部。
    private func folderChip(_ group: CardGroup) -> some View {
        let selected = model.activeCardGroup == group.id
        return Button {
            model.activeCardGroup = selected ? nil : group.id
            // 选完就收回去，把宽度还给卡片。
            if selected { folderRowExpanded = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill").font(.system(size: 9, weight: .semibold))
                Text(group.name)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                Text("\(group.itemIDs.count)")
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .opacity(0.7)
            }
            .foregroundStyle(selected ? Style.primary : Style.cool)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(
                selected ? Style.cool.opacity(0.28) : Style.cool.opacity(0.12), in: Capsule()
            )
            .overlay { Capsule().strokeBorder(Style.cool.opacity(selected ? 0.7 : 0.3)) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(selected ? "回到全部" : "只看「\(group.name)」")
        .contextMenu {
            Button("解散分组", role: .destructive) { model.dissolveCardGroup(group.id) }
        }
    }

    private func platformChip(_ group: AppModel.LinkGroup?) -> some View {
        let selected = model.activeLinkGroup == group
        return Button {
            model.activeLinkGroup = group
            // 点"全部"就是"我不按平台找了"——顺手收回那一摞，把宽度还给卡片。
            if group == nil { platformRowExpanded = false }
        } label: {
            HStack(spacing: 4) {
                if let group {
                    groupGlyph(group, size: 13)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                Text(group?.displayName ?? "全部")
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? Style.primary : Style.tertiary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(selected ? Style.accentMuted : Style.surface, in: Capsule())
            .overlay { if selected { Capsule().strokeBorder(Style.accent.opacity(0.5)) } }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(group?.displayName ?? "不按平台收窄")
    }
}

/// 平台记号。有素材就用素材，没有就退回"首字母 + 稳定配色"的色块。
///
/// 退回而不是留空：这一排的作用就是让人一眼扫出平台，缺一个格子会让整排
/// 读起来是断的。配色由平台名哈希决定，同一个平台每次都是同一个颜色——
/// 随机色会让用户建立不起记忆。
struct PlatformGlyph: View {
    let platform: LinkPlatform
    var size: CGFloat = 16

    var body: some View {
        if let name = platform.iconResourceName,
           let image = NSImage(named: name) ?? Bundle.module.image(forResource: name) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        } else {
            // 没素材就复用 DomainBadge：色相由名字稳定决定，同一个平台每次
            // 都是同一个颜色。不再自己算一份——两份哈希迟早会分叉，同一个
            // 平台在卡片上和筛选条上显示成两个颜色。
            DomainBadge(
                host: platform.rawValue,
                fontSize: size * 0.58,
                monogram: String(platform.displayName.prefix(1))
            )
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        }
    }
}

/// 流式回答。文本随 SSE 增量整体替换，不做逐字动画——那会让长回答一直抖。
private struct SearchAnswerBlock: View {
    @Bindable var model: AppModel

    private static let answerAnchor = "mnemo.searchAnswer"
    private static let tailAnchor = "mnemo.searchAnswer.tail"

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: model.searchAnswerError == nil ? "sparkles" : "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(model.searchAnswerError == nil ? Style.accent : Style.warning)
                Text(model.searchAnswerError == nil ? "AI 检索" : "AI 检索不可用")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Style.secondary)
                if model.isStreamingSearchAnswer {
                    ProcessingDots(tint: Style.cool, dotSize: 3)
                        .frame(width: 22, height: 12)
                        .transition(.opacity)
                }
                Spacer(minLength: 0)
            }

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    Group {
                        if model.searchAnswerError != nil || model.searchAnswer.isEmpty {
                            Text(displayText)
                                .font(.system(size: 12))
                                .foregroundStyle(textTint)
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                        } else {
                            // 模型写的是 Markdown，直接当纯文本显示会满屏 ** 和 -
                            MarkdownText(raw: model.searchAnswer)
                        }
                    }
                    .id(Self.answerAnchor)
                    Color.clear.frame(height: 1).id(Self.tailAnchor)
                }
                // 流式输出时把视图钉在末尾，不用用户自己追着往下滚。
                .onChange(of: model.searchAnswer) {
                    guard model.isStreamingSearchAnswer else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(Self.tailAnchor, anchor: .bottom)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.18), value: model.isStreamingSearchAnswer)
    }

    private var displayText: String {
        if let error = model.searchAnswerError { return error }
        if model.searchAnswer.isEmpty { return "正在读你的库…" }
        return model.searchAnswer
    }

    private var textTint: Color {
        if model.searchAnswerError != nil { return Style.secondary }
        return model.searchAnswer.isEmpty ? Style.tertiary : Style.primary
    }
}

private struct EmptyStash: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(Style.tertiary)
                .symbolEffect(.bounce, options: .repeat(.periodic(3, delay: 2)))
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Style.primary)
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Style.tertiary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(.horizontal, 32)
    }

    private var isSearching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var title: String {
        if isSearching { return "没有找到相关内容" }
        return switch model.activeTab {
        case .all: "还没有 Pin"
        case .privateSpace:
            model.isPrivateSpaceUnlocked ? "隐私空间是空的" : "隐私空间已锁定"
        case .kind(let kind): "还没有\(kindLabel(kind))"
        }
    }

    private var detail: String {
        if isSearching { return "换一种描述，或按回车让 AI 重新检索" }
        return switch model.activeTab {
        case .all: "把文件拖向刘海，复制的文字与截图也会出现在这里"
        case .privateSpace:
            model.isPrivateSpaceUnlocked
                ? "把卡片拖到锁图标上，或右键「移入隐私空间」"
                : "点上面的锁，用触控 ID 或开机密码解锁"
        case .kind(.file), .kind(.pdf), .kind(.binary): "把对应文件拖向刘海即可收纳"
        case .kind(.image): "复制截图或把图片拖向刘海"
        case .kind(.link): "复制链接或把网页地址拖向刘海"
        case .kind(.text): "复制文字，或用快捷键收纳当前选区"
        }
    }

    private var symbol: String {
        if isSearching { return "magnifyingglass" }
        return switch model.activeTab {
        case .all: "tray"
        case .privateSpace: model.isPrivateSpaceUnlocked ? "lock.open" : "lock"
        case .kind(.image): "photo"
        case .kind(.link): "link"
        case .kind(.text): "text.alignleft"
        case .kind(.pdf): "doc.richtext"
        case .kind(.file): "doc"
        case .kind(.binary): "shippingbox"
        }
    }

    private func kindLabel(_ kind: ItemKind) -> String {
        switch kind {
        case .image: "图片"
        case .link: "链接"
        case .text: "文字"
        case .pdf: " PDF"
        case .file: "文件"
        case .binary: "其他内容"
        }
    }
}


private struct PinCard: View {
    /// 单行卡片。高度用来放大缩略图，而不是留成空白。
    static let width: CGFloat = 176
    static let height: CGFloat = 128

    let item: Item
    @Bindable var model: AppModel
    /// 可用高度。出现 AI 回答时上半屏被占走，卡片必须跟着缩，否则不是"挤"
    /// 而是被整块裁掉——底栏和缩略图下沿直接消失在轨道外面。
    var availableHeight: CGFloat = height
    /// 这张卡在版本族里的位置。nil = 它不属于任何一族。
    var versionSlot: AppModel.VersionSlot?
    @State private var hovering = false
    @State private var editingAnnotation = false
    @State private var resolvedURL: URL?
    @State private var thumbnail: NSImage?

    /// 缩略图跟着卡片一起缩。按剩余高度线性给，留出标题两行和底栏的位置。
    private var thumbnailSide: CGFloat {
        min(74, max(40, availableHeight - 54))
    }

    /// 太矮的时候底栏先让位：那一行是次要操作，右键菜单里都有；
    /// 而标题和缩略图没了，卡片就认不出是哪一条了。
    private var showsFooter: Bool { availableHeight >= 104 }

    private var selected: Bool {
        model.detailItem?.id == item.id || model.selectedIDs.contains(item.id)
    }
    private var copied: Bool { model.copiedItemID == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 9) {
                    content
                    Spacer(minLength: 0)
                    if let recommendation = model.retrievalRecommendation(for: item.id) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Style.accent)
                            .help(recommendation.reason)
                    }
                }
                Spacer(minLength: 0)
            }
            // 点击**和拖拽**都只作用在内容区（缩略图 + 文字）。
            //
            // 两者原来都挂在整张卡上，和底部那排图标按钮抢同一次鼠标事件：
            // - 点击竞争让"点删除结果复制了"；
            // - `onDrag` 更隐蔽——按下时鼠标只要漂移一两个像素就被判成拖拽，
            //   按钮那一下就没了。这正是"删除一会能用一会不能用"的成因，
            //   因为它取决于你手抖没抖。
            // 两个手势一起收进内容区，按钮那一行才真正没有竞争者。
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.preview(item) }
            // ⌘ 点是多选，不是复制。批量操作唯一需要的新状态就是这个集合，
            // 视觉上直接复用卡片已有的选中边框，不加任何新控件。
            .modifier(CommandClickSelection(model: model, itemID: item.id))
            .onTapGesture { model.copy(item) }
            .onDrag {
                PinDragProvider.make(item: item, resolvedURL: resolvedURL, model: model)
            } preview: {
                dragPreview
            }

            if showsFooter {
            HStack(spacing: 5) {
                // 版本标在底栏，不在右上角。
                //
                // 右上角是标题的第二行——一个角标压上去，正好盖住这张卡最该
                // 被读到的那几个字。底栏本来就是放"这张卡是什么"的地方，
                // 而且这一排的按钮都好点。
                if let versionSlot {
                    VersionChip(slot: versionSlot, model: model, item: item)
                }
                // 手机同步过来的内容单独标出来。它和"来自哪个应用"回答的不是
                // 同一个问题：那是哪个软件，这是哪台设备——而后者决定了这条
                // 内容为什么会在没有任何 Mac 操作的情况下自己出现在这里。
                if let device = NearbyDeviceOrigin.kind(of: item.id) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Style.cool)
                        .help("从你的 \(device.displayName) 同步过来")
                        .accessibilityLabel("来自\(device.displayName)")
                }
                // 来源应用角标本来压在缩略图右下角。文字和码类卡片已经不画
                // 缩略图了，角标必须有新的落点，否则"这是从哪儿复制来的"
                // 在最常见的两类卡片上直接消失。
                if !isMediaLayout, let icon = SourceAppBadge.icon(for: item) {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 11, height: 11)
                        .clipShape(RoundedRectangle(cornerRadius: 2.5, style: .continuous))
                        .help("来自 \(SourceAppBadge.name(for: item) ?? "其他应用")")
                }
                if isTransientClipboardItem {
                    Image(systemName: "clock")
                    Text(expirationLabel)
                        .monospacedDigit()
                } else {
                    Image(systemName: storageSymbol)
                    Text(storageLabel)
                }
                if item.aiPrivacyBlocked {
                    Text("· 本地处理")
                        .foregroundStyle(Style.cool)
                }
                if item.indexedAt != nil {
                    // 已经建好向量、能被语义检索召回。没有这个标记的话，
                    // 用户没法知道为什么有些东西搜得到、有些搜不到。
                    Image(systemName: "sparkle.magnifyingglass")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(Style.cool)
                        .help("已建立语义索引，可被自然语言检索召回")
                        .accessibilityLabel("已建立语义索引")
                }
                if let hit = model.semanticHit(for: item.id) {
                    if let page = hit.pageNumber {
                        Text("· 第 \(page) 页")
                    } else if hit.source == .imageOCR {
                        Text("· OCR 命中")
                    } else if hit.source == .imageCaption {
                        Text("· 画面命中")
                    } else if hit.source == .linkPage {
                        Text("· 网页命中")
                    }
                    if hit.isUsingStaleVector {
                        Text("· 索引中")
                            .foregroundStyle(Style.accent)
                    }
                }
                Spacer(minLength: 0)
                if copied {
                    Label("已复制", systemImage: "checkmark").foregroundStyle(Style.cool)
                } else if hovering {
                    HStack(spacing: 1) {
                        if isClipboardItem { pinToggle }
                        Button { model.copy(item) } label: {
                            Image(systemName: "doc.on.doc")
                                .frame(width: 24, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("复制")
                        Button { Task { await model.trash(item.id) } } label: {
                            Image(systemName: "trash")
                                .frame(width: 24, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Style.warning)
                        .help("移到回收站，可撤销")
                    }
                } else if isClipboardItem {
                    pinToggle
                }
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(Style.tertiary)
            }
        }
        .padding(8)
        .frame(width: Self.width, height: availableHeight, alignment: .topLeading)
        .background(selected ? Style.accentMuted : (hovering ? Style.surfaceHover : Style.surface),
                    in: RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                .strokeBorder(selected ? Style.accent.opacity(0.82) : (hovering ? Style.strongStroke : Style.stroke))
        }
        .shadow(color: hovering ? Color.black.opacity(0.22) : .clear, radius: hovering ? 8 : 0, y: hovering ? 3 : 0)
        // 这一层只留右键菜单与悬停反馈；点击和拖拽都已经在内容区处理掉了。
        .contentShape(RoundedRectangle(cornerRadius: Style.cardRadius))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.14), value: hovering)
        .contextMenu {
            Button("预览") { model.preview(item) }
            Button("复制") { model.copy(item) }
            if item.kind == .link || resolvedURL != nil {
                Button("打开") { model.open(item) }
            }
            if item.kind == .link {
                // 抽取器改好之后，老卡片里存的还是当年那份失败结果。
                // 给一个手动重来的入口，不必等自动补抓。
                Button("重新解析链接") { model.reparseLink(item.id) }
            }
            if item.origin == .clipboard {
                // 一条动作，一个入口。
                //
                // 这里原来有两项："锁定保留"和"保留，不再自动消失"——文案不同、
                // 干的是同一件事（都是把这条剪贴板内容钉住），而临时条目上两项
                // 会同时出现，看起来像两个不同的功能。留措辞更能说清后果的那
                // 一句，条件不同就换说法。
                Button(pinMenuTitle) {
                    Task { await model.toggleClipboardPin(item.id) }
                }
            }
            if item.isPrivate {
                Button("移出隐私空间") {
                    let targets = model.privacyTargets(anchor: item.id)
                    Task { await model.setPrivate(targets, isPrivate: false) }
                }
            } else {
                Button(privacyMenuTitle) {
                    let targets = model.privacyTargets(anchor: item.id)
                    Task { await model.setPrivate(targets, isPrivate: true) }
                }
            }
            Button("重命名与标签…") { editingAnnotation = true }
            if model.cardGroup(of: item.id) != nil {
                Button("移出分组") { model.detachFromGroup(item.id) }
            }
            Button(model.isTodo(item.id) ? "移出待办" : "标为待办") {
                Task { await model.setTodo(item.id, enabled: !model.isTodo(item.id)) }
            }
            if item.aiPrivacyBlocked && !item.allowsSensitiveAI {
                Button("仅为此 Pin 允许 AI 处理") {
                    Task { await model.allowSensitiveAI(for: item.id) }
                }
            }
            Divider()
            Button("移到回收站", role: .destructive) {
                Task { await model.trash(item.id) }
            }
        }
        .popover(isPresented: $editingAnnotation, arrowEdge: .bottom) {
            AnnotationEditor(item: item, suggestions: model.frequentTags) { title, tags in
                editingAnnotation = false
                Task { await model.setUserAnnotation(item.id, title: title, tags: tags) }
            }
        }
        .task(id: "\(item.id)-\(model.linkCoverGeneration(for: item.id))") {
            do {
                resolvedURL = try await model.library.resolvedFileURL(for: item)
                thumbnail = item.kind == .link
                    ? LinkCoverStore.cachedImage(for: item.id)
                    : await ThumbnailStore.shared.image(
                        item: item,
                        url: resolvedURL,
                        logicalSize: 72
                    )
            } catch {
                resolvedURL = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("单击预览，可拖出到其他应用")
        .accessibilityAction { model.preview(item) }
    }

    // MARK: 正文排版

    /// 卡片正文的三种排版。选哪一种只看一件事：这条 Pin 上最值得一眼看到的是什么。
    ///
    /// 之前所有类型共用一套「62pt 缩略图 + 两行标题 + 两行灰色小字」。对文字来说
    /// 这是双输：缩略图里那点微缩正文根本读不出来，却吃掉整整三分之一的卡片宽度，
    /// 剩下的窄栏又把标题挤成"我想加一个功…"。卡片尺寸不变，把宽度分配重来一遍。
    private enum ContentLayout {
        /// 取餐码 / 验证码 / 快递单号：那串码就是全部内容，其余都是包装。
        case code(ClipboardTextSignature)
        /// 纯文字：没有可看的缩略图，整宽留给真正能读的正文。
        case prose
        /// 图片、PDF、链接、文件：缩略图才是主要识别线索。
        case media
    }

    private var presentation: TodoPresentationMetadata? {
        TodoPresentationStore.item(item.id)
    }

    private var isMediaLayout: Bool {
        if case .media = layout { return true }
        return false
    }

    private var layout: ContentLayout {
        guard item.kind == .text, case .inline(let text) = item.holding else { return .media }
        if let signature = ClipboardTextSignature.detect(text) { return .code(signature) }
        return .prose
    }

    /// 拖拽时跟着指针的那一张。
    ///
    /// 不给显式预览的话，SwiftUI 会拿 `.onDrag` 所挂视图的快照——而它挂在
    /// **内容区**上（点击和拖拽都收在那儿，才不会和底栏按钮抢同一次鼠标）。
    /// 内容区外面才是卡面：圆角、底色、描边全在上一层。于是拖起来的是一块
    /// 没有背景的图和字，看着就是"变透明了"。
    private var dragPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            content
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: Self.width, height: availableHeight, alignment: .topLeading)
        .background(
            Style.surface,
            in: RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
                .strokeBorder(Style.strongStroke)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layout {
        case .code(let signature): codeContent(signature)
        case .prose: proseContent
        case .media: mediaContent
        }
    }

    /// 码类卡片：直接把码印在卡片上，不必点开、不必复制去别处看。
    private func codeContent(_ signature: ClipboardTextSignature) -> some View {
        HStack(alignment: .center, spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(signature.tint.opacity(0.16))
                Image(systemName: signature.icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(signature.tint)
            }
            .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 1) {
                Text(signature.accessibilityLabel)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(Style.tertiary)
                Text(signature.code)
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Style.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
        }
    }

    /// 文字卡片：标题和正文常常是同一句话（本地命名就是取的首行），
    /// 那就只留正文——同样的高度里能多读两行，而不是把一句话印两遍。
    private var proseContent: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !titleRepeatsBody {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Style.primary)
                    .lineLimit(1)
            }
            Text(bodyExcerpt)
                .font(.system(size: 11))
                .foregroundStyle(titleRepeatsBody ? Style.secondary : Style.tertiary)
                .lineSpacing(1.5)
                .lineLimit(titleRepeatsBody ? 4 : 3)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 右下角这一格被品牌 / 平台徽标占用了吗。判据必须和下面真正画徽标的
    /// 两个分支逐字一致，否则会出现"让了位但没人来"或"没让位却撞上"。
    private var hasCornerBadge: Bool {
        if let presentation, presentation.isMeaningful { return true }
        if let platform = model.linkPlatform(of: item), platform.iconResourceName != nil {
            return true
        }
        // 链接兜底那枚浏览器图标也占着右下角，来源应用角标同样要让位。
        return model.browserForLink(item) != nil
    }

    private var mediaContent: some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack(alignment: .bottomTrailing) {
                PinThumbnail(
                    item: item,
                    image: thumbnail,
                    side: thumbnailSide,
                    cornerIsTaken: hasCornerBadge
                )
                if let presentation, presentation.isMeaningful {
                    ServiceBrandIcon(metadata: presentation, size: 22)
                        .offset(x: 4, y: 4)
                } else if let platform = model.linkPlatform(of: item),
                          platform.iconResourceName != nil {
                    // 和麦当劳那个徽标同一个位置、同一个尺寸——那套视觉已经
                    // 立住了，链接没有理由另起一套。区别只在它可点：单击就是
                    // 打开这条链接，双击卡片仍是原来的行为。
                    Button { model.open(item) } label: {
                        PlatformGlyph(platform: platform, size: 22)
                            .overlay {
                                RoundedRectangle(cornerRadius: 22 * 0.24, style: .continuous)
                                    .strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5)
                            }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: 4)
                    .help(model.openLinkHint(item))
                } else if let bundleID = model.browserForLink(item),
                          let icon = LinkOpener.browserIcon(bundleID) {
                    // 认不出平台的链接（论文站、公司官网…）用浏览器图标顶上。
                    //
                    // 只画这一枚：平台图标已经在的时候再挂一枚浏览器，说的是
                    // 同一件事（"点这里打开"），而两枚小圆点挤在一张 74pt 的
                    // 缩略图上，先被牺牲的是缩略图本身。
                    Button { model.openInBrowser(item) } label: {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 20, height: 20)
                            .clipShape(Circle())
                            .overlay {
                                Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 1.5)
                            }
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: 4)
                    .help(model.openInBrowserHint(item))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Style.primary)
                    .lineLimit(2)
                Text(detailLine)
                    .font(.system(size: 10))
                    .foregroundStyle(Style.tertiary)
                    // 文件名和域名是一整串没有断点的字符：给它两行，它就从单词
                    // 中间劈开（"Communicati / on_Semanti"），比直接截断还难看。
                    // 一行截尾，宁可少看几个字符，也不把词拆碎。
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// 正文摘录。换行和连续空白压平成单空格：多行原文在窄栏里会留下大片空洞，
    /// 同样的行数装不下几个字。
    private var bodyExcerpt: String {
        if let hit = model.semanticHit(for: item.id), !hit.snippet.isEmpty {
            return hit.snippet
        }
        guard case .inline(let text) = item.holding else { return detailLine }
        return text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 标题只是正文开头的复述吗。
    ///
    /// 本地命名取的就是首行，AI 命名跑完之前所有文字卡片都是这个样子；
    /// 判据放宽到"标题的前 8 个字出现在正文开头"，避免因为标题末尾多一个
    /// 省略号或标点就判成不重复。
    private var titleRepeatsBody: Bool {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, item.titledLocally else { return false }
        let head = String(title.prefix(8))
        guard head.count >= 2 else { return false }
        return bodyExcerpt.hasPrefix(head)
    }

    private var detailLine: String {
        if let recommendation = model.retrievalRecommendation(for: item.id),
           !recommendation.reason.isEmpty {
            return recommendation.reason
        }
        if let hit = model.semanticHit(for: item.id), !hit.snippet.isEmpty {
            return hit.snippet
        }
        switch item.holding {
        case .inline(let text):
            return item.kind == .link
                ? URL(string: text)?.host() ?? text
                : text.replacingOccurrences(of: "\n", with: " ")
        case .copy(_, let size), .reference(_, let size):
            return "\(item.originalFilename ?? item.title) · \(ByteFormat.short(size))"
        }
    }

    /// 选了多张时菜单要说清楚这一下影响几张，否则用户以为只动了当前这张。
    private var privacyMenuTitle: String {
        let count = model.privacyTargets(anchor: item.id).count
        return count > 1 ? "移入隐私空间（\(count) 张）" : "移入隐私空间"
    }

    /// 锁定这一项该怎么说。"锁定保留"已经说清了后果，不必再补一句解释。
    private var pinMenuTitle: String { item.isPinned ? "取消锁定" : "锁定保留" }

    private var isTransientClipboardItem: Bool {
        item.origin == .clipboard && !item.isPinned
    }

    /// 剪贴板条目上常驻这一个图钉：没锁定时点它锁定，锁定后点它放回临时轨道。
    /// 锁定之后就把入口藏起来，等于只能删掉重来。
    private var isClipboardItem: Bool { item.origin == .clipboard }

    @ViewBuilder
    private var pinToggle: some View {
        Button { Task { await model.toggleClipboardPin(item.id) } } label: {
            Image(systemName: item.isPinned ? "pin.fill" : "pin")
                .frame(width: 24, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(item.isPinned ? Style.accent : Style.tertiary)
        .help(item.isPinned ? "取消锁定，放回临时轨道" : "锁定保留")
        .accessibilityLabel(item.isPinned ? "取消锁定" : "锁定保留")
    }

    /// 剪贴板条目按条数滚动淘汰，没有倒计时可言——写"还剩几小时"是假的。
    /// 卡片底栏只有一行的宽度，写整句会折行并挤掉旁边的图标；"固定后长期保留"
    /// 这件事由旁边那个图钉图标本身说明，tooltip 里再写全。
    private var expirationLabel: String { "临时" }

    private var storageSymbol: String {
        switch item.holding {
        case .inline: "text.alignleft"
        case .copy: "internaldrive"
        case .reference: "link"
        }
    }

    private var storageLabel: String {
        switch item.holding {
        case .inline: item.kind == .link ? "链接" : "文字"
        case .copy: "副本"
        case .reference: "引用"
        }
    }
}

/// 没有封面时的域名徽标。
///
/// 抓不到 og:image 也抓不到站点图标时，原来退回一个通用链条图标——一排链接
/// 于是长得一模一样，只能读标题区分。用域名生成稳定的色相加首字母，扫一眼
/// 就能认出"这是 google 那条"，而且不需要任何网络请求。
struct DomainBadge: View {
    let host: String
    var fontSize: CGFloat = 20
    /// 外部指定的字样。平台徽标用中文首字——"哔"比域名首字母 B 更好认。
    var monogram: String?

    var body: some View {
        let hue = Double(Self.seed(host) % 360) / 360
        LinearGradient(
            colors: [
                Color(hue: hue, saturation: 0.46, brightness: 0.60),
                Color(hue: hue, saturation: 0.60, brightness: 0.38),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Text(monogram ?? Self.monogram(host))
                .font(.system(size: fontSize, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
    }

    /// 取可辨识的那一段：mail.google.com → google，github.com → github。
    static func monogram(_ host: String) -> String {
        let parts = host.lowercased()
            .replacingOccurrences(of: "www.", with: "")
            .split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? "")
        return name.first.map { String($0).uppercased() } ?? "#"
    }

    /// 同一个域名永远同一个颜色；换台机器也一样，因为不依赖 hashValue 的随机种子。
    private static func seed(_ host: String) -> Int {
        var value = 5_381
        for scalar in host.lowercased().unicodeScalars {
            value = (value &* 33 &+ Int(scalar.value)) & 0xFFFF
        }
        return value
    }
}

/// 来源应用的图标。
///
/// 从微信聊天里拖进来的文件和从访达拖进来的长得一模一样，卡片上认不出。
/// 容器路径里写着对方的 bundle id，据此取系统里那个应用的真实图标——
/// 不用自己画，也自动支持 QQ、飞书这些别的来源。
@MainActor
enum SourceAppBadge {
    private static var cache: [String: NSImage?] = [:]
    private static var names: [String: String?] = [:]

    static func icon(for item: Item) -> NSImage? {
        guard let id = bundleID(for: item) else { return nil }
        if let cached = cache[id] { return cached }
        let image = applicationURL(id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache[id] = image
        return image
    }

    static func name(for item: Item) -> String? {
        guard let id = bundleID(for: item) else { return nil }
        if let cached = names[id] { return cached }
        let value = applicationURL(id).map { FileManager.default.displayName(atPath: $0.path) }
        names[id] = value
        return value
    }

    private static func bundleID(for item: Item) -> String? {
        DroppedSourceTrust.sourceApplicationBundleID(forPath: item.originalSourcePath)
    }

    private static func applicationURL(_ id: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }
}

/// 剪贴板文字里的高频结构化内容：取餐/取件码、验证码、快递单号。
///
/// 命中时卡片缩略图直接展示编码本身——比一枚灰图标有用得多。
/// 检测全部要求关键词先行，绝不凭裸数字猜，避免把普通文本误判成码。
private enum ClipboardTextSignature {
    case pickupCode(String)
    case verificationCode(String)
    case trackingNumber(String)

    var code: String {
        switch self {
        case .pickupCode(let c), .verificationCode(let c), .trackingNumber(let c): c
        }
    }

    var icon: String {
        switch self {
        case .pickupCode: "takeoutbag.and.cup.and.straw.fill"
        case .verificationCode: "lock.shield.fill"
        case .trackingNumber: "shippingbox.fill"
        }
    }

    var tint: Color {
        switch self {
        case .pickupCode: Style.accent
        case .verificationCode: Style.cool
        case .trackingNumber: Style.warning
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .pickupCode: "取餐/取件码"
        case .verificationCode: "验证码"
        case .trackingNumber: "快递单号"
        }
    }

    /// 检测本身住在 MnemoCore 的 `ClipboardSignal` 里，和待办提取共用同一
    /// 套正则。之前两边各写一份，改一处漏一处——卡片上认得出的码，待办提取
    /// 未必认得出，反过来也一样。这里只做"领域结论 → 视觉表现"的翻译。
    static func detect(_ text: String) -> ClipboardTextSignature? {
        switch ClipboardSignal.detect(text) {
        case .pickupCode(let code): .pickupCode(code)
        case .verificationCode(let code): .verificationCode(code)
        case .trackingNumber(let code): .trackingNumber(code)
        case nil: nil
        }
    }
}

/// 普通文字的真实内容预览：取前几行小字排进缩略图，底部渐隐。一眼认出内容，比灰图标有信息量。
private struct TextSnippetPreview: View {
    let text: String

    private var snippet: String {
        let cleaned = text
            .replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(220))
    }

    var body: some View {
        Text(snippet)
            .font(.system(size: 5.8, weight: .medium))
            .foregroundStyle(.white.opacity(0.52))
            .lineSpacing(1.7)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(6)
            // 底部渐隐：暗示下面还有内容，而不是被裁掉。
            .mask(
                LinearGradient(
                    colors: [.black, .black, .black.opacity(0.25)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

/// 取餐码 / 验证码 / 快递单号的专属缩略图：类别图标 + 编码本体。
private struct CodeBadge: View {
    let signature: ClipboardTextSignature

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: signature.icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(signature.tint)
            Text(signature.code)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Style.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 3)
        .background(
            LinearGradient(
                colors: [signature.tint.opacity(0.16), signature.tint.opacity(0.05)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(signature.accessibilityLabel) \(signature.code)")
    }
}

/// 用户手动归的一组卡片，像文件夹一样叠着。
///
/// 和版本合集共用同一套折叠 / 展开的动效语言（一摞纸、点开摊出来），但用
/// **另一个颜色**：版本合集是程序认出来的关系，手动分组是用户自己的分类，
/// 两摞叠在同一条轨道上时必须一眼分得出谁是谁。
private struct CardGroupAccordion: View {
    let group: CardGroup
    let members: [Item]
    @Bindable var model: AppModel
    var availableHeight: CGFloat = PinCard.height

    @State private var hovering = false
    @State private var renaming = false
    @State private var draftName = ""
    @State private var thumbnails: [UUID: NSImage?] = [:]

    /// 这次拖拽组接不接：别的卡（能合并或排序）或别的组（只排序）都接；
    /// 本组成员拖过自己组上空时不接——那是"拖出来"，要穿透到成员卡和轨道背景。
    private var acceptsCurrentDrag: Bool {
        switch model.outboundDrag {
        case .group(let id): return id != group.id
        case .item(let id): return !group.itemIDs.contains(id)
        case nil: return false
        }
    }

    private var tint: Color { Style.cool }
    private var isExpanded: Bool { model.expandedCardGroups.contains(group.id) }
    /// 纸边错开多少。悬停时错得更开一点，像被手指拨了一下。
    /// 悬停时纸边错得更开。占位按最大那一档算，见 `collapsed` 的 frame：
    /// 只有画出来的位置在动，这一格占多宽从头到尾不变。
    private static let hoverTile: (x: CGFloat, y: CGFloat) = (9, 7)
    private var tile: (x: CGFloat, y: CGFloat) { hovering ? Self.hoverTile : Self.restTile }
    /// **布局**用的那一份，永远是静止值。
    ///
    /// 让 frontHeight 跟着 hover 走会连锁：卡面高度变 → 缩略图边长变 →
    /// 文字重排。鼠标一进来整张卡的字就跳一下，那不是"响应"，是抖动。
    /// 动效只让后面几张纸动，前面这张的尺寸从头到尾不变。
    private static let restTile: (x: CGFloat, y: CGFloat) = (7, 5)
    private var sheetDepths: [Int] { Array(1...min(2, max(1, members.count - 1))) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
    }

    var body: some View {
        Group {
            if isExpanded { expanded } else { collapsed }
        }
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isExpanded)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
        .contextMenu {
            Button("重命名分组…") { beginRenaming() }
            Button(isExpanded ? "折叠" : "展开") { model.toggleCardGroup(group.id) }
            Divider()
            Button("解散分组", role: .destructive) { model.dissolveCardGroup(group.id) }
        }
        .popover(isPresented: $renaming, arrowEdge: .bottom) {
            GroupNameEditor(name: $draftName) { value in
                renaming = false
                model.renameCardGroup(group.id, to: value)
            }
        }
        // 刚拖出来的新组立刻问名字：这一刻用户脑子里正想着"这几张是一类"，
        // 过后再补名字要重新回忆一遍。
        .onChange(of: model.groupAwaitingName) { _, awaiting in
            guard awaiting == group.id else { return }
            model.groupAwaitingName = nil
            beginRenaming()
        }
    }

    private func beginRenaming() {
        draftName = group.name
        renaming = true
    }

    private var collapsed: some View {
        ZStack(alignment: .topLeading) {
            ForEach(sheetDepths.reversed(), id: \.self) { depth in
                shape
                    .fill(Style.ink)
                    .overlay { shape.fill(tint.opacity(0.2 - Double(depth) * 0.05)) }
                    .overlay {
                        shape.strokeBorder(
                            tint.opacity(0.55 - Double(depth) * 0.14), lineWidth: 1
                        )
                    }
                    .frame(width: PinCard.width, height: frontHeight)
                    .offset(x: CGFloat(depth) * tile.x, y: CGFloat(depth) * tile.y)
                    .shadow(color: Color.black.opacity(0.25), radius: 4, x: 1, y: 1)
            }
            folderFace
                .frame(width: PinCard.width, height: frontHeight, alignment: .topLeading)
                .background { shape.fill(Style.ink) }
                .overlay { shape.fill(tint.opacity(0.06)) }
                .overlay {
                    shape.strokeBorder(tint.opacity(hovering ? 0.6 : 0.38), lineWidth: 1)
                }
                .clipShape(shape)
                .shadow(color: Color.black.opacity(0.32), radius: 6, x: 2, y: 2)
        }
        .frame(
            width: PinCard.width + CGFloat(sheetDepths.count) * Self.hoverTile.x,
            height: availableHeight,
            alignment: .topLeading
        )
        .contentShape(shape)
        // 折叠时整摞就是一个独立实体：拖拽 payload 只有 groupID，绝不借
        // 第一张成员卡。点击展开，拖动搬整组，两种手势都落在同一张文件夹脸上。
        .onDrag { PinDragProvider.make(groupID: group.id, name: group.name, model: model) }
        .onTapGesture { model.toggleCardGroup(group.id) }
        .help("\(group.name) · \(members.count) 张，点开查看")
        .transition(.opacity)
    }

    /// 折叠态画的是**文件夹自己**，不是里面第一张卡。
    ///
    /// 之前直接摆第一张卡的完整卡面，读出来是"一张叫 xxx 的卡片顺便贴了个
    /// 文件夹标签"——组名被挤在标题旁边，而卡片正文占满了整张脸。文件夹要被
    /// 一眼认出来靠的是名字和"里面有什么"，所以：缩略图换成成员的九宫格
    /// （像手机上的应用文件夹），标题位置让给组名，副标题列成员的名字。
    private var folderFace: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 9) {
                memberGrid
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(tint)
                        Text(group.name)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Style.primary)
                            .lineLimit(1)
                    }
                    Text(memberSummary)
                        .font(.system(size: 10))
                        .foregroundStyle(Style.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            HStack(spacing: 5) {
                Text("\(members.count) 张")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(tint)
                    .padding(.horizontal, 6)
                    .frame(height: 16)
                    .background(tint.opacity(0.16), in: Capsule())
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? tint : Style.tertiary)
            }
        }
        .padding(8)
    }

    /// 最前面那张的高度：整摞外框减去后面几层往下错开的那一段。
    private var frontHeight: CGFloat {
        availableHeight - CGFloat(sheetDepths.count) * Self.hoverTile.y
    }

    /// 成员缩略图拼成的小格子。数量决定几宫格，最多四张。
    private var memberGrid: some View {
        let side = min(74, max(40, frontHeight - 54))
        let cell = (side - 3) / 2
        return LazyVGrid(
            columns: [GridItem(.fixed(cell), spacing: 3), GridItem(.fixed(cell), spacing: 3)],
            spacing: 3
        ) {
            ForEach(Array(members.prefix(4).enumerated()), id: \.element.id) { index, item in
                PinThumbnail(item: item, image: thumbnails[item.id] ?? nil, side: cell)
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
        .task(id: members.map(\.id)) { await loadThumbnails() }
    }

    private var memberSummary: String {
        members.prefix(4).map(\.title).joined(separator: "、")
    }

    private func loadThumbnails() async {
        for item in members.prefix(4) where thumbnails[item.id] == nil {
            let url = try? await model.library.resolvedFileURL(for: item)
            let image = item.kind == .link
                ? LinkCoverStore.cachedImage(for: item.id)
                : await ThumbnailStore.shared.image(item: item, url: url, logicalSize: 44)
            thumbnails[item.id] = image
        }
    }

    private var expanded: some View {
        // 成员可能十几张；普通 HStack 会一次性构建全部 PinCard（缩略图、
        // 平台解析、语义状态、手势任务一起启动）。放在横向 ScrollView 里必须
        // 用 LazyHStack，只创建视口附近的成员。
        LazyHStack(spacing: 8) {
            spine
            ForEach(members) { item in
                GroupMemberCell(
                    item: item,
                    group: group,
                    model: model,
                    availableHeight: availableHeight - 12
                )
                .transition(.opacity)
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: Style.cardRadius + 4, style: .continuous)
                .fill(tint.opacity(0.14))
                .overlay {
                    RoundedRectangle(cornerRadius: Style.cardRadius + 4, style: .continuous)
                        .strokeBorder(tint.opacity(0.35))
                }
        }
        .transition(.opacity)
    }

    /// 脊上放得下几个字：按可用高度算。硬写一个字数会在回答态（卡片变矮）
    /// 时溢出到脊外面。
    private var spineName: String {
        let budget = max(2, Int((availableHeight - 76) / 11))
        guard group.name.count > budget else { return group.name }
        return String(group.name.prefix(max(1, budget - 1))) + "…"
    }

    /// 左侧竖脊：分组的身份和收起入口都在这里，不占卡片本身的地方。
    private var spine: some View {
        Button { model.toggleCardGroup(group.id) } label: {
            VStack(spacing: 0) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.bottom, 5)
                // 名字竖排在脊上，像书脊。展开之后这是唯一还写着"打开的是哪
                // 一组"的地方——只有一个文件夹图标和数字的话，用户看不出来。
                //
                // 逐字竖排而不是把整行旋转 90°：中文本来就能竖排，转过来的
                // 横排字要歪着头读。
                VStack(spacing: 1) {
                    ForEach(Array(spineName.enumerated()), id: \.offset) { _, character in
                        Text(String(character)).font(.system(size: 10, weight: .semibold))
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
                Text("\(members.count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(tint)
            .frame(width: 28)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 8)
            .background(
                tint.opacity(hovering ? 0.18 : 0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 展开后成员卡恢复各自的 item 拖拽；只有书脊仍代表整组。
        .onDrag { PinDragProvider.make(groupID: group.id, name: group.name, model: model) }
        .help("折叠「\(group.name)」；拖动这里移动整组")
    }
}

/// 展开组里的一个成员。只有展开态才存在，所以此时 item 拖拽 / 组内排序 /
/// 拖到组外退出都成立；折叠态根本不渲染它，绝不会拿成员冒充整组。
private struct GroupMemberCell: View {
    let item: Item
    let group: CardGroup
    @Bindable var model: AppModel
    let availableHeight: CGFloat
    @State private var targeted = false
    @State private var insertAfter = false

    var body: some View {
        PinCard(item: item, model: model, availableHeight: availableHeight)
            .overlay(alignment: insertAfter ? .trailing : .leading) {
                if targeted {
                    Capsule()
                        .fill(Style.cool)
                        .frame(width: 3)
                        .padding(.vertical, 6)
                        .offset(x: insertAfter ? 5.5 : -5.5)
                }
            }
            .onDrop(
                of: [UTType.data],
                delegate: GroupMemberDropDelegate(
                    targetID: item.id,
                    groupID: group.id,
                    model: model,
                    targeted: $targeted,
                    insertAfter: $insertAfter
                )
            )
    }
}

private struct GroupMemberDropDelegate: DropDelegate {
    let targetID: UUID
    let groupID: UUID
    @Bindable var model: AppModel
    @Binding var targeted: Bool
    @Binding var insertAfter: Bool

    private var draggedItem: UUID? {
        guard case .item(let id) = model.outboundDrag,
              id != targetID,
              model.cardGroup(of: id)?.id == groupID else { return nil }
        return id
    }

    func validateDrop(info: DropInfo) -> Bool { draggedItem != nil }

    func dropEntered(info: DropInfo) {
        guard draggedItem != nil else { return }
        targeted = true
        insertAfter = info.location.x > PinCard.width / 2
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard draggedItem != nil else { return nil }
        if !targeted { targeted = true }
        let next = info.location.x > PinCard.width / 2
        if next != insertAfter { insertAfter = next }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { targeted = false }

    func performDrop(info: DropInfo) -> Bool {
        guard let id = draggedItem else { targeted = false; return false }
        let after = insertAfter
        targeted = false
        model.completeOutboundDrop()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
            model.moveGroupMember(id, before: targetID, after: after)
        }
        return true
    }
}

/// 给分组起名字。就一个输入框——名字是用户自己的话，不该有别的选项来分散它。
private struct GroupNameEditor: View {
    @Binding var name: String
    let commit: (String) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("分组名字")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Style.secondary)
            TextField("比如「招聘信息」", text: $name)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($focused)
                .onSubmit { commit(name) }
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Style.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Style.accent.opacity(focused ? 0.6 : 0))
                }
            HStack {
                Spacer(minLength: 0)
                Button("完成") { commit(name) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 240)
        .onAppear { focused = true }
    }
}

/// 同一份文档的几个版本，像手风琴一样叠在一起。
///
/// 折叠时几张**真正的卡片**首尾错开压成一摞，只露出后面几张的右边缘；点一下
/// 整排向右弹开。和平台归类那一排是同一套语言——那边叠的是图标，这边叠的是
/// 卡片，形状一致，用户认过一次不用再学第二次。
///
/// 折叠态不另做一张"合集卡"：同一份东西的几个版本，最该被看到的仍然是它长
/// 什么样，而重叠这个形状本身已经说清了"底下还压着几张"。
///
/// 展开后整族仍然装在一格里，左边一道竖脊圈住它们。成员各自摊回轨道的话，
/// 它们和旁边不相干的卡片长得一模一样，归属只剩一枚小标在说——看起来就像
/// 聚类没生效。
private struct VersionAccordion: View {
    let collection: AppModel.VersionCollection
    let members: [Item]
    @Bindable var model: AppModel
    var availableHeight: CGFloat = PinCard.height

    @State private var hovering = false

    private var isExpanded: Bool { model.expandedVersionGroups.contains(collection.id) }

    var body: some View {
        Group {
            if isExpanded { expanded } else { collapsed }
        }
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.34, dampingFraction: 0.72), value: isExpanded)
        .animation(.spring(response: 0.28, dampingFraction: 0.8), value: hovering)
    }

    // MARK: 折叠

    /// 折叠态是一套**独立的版面**，不是把几张完整卡片压在一起。
    ///
    /// 压完整卡片试过，不能用：后面几张的标题、文件名、底栏图标全都从缝里
    /// 透出来，和最前面那张的文字叠在一起，谁都读不出来——一摞纸的重点是
    /// "这是一摞"，不是"每一张分别写了什么"。所以后面几张只画**空白纸边**，
    /// 内容只留给最上面那张。
    private var collapsed: some View {
        // ZStack 默认居中对齐：后面几张比前面矮，自然就藏在前面那张身后，
        // 只从右侧探出一条边。用"更矮 + 右移"而不是"同高 + 右下偏移"——
        // 后者会让纸边戳出轨道下沿，压在隔壁卡片和下一行上，正是那种
        // "乱"的来源。整摞占的高度和一张卡片完全一样。
        ZStack(alignment: .center) {
            ForEach(sheetDepths.reversed(), id: \.self) { depth in
                sheetShape
                    // 卡片底色是 6.5% 的白——几乎全透明。不垫一层不透明底的话，
                    // 后面每一张都会整个从前面那张身上透出来，看到的是三层文字
                    // 叠在一起。堆叠要成立，前面那张必须真的挡住后面。
                    .fill(Style.ink)
                    // 纸边上色。中性灰的边压在近黑的面板上，对比只有几个百分点，
                    // 眼睛读不出"这里叠着东西"。用强调色，而且和底栏那枚"N 版"
                    // 是同一个色——两处说的本来就是同一件事。
                    .overlay {
                        sheetShape.fill(Style.accent.opacity(0.2 - Double(depth) * 0.05))
                    }
                    .overlay {
                        sheetShape.strokeBorder(
                            Style.accent.opacity(0.55 - Double(depth) * 0.14),
                            lineWidth: 1
                        )
                    }
                    .frame(
                        width: PinCard.width,
                        height: availableHeight - CGFloat(depth) * 11
                    )
                    .offset(x: CGFloat(depth) * peek)
            }
            PinCard(
                item: newest,
                model: model,
                availableHeight: availableHeight,
                versionSlot: slot(rank: 1)
            )
            // 同理：最上面那张也要有不透明底，否则纸边照样从它身上透出来。
            .background { sheetShape.fill(Style.ink) }
            // 最上面这张也描一道同色的边，整摞才是一个整体，而不是"一张卡
            // 旁边贴了两条橙色"。
            .overlay {
                sheetShape.strokeBorder(
                    Style.accent.opacity(hovering ? 0.6 : 0.38),
                    lineWidth: 1
                )
            }
            .shadow(color: Color.black.opacity(0.45), radius: 7, x: 3)
        }
        // 整摞的宽度 = 一张卡 + 探出来的那两条边，不会挤到隔壁。
        //
        // 宽度必须用**静止值**，不能用 peek：peek 随 hover 变，于是鼠标一碰
        // 这一摞，它在 LazyHStack 里占的宽度就变了，右边所有卡片跟着平移——
        // 用户什么都没做，只是把指针放上去，整条轨道抖一下。悬停只该让纸边
        // 错得更开（那是 offset，不参与布局）。
        .frame(
            width: PinCard.width + CGFloat(sheetDepths.count) * Self.hoverTileX,
            height: availableHeight,
            alignment: .leading
        )
        // 底下卡片自己的单击（复制）、双击（预览）此刻都不该生效，
        // 用户要的只有"打开这一摞"。
        .allowsHitTesting(false)
        .overlay {
            Color.black.opacity(0.001)
                .contentShape(Rectangle())
                .onTapGesture { model.toggleVersionGroup(collection.id) }
                .help("这份文档有 \(members.count) 个版本，点开逐版查看")
        }
        .transition(.opacity)
    }

    private var sheetShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous)
    }

    /// 探出来的宽度。悬停时多探一点，像被手指拨开一条缝。
    /// 悬停时纸边错得更开。**宽度按最大那一档预留**（见下面的 frame）：
    /// 按静止值预留的话，悬停时纸边会探出自己那一格，压到隔壁卡片上——
    /// 那就是"卡片重叠"。而反过来让宽度跟着 hover 变，则是整条轨道跟着抖。
    /// 两个都不能要：占位固定取最大值，只有画出来的位置在动。
    private static let hoverTileX: CGFloat = 9
    private var peek: CGFloat { hovering ? Self.hoverTileX : Self.restTileX }
    /// 布局用的静止值，见下面外框那句注释。
    private static let restTileX: CGFloat = 7

    /// 后面画几张纸边。最多两张：第三张开始已经看不出区别，只是把边缘弄花。
    private var sheetDepths: [Int] { Array(1...min(2, max(1, members.count - 1))) }
    private var newest: Item { members[0] }

    // MARK: 展开

    private var expanded: some View {
        LazyHStack(spacing: 8) {
            spine
            ForEach(Array(members.enumerated()), id: \.element.id) { index, item in
                PinCard(
                    item: item,
                    model: model,
                    availableHeight: availableHeight - 12,
                    versionSlot: slot(rank: index + 1)
                )
                // 逐张错开一点点入场，读起来是"依次弹出来"而不是"一起冒出来"。
                .transition(
                    .scale(scale: 0.9, anchor: .leading)
                    .combined(with: .opacity)
                    .animation(
                        .spring(response: 0.34, dampingFraction: 0.72)
                            .delay(Double(index) * 0.04)
                    )
                )
            }
        }
        .padding(6)
        .background {
            RoundedRectangle(cornerRadius: Style.cardRadius + 4, style: .continuous)
                .fill(Style.accentMuted.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: Style.cardRadius + 4, style: .continuous)
                        .strokeBorder(Style.accent.opacity(0.35))
                }
        }
        .transition(.opacity)
    }

    private func slot(rank: Int) -> AppModel.VersionSlot {
        AppModel.VersionSlot(
            groupID: collection.id,
            rank: rank,
            total: members.count,
            isExpanded: isExpanded
        )
    }

    /// 左侧竖脊：合集的身份和收起入口都在这里，不占卡片本身的地方。
    private var spine: some View {
        Button { model.toggleVersionGroup(collection.id) } label: {
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                Text("\(members.count) 版")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Style.accent)
            .frame(width: 26)
            .frame(maxHeight: .infinity)
            .padding(.vertical, 8)
            .background(
                Style.accent.opacity(hovering ? 0.18 : 0.1),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("折叠回一摞：" + collection.title)
    }
}

/// 版本小标，画在卡片底栏。
///
/// 折叠时它长在最前面那张上，写"N 版"，是这一摞唯一的说明文字；展开后第一张
/// 变成"最新"，其余写"第 N 版"。同一个位置一直在说同一件事——
/// "这张卡属于一摞里的哪一层"。收起只有一个入口，在左侧竖脊上。
private struct VersionChip: View {
    let slot: AppModel.VersionSlot
    @Bindable var model: AppModel
    let item: Item

    var body: some View {
        if !slot.isExpanded {
            if slot.rank == 1 {
                label(icon: "square.stack.3d.down.right.fill", text: "\(slot.total) 版",
                      tint: Style.accent, background: Style.accentMuted)
                    .help("这份文档有 \(slot.total) 个版本，点开逐版查看")
            }
        } else if slot.rank == 1 {
            // 展开态这里只做说明，不再放第二个收起按钮：收起归左边那道竖脊，
            // 一个动作一个入口。两个长得不一样的收起键并排摆着，用户得先分辨
            // 它们是不是同一件事。
            label(icon: nil, text: "最新",
                  tint: Style.accent, background: Style.accentMuted)
                .help(versionHelp)
        } else {
            label(icon: nil, text: "第 \(slot.rank) 版",
                  tint: Style.tertiary, background: Style.surfacePressed)
                .help(versionHelp)
        }
    }

    private func label(
        icon: String?, text: String, tint: Color, background: Color
    ) -> some View {
        HStack(spacing: 3) {
            if let icon {
                Image(systemName: icon).font(.system(size: 8, weight: .bold))
            }
            Text(text).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .frame(height: 16)
        .background(background, in: Capsule())
    }

    private var versionHelp: String {
        let date = ItemTemporalFacts(item: item).contentDate
        return "这一版的时间：" + date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// 改名字、加标签。
///
/// 这两件事放在一起，因为它们是同一个动作的两半：让这份东西**以后能被自己
/// 想起来**。所以保存之后它们都会进向量库——只留在界面上的备注等于没写。
///
/// 界面上做的三件事，都是为了少打字：
/// 1. 自动生成的名字（`pinland-clipboard-…`）不预填，直接留空——那种名字
///    从来没有人想保留，预填只是逼用户先全选删掉；
/// 2. 用过的标签摆出来点一下就加，不用凭记忆重打一遍（也免得同一个概念
///    分裂成「阿里云」和「阿里云密钥」两个标签，检索时少一半）；
/// 3. 空格、逗号、回车都算一个标签结束，不用去够那个"添加"按钮。
private struct AnnotationEditor: View {
    let item: Item
    var suggestions: [String] = []
    let save: (String?, [String]) -> Void

    @State private var title: String = ""
    @State private var tags: [String] = []
    @State private var draftTag: String = ""
    @FocusState private var focus: Field?

    private enum Field { case title, tag }

    /// 这个名字是机器起的吗。是的话不预填——那种名字从来没有人想保留，
    /// 预填只是逼用户先全选删掉。改名前后两种前缀都要认。
    private var titleIsPlaceholder: Bool {
        item.titledLocally
            || item.title.hasPrefix("mnemo-clipboard-")
            || item.title.hasPrefix("pinland-clipboard-")
    }

    private var unusedSuggestions: [String] {
        suggestions.filter { suggestion in
            !tags.contains { $0.caseInsensitiveCompare(suggestion) == .orderedSame }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            titleField
            tagField
            if !unusedSuggestions.isEmpty { suggestionRow }
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onAppear {
            title = titleIsPlaceholder ? "" : item.title
            tags = item.tags
            focus = .title
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("叫什么").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Style.secondary)
            HStack(spacing: 6) {
                TextField(
                    titleIsPlaceholder ? "起个自己记得住的名字" : item.title,
                    text: $title
                )
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .focused($focus, equals: .title)
                .onSubmit { focus = .tag }
                if !title.isEmpty {
                    Button { title = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Style.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("清空")
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Style.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focus == .title ? Style.accent.opacity(0.6) : Style.stroke)
            }
        }
    }

    /// 已选标签和输入框在同一个框里，像邮件的收件人栏——加完一个接着打下一个，
    /// 不用在"输入框"和"标签区"之间来回看。
    private var tagField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("标签").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Style.secondary)
            FlowLayout(spacing: 5) {
                ForEach(tags, id: \.self) { tag in
                    TagChip(text: tag, tint: Style.accent) {
                        tags.removeAll { $0 == tag }
                    }
                }
                TextField("空格或回车分隔", text: $draftTag)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .frame(minWidth: 96)
                    .focused($focus, equals: .tag)
                    .onSubmit(commitDraft)
                    // 空格和逗号也当作一个标签结束：中文输入里逗号比回车顺手，
                    // 而空格几乎不会出现在标签内部。
                    .onChange(of: draftTag) { _, value in
                        guard value.hasSuffix(" ") || value.hasSuffix("，")
                                || value.hasSuffix(",") else { return }
                        draftTag = String(value.dropLast())
                        commitDraft()
                    }
            }
            .padding(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Style.surface, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focus == .tag ? Style.accent.opacity(0.6) : Style.stroke)
            }
            .contentShape(Rectangle())
            .onTapGesture { focus = .tag }
        }
    }

    private var suggestionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("用过的").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Style.secondary)
            FlowLayout(spacing: 5) {
                ForEach(unusedSuggestions, id: \.self) { tag in
                    Button { tags.append(tag) } label: {
                        Text(tag)
                            .font(.system(size: 11))
                            .foregroundStyle(Style.secondary)
                            .padding(.horizontal, 8)
                            .frame(height: 21)
                            .background(Style.surfacePressed, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("都会进检索，之后用这些说法就能找回它")
                .font(.system(size: 10))
                .foregroundStyle(Style.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("保存") {
                // 输入框里还没提交的那一个也算数。打完字直接点保存是最自然的
                // 操作，让它落空只会被当成"加不上标签"。
                var finalTags = tags
                let pending = draftTag.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { finalTags.append(pending) }
                save(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : title,
                     finalTags)
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private func commitDraft() {
        let tag = draftTag.trimmingCharacters(in: .whitespacesAndNewlines)
        draftTag = ""
        guard !tag.isEmpty,
              !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame })
        else { return }
        tags.append(tag)
        focus = .tag
    }
}

private struct TagChip: View {
    let text: String
    let tint: Color
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 11, weight: .medium))
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .frame(height: 21)
        .background(Style.accentMuted, in: Capsule())
    }
}

/// 按宽度自动换行的横排。
///
/// SwiftUI 没有现成的流式布局，而标签的数量和长度都不可控：用固定列的网格，
/// 长标签会把整列撑开、短标签留一堆空；用单行 HStack 则会一路顶出弹层。
private struct FlowLayout: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = arrange(subviews: subviews, width: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let rows = arrange(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let advance = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, advance > width {
                rows.append(current)
                current = Row()
                current.indices = [index]
                current.width = size.width
                current.height = size.height
            } else {
                current.indices.append(index)
                current.width = advance
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

private struct PinThumbnail: View {
    let item: Item
    let image: NSImage?
    /// 缩略图边长。文字卡片已经不再要缩略图，媒体卡片改用 48pt——
    /// 省下的 14pt 全给标题栏，两行标题不再一上来就被截断。
    var side: CGFloat = 62
    /// 右下角已经被品牌 / 平台徽标占了吗。
    ///
    /// 两个角标是各画各的：来源应用角标在缩略图内部，品牌徽标由外层 ZStack
    /// 叠上来，两边都写死 bottomTrailing + offset(4,4)，于是同时出现时就是
    /// 一个压着另一个——截图里那个绿色日历徽标底下压着的橙色方块就是它。
    /// 让来源应用角标让位到左下角：品牌徽标是可点的、也更需要被认出来，
    /// 而"从哪个应用来的"退一格仍然看得见。
    var cornerIsTaken = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else if let host = linkHost {
                DomainBadge(host: host, fontSize: 22)
            } else if item.kind == .text, case .inline(let text) = item.holding,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if let signature = ClipboardTextSignature.detect(text) {
                    CodeBadge(signature: signature)
                } else {
                    TextSnippetPreview(text: text)
                }
            } else {
                Image(systemName: glyph)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(tint)
            }
        }
        .frame(width: side, height: side)
        .background(Style.surfacePressed, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Style.stroke) }
        // 角标压在缩略图角上，不参与裁剪，所以放在 clipShape 之后。
        .overlay(alignment: cornerIsTaken ? .bottomLeading : .bottomTrailing) {
            if let icon = SourceAppBadge.icon(for: item) {
                // 应用图标本身是圆角方形。之前把它摆在一个圆形底上，四个角
                // 支出来、又多一圈描边，边缘就乱了。裁成圆形、只留一圈深色
                // 分隔环，压在缩略图上才干净。
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 16, height: 16)
                    .clipShape(Circle())
                    .overlay { Circle().strokeBorder(Color.black.opacity(0.65), lineWidth: 1.5) }
                    .offset(x: cornerIsTaken ? -4 : 4, y: 4)
                    .help("来自 \(SourceAppBadge.name(for: item) ?? "其他应用")")
            }
        }
    }

    /// 缩略图里的域名色块和平台图标。
    ///
    /// 只对**链接**条目解析：`linkURL` 对任何内联文字都会试着抽链接，而这个
    /// 视图对每一条都会问。文字卡根本不需要域名色块，先按 kind 挡掉。
    private var linkHost: String? {
        guard item.kind == .link else { return nil }
        return item.linkURL?.host()
    }

    private var platform: LinkPlatform? {
        guard item.kind == .link else { return nil }
        return item.linkURL.flatMap(LinkPlatform.resolve)
    }

    private var glyph: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .link: "link"
        case .file: "doc"
        case .binary: "shippingbox"
        }
    }

    private var tint: Color {
        switch item.kind {
        case .image: Style.cool
        case .pdf: Style.accent
        case .link: Color.cyan.opacity(0.78)
        default: Style.secondary
        }
    }
}

// MARK: - Focus

/// 效率模式：左列计时、右列待办、底部专注记录。
///
/// 旧版把 260pt 切成三条横带，待办只剩 54pt 却要放 42pt 高的两列网格，
/// 永远只能看见一行半。改成左右分栏后待办拿到整列高度，热力图退到底部统计条。
private struct FocusWorkspace: View {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let timerColumnWidth: CGFloat = 244
    /// 统计栏高度。
    ///
    /// 这个数字不是随便定的：计时列最小要 168pt（表盘 80 + 两段间距 + 时长
    /// 选择 26 + 主按钮 34 + 上下留白），加上一条分隔线，212pt 的工作区只剩
    /// 40pt 给统计栏。之前为了让柱子"看得见"把它加到 64，结果整块内容被裁掉
    /// 27pt——柱子确实更高了，但底部标签和主按钮一起挤出了可视区。
    /// 可读性问题的真正解法是提高对比度，不是抢空间。
    private static let statsHeight: CGFloat = 40

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                FocusTimerColumn(model: model)
                    .frame(width: Self.timerColumnWidth)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.26),
                               value: model.focusTimer.phase)
                Hairline(vertical: true)
                TodoColumn(model: model)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: .infinity)
            Hairline()
            FocusStatsBar(days: model.focusHeatmap)
                .frame(height: Self.statsHeight)
        }
    }
}

private struct FocusTimerColumn: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            FocusDial(model: model)
            Spacer(minLength: 6)
            phaseControl.frame(height: 26)
            Spacer(minLength: 6)
            actionRow.frame(height: 34)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 空闲时是时长选择，计时中换成同尺寸的状态胶囊，列宽和行高都不变。
    @ViewBuilder
    private var phaseControl: some View {
        if model.focusTimer.phase == .idle {
            // 时长主要靠表盘滚轮/拖动调；这几个只是常用值的快捷键。
            HStack(spacing: 6) {
                ForEach([15, 25, 45], id: \.self) { value in
                    Button { model.focusDurationMinutes = value } label: {
                        Text("\(value)")
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(model.focusDurationMinutes == value
                                             ? Style.primary : Style.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(model.focusDurationMinutes == value
                                        ? Style.surfacePressed : Style.surface,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("\(value) 分钟")
                }
            }
            .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol)
                Text(statusTitle)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(model.focusTimer.phase == .paused ? Style.warning : Style.cool)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Style.surface, in: Capsule())
            .overlay { Capsule().strokeBorder(Style.stroke) }
            .transition(.opacity)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button { model.toggleFocusPause() } label: {
                Label(primaryActionTitle, systemImage: primaryActionSymbol)
            }
            .buttonStyle(PrimaryActionButtonStyle(expands: true))
            .help(primaryActionHelp)

            if model.focusTimer.phase != .idle {
                Button { model.cancelFocus() } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .help("结束本次专注，本次不计入记录")
                .accessibilityLabel("结束本次专注")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
    }

    private var statusTitle: String {
        switch model.focusTimer.phase {
        case .idle: "准备专注"
        case .running: "专注中"
        case .paused: "已暂停"
        }
    }

    private var statusSymbol: String {
        switch model.focusTimer.phase {
        case .idle: "circle.dotted"
        case .running: "timer"
        case .paused: "pause.circle.fill"
        }
    }

    private var primaryActionTitle: String {
        switch model.focusTimer.phase {
        case .idle: "开始专注"
        case .running: "暂停"
        case .paused: "继续"
        }
    }

    private var primaryActionSymbol: String {
        model.focusTimer.phase == .running ? "pause.fill" : "play.fill"
    }

    private var primaryActionHelp: String {
        switch model.focusTimer.phase {
        case .idle: "开始后收起 Mnemo，刘海会继续显示剩余时间"
        case .running: "暂停计时，随时可以继续"
        case .paused: "继续本次专注"
        }
    }
}

private struct FocusDial: View {
    @Bindable var model: AppModel

    @State private var scrubAccumulator: CGFloat = 0

    private var isIdle: Bool { model.focusTimer.phase == .idle }

    var body: some View {
        ZStack {
            Circle().stroke(Style.surfacePressed, lineWidth: 6)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(ringColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 1) {
                Text(primaryText)
                    .font(.system(size: isIdle ? 27 : 21, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Style.primary)
                    .contentTransition(.numericText())
                Text(isIdle ? "分钟" : "剩余")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Style.tertiary)
            }
        }
        .frame(width: 80, height: 80)
        .contentShape(Circle())
        .overlay {
            // 空闲时表盘就是时长滚轮：滚动或上下拖动都能调。
            if isIdle {
                ScrollWheelCatcher { model.nudgeFocusDuration(by: $0) }
                    .clipShape(Circle())
            }
        }
        .gesture(isIdle ? scrubGesture : nil)
        .help(isIdle ? "滚动或上下拖动调节时长" : "本次专注剩余时间")
        .animation(.smooth, value: progress)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAdjustableAction { direction in
            model.nudgeFocusDuration(by: direction == .increment ? 1 : -1)
        }
    }

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                scrubAccumulator += value.translation.height
                while scrubAccumulator <= -6 {
                    scrubAccumulator += 6
                    model.nudgeFocusDuration(by: 1)
                }
                while scrubAccumulator >= 6 {
                    scrubAccumulator -= 6
                    model.nudgeFocusDuration(by: -1)
                }
            }
            .onEnded { _ in scrubAccumulator = 0 }
    }

    private var primaryText: String {
        isIdle ? "\(model.focusDurationMinutes)" : TimeFormat.mmss(model.timerRemaining ?? 0)
    }

    private var ringColor: Color {
        switch model.focusTimer.phase {
        case .idle: Style.accent.opacity(0.55)
        case .running: Style.accent
        case .paused: Style.warning
        }
    }

    /// 空闲时圆环表示在可选区间里的位置，滚轮一转就能看见它涨落。
    private var progress: CGFloat {
        guard !isIdle else {
            return CGFloat(model.focusDurationMinutes) / CGFloat(AppModel.maxFocusDurationMinutes)
        }
        let remaining = model.timerRemaining ?? 0
        return min(1, max(0, remaining / max(1, model.focusTimer.duration)))
    }

    private var accessibilityLabel: String {
        switch model.focusTimer.phase {
        case .idle: "准备专注，时长 \(model.focusDurationMinutes) 分钟"
        case .running: "专注中，剩余 \(TimeFormat.mmss(model.timerRemaining ?? 0))"
        case .paused: "专注已暂停，剩余 \(TimeFormat.mmss(model.timerRemaining ?? 0))"
        }
    }
}

/// 把 AppKit 的滚轮事件接进 SwiftUI。累积到 6pt 才走一格，触控板和鼠标
/// 滚轮的手感都不会太跳。
private struct ScrollWheelCatcher: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> NSView { CatcherView(onStep: onStep) }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onStep = onStep
    }

    final class CatcherView: NSView {
        var onStep: (Int) -> Void
        private var accumulated: CGFloat = 0

        init(onStep: @escaping (Int) -> Void) {
            self.onStep = onStep
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func scrollWheel(with event: NSEvent) {
            accumulated += event.scrollingDeltaY
            while accumulated >= 6 {
                accumulated -= 6
                onStep(1)
            }
            while accumulated <= -6 {
                accumulated += 6
                onStep(-1)
            }
        }
    }
}

// MARK: - Todo

private struct TodoColumn: View {
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var draftFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            header.frame(height: 44)
            Hairline()
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Text("待办")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Style.primary)
                Text("\(openCount)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(openCount == 0 ? Style.tertiary : Style.accent)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 17)
                    .background(openCount == 0 ? Style.surface : Style.accentMuted, in: Capsule())
                    .contentTransition(.numericText())
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("待办，\(openCount) 项未完成")

            // 输入框跟随列宽，不再写死 310pt。
            HStack(spacing: 6) {
                Image(systemName: "plus.circle")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(draftFocused ? Style.accent : Style.tertiary)
                TextField("添加待办，回车保存", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .focused($draftFocused)
                    .onSubmit(addTodo)
                if !trimmedDraft.isEmpty {
                    Button(action: addTodo) {
                        Image(systemName: "return")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Style.accent)
                    .help("添加待办")
                    .transition(.opacity)
                }
            }
            .foregroundStyle(Style.secondary)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .background(Style.surface, in: RoundedRectangle(cornerRadius: Style.controlRadius))
            .overlay {
                RoundedRectangle(cornerRadius: Style.controlRadius)
                    .strokeBorder(draftFocused ? Style.accent.opacity(0.55) : Style.stroke)
            }
            .animation(.easeInOut(duration: 0.16), value: draftFocused)
            .animation(.easeInOut(duration: 0.16), value: trimmedDraft.isEmpty)
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var content: some View {
        if model.todoItems.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "checklist")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Style.tertiary)
                    .symbolEffect(.bounce, options: .repeat(.periodic(3, delay: 2)))
                VStack(alignment: .leading, spacing: 2) {
                    Text("还没有待办")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Style.secondary)
                    Text("在上方输入，或右键某个 Pin 选「标为待办」")
                        .font(.system(size: 10))
                        .foregroundStyle(Style.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(model.todoItems) { todo in
                        TodoRow(todo: todo, model: model)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.vertical, 4)
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.26), value: model.todoItems)
        }
    }

    private var openCount: Int {
        model.todoItems.reduce(0) { $0 + ($1.isCompleted ? 0 : 1) }
    }

    private var trimmedDraft: String {
        draft.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTodo() {
        let value = trimmedDraft
        guard !value.isEmpty else { return }
        draft = ""
        Task { await model.addStandaloneTodo(value) }
    }
}

private struct TodoRow: View {
    let todo: Todo
    @Bindable var model: AppModel
    @State private var hovering = false
    @State private var confirmsDeletion = false
    @State private var editingDue = false
    @State private var draftDue = Date.now

    var body: some View {
        HStack(spacing: 8) {
            Button { Task { await model.toggleTodoCompleted(todo.id) } } label: {
                Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(todo.isCompleted ? Style.cool : Style.secondary)
            .help(toggleTitle)
            .accessibilityLabel(toggleTitle)

            if let presentation = TodoPresentationStore.todo(todo.id), presentation.isMeaningful {
                ServiceBrandIcon(metadata: presentation, size: 22)
            }

            title

            Spacer(minLength: 6)

            // 时间是可以改的，所以它必须看起来像个控件。之前这里只是一枚
            // 只读胶囊，"几点提醒我"这件事在界面上根本没有入口——只能在
            // 今天 / 明天 / 下周三个整天之间选，而它们全都落在 23:59。
            Button {
                draftDue = todo.dueAt ?? Self.defaultDue()
                editingDue = true
            } label: {
                if let dueAt = todo.dueAt {
                    DueChip(date: dueAt, isCompleted: todo.isCompleted)
                } else {
                    Image(systemName: "clock")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Style.tertiary)
                        .frame(width: 20, height: 18)
                        .contentShape(Rectangle())
                        .opacity(hovering ? 1 : 0)
                }
            }
            .buttonStyle(.plain)
            .help(todo.dueAt == nil ? "设定提醒时间" : "改提醒时间")
            .popover(isPresented: $editingDue, arrowEdge: .bottom) {
                DueEditor(
                    date: $draftDue,
                    hasDue: todo.dueAt != nil,
                    apply: { value in
                        editingDue = false
                        Task { await model.setTodoDueDate(todo.id, date: value) }
                    }
                )
            }

            // 省略号菜单撤掉了。
            //
            // 它是"没有别的入口"时代的产物：一整排都要靠它才够得着。现在
            // 完成、时间都已经是行内可点的控件，悬停就出现，剩下的只有删除
            // 值得再占一个位置——而其余那些（打开关联 Pin、清除时间…）右键
            // 菜单原样都在。多一层要先点开才看得见的菜单，只是让每一步多一下。
            Button { confirmsDeletion = true } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Style.warning)
            .opacity(hovering ? 1 : 0)
            .help("删除待办")
            .accessibilityLabel("删除待办")
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(hovering ? Style.surfaceHover : .clear,
                    in: RoundedRectangle(cornerRadius: Style.cardRadius, style: .continuous))
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.14), value: hovering)
        .contextMenu { menuContent }
        .offset(y: hovering ? -0.5 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .alert("删除这条待办？", isPresented: $confirmsDeletion) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task { await model.deleteTodo(todo.id) }
            }
        } message: {
            if TodoProvenanceStore.sourceItemID(for: todo.id) != nil {
                Text("删除后会同步清理它的提取来源；若来源已在回收站，将永久清空来源与 RAG 数据。")
            } else {
                Text("此操作会删除待办。")
            }
        }
    }

    /// 纯文字待办没有可打开的目标，就别做成 disabled 的死按钮。
    @ViewBuilder
    private var title: some View {
        if todo.linkedItemID != nil {
            Button { model.openLinkedItem(for: todo) } label: {
                titleLabel.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开关联的 Pin")
        } else {
            titleLabel
        }
    }

    private var titleLabel: some View {
        HStack(spacing: 5) {
            if todo.linkedItemID != nil {
                Image(systemName: "paperclip")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Style.tertiary)
            }
            Text(todo.title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(todo.isCompleted ? Style.tertiary : Style.primary)
                .strikethrough(todo.isCompleted, color: Style.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var menuContent: some View {
        Button("今天到期") { setDue(daysFromToday: 0) }
        Button("明天到期") { setDue(daysFromToday: 1) }
        Button("下周到期") { setDue(daysFromToday: 7) }
        Button("设定具体时间…") {
            draftDue = todo.dueAt ?? Self.defaultDue()
            editingDue = true
        }
        if todo.dueAt != nil {
            Button("清除截止日期") { Task { await model.setTodoDueDate(todo.id, date: nil) } }
        }
        Divider()
        Button(toggleTitle) { Task { await model.toggleTodoCompleted(todo.id) } }
        if todo.linkedItemID != nil {
            Button("打开关联的 Pin") { model.openLinkedItem(for: todo) }
        }
        Divider()
        Button("删除待办", role: .destructive) { confirmsDeletion = true }
    }

    private var toggleTitle: String {
        todo.isCompleted ? "标记为未完成" : "标记为完成"
    }

    /// 还没有时间时，编辑器打开在哪一刻。
    ///
    /// 取"下一个整点后的今天 9 点 / 14 点 / 20 点"里第一个还没过去的；
    /// 今天全过完了就给明天早上 9 点。默认值落在一个能用的时刻上，
    /// 用户多数时候只要点确定。
    private static func defaultDue(now: Date = .now, calendar: Calendar = .current) -> Date {
        for hour in [9, 14, 20] {
            if let candidate = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: now),
               candidate > now {
                return candidate
            }
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? now
    }

    private func setDue(daysFromToday: Int) {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: .now)
        let date = calendar.date(byAdding: .day, value: daysFromToday + 1, to: start)?
            .addingTimeInterval(-1)
        Task { await model.setTodoDueDate(todo.id, date: date) }
    }
}

/// 改"几点提醒我"。
///
/// 日期和钟点一起给：只有整天的话，提醒设置里那个"提前 N 分钟"没有落点，
/// 所有事都堆在 23:59 提醒一次，等于没有提醒。
private struct DueEditor: View {
    @Binding var date: Date
    let hasDue: Bool
    let apply: (Date?) -> Void

    /// 常用时刻。表格里的钟点和本地待办提取用的是同一套（上午 9、下午 2、
    /// 晚上 8），保证"自动认出来的"和"手动改的"落在同一批时间上。
    private static let presets: [(String, Int)] = [
        ("上午 9:00", 9), ("下午 2:00", 14), ("晚上 8:00", 20),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("提醒时间")
                .font(.system(size: 12, weight: .semibold))

            DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                .datePickerStyle(.compact)
                .labelsHidden()

            HStack(spacing: 6) {
                ForEach(Self.presets, id: \.0) { label, hour in
                    Button(label) { setHour(hour) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .background(Style.surfaceHover, in: Capsule())
                }
            }

            HStack(spacing: 6) {
                Button("今天") { setDay(0) }
                Button("明天") { setDay(1) }
                Button("下周") { setDay(7) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(Style.secondary)

            Divider()

            HStack {
                if hasDue {
                    Button("清除") { apply(nil) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Style.warning)
                }
                Spacer(minLength: 8)
                Button("确定") { apply(date) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 262)
    }

    /// 只改钟点，日期保持不动——用户点"下午 2:00"是想调今天这一条的时刻，
    /// 不是想把它挪到别的哪一天。
    private func setHour(_ hour: Int) {
        let calendar = Calendar.current
        guard let value = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) else {
            return
        }
        date = value
    }

    /// 只改日期，钟点保持不动，理由同上。
    private func setDay(_ daysFromToday: Int) {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let day = calendar.date(
            byAdding: .day,
            value: daysFromToday,
            to: calendar.startOfDay(for: .now)
        ) ?? date
        date = calendar.date(
            bySettingHour: components.hour ?? 9,
            minute: components.minute ?? 0,
            second: 0,
            of: day
        ) ?? day
    }
}

private struct DueChip: View {
    let date: Date
    let isCompleted: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(isCompleted ? Style.tertiary : tint)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(isCompleted ? Style.surface : tint.opacity(0.15), in: Capsule())
            .fixedSize()
            .help("截止 \(Self.absolute.string(from: date))")
            .accessibilityLabel("截止 \(Self.absolute.string(from: date))")
    }

    private var daysFromToday: Int {
        let calendar = Calendar.current
        return calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: .now),
            to: calendar.startOfDay(for: date)
        ).day ?? 0
    }

    private var label: String {
        switch daysFromToday {
        case ..<0: "已过期"
        case 0: "今天"
        case 1: "明天"
        default: Self.absolute.string(from: date)
        }
    }

    private var tint: Color {
        switch daysFromToday {
        case ..<0: Style.warning
        case 0: Style.accent
        default: Style.secondary
        }
    }

    private static let absolute: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .short
        formatter.timeStyle = .none
        return formatter
    }()
}

// MARK: - Focus history

/// 底部统计条。旧版是 7×13 的 5pt 方格，53pt 内容塞进 50pt 框会被裁切，
/// 且格子小到既看不清也点不中。改成最近 30 天的柱条，高度由当天专注时长决定。
/// 底部统计栏。
///
/// 旧版是"一句概要 + 30 根等高灰条"。没有记录时那 30 根灰条像一排加载骨架，
/// 有记录时也只回答了趋势，回答不了用户真正会问的三件事：今天做了没有、
/// 这周多少、连着几天了。现在把这三个数字摆在中间，趋势条退到右侧并且
/// 空白日只留一颗点——不再有那条"条形码"。
private struct FocusStatsBar: View {
    let days: [FocusDaySummary]

    private static let stripDayCount = 14
    private static let barWidth: CGFloat = 9
    private static let barSpacing: CGFloat = 4
    private static let barHeight: CGFloat = 24

    private var snapshot: FocusSnapshot { FocusHistory.snapshot(days) }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text("专注趋势")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Style.primary)
                Text(summary)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Style.tertiary)
                    .lineLimit(1)
            }
            .frame(width: 118, alignment: .leading)

            HStack(spacing: 13) {
                metric("今天", value: minuteText(snapshot.todayDuration), unit: "分",
                       highlighted: snapshot.todayCount > 0)
                metric("本周", value: "\(snapshot.weekCount)", unit: "次",
                       highlighted: snapshot.weekCount > 0)
                metric("连续", value: "\(snapshot.streakDays)", unit: "天",
                       highlighted: snapshot.streakDays >= 2)
            }
            .fixedSize()

            Spacer(minLength: 10)

            HStack(alignment: .bottom, spacing: Self.barSpacing) {
                ForEach(strip) { day in
                    FocusDayBar(day: day, isToday: day.id == strip.last?.id)
                        .frame(width: Self.barWidth, height: Self.barHeight)
                }
            }
            .fixedSize()
            .help("最近 \(strip.count) 天（左旧右新），柱高对应当日专注时长")
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func metric(
        _ title: String,
        value: String,
        unit: String,
        highlighted: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(Style.tertiary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(highlighted ? Style.accent : Style.secondary)
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(Style.tertiary)
            }
        }
    }

    private var strip: [FocusDaySummary] {
        Array(days.suffix(Self.stripDayCount))
    }

    private var summary: String {
        guard snapshot.hasAnyRecord else { return "完成一次后这里会长出来" }
        return "近 14 天 · \(snapshot.totalCount) 次 · \(minuteText(snapshot.totalDuration)) 分钟"
    }

    private func minuteText(_ duration: TimeInterval) -> String {
        "\(Int(duration / 60))"
    }

    private var accessibilityLabel: String {
        guard snapshot.hasAnyRecord else { return "专注趋势，还没有完成记录" }
        return "专注趋势，今天 \(snapshot.todayCount) 次，本周 \(snapshot.weekCount) 次，"
            + "连续 \(snapshot.streakDays) 天，图表显示最近 \(strip.count) 天"
    }
}

private struct FocusDayBar: View {
    let day: FocusDaySummary
    let isToday: Bool

    private let shape = RoundedRectangle(cornerRadius: 2.5, style: .continuous)

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                // 空槽也必须看得见。之前用的是 surfacePressed（约 14% 白），
                // 压在近黑面板上几乎分辨不出来——那才是"柱子看不到"的真因，
                // 不是高度不够。这里把空槽提到 22%，有记录的用亮橙实心。
                shape
                    .fill(Color.white.opacity(0.22))
                    .frame(height: proxy.size.height)
                if fill > 0 {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [Style.accent.opacity(0.78), Style.accent],
                                startPoint: .bottom,
                                endPoint: .top
                            )
                        )
                        .frame(height: max(6, proxy.size.height * fill))
                        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: fill)
                }
            }
        }
        .overlay {
            if isToday {
                shape.strokeBorder(Style.primary.opacity(0.7), lineWidth: 1.2)
            }
        }
        .help(tooltip)
    }

    private var fill: CGFloat {
        switch day.intensity {
        case 1: 0.34
        case 2: 0.58
        case 3: 0.80
        case 4...: 1
        default: 0
        }
    }

    private var tooltip: String {
        let date = day.date.formatted(.dateTime.month(.abbreviated).day())
        guard day.completedCount > 0 else { return "\(date) 没有记录" }
        return "\(date) · \(day.completedCount) 次 · \(Int(day.focusedDuration / 60)) 分钟"
    }
}


// MARK: - Detail and preview

struct DetailPanel: View {
    let item: Item
    @Bindable var model: AppModel
    @State private var draft = ""
    @FocusState private var editorFocused: Bool

    private var isEditing: Bool { model.editingItemID == item.id }
    private var isEditable: Bool { item.kind == .text && inlineText != nil }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kindTint)
                Text(isEditing ? "文字 · \(draft.count) 字" : item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Style.primary)
                    .lineLimit(1)
                Text(metadata)
                    .font(.system(size: 10))
                    .foregroundStyle(Style.tertiary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if isEditing {
                    Button("取消") { model.requestDismissDetail() }
                        .buttonStyle(SecondaryActionButtonStyle())
                    Button { Task { await model.commitEdit(item.id, text: draft) } } label: {
                        Label("确认", systemImage: "checkmark")
                    }
                    .buttonStyle(PrimaryActionButtonStyle())
                } else {
                    if item.aiPrivacyBlocked && !item.allowsSensitiveAI {
                        IconButton("shield.lefthalf.filled", help: "仅为这个 Pin 允许 AI 处理") {
                            Task { await model.allowSensitiveAI(for: item.id) }
                        }
                    }
                    IconButton(model.isTodo(item.id) ? "checkmark.circle.fill" : "checkmark.circle", help: model.isTodo(item.id) ? "移出待办" : "标为待办") {
                        Task { await model.setTodo(item.id, enabled: !model.isTodo(item.id)) }
                    }
                    if isEditable {
                        IconButton("pencil", help: "编辑文字") {
                            model.beginEditing(item); editorFocused = true
                        }
                    }
                    IconButton("doc.on.doc", help: "复制") { model.copy(item) }
                    if item.kind == .link || item.kind != .text {
                        IconButton("arrow.up.forward.app", help: "打开") { model.open(item) }
                    }
                    IconButton("trash", help: "移到回收站") {
                        Task { await model.trash(item.id) }
                    }
                    IconButton("xmark", help: "关闭预览") { model.requestDismissDetail() }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 46)

            Hairline()

            HStack(spacing: 0) {
            Group {
                if isEditing {
                    TextEditor(text: $draft)
                        .font(.system(size: 13))
                        .foregroundStyle(Style.primary)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .focused($editorFocused)
                        .onChange(of: draft) {
                            model.updateEditDirty(draft != (inlineText ?? ""), for: item.id)
                        }
                } else if item.kind == .link, let text = inlineText {
                    LinkDetail(
                        itemID: item.id,
                        text: text,
                        title: item.title,
                        open: { model.open(item) }
                    )
                } else if let text = inlineText {
                    ScrollView {
                        Text(text)
                            .font(.system(size: 13))
                            .foregroundStyle(Style.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(16)
                    }
                } else {
                    FilePreview(item: item, model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            // 问答和预览并排，不再上下挤成两条。窗口可以拉，两边一起长。
            if !isEditing, item.kind == .pdf, model.isPDFQuestioning {
                Hairline(vertical: true)
                PDFQuestionColumn(item: item, model: model)
                    .frame(width: 360)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            }
            .animation(.snappy(duration: 0.26), value: model.isPDFQuestioning)

            if !isEditing, !quickActions.isEmpty {
                Hairline()
                QuickActionBar(item: item, actions: quickActions, model: model)
                    .frame(height: 44)
            }
        }
        .onAppear { resetDraft() }
        .onChange(of: item.holding) { resetDraft() }
    }

    /// 固定的常用动作，按条目类型决定，不再由模型逐条生成建议。
    private var quickActions: [SceneActionID] {
        switch item.kind {
        case .image: [.plainText, .translate]
        case .pdf: [.askPDF, .summarize]
        case .text: [.translate, .summarize]
        case .link, .file, .binary: []
        }
    }

    private var inlineText: String? {
        if case .inline(let text) = item.holding { text } else { nil }
    }

    private var metadata: String {
        switch item.holding {
        case .inline(let value): "\(value.count) 字"
        case .copy(_, let size): "副本 · \(ByteFormat.short(size))"
        case .reference(_, let size): "引用 · \(ByteFormat.short(size))"
        }
    }

    private var glyph: String {
        switch item.kind {
        case .text: "text.alignleft"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .link: "link"
        case .file: "doc"
        case .binary: "shippingbox"
        }
    }

    private var kindTint: Color {
        switch item.kind {
        case .image: Style.cool
        case .pdf, .link: Style.accent
        default: Style.secondary
        }
    }

    private func resetDraft() {
        draft = inlineText ?? ""
        model.updateEditDirty(false, for: item.id)
        if isEditing { editorFocused = true }
    }
}

/// PDF 问答独立成右侧一栏。
///
/// 原来它压在预览下面，和预览、动作栏三层挤在固定高度里，回答永远被裁掉。
private struct PDFQuestionColumn: View {
    let item: Item
    @Bindable var model: AppModel
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Style.accent)
                Text("问这篇 PDF")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Style.primary)
                Spacer(minLength: 0)
                if model.isAnsweringPDF {
                    ProcessingDots(tint: Style.cool, dotSize: 3).frame(width: 22, height: 12)
                }
                Button { model.isPDFQuestioning = false } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Style.secondary)
                .help("收起问答")
            }
            .padding(.horizontal, 14)
            .frame(height: 38)

            Hairline()

            ScrollView {
                Group {
                    if model.isAnsweringPDF, model.pdfAnswer == nil {
                        VStack(alignment: .leading, spacing: 6) {
                            ProcessingSkeleton(widthFraction: 0.94)
                            ProcessingSkeleton(widthFraction: 0.78)
                            ProcessingSkeleton(widthFraction: 0.56)
                        }
                    } else if let answer = model.pdfAnswer {
                        MarkdownText(raw: answer, font: .system(size: 11.5))
                            .opacity(model.isAnsweringPDF ? 0.54 : 1)
                    } else {
                        Text("问点什么，比如「它解决的核心问题是什么」「第 4 页讲了什么」。")
                            .font(.system(size: 11))
                            .foregroundStyle(Style.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: .infinity)

            Hairline()

            HStack(spacing: 8) {
                TextField("询问这份 PDF", text: $question)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .focused($focused)
                    .onSubmit { submit() }
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 17))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(canSubmit ? Style.accent : Style.tertiary)
                .disabled(!canSubmit)
                .help("发送问题")
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(Style.surfaceHover, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(Style.stroke) }
            .padding(12)
        }
        .frame(maxHeight: .infinity)
        .onAppear { focused = true }
        .animation(.easeInOut(duration: 0.22), value: model.isAnsweringPDF)
    }

    private var canSubmit: Bool {
        !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !model.isAnsweringPDF
    }

    private func submit() {
        guard canSubmit else { return }
        model.askPDF(question, about: item)
    }
}

/// 详情底部的常用动作。尺寸固定、文案固定，不受模型输出长度影响。
private struct QuickActionBar: View {
    let item: Item
    let actions: [SceneActionID]
    @Bindable var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(actions, id: \.self) { action in
                Button { perform(action) } label: {
                    HStack(spacing: 5) {
                        if model.runningSceneAction == action {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: action.symbol)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        Text(title(action))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Style.primary)
                    .padding(.horizontal, 11)
                    .frame(height: 30)
                    .background(Style.surfaceHover, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Style.stroke) }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(model.runningSceneAction != nil)
                .help(help(action))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
    }

    private func perform(_ action: SceneActionID) {
        model.performSceneRecommendation(
            SceneRecommendation(
                id: action,
                title: title(action),
                reason: "",
                confidence: 1,
                requiresConfirmation: false
            ),
            on: item
        )
    }

    private func title(_ action: SceneActionID) -> String {
        switch action {
        case .plainText: "取文字"
        case .translate: "翻译"
        case .summarize: "摘要"
        case .askPDF: "问这篇 PDF"
        case .extractTaxNumber: "提取税号"
        case .copy: "复制"
        case .open: "打开"
        case .preview: "预览"
        case .createTodo: "加入待办"
        }
    }

    private func help(_ action: SceneActionID) -> String {
        switch action {
        case .plainText: "识别图片里的文字并复制"
        case .translate: "翻译内容并复制结果"
        case .summarize: "生成摘要并复制结果"
        case .askPDF: "对这篇 PDF 提问"
        default: title(action)
        }
    }
}

private struct TodoRecognitionEdge<S: Shape>: View {
    let shape: S
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lit = false

    var body: some View {
        shape
            .stroke(Style.cool.opacity(reduceMotion ? 0.24 : (lit ? 0.34 : 0.10)), lineWidth: 0.8)
            .shadow(color: Style.cool.opacity(reduceMotion ? 0.10 : (lit ? 0.20 : 0.04)), radius: lit ? 4 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 1.25).repeatForever(autoreverses: true), value: lit)
            .onAppear { lit = true }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct EdgeStatusGlow<S: Shape>: View {
    let shape: S
    let signal: AppModel.EdgeStatusSignal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

    var body: some View {
        // 一下弹到亮、带一点回弹地稳住，而不是持续来回的呼吸——那种慢悠悠的
        // 律动更适合"还在识别"，拿来说"成功了"反而含糊：短暂展示时甚至等不到
        // 一次完整的呼吸就被收掉，看着像没反应。这里改成一次性的弹簧上扬，
        // 停在明显亮的那一档，直到这条信号自己过期消失。
        shape
            .stroke(color.opacity(reduceMotion ? 0.42 : (active ? 0.62 : 0.12)), lineWidth: 1.1)
            .shadow(color: color.opacity(reduceMotion ? 0.18 : (active ? 0.4 : 0.04)), radius: active ? 6 : 2)
            .animation(
                reduceMotion ? nil : .spring(response: 0.22, dampingFraction: 0.55),
                value: active
            )
            .onAppear { active = true }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch signal {
        case .focusCompleted: Style.accent
        case .indexingFailed: Style.warning
        case .todoCreated: Style.cool
        }
    }
}

private struct ProcessingDots: View {
    var tint = Style.secondary
    var dotSize: CGFloat = 4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

    var body: some View {
        HStack(spacing: dotSize) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(tint)
                    .frame(width: dotSize, height: dotSize)
                    .scaleEffect(reduceMotion ? 1 : (active == (index % 2 == 0) ? 1 : 0.62))
                    .opacity(reduceMotion ? 0.72 : (active == (index % 2 == 0) ? 0.95 : 0.34))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.62).repeatForever(autoreverses: true),
                   value: active)
        .onAppear { active = true }
    }
}

private struct ProcessingSkeleton: View {
    let widthFraction: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var active = false

    var body: some View {
        GeometryReader { proxy in
            Capsule()
                .fill(Style.surfacePressed)
                .frame(width: proxy.size.width * widthFraction, height: 7)
                .opacity(reduceMotion ? 0.7 : (active ? 0.86 : 0.36))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.86).repeatForever(autoreverses: true),
                           value: active)
        }
        .frame(height: 7)
        .onAppear { active = true }
    }
}

private extension SceneActionID {
    var symbol: String {
        switch self {
        case .copy: "doc.on.doc"
        case .open: "arrow.up.forward.app"
        case .preview: "eye"
        case .extractTaxNumber: "number"
        case .plainText: "text.alignleft"
        case .translate: "character.book.closed"
        case .summarize: "list.bullet.rectangle"
        case .askPDF: "questionmark.bubble"
        case .createTodo: "checkmark.circle"
        }
    }
}

/// 链接详情：像浏览器一样显示这一页。
///
/// 之前默认给封面，而且用的是裁剪填充——一张宽图会被放大到糊、还溢出显示区。
/// 现在默认就把页面渲染出来，地址栏在顶上，内容随窗口大小自适应；
/// 想看社交卡片那张封面时再切过去，而且是按比例缩放，不再拉伸。
private struct LinkDetail: View {
    enum Mode { case page, cover }

    let itemID: UUID
    let text: String
    let title: String
    let open: () -> Void

    @State private var mode: Mode = .page
    @State private var loadFailed = false

    private var url: URL? { URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) }
    private var host: String? { url?.host() }

    var body: some View {
        VStack(spacing: 0) {
            addressBar
            Hairline()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 地址栏：站点图标 + 域名 + 标题，右边是动作。读起来就是一个浏览器标签。
    private var addressBar: some View {
        HStack(spacing: 8) {
            Group {
                if let host {
                    DomainBadge(host: host, fontSize: 8)
                } else {
                    Image(systemName: "link").font(.system(size: 9, weight: .semibold))
                }
            }
            .frame(width: 15, height: 15)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            Text(host ?? title)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Style.secondary)
                .lineLimit(1)
            Text(url?.path().isEmpty == false ? url!.path() : "")
                .font(.system(size: 11))
                .foregroundStyle(Style.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)
            // 复制、在浏览器打开、关闭在详情头部已经有了，这里再放一遍就是
            // 同一行动作出现两次。地址栏只留它独有的那一个：页面 / 封面。
            barButton(
                mode == .page ? "photo" : "doc.richtext",
                help: mode == .page ? "看社交卡片封面" : "看页面"
            ) {
                loadFailed = false
                mode = mode == .page ? .cover : .page
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
    }

    @ViewBuilder
    private var content: some View {
        if mode == .page, let url, !loadFailed {
            WebPreview(url: url, failed: $loadFailed)
        } else if let cover = LinkCoverStore.cachedImage(for: itemID) {
            // 按比例缩放：填充会把一张宽图放大到糊，还会顶出显示区。
            Image(nsImage: cover)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
                .background(Style.ink)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            if let host {
                DomainBadge(host: host, fontSize: 30)
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Style.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(loadFailed ? "这个页面暂时打不开" : text)
                .font(.system(size: 11))
                .foregroundStyle(Style.tertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Button("在浏览器打开", action: open)
                .buttonStyle(SecondaryActionButtonStyle())
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func barButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Style.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// 详情里的内嵌网页。只在用户主动切换到"看页面"时才加载。
private struct WebPreview: NSViewRepresentable {
    let url: URL
    @Binding var failed: Bool

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        view.navigationDelegate = context.coordinator
        // 同 PDF：网页多数是白底，滚动条不能跟着窗口的深色外观画。
        view.appearance = NSAppearance(named: .aqua)
        view.load(URLRequest(url: url, timeoutInterval: 15))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        nsView.load(URLRequest(url: url, timeoutInterval: 15))
    }

    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed, loaded: url) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding private var failed: Bool
        var loaded: URL?

        init(failed: Binding<Bool>, loaded: URL?) {
            self._failed = failed
            self.loaded = loaded
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            failed = true
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: any Error
        ) {
            failed = true
        }
    }
}

private struct FilePreview: View {
    let item: Item
    @Bindable var model: AppModel
    @State private var url: URL?
    @State private var image: NSImage?
    @State private var text: String?
    @State private var icon: NSImage?
    @State private var loadFailed = false

    var body: some View {
        Group {
            if let image, item.kind == .image {
                Image(nsImage: image).resizable().scaledToFit().padding(12)
            } else if let url, item.kind == .pdf {
                PDFDocumentPreview(url: url)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else if let text, item.kind == .text {
                ScrollView {
                    Text(text)
                        .font(.system(size: 13))
                        .foregroundStyle(Style.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
            } else if loadFailed {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(Style.warning)
                    Text("无法读取预览")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Style.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 16) {
                    Group {
                        if let icon {
                            Image(nsImage: icon).resizable().scaledToFit()
                        } else {
                            ProgressView().controlSize(.small)
                                .scaleEffect(1.2)
                        }
                    }
                    .frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.originalFilename ?? item.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Style.primary)
                        Text(fileMetadata)
                            .font(.system(size: 11))
                            .foregroundStyle(Style.tertiary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(item.id)-\(model.linkCoverGeneration(for: item.id))") { await load() }
    }

    private func load() async {
        do {
            guard let resolved = try await model.library.resolvedFileURL(for: item) else {
                loadFailed = true; return
            }
            url = resolved
            icon = NSWorkspace.shared.icon(forFile: resolved.path)
            if item.kind == .image {
                image = await ThumbnailStore.shared.image(
                    item: item,
                    url: resolved,
                    logicalSize: 900
                )
                loadFailed = image == nil
            }
            if item.kind == .text {
                text = await Task.detached(priority: .userInitiated) {
                    let limit = 2 * 1_024 * 1_024
                    guard let handle = try? FileHandle(forReadingFrom: resolved) else { return nil }
                    defer { try? handle.close() }
                    guard let data = try? handle.read(upToCount: limit),
                          var value = String(data: data, encoding: .utf8) else { return nil }
                    if data.count == limit { value += "\n\n[预览已截断]" }
                    return value
                }.value
                loadFailed = text == nil
            }
        } catch {
            loadFailed = true
            model.lastError = error.localizedDescription
        }
    }

    private var fileMetadata: String {
        switch item.holding {
        case .inline: "文字"
        case .copy(_, let size): "本地副本 · \(ByteFormat.short(size))"
        case .reference(_, let size): "原文件引用 · \(ByteFormat.short(size))"
        }
    }
}

private struct PDFDocumentPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.backgroundColor = .clear
        // 详情窗整扇被钉成深色（那是为了让我们自己的控件取到正确的文字颜色），
        // 而这里显示的是白底的 PDF 页面。滚动条会跟着窗口的深色外观画，
        // 于是白纸上出现一条纯黑的粗条——看不清，也不像滚动条。
        // 内容是浅色的，滚动条就该按浅色画。
        view.appearance = NSAppearance(named: .aqua)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
        // 悬浮滚动条：不占版面，也不会在页面边上留一条常驻的槽。
        view.enclosingScrollView?.scrollerStyle = .overlay
        view.subviews.compactMap { $0 as? NSScrollView }.forEach {
            $0.scrollerStyle = .overlay
            $0.horizontalScrollElasticity = .allowed
        }
    }
}

private struct Hairline: View {
    var vertical = false

    var body: some View {
        Rectangle()
            .fill(Style.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    var expands = false

    func makeBody(configuration: Configuration) -> some View {
        let maxWidth: CGFloat? = expands ? .infinity : nil
        return configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Style.ink.opacity(0.82))
            .padding(.horizontal, 16)
            .frame(maxWidth: maxWidth)
            .frame(height: 34)
            .background(Style.accent.opacity(configuration.isPressed ? 0.76 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Style.primary.opacity(configuration.isPressed ? 0.62 : 1))
            .padding(.horizontal, 13)
            .frame(height: 32)
            .background(Style.contentElevated.opacity(configuration.isPressed ? 0.72 : 1))
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(Style.hairline, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

private struct StatusToast: View {
    let message: String
    var isError = false
    var dismiss: (() -> Void)?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? Style.warning : Style.cool)
                .allowsHitTesting(false)
            Text(message).lineLimit(1).truncationMode(.middle)
                .allowsHitTesting(false)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(Style.accent)
            }
            if let dismiss {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Style.secondary)
                .help("关闭")
            }
        }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Style.primary)
            .padding(.horizontal, 13)
            // 错误文案的长度不受我们控制（供应商返回的原文都在里面）。
            // 不封顶的话横幅会顶到面板两侧，圆角都被裁掉。
            .frame(maxWidth: 380)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: 30)
            // 横幅浮在卡片轨道上方，而它要停留好几秒。整块都收鼠标的话，
            // 这几秒里横幅底下那一段卡片就是死的——删掉一条之后紧接着再删
            // 第二条，点下去毫无反应，看起来就是"删除按钮时好时坏"。
            //
            // 只有按钮该收鼠标：图标、文字和这层胶囊底一律让点击穿过去。
            .background {
                Capsule()
                    .fill(Style.contentElevated)
                    .overlay { Capsule().stroke(Style.hairline, lineWidth: 1) }
                    .allowsHitTesting(false)
            }
            .clipShape(Capsule())
            .shadow(color: Style.ink.opacity(0.24), radius: 12, y: 5)
            // Toast 出现时有轻微的 scale + slide 组合，比纯 fade 更有质感
            .transition(.move(edge: .bottom).combined(with: .scale(scale: 0.94)).combined(with: .opacity))
    }
}

private enum TimeFormat {
    static func mmss(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval.rounded(.up)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

private enum ByteFormat {
    static func short(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: count)
    }
}


/// ⌘ 点选。
///
/// SwiftUI 没有"带修饰键的点击"手势，`onTapGesture` 也拿不到当时的修饰键。
/// 用一个高优先级手势在触发时读一次 `NSEvent.modifierFlags`——那是当前真实的
/// 键盘状态，比自己维护一份可靠。没按 ⌘ 时手势不消费，点击照常落到下面的
/// 复制手势上。
private struct CommandClickSelection: ViewModifier {
    @Bindable var model: AppModel
    let itemID: UUID

    func body(content: Content) -> some View {
        content.highPriorityGesture(
            TapGesture().onEnded {
                guard NSEvent.modifierFlags.contains(.command) else { return }
                model.toggleSelection(itemID)
            },
            including: NSEvent.modifierFlags.contains(.command) ? .all : .subviews
        )
    }
}
