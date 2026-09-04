import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Observation
import MnemoCore
import MnemoStore
import UniformTypeIdentifiers

@MainActor
@Observable
final class AppModel {

    struct IngestReport: Sendable {
        var inserted = 0
        var reused = 0
        var failed = 0

        mutating func merge(_ other: Self) {
            inserted += other.inserted
            reused += other.reused
            failed += other.failed
        }
    }

    enum Mode: String, CaseIterable, Identifiable {
        case stash = "收纳"
        case focus = "效率"

        var id: String { rawValue }
        var symbol: String { self == .stash ? "tray.full" : "checklist" }
    }

    struct ContextSuggestion: Identifiable, Equatable, Sendable {
        var id: UUID { itemID }
        var itemID: UUID
        var title: String
        var reason: String
        var kind: ItemKind
        /// 本地证据唯一确定了目标，内容已经替用户放进剪贴板。
        var didAutoCopy: Bool
        /// 用户已经按下这行，文件 URL / 剪贴板写入还没完成。
        var isCopying = false
        /// 写入失败时保留在行内，不能静默得像"没点到"。
        var copyError: String?
    }

    struct ContextResolution: Sendable {
        /// 唯一确定时只有一条；有歧义时给出几条让用户挑。
        var suggestions: [ContextSuggestion] = []
        /// 这段内容被判定成"来找东西的"，不是"要存下来的"。
        var isRetrievalQuery = false
        /// 字段型：直接写这一串值（税号、邮箱、单号……）。
        var autoCopyText: String?
        /// 整条型：写这个条目（论文文件、图片……）。
        /// 两者都走会登记 changeCount 的写入路径，否则监听器会把自写
        /// 当成一次新的复制再触发一轮。
        var autoCopyItemID: UUID?
        /// 解释型快捷请求：不要把候选片段当作复制载荷；用本轮真实 ID 读取完整
        /// 本地证据，再生成一个独立的中文回答。
        var answerRequest: String?
        var answerEvidenceItemIDs: [UUID] = []
    }

    enum BarState: Int, Comparable, Hashable, CaseIterable {
        // 顺序即优先级：数值大的压过数值小的。提醒排在推荐之上——用户自己
        // 设的截止时间到了，比"库里可能有相关内容"更需要立刻被看见。
        case idle = 0, syncing, indexing, paused, timing, todoDraft, suggesting, reminding, dropTargeted
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }

    enum InboundPayloadKind: Hashable {
        case text, image, file, link, unknown

        var symbol: String {
            switch self {
            case .text: "text.alignleft"
            case .image: "photo"
            case .file: "doc"
            case .link: "link"
            case .unknown: "arrow.down"
            }
        }
    }

    enum EdgeStatusSignal: Hashable {
        case focusCompleted
        case indexingFailed
    }

    enum Tab: Hashable {
        case all
        case kind(ItemKind)
        /// 隐私空间。它是一个页签而不是一块新面板——面板一共 212 点高，
        /// 任何新增的常驻区域都在跟卡片抢地方，而页签栏本来就横向滚动。
        case privateSpace

        var label: String {
            switch self {
            case .all: "全部"
            case .privateSpace: "隐私"
            case .kind(let kind):
                switch kind {
                case .text: "文字"
                case .image: "图片"
                case .pdf: "PDF"
                case .link: "链接"
                case .file: "文件"
                case .binary: "其他"
                }
            }
        }
    }

    private struct SceneCacheEntry: Codable {
        var contentFingerprint: String
        var routeFingerprint: String
        var recommendations: [SceneRecommendation]
    }

    private static let modeKey = "Pinland.mode"
    private static let focusDurationKey = "Pinland.focusDurationMinutes"
    private static let indexQueueKey = "Pinland.pendingIndexIDs"
    private static let forcedLinkRefreshKey = "Pinland.forcedLinkRefreshIDs"
    private static let knownInvalidLinkPageKey = "Pinland.knownInvalidLinkPageIDs"
    private static let aiQueueKey = "Pinland.pendingAIIDs"
    private static let sceneCacheKey = "Pinland.sceneRecommendationCache.v1"
    private static let edgeStatusEffectsKey = "Pinland.edgeStatusEffectsEnabled"
    private static let preferredBrowserKey = "Pinland.preferredBrowser"
    private static let autoGroupingKey = "Pinland.autoGrouping"
    static let launchAtLoginKey = "Pinland.launchAtLogin"
    private static let expandTriggerKey = "Pinland.notchExpandTrigger"
    private static let processesTemporaryClipboardKey = "Pinland.processesTemporaryClipboard"
    private static let processableTemporaryIDsKey = "Pinland.processableTemporaryClipboardIDs"
    private static let todoIntakeKey = "Pinland.todoIntakeEnabled"
    private static let todoAutoCreateKey = "Pinland.todoAutoCreateFromClipboard"
    private static let screenshotTodoScanKey = "Pinland.screenshotTodoScanEnabled"
    private static let reminderSettingsKey = "Pinland.todoReminderSettings.v1"
    private static let deliveredRemindersKey = "Pinland.deliveredReminderKeys.v1"
    private static let aiSettledKey = "Pinland.aiSettledItemIDs"
    private static let aiSettledFingerprintKey = "Pinland.aiSettledRoutingFingerprint"
    private static let todoScanQueueKey = "Pinland.pendingTodoScanIDs.v1"

    private(set) var items: [Item] = [] {
        didSet { visibleItemsRevision &+= 1 }
    }
    private(set) var trashedItems: [Item] = []
    private(set) var todos: [Todo] = []
    private(set) var todoItems: [Todo] = []
    private(set) var focusSessions: [FocusSession] = []
    private(set) var focusHeatmap: [FocusDaySummary] = FocusHistory.summaries(sessions: [], days: 91)
    private(set) var activeStorageBytes: Int64 = 0
    private(set) var trashStorageBytes: Int64 = 0
    var query = "" {
        didSet {
            guard query != oldValue else { return }
            understoodSearchQuery = nil
            scheduleSemanticSearch()
        }
    }
    var isSearching = false
    var activeTab: Tab = .all {
        didSet {
            guard activeTab != oldValue else { return }
            // 平台筛选只属于链接页签。切走不清掉的话，切回来时它还在生效，
            // 而那一排可能已经不显示了——变成一个看不见的过滤器。
            activeLinkGroup = nil
            platformRowShouldCollapse &+= 1
            // 走出隐私空间就立刻上锁。"解锁"的作用域是**待在里面这段时间**，
            // 不是"这次开机剩下的时间"——切到全部再切回来还能直接进去的话，
            // 那把锁只挡住了第一次。
            if oldValue == .privateSpace, isPrivateSpaceUnlocked { lockPrivateSpace() }
            clearCardGroupSelectionLeavingAllTab()
            requestScrollToFirstCard()
        }
    }

    // MARK: - 隐私空间
    //
    // 它**只隐藏，不加密**：库文件里仍是明文。所以界面上一律说"已隐藏"，
    // 绝不说"已加密"——让用户以为数据被保护了，比不提供这个功能更糟。
    //
    // 真正让"隐藏"有意义的不是这把锁，是把内容从检索链路里摘干净：分块删掉、
    // 索引跳过、候选与证据全部过滤。锁只挡住眼睛，检索才是真正的后门。

    /// 解锁状态**不持久化**：每次启动都是锁上的。
    private(set) var isPrivateSpaceUnlocked = false
    private(set) var privateUnlockError: String?
    @ObservationIgnored private var privateUnlockTask: Task<Void, Never>?

    var privateItemCount: Int { items.count { $0.isPrivate } }

    /// 用系统的"设备所有者"策略：一个 API 同时给 Touch ID 和密码回退，
    /// 没有指纹硬件的机器自动只走密码，不用我们自己判断。
    func unlockPrivateSpace() {
        guard !isPrivateSpaceUnlocked, privateUnlockTask == nil else { return }
        privateUnlockError = nil
        privateUnlockTask = Task { [weak self] in
            defer { self?.privateUnlockTask = nil }
            let context = LAContext()
            context.localizedCancelTitle = "取消"
            do {
                let ok = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "查看隐私空间里的内容"
                )
                guard let self, ok else { return }
                self.isPrivateSpaceUnlocked = true
                self.privateUnlockError = nil
            } catch {
                guard let self else { return }
                // 用户主动取消不是错误，不该在界面上留一条红字。
                let code = (error as NSError).code
                guard code != LAError.userCancel.rawValue,
                      code != LAError.appCancel.rawValue,
                      code != LAError.systemCancel.rawValue else { return }
                self.privateUnlockError = "验证失败：\(error.localizedDescription)"
            }
        }
    }

    func lockPrivateSpace() {
        privateUnlockTask?.cancel()
        privateUnlockTask = nil
        isPrivateSpaceUnlocked = false
        privateUnlockError = nil
        selectedIDs.removeAll()
        if activeTab == .privateSpace { activeTab = .all }
    }

    /// 收起面板就锁回去。不做这一步，解锁一次就一直开着，等于没锁。
    func lockPrivateSpaceOnCollapse() {
        guard isPrivateSpaceUnlocked else { return }
        lockPrivateSpace()
    }

    /// 批量操作用的多选。视觉上复用卡片已有的选中边框，不加新控件。
    private(set) var selectedIDs: Set<UUID> = []

    func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) } else { selectedIDs.insert(id) }
    }

    func clearSelection() { selectedIDs.removeAll() }

    func selectAllVisible() { selectedIDs = Set(visibleItems.map(\.id)) }

    /// 一次移动的目标：选中了就是选中的那批，没选中就是被操作的那一条。
    func privacyTargets(anchor id: UUID) -> [UUID] {
        selectedIDs.contains(id) ? Array(selectedIDs) : [id]
    }

    func setPrivate(_ ids: [UUID], isPrivate: Bool) async {
        guard !ids.isEmpty else { return }
        do {
            for id in ids { try await library.setPrivate(id: id, isPrivate: isPrivate) }
            selectedIDs.subtract(ids)
            await reload()
            // 被选中的分组可能已经没有一条可见内容了（比如 X 唯一一条刚被
            // 藏进隐私空间）。筛选还留着的话，用户看到的是一片空白加一排
            // 点不动的入口——把失效的筛选撤掉，回到全部。
            if let group = activeLinkGroup, !availableLinkGroups.contains(group) {
                activeLinkGroup = nil
            }
            showTransientFeedback(
                isPrivate ? "已移入隐私空间（\(ids.count)）" : "已移出隐私空间（\(ids.count)）"
            )
        } catch {
            lastError = "隐私空间操作失败：\(error.localizedDescription)"
        }
    }

    /// 请求把平台那一摞收回折叠态。切走页签时用——否则下次回到链接页签
    /// 它还是展开的，占着本该属于卡片的宽度。
    private(set) var platformRowShouldCollapse = 0

    /// 请求把卡片条滚回第一张。视图订阅它，每加一就滚一次。
    ///
    /// 用计数器而不是布尔：布尔要视图滚完再复位，中间那一拍如果又来一次请求
    /// 就被吞掉了。计数器每次都是新值，不存在"已经是 true 所以不触发"。
    private(set) var scrollToFirstCardRequest = 0

    /// 封面抓好一张就加一。卡片订阅它来重读缓存。
    ///
    /// 卡片的缩略图是 `.task(id:)` 里一次性读的，而 `item.id` 不会因为封面
    /// 到货而改变——于是封面明明已经存进 `LinkCoverStore`，卡片还是空的，
    /// 要等切页签、滚走再回来把视图整个重建才显示。用户看到的就是
    /// "拖进去的链接要过一会才有预览图"。
    /// 每条链接自己的封面代次。某一张封面回来，只重载那一张卡。
    /// 全局 Int 会让所有可见卡（包括非链接）一起重跑 resolvedFileURL + 缩略图。
    private(set) var linkCoverGenerations: [UUID: Int] = [:]

    func linkCoverGeneration(for id: UUID) -> Int { linkCoverGenerations[id, default: 0] }

    func requestScrollToFirstCard() {
        scrollToFirstCardRequest &+= 1
    }
    var detailItem: Item?
    private(set) var sceneRecommendations: [SceneRecommendation] = []
    private(set) var isLoadingSceneRecommendations = false
    private(set) var runningSceneAction: SceneActionID?
    var isPDFQuestioning = false
    private(set) var isAnsweringPDF = false
    private(set) var pdfAnswer: String?
    private(set) var semanticHits: [SemanticSearchHit] = [] {
        didSet {
            visibleItemsRevision &+= 1
            semanticHitIndex = Dictionary(
                semanticHits.map { ($0.itemID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    @ObservationIgnored private var semanticHitIndex: [UUID: SemanticSearchHit] = [:]

    private(set) var retrievalRecommendations: [RetrievalRecommendation] = [] {
        didSet {
            retrievalRecommendationIndex = Dictionary(
                retrievalRecommendations.map { ($0.itemID, $0) },
                uniquingKeysWith: { first, _ in first }
            )
        }
    }
    @ObservationIgnored private var retrievalRecommendationIndex: [UUID: RetrievalRecommendation] = [:]
    private(set) var semanticQuery = ""
    private(set) var understoodSearchQuery: StructuredQuery?
    private(set) var isPerformingSemanticSearch = false
    /// LLM 对本次查询的自然语言回答，逐段到达。
    /// 剪贴板上下文推荐。刚复制的内容像是在索取库里的东西时才有值。
    private(set) var contextSuggestions: [ContextSuggestion] = []
    /// 快捷推荐中的解释答案。和候选卡片同属一轮 contextGeneration；新请求、关闭
    /// 或过期都会一起清空，收起工作台不会取消它。
    private(set) var contextAnswer: String?
    private(set) var contextAnswerError: String?
    /// 只有最终回答实际写进系统剪贴板后才为 true；失败时回答仍保留，按钮可重试。
    private(set) var didAutoCopyContextAnswer = false
    /// 这一轮回答落到了哪里。nil = 还没交付（正在生成，或生成失败）。
    private(set) var contextAnswerDelivery: AnswerDeliveryRoute?
    /// 正在逐段写进输入框。卡片要说“正在写进”，不能提前说“已写进”。
    private(set) var isStreamingContextAnswer = false

    // MARK: - 思考过程
    //
    // 推理模型在给出答案之前会先写一段自己的推演。以前它有两种下场：混进正文
    // 把答案挤到看不见（内联 `<think>`），或者被解码层直接丢掉（结构化字段）。
    // 两种都不对——等待的那几秒里，它是唯一能说明“机器没死、正在想”的信号。
    //
    // 现在它是一条独立通道：生成时快速滚动着展示，答案一开始落地就自动折叠成
    // 一行，用户想看再点开。

    enum ReasoningPhase: Equatable, Sendable {
        case none
        /// 正在想，还没有一个正文字符。这一段要动起来。
        case thinking
        /// 想完了（答案开始落地，或流结束）。折叠成一行。
        case settled
    }

    private(set) var contextReasoning = ""
    private(set) var contextReasoningPhase: ReasoningPhase = .none
    /// 折叠行上那句“已思考 N 秒”。想完才定值，想的过程中实时算。
    private(set) var contextReasoningDuration: TimeInterval?
    @ObservationIgnored private var contextReasoningStartedAt: Date?
    /// 用户点开了折叠行。它由用户控制，不随新一轮自动恢复——除非换了一轮问答。
    var isContextReasoningExpanded = false

    /// 思考里已经攒了多久。折叠行和展开视图共用这一个数。
    var contextReasoningElapsed: TimeInterval {
        if let duration = contextReasoningDuration { return duration }
        guard let started = contextReasoningStartedAt else { return 0 }
        return Date.now.timeIntervalSince(started)
    }

    func appendContextReasoning(_ delta: String, generation: Int) {
        guard generation == contextGeneration, !delta.isEmpty else { return }
        if contextReasoningPhase == .none {
            contextReasoningStartedAt = .now
            contextReasoningDuration = nil
            isContextReasoningExpanded = false
        }
        contextReasoningPhase = .thinking
        contextReasoning += delta
        // 思考可以很长，而卡片只有那么大。留最近的一段——用户真要读全文时，
        // 展开视图本来也是从头滚的，但内存里不必留一篇论文。
        if contextReasoning.count > Self.maximumReasoningCharacters {
            contextReasoning = String(contextReasoning.suffix(Self.maximumReasoningCharacters))
        }
    }

    /// 答案开始落地，或者这一轮结束了：把思考定格并折叠。
    func settleContextReasoning() {
        guard contextReasoningPhase == .thinking else { return }
        contextReasoningPhase = .settled
        contextReasoningDuration = contextReasoningStartedAt.map { Date.now.timeIntervalSince($0) }
    }

    private func clearContextReasoning() {
        contextReasoning = ""
        contextReasoningPhase = .none
        contextReasoningDuration = nil
        contextReasoningStartedAt = nil
        isContextReasoningExpanded = false
    }

    private static let maximumReasoningCharacters = 8_000
    /// 内容本身是否未完成。复制只能改变落点，不能把半成品洗成“完整回答”。
    private var isContextAnswerIncomplete = false
    private(set) var isResolvingContext = false
    @ObservationIgnored private var contextTask: Task<Void, Never>?
    @ObservationIgnored private var contextDismissTask: Task<Void, Never>?
    @ObservationIgnored private var contextResolutionCache: [ContextualProcessingKey: ContextResolution] = [:]
    @ObservationIgnored private var contextResolutionOrder: [ContextualProcessingKey] = []
    private static let contextResolutionCacheLimit = 32
    @ObservationIgnored private var contextGeneration = 0
    @ObservationIgnored var clipboardContextAction: (
        (ClipboardContextEvent, [Item], UUID?, Bool) async -> ContextResolution
    )?
    /// 只回答"这段刚复制的文字是不是在找东西"，用来决定它要不要留进轨道。
    @ObservationIgnored var queryClassifierAction: ((String) async -> Bool)?
    @ObservationIgnored var contextAnswerAction: ((String, [UUID], [Item]) async -> String?)?
    /// 同一个回答的逐段版本。只有“写进前台输入框”这条路径用它。
    @ObservationIgnored var contextAnswerStreamAction: (
        (String, [UUID], [Item]) -> AsyncThrowingStream<AIStreamChunk, any Error>
    )?
    /// 用户在设置里允不允许直接写进输入框。默认开。
    @ObservationIgnored var prefersAnswerInFocusedInputAction: (() -> Bool)?
    /// 按下 ⌘G 那一刻抓到的输入框。等回答生成完再问系统“焦点在哪”就晚了。
    @ObservationIgnored private var pendingAnswerInsertion: FocusedInputTarget?
    /// 只有本轮文字确实来自这个输入框的当前选区才允许回写。记忆降级的旧选区
    /// 可以继续检索，但不能据此往眼前输入框里注入回答。
    @ObservationIgnored private var pendingAnswerInsertionWasCurrentSelection = false
    @ObservationIgnored private var queryClassifyTask: Task<Void, Never>?
    @ObservationIgnored private var classifiedQueries: Set<String> = []

    private(set) var searchAnswer = ""
    private(set) var isStreamingSearchAnswer = false
    private(set) var searchAnswerError: String?
    @ObservationIgnored private var searchAnswerTask: Task<Void, Never>?
    @ObservationIgnored private var pendingSearchAnswer: String?
    @ObservationIgnored private var searchAnswerFlushTask: Task<Void, Never>?
    @ObservationIgnored private var searchGeneration = 0
    var mode: Mode {
        didSet {
            guard ProcessInfo.processInfo.environment["MNEMO_DATA_ROOT"] == nil else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        }
    }

    private(set) var notchPresentation = NotchPresentationState()
    var isIndexing = false
    private(set) var isAIProcessing = false
    var isPinnedOpen = false
    private(set) var inboundPayloadKind: InboundPayloadKind = .unknown
    private(set) var edgeStatusSignal: EdgeStatusSignal?
    /// 自动捕获、尚未固定的剪贴板截图 / 文字要不要立即跑 OCR / AI / Embedding。
    /// 默认 false：临时轨道只负责保留，固定后或主动拖入才进入完整处理。
    var processesTemporaryClipboard: Bool {
        didSet {
            UserDefaults.standard.set(
                processesTemporaryClipboard,
                forKey: Self.processesTemporaryClipboardKey
            )
            // 只影响从这一刻以后新捕获的条目。已有队列、已有索引与旧临时项
            // 全部保持原状，不全量补跑，也不撤销正在进行的任务。
        }
    }

    /// 用户在设置里钉死的浏览器。
    ///
    /// nil = 跟随来源：这条链接从哪个浏览器拖进来的，就回哪个去（登录态、
    /// 扩展、书签都在那边，换一个浏览器等于换了个环境）。选定某一个之后它
    /// 一律优先——用户明确挑过的，不该再被"来源记忆"推翻。
    /// 新内容要不要自动归进已有分组。
    ///
    /// 只在**已经有分组**的时候才有意义：模型只能在用户建好的组里选，
    /// 建组永远是用户的动作。触发时机和检索索引同一条路——不是主动拖进来的
    /// 临时内容不会每次都去问模型。
    /// 开机自启。真值以系统为准——用户可能在「系统设置 → 登录项」里关掉，
    /// 我们自己存的那份就成了谎话。
    var launchesAtLogin: Bool {
        didSet {
            guard launchesAtLogin != oldValue else { return }
            UserDefaults.standard.set(launchesAtLogin, forKey: Self.launchAtLoginKey)
            if !LaunchAtLogin.set(launchesAtLogin) {
                lastError = "开机自启设置失败，可到「系统设置 → 通用 → 登录项」手动开启"
                launchesAtLogin = LaunchAtLogin.isEnabled
            }
        }
    }

    var autoGroupingEnabled: Bool {
        didSet {
            guard autoGroupingEnabled != oldValue else { return }
            UserDefaults.standard.set(autoGroupingEnabled, forKey: Self.autoGroupingKey)
        }
    }

    var preferredBrowserBundleID: String? {
        didSet {
            guard preferredBrowserBundleID != oldValue else { return }
            let defaults = UserDefaults.standard
            if let preferredBrowserBundleID {
                defaults.set(preferredBrowserBundleID, forKey: Self.preferredBrowserKey)
            } else {
                defaults.removeObject(forKey: Self.preferredBrowserKey)
            }
            invalidateLinkBrowserCache()
        }
    }

    /// 这条链接实际会用哪个浏览器。设置优先，其次来源记忆，最后交给系统。
    func browserBundleID(for itemID: UUID) -> String? {
        preferredBrowserBundleID ?? LinkSourceBrowserStore.bundleID(for: itemID)
    }

    var edgeStatusEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(edgeStatusEffectsEnabled, forKey: Self.edgeStatusEffectsKey)
            if !edgeStatusEffectsEnabled { edgeStatusSignal = nil }
        }
    }

    /// 刘海用什么手势展开。窗口层每一拍都读它来决定要不要武装悬停计时。
    var expandTrigger: NotchExpandTrigger {
        didSet {
            UserDefaults.standard.set(expandTrigger.rawValue, forKey: Self.expandTriggerKey)
        }
    }

    // MARK: - 待办联动

    /// 复制的文字和截图 OCR 要不要过一遍待办提取。
    var todoIntakeEnabled: Bool {
        didSet {
            UserDefaults.standard.set(todoIntakeEnabled, forKey: Self.todoIntakeKey)
            if !todoIntakeEnabled { cancelTodoIntakeAndClearPrompts() }
        }
    }

    /// 固定一张截图之后，要不要顺手看看它的识别文字里有没有待办。
    ///
    /// 时机是**固定那一刻**，不是复制那一刻。理由是代价该由意图来买单：
    /// 复制截图是每天几十次的动作，固定是"我要留着它"，一天没几次。
    /// 而固定本来就会让这条图走完整索引（含本机 OCR），所以这里不额外
    /// 花一次识别——只是把已经算出来的文字多读一遍。
    ///
    /// 提取出的待办是**独立**的一条：`addTodo(title:)` 不写 `linkedItemID`，
    /// 所以之后把截图删掉、清出回收站，待办都还在。
    var screenshotTodoScanEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                screenshotTodoScanEnabled,
                forKey: Self.screenshotTodoScanKey
            )
        }
    }

    /// 提取到候选后直接建待办，还是先在刘海上问一句。
    ///
    /// 默认**问一句**。提取全靠本地正则，误判在所难免；不问就建，用户的待办
    /// 列表会被通知里的边角料慢慢污染，而清理成本比确认一下高得多。
    var todoAutoCreateEnabled: Bool {
        didSet { UserDefaults.standard.set(todoAutoCreateEnabled, forKey: Self.todoAutoCreateKey) }
    }

    /// 刘海上那张待办候选卡的形态。
    ///
    /// 分两种，取决于结论建立在什么之上（见 `TodoDraft.isCertain`）：
    /// 确凿的**直接建**，只留一个叉用来撤销；拿不准的才问，而"问"就是
    /// 一个对号一个叉，不是一段话加两个按钮。
    enum TodoPrompt: Equatable {
        case created(TodoRevisionPlan, undo: TodoUndo)
        /// 来源随待确认提案一起保留。用户稍后点 ✓ 时，新待办仍能关联回原 Pin。
        case asking(TodoRevisionPlan, sourceItemID: UUID?)

        var plan: TodoRevisionPlan {
            switch self {
            case .created(let plan, _), .asking(let plan, _): plan
            }
        }

        /// 卡片右端有几个按钮。已经替你做完的只有“撤销”一个。
        var actionCount: Int {
            switch self {
            case .created: 1
            case .asking: 2
            }
        }
    }

    /// 撤销一次已经执行的改动需要什么。
    ///
    /// 只有"确凿到不必问"的那几种动作会走到这里，所以只有两种：新建和改期。
    /// 完成和取消永远要用户先点头，不存在需要撤销的情况。
    enum TodoUndo: Equatable {
        case deleteTodo(UUID)
        case restoreDueDate(UUID, Date?, TodoPresentationMetadata?)
        case restoreTitle(UUID, String, Date?, TodoPresentationMetadata?)
        /// 已确认且不提供撤销（完成 / 取消）；让调用方仍能区分成功与失败。
        case confirmed
    }

    private(set) var todoPrompt: TodoPrompt?
    /// 一次输入拆出的候选逐张展示，避免后一个直接覆盖前一个。
    struct QueuedTodoPrompt: Equatable {
        var prompt: TodoPrompt
        var fromNearbyDevice: Bool
        var deviceKind: NearbyDeviceKind
    }
    @ObservationIgnored private var queuedTodoPrompts: [QueuedTodoPrompt] = []
    /// 这条候选来自其他苹果设备（iPhone / iPad 的通用剪贴板）。
    private(set) var todoDraftCameFromNearbyDevice = false
    /// 候选卡上画哪一个设备角标。系统不给型号，拿不准就是 unknown。
    private(set) var todoDraftDeviceKind: NearbyDeviceKind = .unknown
    /// 已经处理过的候选去重键。同一条通知复制两遍、或者截图和文字各来一次，
    /// 都只打扰用户一次。
    @ObservationIgnored private var handledTodoDraftIDs: Set<String> = []
    @ObservationIgnored private var todoDraftDismissTask: Task<Void, Never>?
    @ObservationIgnored private var isMutatingTodoPrompt = false
    /// 一次待办理解的输入。排队而不是互相取消——两张截图前后脚到达时，
    /// 旧实现会让第二张把第一张的模型调用 cancel 掉，第一张就此消失。
    struct TodoIntakeJob: Equatable {
        var text: String
        var sourceItemID: UUID?
        var fromNearbyDevice: Bool
        var enqueuedAt: Date
    }

    /// 串行队列。模型调用是秒级的，同时发几个既费钱又会让候选卡互相顶掉。
    @ObservationIgnored private var todoIntakeQueue: [TodoIntakeJob] = []
    @ObservationIgnored private var todoIntakeTask: Task<Void, Never>?
    @ObservationIgnored private var activeTodoIntakeSourceID: UUID?
    /// 关闭识别或主动清空时递增；已经跨过模型 await 的旧任务不得再执行或弹卡。
    @ObservationIgnored private var todoIntakeGeneration: UInt64 = 0
    /// 等着"索引完成后看一眼有没有待办"的截图。
    ///
    /// **跨启动保留**。只装用户明确留下的那几张（固定、拖入、手机同步），
    /// 集合本来就很小；但它必须活过一次网络失败和一次重启——否则模型这一轮
    /// 没答上来，这张截图就永远失去了被理解的机会，而 OCR 明明已经躺在库里。
    @ObservationIgnored private var pendingTodoScanIDs: Set<UUID> = [] {
        didSet {
            guard pendingTodoScanIDs != oldValue else { return }
            UserDefaults.standard.set(
                pendingTodoScanIDs.map(\.uuidString).sorted(),
                forKey: Self.todoScanQueueKey
            )
        }
    }

    // MARK: - 待办提醒

    var reminderSettings: TodoReminderSettings {
        didSet {
            guard reminderSettings != oldValue else { return }
            if let data = try? JSONEncoder().encode(reminderSettings) {
                UserDefaults.standard.set(data, forKey: Self.reminderSettingsKey)
            }
            if !reminderSettings.isEnabled { dismissReminder() }
            reminderSettingsDidChange?(reminderSettings)
        }
    }

    /// 正在刘海上响的那条提醒。
    private(set) var activeReminder: TodoReminder?
    @ObservationIgnored private var deliveredReminderKeys: Set<String> = []
    @ObservationIgnored private var reminderDismissTask: Task<Void, Never>?
    /// 设置变化时通知 App 层重排系统通知。
    @ObservationIgnored var reminderSettingsDidChange: ((TodoReminderSettings) -> Void)?
    /// 待办集合变化时重排系统通知。
    @ObservationIgnored var reminderScheduleDidChange: (([Todo], TodoReminderSettings) -> Void)?

    private(set) var editingItemID: UUID?
    private(set) var hasUnsavedChanges = false
    private var isConfirmingDetailDiscard = false

    private(set) var focusTimer = FocusTimerState()
    private(set) var timerRemaining: TimeInterval?
    var focusDurationMinutes: Int {
        didSet { UserDefaults.standard.set(focusDurationMinutes, forKey: Self.focusDurationKey) }
    }
    /// Mac 本机与手机通用剪贴板**各自**保留 5 条临时内容。
    /// 这是产品规则，不再暴露一个会把两条轨道混成一个数字的设置。
    static let clipboardHistoryLimitPerDevice = 5

    /// 待办、提醒、外观行为页的显式保存入口。
    /// didSet 仍负责防崩溃式即时落盘；这个入口重新写一遍完整快照并重排提醒，
    /// 让“保存”成为一个可见、可验证的应用动作，而不是装饰按钮。
    func saveSettings() {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: Self.modeKey)
        defaults.set(focusDurationMinutes, forKey: Self.focusDurationKey)
        defaults.set(edgeStatusEffectsEnabled, forKey: Self.edgeStatusEffectsKey)
        defaults.set(autoGroupingEnabled, forKey: Self.autoGroupingKey)
        defaults.set(expandTrigger.rawValue, forKey: Self.expandTriggerKey)
        defaults.set(processesTemporaryClipboard, forKey: Self.processesTemporaryClipboardKey)
        defaults.set(todoIntakeEnabled, forKey: Self.todoIntakeKey)
        defaults.set(todoAutoCreateEnabled, forKey: Self.todoAutoCreateKey)
        defaults.set(screenshotTodoScanEnabled, forKey: Self.screenshotTodoScanKey)
        if let data = try? JSONEncoder().encode(reminderSettings) {
            defaults.set(data, forKey: Self.reminderSettingsKey)
        }
        rescheduleReminders()
    }

    var lastError: String?
    /// 出现过"别的应用容器读不到"的失败，设置里据此显示授权入口。
    var needsFullDiskAccess = false
    var feedbackMessage: String?
    var copiedItemID: UUID?
    @ObservationIgnored private var undoDismissTask: Task<Void, Never>?
    private(set) var recentlyTrashedID: UUID?
    private(set) var recentlyTrashedTitle: String?
    /// 删除前的分组快照；撤销时把成员关系和原顺序一起恢复。
    @ObservationIgnored private var recentlyTrashedGroup: CardGroup?
    private(set) var isProcessingArchive = false

    let library: Library
    @ObservationIgnored private let entitlementGate: any EntitlementChecking
    @ObservationIgnored var openSettingsAction: (() -> Void)?
    @ObservationIgnored var aiEnrichmentAction: ((Item) async -> ItemAIEnrichment?)?
    /// 给一组卡片起名字。见 `ProviderSettingsModel.nameGroup`。
    @ObservationIgnored var groupNamingAction: (([String]) async -> String?)?
    /// 这条新内容归进已有的哪个分组。返回下标，nil = 哪个都不归。
    @ObservationIgnored var groupAssignmentAction: ((String, [String]) async -> Int?)?
    @ObservationIgnored var sceneRecommendationRouteFingerprintAction: (() -> String?)?
    @ObservationIgnored var contextRouteFingerprintAction: (() -> String?)?
    @ObservationIgnored var aiTransformAction: ((Item, SceneActionID) async -> String?)?
    @ObservationIgnored var contentIndexAction: (
        (Item, Bool) async -> IndexingRunResult
    )?
    @ObservationIgnored var semanticSearchAction: ((String, [Item], Bool) async -> SemanticSearchRun)?
    @ObservationIgnored var searchAnswerStreamAction: (
        (String, [RetrievalRankingCandidate], RecencyPreference?)
            -> AsyncThrowingStream<ProviderSettingsModel.SearchAnswerEvent, any Error>
    )?
    @ObservationIgnored var pdfQuestionAction: ((Item, String) async -> String?)?
    private var feedbackTask: Task<Void, Never>?
    private var dragCompletionTask: Task<Void, Never>?
    private var edgeStatusTask: Task<Void, Never>?
    @ObservationIgnored private var indexQueueTask: Task<Void, Never>?
    @ObservationIgnored private var indexRetryTask: Task<Void, Never>?
    @ObservationIgnored private var semanticSearchTask: Task<Void, Never>?
    @ObservationIgnored private var aiQueueTask: Task<Void, Never>?
    @ObservationIgnored private var linkMetadataTasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var activeAIItemID: UUID?
    @ObservationIgnored private var pdfQuestionTask: Task<Void, Never>?
    @ObservationIgnored private var sceneRecommendationCache: [UUID: SceneCacheEntry] = [:]
    private var pendingIndexIDs: [UUID] = []
    /// 手动重新解析中的链接。只决定是否忽略旧 linkPage 缓存；直到新正文、向量、
    /// 标题原子落库成功才移除，失败会保留旧 RAG 并继续留在队列。
    private var forcedLinkRefreshIDs: Set<UUID> = []
    /// 仅用于把手动重解析的最终结果反馈给用户；不持久化，应用退出后仍由
    /// forcedLinkRefreshIDs + pendingIndexIDs 保证任务不丢。
    @ObservationIgnored private var manualLinkRefreshIDs: Set<UUID> = []
    /// 已确认旧 linkPage 是小红书登录墙。刷新失败时不能继续保留它污染 RAG；
    /// 与 forced 集合同样持久化，崩溃重启后仍能完成清理。
    private var knownInvalidLinkPageIDs: Set<UUID> = []
    private var pendingAIIDs: [UUID] = []
    /// 模型已经真的回答过的条目。
    ///
    /// 光靠"标题还是本地的 / 还没有分组"判断该不该再问，会让一类条目永远
    /// 问不完：只配了自动命名、没配自动分类时，命名跑完 group 仍是 nil，
    /// 于是每次启动、每次网络恢复都把同一批条目重新问一遍模型。
    /// 记下"这一版路由下已经问过了"，只有路由真的变了才重新给机会。
    private var aiSettledIDs: Set<UUID> = []
    @ObservationIgnored private var aiSettledFingerprint: String = ""
    @ObservationIgnored var aiRoutingFingerprintAction: (() -> String)?
    /// 待办协调的模型入口。没配路由时它返回 nil，整条链退化成纯本地。
    @ObservationIgnored var todoRevisionAction: (
        (String, [TodoRevisionCandidate]) async -> TodoInterpretation
    )?
    /// 捕获当时开关为开的临时条目；开关后续变化不追溯修改这些 ID。
    private var processableTemporaryIDs: Set<UUID> = []
    private var indexRetryAttempt = 0

    init(entitlementGate: any EntitlementChecking = OpenEntitlementGate()) {
        self.entitlementGate = entitlementGate
        let defaults = UserDefaults.standard
        mode = Mode(rawValue: defaults.string(forKey: Self.modeKey) ?? "") ?? .stash
        let savedDuration = defaults.integer(forKey: Self.focusDurationKey)
        focusDurationMinutes = savedDuration > 0
            ? min(Self.maxFocusDurationMinutes, max(Self.minFocusDurationMinutes, savedDuration))
            : 25

        edgeStatusEffectsEnabled = defaults.object(forKey: Self.edgeStatusEffectsKey) as? Bool ?? true
        preferredBrowserBundleID = defaults.string(forKey: Self.preferredBrowserKey)
        autoGroupingEnabled = defaults.object(forKey: Self.autoGroupingKey) as? Bool ?? true
        LaunchAtLogin.applyDefaultIfNeeded(defaultsKey: Self.launchAtLoginKey)
        launchesAtLogin = LaunchAtLogin.isEnabled
        expandTrigger = (defaults.string(forKey: Self.expandTriggerKey))
            .flatMap(NotchExpandTrigger.init(rawValue:)) ?? .click
        processesTemporaryClipboard = defaults.object(
            forKey: Self.processesTemporaryClipboardKey
        ) as? Bool ?? false
        todoIntakeEnabled = defaults.object(forKey: Self.todoIntakeKey) as? Bool ?? true
        todoAutoCreateEnabled = defaults.object(forKey: Self.todoAutoCreateKey) as? Bool ?? false
        screenshotTodoScanEnabled = defaults.object(
            forKey: Self.screenshotTodoScanKey
        ) as? Bool ?? true
        reminderSettings = defaults.data(forKey: Self.reminderSettingsKey)
            .flatMap { try? JSONDecoder().decode(TodoReminderSettings.self, from: $0) }
            ?? TodoReminderSettings()
        // 已送达的提醒键跨启动保留：否则每次开机都会把今天上午提过的事再提一遍。
        deliveredReminderKeys = Set(defaults.stringArray(forKey: Self.deliveredRemindersKey) ?? [])
        aiSettledIDs = Set(
            (defaults.stringArray(forKey: Self.aiSettledKey) ?? []).compactMap(UUID.init(uuidString:))
        )
        aiSettledFingerprint = defaults.string(forKey: Self.aiSettledFingerprintKey) ?? ""
        pendingTodoScanIDs = Set(
            (defaults.stringArray(forKey: Self.todoScanQueueKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )

        let environment = ProcessInfo.processInfo.environment
        let support = environment["MNEMO_DATA_ROOT"].map {
            URL(filePath: $0, directoryHint: .isDirectory)
        } ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pinland", directoryHint: .isDirectory) // 这条路径是数据的**家**，不是品牌名。整个库、向量索引、文件仓、
            // 目录缓存都在 ~/Library/Application Support/Pinland 里。应用改名
            // 不换数据的家——换一次家等于把用户攒下的所有东西留在原地。
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)

        let vaultRoot = support.appending(path: "vault", directoryHint: .isDirectory)
        let vault = try! FileVault(root: vaultRoot)
        let container = try! SwiftDataItemStore.makeContainer(at: support.appending(path: "library.store"))
        let store = SwiftDataItemStore(modelContainer: container)
        library = Library(store: store, vault: vault)
        pendingIndexIDs = defaults.stringArray(forKey: Self.indexQueueKey)?
            .compactMap(UUID.init(uuidString:)) ?? []
        forcedLinkRefreshIDs = Set(
            (defaults.stringArray(forKey: Self.forcedLinkRefreshKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
        knownInvalidLinkPageIDs = Set(
            (defaults.stringArray(forKey: Self.knownInvalidLinkPageKey) ?? [])
                .compactMap(UUID.init(uuidString:))
        )
        // 两份 defaults 不是事务写入：应用恰好在两次 set 之间退出时，可能只剩
        // force 标记没有队列项。启动时取并集，保证强制刷新不会永久搁浅。
        for id in forcedLinkRefreshIDs where !pendingIndexIDs.contains(id) {
            pendingIndexIDs.insert(id, at: 0)
        }
        pendingAIIDs = defaults.stringArray(forKey: Self.aiQueueKey)?
            .compactMap(UUID.init(uuidString:)) ?? []
        if let saved = defaults.stringArray(forKey: Self.processableTemporaryIDsKey) {
            processableTemporaryIDs = Set(saved.compactMap(UUID.init(uuidString:)))
        } else {
            // 新字段第一次出现：升级前已经排队的工作保持原样继续，不能因默认开关
            // 为关就撤掉。只从这次启动之后的新捕获开始执行"捕获时授权"规则。
            processableTemporaryIDs = Set(pendingIndexIDs + pendingAIIDs)
            defaults.set(
                processableTemporaryIDs.map(\.uuidString).sorted(),
                forKey: Self.processableTemporaryIDsKey
            )
        }
        if let data = defaults.data(forKey: Self.sceneCacheKey),
           let saved = try? JSONDecoder().decode([String: SceneCacheEntry].self, from: data) {
            sceneRecommendationCache = Dictionary(uniqueKeysWithValues: saved.compactMap { key, value in
                UUID(uuidString: key).map { ($0, value) }
            })
        }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "development"
        EarlyAccessMarker.recordIfNeeded(currentVersion: version, defaults: defaults)
    }

    // MARK: - Derived state

    var tabs: [Tab] {
        var result: [Tab] = [
            .all, .kind(.image), .kind(.link), .kind(.text),
            .kind(.pdf), .kind(.file), .kind(.binary),
        ]
        // 什么时候显示这个页签：
        // - 库里已经有隐私内容；
        // - 已解锁（否则移出最后一条时页签当场消失，用户以为东西丢了）；
        // - **正在拖卡片**——这条是关键。原来只看前两个条件，于是第一条内容
        //   永远拖不进去：没有隐私内容就没有锁，没有锁就没有投放目标，
        //   拖拽入口要等你先用一次右键菜单才生效，等于白做。
        if privateItemCount > 0 || isPrivateSpaceUnlocked || draggingItemID != nil {
            result.append(.privateSpace)
        }
        return result
    }

    /// 交给检索、模型、索引的条目集合。**所有** AI 相关路径都必须读它。
    ///
    /// 隐私条目在这里被摘掉，与解不解锁无关：解锁只是让你在界面上看得见，
    /// 不代表可以把它们发给模型。锁只挡眼睛，这一层才挡住真正的后门。
    var aiEligibleItems: [Item] { items.filter { !$0.isPrivate } }

    var pinnedItems: [Item] { items.filter(\.isPinned) }

    var clipboardItems: [Item] {
        items.filter { $0.origin == .clipboard && !$0.isPinned }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func isTodo(_ itemID: UUID) -> Bool {
        todos.contains { $0.linkedItemID == itemID }
    }

    /// 链接按什么归类。
    ///
    /// 认得出的平台用平台身份（有中文名、有徽标、有跳转能力）；认不出的退回
    /// 域名。只按已知平台分组的话，真实库里大量普通站点会全挤进"其他"——
    /// 那等于没分。域名虽然朴素，但它稳定、唯一，而且用户认得。
    enum LinkGroup: Hashable, Sendable {
        case platform(LinkPlatform)
        case domain(String)

        var displayName: String {
            switch self {
            case .platform(let platform): platform.displayName
            case .domain(let host): host
            }
        }

        /// 排序时已知平台排在前面：它们是用户真正会去"按平台找"的那些。
        var sortRank: Int {
            switch self {
            case .platform(let platform): platform.category.rawValue
            case .domain: LinkPlatform.Category.allCases.count
            }
        }
    }

    /// 链接页签下再按平台 / 域名收窄。nil = 不收窄。
    ///
    /// 只在链接页签下出现，因为只有链接有这个维度。做成常驻的第二排会一直
    /// 占着那 26 点高——面板一共才 212 点，任何常驻装饰都在跟卡片抢地方。
    var activeLinkGroup: LinkGroup? {
        didSet {
            guard activeLinkGroup != oldValue else { return }
            // 换了筛选就回到第一张，否则用户停在第 20 张的位置看一个只有
            // 3 张的结果，界面看着像空的。
            requestScrollToFirstCard()
        }
    }

    /// 当前页签下真实存在的分组，条数多的排前面。
    ///
    /// 只列库里真有的：把四十个平台全摆出来、其中三十七个点进去是空的，
    /// 那不是筛选器，是一排噪音。
    var availableLinkGroups: [LinkGroup] { filterRow().links }

    private var computedLinkGroups: [LinkGroup] {
        guard case .kind(.link) = activeTab else { return [] }
        var counts: [LinkGroup: Int] = [:]
        // 隐私条目不参与计数：藏起来就是藏起来。X 的最后一条进了隐私空间，
        // 链接页签上的 X 入口就该跟着消失——否则它点进去是一片空白，
        // 而且那一排本身就暴露了"有一条 X 链接被藏起来了"。
        for item in items where item.kind == .link && !item.isPrivate {
            guard let group = linkGroup(of: item) else { continue }
            counts[group, default: 0] += 1
        }
        return counts.keys.filter { group in
            // 认得出的平台一条也值得给个入口——它有名字有图标，是用户真的会
            // 拿来找的维度。普通域名要攒够两条才算"一类"：一条一个 chip 排出去
            // 不是聚类，是把噪音排成一行。
            switch group {
            case .platform: true
            case .domain: counts[group]! >= 2
            }
        }.sorted {
            let (lhs, rhs) = (counts[$0]!, counts[$1]!)
            if $0.sortRank != $1.sortRank { return $0.sortRank < $1.sortRank }
            return lhs == rhs ? $0.displayName < $1.displayName : lhs > rhs
        }
    }

    /// 这条 Pin 属于哪个分组。卡片徽标和筛选条读同一个判定。
    func linkGroup(of item: Item) -> LinkGroup? {
        guard let url = linkURL(of: item) else { return nil }
        if let platform = LinkPlatform.resolve(url) { return .platform(platform) }
        guard let host = url.host(), !host.isEmpty else { return nil }
        return .domain(RegistrableDomain.of(host))
    }

    /// 悬停提示：这一下会落到哪个 App / 浏览器。
    /// 只在浏览器里打开，不管有没有装对应的 App。卡片左下角那枚浏览器徽标走这条。
    func openInBrowser(_ item: Item) {
        guard let url = item.linkURL else { return }
        LinkOpener.openInBrowser(url, bundleID: browserBundleID(for: item.id))
    }

    func browserForLink(_ item: Item) -> String? {
        if let cached = linkBrowserCache[item.id] { return cached }
        let resolved: String? = linkURL(of: item) == nil
            ? nil
            : (browserBundleID(for: item.id) ?? LinkOpener.systemDefaultBrowserBundleID)
        linkBrowserCache[item.id] = resolved
        return resolved
    }

    /// 设置里换了默认浏览器之后，上面那份缓存就过期了。
    private func invalidateLinkBrowserCache() { linkBrowserCache.removeAll() }

    func openInBrowserHint(_ item: Item) -> String {
        guard let bundleID = browserForLink(item),
              let name = LinkOpener.browserName(bundleID) else { return "在浏览器里打开" }
        return "用 \(name) 打开"
    }

    func openLinkHint(_ item: Item) -> String {
        guard let url = item.linkURL else { return "打开" }
        let destination = LinkOpener.destinationName(
            for: url,
            preferredBrowserBundleID: browserBundleID(for: item.id)
        )
        return "用 \(destination) 打开"
    }

    /// 这条 Pin 属于哪个已知平台。只有它决定徽标和跳转，域名分组不参与。
    /// 这条内容指向的链接，带缓存。
    ///
    /// `Item.linkURL` 便宜的路径是一次字符串解析，贵的路径要跑 NSDataDetector。
    /// 而卡片排版对**每一条**都会问，滚动时每帧都问一遍——必须记住答案。
    /// 内容变了 id 也会变（重新入库），按 id 缓存是安全的。
    @ObservationIgnored private var linkURLCache: [UUID: URL?] = [:]

    func linkURL(of item: Item) -> URL? {
        if let cached = linkURLCache[item.id] { return cached }
        let resolved = item.linkURL
        linkURLCache[item.id] = resolved
        return resolved
    }

    /// 这条链接属于哪个平台。
    ///
    /// 结果缓存住：`item.linkURL` 每次都要重新解析一遍分享文案（正则 +
    /// NSDataDetector），而卡片排版每帧都会问。同一条内容的链接不会变，
    /// 内容变了 id 也会变（重新入库），所以按 id 缓存是安全的。
    @ObservationIgnored private var linkPlatformCache: [UUID: LinkPlatform?] = [:]

    func linkPlatform(of item: Item) -> LinkPlatform? {
        if let cached = linkPlatformCache[item.id] { return cached }
        let resolved = linkURL(of: item).flatMap(LinkPlatform.resolve)
        linkPlatformCache[item.id] = resolved
        return resolved
    }

    /// 这条链接会用哪个浏览器打开——卡片上那枚徽标的图标和提示都问它。
    ///
    /// 同样缓存：它要串起"设置 → 来源记忆 → 系统默认"三层，而排版每帧问两次
    /// （一次判角标占位，一次画图标）。
    @ObservationIgnored private var linkBrowserCache: [UUID: String?] = [:]

    // MARK: - 同一份文档的多个版本

    /// 首页标题缓存：条目 ID → 文档自己首页上印的标题。
    ///
    /// 不进库表。它是从已有的检索分块里读出来的派生数据，重建一次的代价是
    /// 一次 chunk 查询，而为它做一次结构迁移的代价要大得多。
    @ObservationIgnored private var documentTitles: [UUID: String] = [:]
    @ObservationIgnored private var documentTitleLoads: Set<UUID> = []
    /// 版本族的分组结果随 documentTitles 一起变，这个计数触发界面重算。
    private(set) var documentTitleGeneration = 0

    /// 已经展开的版本组，键是这一族里**最新那版**的 ID。
    var expandedVersionGroups: Set<UUID> = []

    /// 当前可见条目里的版本族。
    ///
    /// 族、成员槽位、groupID→族三份结果在**一次**计算里生成并一起缓存。
    /// 旧实现 `displayEntries` 对每一个 rank=1 的文档又重新调用一次
    /// `versionFamilies`，每次都跑 O(n²) 的名字相似度；拖拽/悬停刷新 body 时
    /// 这条路径会反复烧 CPU。
    var versionFamilies: [DocumentVersionFamily] { versionSnapshot.families }

    /// 条目 ID → 它在版本族里的位置。
    struct VersionSlot: Equatable {
        var groupID: UUID
        /// 1 = 最新。
        var rank: Int
        var total: Int
        var isExpanded: Bool
    }

    struct VersionSnapshotKey: Equatable {
        var visible: VisibleItemsKey
        var documentTitleGeneration: Int
        var expanded: [UUID]
    }

    private struct VersionSnapshot {
        var key: VersionSnapshotKey
        var families: [DocumentVersionFamily]
        var familyByID: [UUID: DocumentVersionFamily]
        var slots: [UUID: VersionSlot]
    }

    @ObservationIgnored private var versionSnapshotCache: VersionSnapshot?

    var versionSnapshotKey: VersionSnapshotKey {
        VersionSnapshotKey(
            visible: visibleItemsKey,
            documentTitleGeneration: documentTitleGeneration,
            expanded: expandedVersionGroups.sorted { $0.uuidString < $1.uuidString }
        )
    }

    private var versionSnapshot: VersionSnapshot {
        let key = versionSnapshotKey
        if let cache = versionSnapshotCache, cache.key == key { return cache }

        let documents = visibleItems
            .filter { $0.kind == .pdf || $0.kind == .file }
            .map { item in
                VersionedDocument(
                    id: item.id,
                    title: item.title,
                    filename: item.originalFilename,
                    kind: item.kind,
                    contentDate: ItemTemporalFacts(item: item).contentDate,
                    documentTitle: documentTitles[item.id]
                )
            }
        let families = DocumentVersioning.families(documents)
        var familyByID: [UUID: DocumentVersionFamily] = [:]
        var slots: [UUID: VersionSlot] = [:]
        for family in families {
            guard let groupID = family.orderedIDs.first else { continue }
            familyByID[groupID] = family
            let isExpanded = expandedVersionGroups.contains(groupID)
            for (index, id) in family.orderedIDs.enumerated() {
                slots[id] = VersionSlot(
                    groupID: groupID,
                    rank: index + 1,
                    total: family.orderedIDs.count,
                    isExpanded: isExpanded
                )
            }
        }
        let snapshot = VersionSnapshot(
            key: key, families: families, familyByID: familyByID, slots: slots
        )
        versionSnapshotCache = snapshot
        return snapshot
    }

    var versionSlots: [UUID: VersionSlot] { versionSnapshot.slots }

    // MARK: - 钉住区

    /// 钉住区变化的可观察计数。`PinnedLaneStore` 是静态存储，不参与
    /// Observation，需要一个可观察的量把它的变化带进视图。
    private(set) var pinnedLaneGeneration = 0

    var pinnedLaneIDs: [UUID] {
        _ = pinnedLaneGeneration
        return PinnedLaneStore.ids()
    }

    func isPinnedToFront(_ id: UUID) -> Bool {
        _ = pinnedLaneGeneration
        return PinnedLaneStore.contains(id)
    }

    /// 钉到最前面。`before` 为 nil 时排在钉住区末尾。
    ///
    /// 钉住的同时把它从分组里拿出来：分组是"这几张是一类"，钉住是"这一张我
    /// 现在一直要看"，一张卡不能同时被两套版式管——那样它到底画在哪儿没有答案。
    func pinToFront(_ id: UUID, anchor target: UUID? = nil, after: Bool = false) {
        if cardGroup(of: id) != nil {
            CardGroupStore.detach(id)
            cardGroupGeneration &+= 1
        }
        PinnedLaneStore.pin(id, anchor: target, after: after)
        pinnedLaneGeneration &+= 1
        showTransientFeedback("已钉到最前")
    }

    /// 一个组是不是钉住的。
    ///
    /// 不变量：**一个组要么整组钉住，要么整组不钉，永远没有一半**。半钉的话
    /// 成员会被钉住区排到队首、其余留在原处，同一个组被撕成两段画在轨道两头，
    /// 而"取消钉住"又只对其中几张生效。
    func isGroupPinned(_ groupID: UUID) -> Bool {
        guard let group = cardGroupByID(groupID), !group.itemIDs.isEmpty else { return false }
        return group.itemIDs.allSatisfy { PinnedLaneStore.contains($0) }
    }

    /// 把一整个组钉到前面。成员按组内顺序连续排在钉住区里。
    func pinGroup(_ groupID: UUID, anchor target: UUID? = nil, after: Bool = false) {
        guard let group = cardGroupByID(groupID) else { return }
        let members = group.itemIDs.filter { id in items.contains(where: { $0.id == id }) }
        guard !members.isEmpty else { return }
        var cursor = target
        var insertAfter = after
        for id in members {
            PinnedLaneStore.pin(id, anchor: cursor, after: insertAfter)
            cursor = id
            insertAfter = true
        }
        pinnedLaneGeneration &+= 1
        showTransientFeedback("已把「\(group.name)」钉到最前")
    }

    func unpinGroup(_ groupID: UUID) {
        guard let group = cardGroupByID(groupID) else { return }
        var changed = false
        for id in group.itemIDs where PinnedLaneStore.contains(id) {
            PinnedLaneStore.unpin(id)
            changed = true
        }
        guard changed else { return }
        pinnedLaneGeneration &+= 1
        showTransientFeedback("已取消钉住")
    }

    /// 把一个组的钉住状态重新拉平到"全钉"或"全不钉"。合并进新成员之后要调用，
    /// 否则新成员会让整组变成半钉。
    private func normalizeGroupPinning(_ groupID: UUID, pinned: Bool) {
        guard let group = cardGroupByID(groupID) else { return }
        var changed = false
        if pinned {
            var cursor: UUID? = group.itemIDs.first.flatMap {
                PinnedLaneStore.contains($0) ? $0 : nil
            }
            for id in group.itemIDs {
                guard !PinnedLaneStore.contains(id) else { cursor = id; continue }
                PinnedLaneStore.pin(id, anchor: cursor, after: true)
                cursor = id
                changed = true
            }
        } else {
            for id in group.itemIDs where PinnedLaneStore.contains(id) {
                PinnedLaneStore.unpin(id)
                changed = true
            }
        }
        if changed { pinnedLaneGeneration &+= 1 }
    }

    func unpinFromFront(_ id: UUID) {
        guard PinnedLaneStore.contains(id) else { return }
        PinnedLaneStore.unpin(id)
        pinnedLaneGeneration &+= 1
        showTransientFeedback("已取消钉住")
    }

    /// 整组换位：把成员按原顺序连续地挪到落点。
    ///
    /// 组在轨道上的位置是由"第一个被扫到的成员"决定的，所以只挪一张卡不够——
    /// 其余成员还留在原处，下一帧组又跳回去了。把整组搬成连续的一段，位置
    /// 才真的跟着走。成员数是个位数，逐张写代价可以忽略。
    func moveGroup(_ groupID: UUID, anchor target: UUID, after: Bool) {
        guard let group = cardGroups.first(where: { $0.id == groupID }),
              !group.itemIDs.contains(target) else { return }

        // 组和卡片走同一套跨区规则：落点在钉住区就进钉住区，落点在普通区就
        // 离开钉住区。之前 moveGroup 只重排 `items`、完全不碰钉住区——把组拖到
        // 前面松手，下一帧钉住区又按自己的顺序把那些卡排回去，组就"弹回来了"。
        let targetPinned = isPinnedToFront(target)
        let groupPinned = isGroupPinned(groupID)
        if targetPinned {
            if groupPinned {
                movePinnedGroup(groupID, anchor: target, after: after)
            } else {
                pinGroup(groupID, anchor: target, after: after)
            }
            return
        }
        if groupPinned { unpinGroup(groupID) }

        // 落点若在另一个组里，整摞要跨过那一组，不能停在它中间——否则两组的
        // 卡片交错，各自都不再是连续的一段。
        var target = target
        if let host = cardGroup(of: target), host.id != groupID {
            target = (after ? host.itemIDs.last : host.itemIDs.first) ?? target
        }
        let memberIDs = group.itemIDs.filter { id in items.contains(where: { $0.id == id }) }
        guard !memberIDs.isEmpty else { return }

        // **一次**算出最终顺序，一次写入。
        //
        // 之前在循环里逐步改 `items`：每改一次 UI 就刷新一帧，五张卡的组就是
        // 五次连续的跳动——用户看到的就是"成员一张一张蹦过去"。先在纯 id 数组
        // 上挪好，再整体落回 `items`，屏幕上是一步到位的，整组作为一个格子
        // 被那条换位 spring 一起推过去。
        var order = items.map(\.id)
        let moving = Set(memberIDs)
        order.removeAll { moving.contains($0) }
        var index = order.firstIndex(of: target).map { $0 + (after ? 1 : 0) } ?? order.count
        index = min(max(0, index), order.count)
        order.insert(contentsOf: memberIDs, at: index)
        guard order != items.map(\.id) else { return }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = order.compactMap { byID[$0] }

        // 持久化：倒序逐张"挪到 X 前"。X 是已经放好的最终邻居，所以倒着来每一
        // 步都成立；正着来的话，后面的计划里引用的锚点可能已经被挪走了。
        // 内存里已经是最终状态，写库失败就 reload 拉回真实顺序。
        let tailAnchor: UUID? = index + memberIDs.count < order.count
            ? order[index + memberIDs.count] : nil
        enqueueReorderPersistence { [library] in
            var anchor = tailAnchor
            for id in memberIDs.reversed() {
                try await library.moveItem(id, before: anchor)
                anchor = id
            }
        }
    }

    /// 卡片换位的唯一入口：它同时决定这次拖动有没有跨区。
    ///
    /// 把三件事收在一处，是因为它们本来就是同一个动作的三种结果，而用户做的
    /// 只有一个动作——把卡片放到某两张之间。分散在各处判断的话，必然出现
    /// "拖出来了但还留在组里"这种自相矛盾的状态。
    func moveCard(_ dragged: UUID, anchor target: UUID, after: Bool) {
        let draggedPinned = isPinnedToFront(dragged)
        let targetPinned = isPinnedToFront(target)

        // 落到钉住区里 = 进钉住区（或在区内换位）。
        if targetPinned {
            if draggedPinned {
                movePinned(dragged, anchor: target, after: after)
            } else {
                pinToFront(dragged, anchor: target, after: after)
            }
            return
        }
        // 落到普通区 = 离开钉住区。
        if draggedPinned { unpinFromFront(dragged) }
        // 插到分组以外的位置，就是把它从组里拿出来了——用户看到的是它落在
        // 别处，那它就该真的在别处。留在组里的话下一帧它会跳回组里，
        // 看着像"拖了个寂寞"。
        if activeTab == .all,
           let group = cardGroup(of: dragged), !group.itemIDs.contains(target) {
            detachFromGroup(dragged)
        }
        moveItem(dragged, anchor: target, after: after)
    }

    /// 钉住区内部：整组换位。成员保持连续。
    func movePinnedGroup(_ groupID: UUID, anchor target: UUID, after: Bool) {
        guard let group = cardGroupByID(groupID), !group.itemIDs.contains(target) else { return }
        var cursor: UUID? = target
        var insertAfter = after
        for id in group.itemIDs where PinnedLaneStore.contains(id) {
            PinnedLaneStore.move(id, before: cursor, after: insertAfter)
            cursor = id
            insertAfter = true
        }
        pinnedLaneGeneration &+= 1
    }

    /// 钉住区内部换位。
    func movePinned(_ id: UUID, anchor target: UUID, after: Bool) {
        PinnedLaneStore.move(id, before: target, after: after)
        pinnedLaneGeneration &+= 1
    }

    // MARK: - 手动分组

    /// 分组数据的版本号。改一次界面重算一次——`CardGroupStore` 是静态存储，
    /// 不参与 Observation，需要一个可观察的量把它的变化带进视图。
    private(set) var cardGroupGeneration = 0
    /// 展开的分组。和版本合集分开存：两者语义不同，混在一起会互相干扰。
    var expandedCardGroups: Set<UUID> = []
    /// 顶部那一排选中的分组。选中后只看这一组的卡片。
    var activeCardGroup: UUID? {
        didSet {
            guard activeCardGroup != oldValue else { return }
            // 选了分组就别再叠一层平台筛选，两个一起收窄多半什么都剩不下。
            if activeCardGroup != nil { activeLinkGroup = nil }
        }
    }
    /// 分组筛选只在「全部」有意义。离开全部时把选中的分组清掉，否则它会变成
    /// 一个用户看不见的过滤器——轨道理应显示那一页签的内容，却只剩分组里的。
    private func clearCardGroupSelectionLeavingAllTab() {
        guard activeTab != .all, activeCardGroup != nil else { return }
        activeCardGroup = nil
    }

    /// 刚建好、等着起名字的那一组。界面据此弹出命名框。
    var groupAwaitingName: UUID?

    var cardGroups: [CardGroup] {
        _ = cardGroupGeneration
        return CardGroupStore.all()
    }

    /// 顶部一排里能点的分组：成员至少有一张还看得见。
    /// 顶部那一排的内容。
    ///
    /// 缓存：`StashWorkspace.body` 里 `availableLinkGroups` 被读两次（一次
    /// 决定页签高度、一次画那一排），每次都要把整份库过一遍并解析链接；
    /// 而这个 body 在悬停、拖拽的每一次 `dropUpdated` 上都会重跑。
    @ObservationIgnored private var filterRowCache: (
        key: VisibleItemsKey, links: [LinkGroup], folders: [CardGroup]
    )?

    private func filterRow() -> (links: [LinkGroup], folders: [CardGroup]) {
        let key = visibleItemsKey
        if let filterRowCache, filterRowCache.key == key {
            return (filterRowCache.links, filterRowCache.folders)
        }
        let value = (links: computedLinkGroups, folders: computedCardGroups)
        filterRowCache = (key, value.links, value.folders)
        return value
    }

    var availableCardGroups: [CardGroup] { filterRow().folders }

    private var computedCardGroups: [CardGroup] {
        // 顶部胶囊属于「全部」页，所以数字必须等于全部页真正能看到的活跃成员：
        // 回收站和隐私成员不计数。少于两张就不显示这个分组入口——一张卡不是组，
        // 更不能显示「3」点进去却只看到一张。
        let visible = Set(items.lazy.filter { !$0.isPrivate }.map(\.id))
        return cardGroups.compactMap { group in
            let members = group.itemIDs.filter { visible.contains($0) }
            guard members.count >= 2 else { return nil }
            return CardGroup(id: group.id, name: group.name, itemIDs: members)
        }
    }

    /// 条目 → 它所在的组。
    ///
    /// 建成索引而不是每次线性找：`cardGroup(of:)` 在排版时对**每一条**都要问
    /// 一次，而 `CardGroupStore.group(containing:)` 内部是一次全表扫描——
    /// 合起来就是 O(条目数 × 分组数)，每帧都跑。索引按分组代次缓存，
    /// 分组没变就不重建。
    private struct CardGroupLookup {
        var generation: Int
        var byItemID: [UUID: CardGroup]
        var byGroupID: [UUID: CardGroup]
    }

    @ObservationIgnored private var cardGroupIndexCache: CardGroupLookup?

    private var cardGroupLookup: CardGroupLookup {
        if let cache = cardGroupIndexCache, cache.generation == cardGroupGeneration {
            return cache
        }
        var byItemID: [UUID: CardGroup] = [:]
        var byGroupID: [UUID: CardGroup] = [:]
        for group in CardGroupStore.all() {
            byGroupID[group.id] = group
            for id in group.itemIDs { byItemID[id] = group }
        }
        let value = CardGroupLookup(
            generation: cardGroupGeneration,
            byItemID: byItemID,
            byGroupID: byGroupID
        )
        cardGroupIndexCache = value
        return value
    }

    var cardGroupIndex: [UUID: CardGroup] { cardGroupLookup.byItemID }

    func cardGroup(of itemID: UUID) -> CardGroup? { cardGroupLookup.byItemID[itemID] }

    /// 按组 id 查，给高频 drop validation 用。拖拽期间每秒会问几十次，
    /// 和 item→group 在同一代缓存里一次建好。
    func cardGroupByID(_ groupID: UUID) -> CardGroup? { cardGroupLookup.byGroupID[groupID] }

    /// 把一张卡拖到另一张上：合成一组，或者加入对方已有的组。
    ///
    /// 组不能和组合并——两组各自是用户归好的一个概念，合起来之后没有任何
    /// 办法还原成原来的两堆。要合并只能一张一张拖过去，那时候用户是清楚的。
    func mergeCards(_ dragged: UUID, into target: UUID) {
        guard draggingGroupID == nil, cardGroup(of: dragged)?.id != cardGroup(of: target)?.id
                || cardGroup(of: dragged) == nil else { return }
        // 进组就得先出钉住区。"一张卡只属于一个区"以前只在钉住那一侧成立
        // （`pinToFront` 会先出组），合并这一侧没做——结果是一张卡同时在
        // 钉住区和分组里：整组被钉住区排到队首、拖不动（拖完立刻被重排回去），
        // 而"移出分组"又只解开组不解开钉住，剩不下任何能取消钉住的手势。
        // 目标组本来就整组钉着，就把新成员一起钉进去；否则整组落回普通区。
        // 关键是别留下"半钉"——那会把一个组撕成两段画在轨道两头。
        let targetGroupPinned = CardGroupStore.group(containing: target)
            .map { isGroupPinned($0.id) } ?? isPinnedToFront(target)
        let existing = CardGroupStore.group(containing: target)
        let created = CardGroupStore.merge(dragged, into: target, defaultName: defaultGroupName())
        cardGroupGeneration &+= 1
        guard let created else { return }
        normalizeGroupPinning(created, pinned: targetGroupPinned)
        normalizeGroupMembers(created, around: target)
        // 不自动展开：合并之后用户多半还要接着拖第三张、第四张，展开的组占
        // 整条轨道，反而把要拖的那些挤出了视野。想看里面点一下就是。
        showTransientFeedback(existing == nil ? "已建分组" : "已加入分组")
        // 新建的组交给模型起名字：用户把两张卡叠在一起的那一刻，心里已经有
        // 一个词了（"招聘信息""房子"），只是懒得打。模型看一眼内容说出来，
        // 猜错了改一下就是，总好过一律叫"新分组 1"。
        //
        // 不弹输入框打断他：名字先自己长出来，右键随时能改。
        guard existing == nil else { return }
        nameGroupAutomatically(created)
    }

    /// 分组元数据和轨道顺序必须是同一个事实：成员在 canonical item order 里
    /// 连续，而且顺序等于 CardGroup.itemIDs。
    ///
    /// 旧实现只写 CardGroupStore，不动 items：A、X、B 合并成 [B,A] 后，屏幕扫描
    /// 到 A 就先画组，组出现在 A 的旧位置；再按 B/A 当边缘做换位，结果会跨过
    /// 中间的 X。这里保留目标组原来的视觉位置，把成员一次归成连续块。
    private func normalizeGroupMembers(_ groupID: UUID, around targetID: UUID) {
        guard let group = cardGroups.first(where: { $0.id == groupID }) else { return }
        let members = group.itemIDs.filter { id in items.contains(where: { $0.id == id }) }
        guard members.count >= 2 else { return }
        let memberSet = Set(members)
        let oldOrder = items.map(\.id)
        let originalAnchor = oldOrder.firstIndex(of: targetID)
            ?? oldOrder.indices.first(where: { memberSet.contains(oldOrder[$0]) })
            ?? oldOrder.endIndex
        // 移除成员后，锚点前被移走了几个，就从原索引扣掉几个。
        let removedBefore = oldOrder.prefix(originalAnchor).reduce(0) {
            $0 + (memberSet.contains($1) ? 1 : 0)
        }
        var order = oldOrder.filter { !memberSet.contains($0) }
        let insertion = min(max(0, originalAnchor - removedBefore), order.count)
        order.insert(contentsOf: members, at: insertion)
        guard order != oldOrder else { return }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        items = order.compactMap { byID[$0] }

        let tailAnchor = insertion + members.count < order.count
            ? order[insertion + members.count] : nil
        enqueueReorderPersistence { [library] in
            var anchor = tailAnchor
            for id in members.reversed() {
                try await library.moveItem(id, before: anchor)
                anchor = id
            }
        }
    }

    private func nameGroupAutomatically(_ groupID: UUID) {
        guard let action = groupNamingAction,
              let group = cardGroups.first(where: { $0.id == groupID }) else { return }
        let summaries = group.itemIDs.compactMap { id in
            items.first(where: { $0.id == id }).map(groupingSummary(of:))
        }
        guard !summaries.isEmpty else { return }
        Task { [weak self] in
            guard let name = await action(summaries), let self else { return }
            // 期间用户可能已经自己改过名字了，那就以他的为准。
            guard self.cardGroups.first(where: { $0.id == groupID })?.name
                    == group.name else { return }
            self.renameCardGroup(groupID, to: name)
        }
    }

    /// 交给模型看的那一段"这张卡是什么"。
    ///
    /// 标题 + 标签 + 正文摘录，够它判断归属了；不塞全文——分组判断只需要
    /// 认出主题，而全文会让每一次归类都变成一次昂贵调用。
    private func groupingSummary(of item: Item) -> String {
        var parts = [item.title]
        if let group = item.group { parts.append(group) }
        if !item.tags.isEmpty { parts.append(item.tags.joined(separator: "、")) }
        if case .inline(let text) = item.holding {
            parts.append(String(text.prefix(200)))
        } else if let filename = item.originalFilename {
            parts.append(filename)
        }
        return parts.joined(separator: " · ")
    }

    /// 一条新内容建好索引之后，看它属不属于已有的某个分组。
    ///
    /// 触发时机和检索索引完全同一条路：只有拖入、显式收纳、手机同步过来的
    /// 内容会走到这里，随手复制的临时内容不会——那些多数是过路的，
    /// 为它们每条都问一次模型既费钱又吵。
    func considerAutoGrouping(_ itemID: UUID) async {
        // 归组会把几张卡折成一摞——轨道当场变短。用户正拖着、或者指针就压在
        // 轨道上时做这件事，看到的是"卡片自己消失了、剩下的全错位"。排进队列，
        // 等手离开再补。
        guard !deferStructuralChanges else {
            if !pendingAutoGroupIDs.contains(itemID) { pendingAutoGroupIDs.append(itemID) }
            return
        }
        guard autoGroupingEnabled,
              isFeatureUnlocked(.ai),
              let action = groupAssignmentAction,
              cardGroup(of: itemID) == nil,
              let item = items.first(where: { $0.id == itemID }),
              shouldProcessContent(item) else { return }
        let groups = cardGroups
        guard !groups.isEmpty else { return }
        guard let index = await action(groupingSummary(of: item), groups.map(\.name)),
              groups.indices.contains(index) else { return }
        // 等模型回来的这段时间里，用户可能已经自己把它归好、或者把那个组
        // 解散了。落地前重新确认一遍。
        guard cardGroup(of: itemID) == nil,
              let target = cardGroups.first(where: { $0.id == groups[index].id }),
              let anchor = target.itemIDs.first else { return }
        guard let groupID = CardGroupStore.merge(
            itemID, into: anchor, defaultName: target.name
        ) else { return }
        cardGroupGeneration &+= 1
        normalizeGroupMembers(groupID, around: anchor)
        showTransientFeedback("已归入「\(target.name)」")
    }

    private func defaultGroupName() -> String {
        let taken = Set(cardGroups.map(\.name))
        var index = 1
        while taken.contains("新分组 \(index)") { index += 1 }
        return "新分组 \(index)"
    }

    func moveGroupMember(_ itemID: UUID, before targetID: UUID, after: Bool) {
        guard cardGroup(of: itemID)?.id == cardGroup(of: targetID)?.id else { return }
        CardGroupStore.moveMember(itemID, before: targetID, after: after)
        cardGroupGeneration &+= 1
    }

    /// 把卡片放到轨道空白处意味着什么：在组里就是拿出来，钉着就是松开钉子，
    /// 其余情况什么都不做。
    ///
    /// 判定和执行都收在模型里。之前这段逻辑只写在轨道背景那一层，边缘翻页
    /// 感应带压在它上面又只会 `return false`——靠边松手的投放既没落位、也没
    /// 人接手，卡片直接弹回原处。同一个动作必须只有一份解释。
    enum LeaveZoneIntent: Equatable {
        case none
        case detachGroup(UUID)
        case unpin(UUID)
        case unpinGroup(UUID)
    }

    func leaveZoneIntent() -> LeaveZoneIntent {
        switch outboundDrag {
        case .group(let groupID):
            // 组落到空白处绝不拆成员；唯一有意义的结果是"离开钉住区"。
            return isGroupPinned(groupID) ? .unpinGroup(groupID) : .none
        case .item(let id):
            // 分类页里的组成员只是普通卡投影，放到空白处不应改变「全部」页的
            // 组织关系。只有全部页才有“拖出组”这层语义。
            if activeTab == .all, cardGroup(of: id) != nil { return .detachGroup(id) }
            if isPinnedToFront(id) { return .unpin(id) }
            return .none
        case nil:
            return .none
        }
    }

    @discardableResult
    func applyLeaveZoneDrop() -> Bool {
        let action = leaveZoneIntent()
        guard action != .none else { return false }
        completeOutboundDrop()
        switch action {
        case .none:
            return false
        case .detachGroup(let id):
            // 从一个**钉住的**组里拖出来，就是整个离开前区：只解开组不解开
            // 钉子的话，它会变成一张孤零零钉在前面的卡，而用户的动作分明是
            // "把它拿出来"。
            if isPinnedToFront(id) { unpinFromFront(id) }
            detachFromGroup(id)
        case .unpin(let id):
            unpinFromFront(id)
        case .unpinGroup(let id):
            unpinGroup(id)
        }
        return true
    }

    func detachFromGroup(_ itemID: UUID) {
        guard CardGroupStore.group(containing: itemID) != nil else { return }
        CardGroupStore.detach(itemID)
        cardGroupGeneration &+= 1
        clearStaleCardGroupSelection()
        showTransientFeedback("已移出分组")
    }

    func renameCardGroup(_ groupID: UUID, to name: String) {
        CardGroupStore.rename(groupID, to: name)
        cardGroupGeneration &+= 1
    }

    func dissolveCardGroup(_ groupID: UUID) {
        CardGroupStore.dissolve(groupID)
        expandedCardGroups.remove(groupID)
        cardGroupGeneration &+= 1
        clearStaleCardGroupSelection()
        showTransientFeedback("已解散分组")
    }

    func toggleCardGroup(_ groupID: UUID) {
        if expandedCardGroups.contains(groupID) {
            expandedCardGroups.remove(groupID)
        } else {
            expandedCardGroups.insert(groupID)
        }
    }

    /// 选中的分组消失了（解散、成员全删）就把筛选收回去，否则界面停在
    /// 一片空白上，而那个筛选条已经不存在了。
    private func clearStaleCardGroupSelection() {
        guard let activeCardGroup else { return }
        if !availableCardGroups.contains(where: { $0.id == activeCardGroup }) {
            self.activeCardGroup = nil
        }
    }

    /// 卡片轨道上排的一格。
    ///
    /// 折叠起来的一族**不是"最新那版加个角标"，而是一张合集卡**：它代表的是
    /// 这份文档本身，不是其中某一版。展开之后才轮到每一版各自的普通卡片。
    /// 两种形态各有各的信息——合集卡说"这份东西有几版、最新的是什么时候"，
    /// 普通卡说"这一版是什么"——用同一张卡兼任会两头都说不清。
    enum DisplayEntry: Identifiable {
        /// 一族占一格。折叠时几张卡叠在一起只露边，展开时向右摊开。
        ///
        /// 折叠态用的还是**卡片本身**，不是另做一张合集卡：同一份东西的几个
        /// 版本，最该被看到的仍然是"它长什么样"，而重叠这个形状已经说清了
        /// "底下还有几张"。整族占一格则保证展开后它们仍然是一伙的，不会和
        /// 旁边不相干的卡片混成一片。
        case family(VersionCollection, [Item])
        /// 用户手动归的一组。和版本合集共用同一套折叠动效，但它有名字、
        /// 能改名、能解散——那是用户自己的分类，不是程序猜出来的。
        case cardGroup(CardGroup, [Item])
        case item(Item)

        var id: UUID {
            switch self {
            case .family(let collection, _): collection.id
            case .cardGroup(let group, _): group.id
            case .item(let item): item.id
            }
        }
    }

    /// 折叠态的一族。
    struct VersionCollection: Identifiable, Equatable {
        /// 用最新那版的 ID 当身份：展开/折叠、滚动定位都拿它当锚。
        var id: UUID
        /// 合集名。用文档自己首页上的标题，退回到最新那版的标题。
        var title: String
        var subtitle: String
        var count: Int
        var newest: Item
        var latestDate: Date
    }

    /// 折叠不改变 `visibleItems`——搜索、拖拽排序、隐私过滤全都还在整份列表上
    /// 工作，这里只决定"这一刻怎么画"。
    /// 轨道顺序 / 条目集合的变化令牌。给 `.animation(value:)` 用。
    ///
    /// 不拿 `entries.map(\.id)` 当触发值——那要求先算出 entries，而这条路径
    /// 每一次滚动、每一次悬停都在跑。这些代次本来就是 displayEntries 的全部
    /// 输入，比较几个 Int 是常数时间。
    var trackOrderToken: VersionSnapshotKey { versionSnapshotKey }

    @ObservationIgnored private var displayEntriesCache: (key: VersionSnapshotKey, value: [DisplayEntry])?

    var displayEntries: [DisplayEntry] {
        let key = versionSnapshotKey
        if let cache = displayEntriesCache, cache.key == key { return cache.value }
        let value = computedDisplayEntries
        displayEntriesCache = (key, value)
        return value
    }

    private var computedDisplayEntries: [DisplayEntry] {
        // visibleItems 自己就要过滤 + 排序一遍，取一次存下来。下面每处都用它，
        // 不再反复重算。
        let visible = visibleItems
        let slots = versionSlots
        guard !slots.isEmpty || !cardGroups.isEmpty else {
            return visible.map(DisplayEntry.item)
        }
        var seenGroups: Set<UUID> = []
        var result: [DisplayEntry] = []

        // 一次建好，循环里直接查。原来这一句写在循环体内，每遇到一个分组成员
        // 就把整份可见列表重建一遍字典——O(条目数²)，而它每帧都在跑。
        let byID = Dictionary(uniqueKeysWithValues: visible.map { ($0.id, $0) })
        let groupIndex = cardGroupIndex

        for item in visible {
            // 手动分组优先于版本合集：用户亲手归的类比程序认出来的关系更强，
            // 而且同一张卡不能同时出现在两摞里。
            // 手动分组是「全部」页的组织层。分类页（尤其链接页）已经有自己
            // 的平台筛选，那里成员按普通卡显示；不能又折成分组瓦片，点进去却
            // 因分类过滤看不到完整成员。
            if activeTab == .all,
               let group = groupIndex[item.id], activeCardGroup == nil {
                guard seenGroups.insert(group.id).inserted else { continue }
                let members = group.itemIDs.compactMap { byID[$0] }
                if members.count >= 2 {
                    result.append(.cardGroup(group, members))
                    continue
                }
                // 成员被删到只剩一张时按普通卡片画，别留一个空壳分组。
                result.append(.item(item))
                continue
            }
            // 钉住的卡片按它自己那一张画，不并进版本合集。
            //
            // 不挡的话会整张消失：钉住区把它排到了队首，而它在版本族里
            // rank != 1，循环走到 `guard slot.rank == 1` 那一句直接 continue，
            // 谁都没画它——用户看到的是"钉了一下，卡片不见了"。
            guard let slot = slots[item.id], !isPinnedToFront(item.id) else {
                result.append(.item(item))
                continue
            }
            // 整族出现在**最新那一版**所在的位置，其余成员让位。
            //
            // 一份文档在列表里该排在哪，取决于它最近一次更新是什么时候——
            // 而不是取决于哪一版碰巧先被扫到。旧版本后补进来时（把去年的 v1
            // 拖进来存档），整摞不该因此跑到最前面去。
            guard slot.rank == 1, seenGroups.insert(slot.groupID).inserted else { continue }
            guard let collection = versionCollection(groupID: slot.groupID, count: slot.total),
                  let family = versionSnapshot.familyByID[slot.groupID]
            else {
                result.append(.item(item))
                continue
            }
            // 成员按版本次序（新→旧）排，不按它们在轨道上的先后。
            let group = family.orderedIDs.compactMap { byID[$0] }
            guard !group.isEmpty else {
                result.append(.item(item))
                continue
            }
            result.append(.family(collection, group))
        }
        return result
    }

    private func versionCollection(groupID: UUID, count: Int) -> VersionCollection? {
        guard let newest = items.first(where: { $0.id == groupID }) else { return nil }
        let date = ItemTemporalFacts(item: newest).contentDate
        return VersionCollection(
            id: groupID,
            // 首页标题是这份文档自己的名字，比 AI 给某一版起的概括更适合当合集名。
            title: documentTitles[groupID] ?? newest.title,
            subtitle: "\(count) 个版本 · 最新 " + date.formatted(.dateTime.month().day()),
            count: count,
            newest: newest,
            latestDate: date
        )
    }

    func toggleVersionGroup(_ groupID: UUID) {
        if expandedVersionGroups.contains(groupID) {
            expandedVersionGroups.remove(groupID)
        } else {
            expandedVersionGroups.insert(groupID)
        }
    }

    /// 这条内容自己首页上写的标题。缺席时按需读一次分块。
    func documentTitle(of item: Item) -> String? {
        if let cached = documentTitles[item.id] { return cached }
        loadDocumentTitleIfNeeded(item)
        return nil
    }

    private func loadDocumentTitleIfNeeded(_ item: Item) {
        guard item.kind == .pdf || item.kind == .file,
              item.indexedAt != nil,
              documentTitles[item.id] == nil,
              documentTitleLoads.insert(item.id).inserted else { return }
        Task { [weak self] in
            guard let self else { return }
            defer { self.documentTitleLoads.remove(item.id) }
            let chunks = (try? await self.library.chunks(for: item.id)) ?? []
            // 只看第一页：标题一定在那儿，往后翻全是正文。
            let firstPage = chunks
                .filter { $0.source == .pdfPage || $0.source == .fileText }
                .min { $0.ordinal < $1.ordinal }
            guard let firstPage,
                  let title = DocumentTitleExtraction.title(fromFirstPage: firstPage.text)
            else { return }
            self.documentTitles[item.id] = title
            // 写进缓存但不一定立刻让界面重算：拖拽中版本族重排会把卡片当场
            // 折走。代次 bump 挂到用户放开轨道之后。
            if self.deferStructuralChanges {
                self.deferredDocumentTitleGenerationBump = true
            } else {
                self.documentTitleGeneration &+= 1
            }
        }
    }

    /// reload 之后补齐首页标题。没有它，版本族要等用户点开某条才认得出来。
    private func refreshDocumentTitles() {
        for item in items where item.kind == .pdf || item.kind == .file {
            loadDocumentTitleIfNeeded(item)
        }
    }

    /// 决定 `visibleItems` 结果的那几个输入。任何一个变了就重算。
    ///
    /// 数组不进 key（比较它们本身就和重算一样贵），改用一个由 didSet 维护的
    /// 修订号；其余全是标量，比较是常数时间。
    @ObservationIgnored private var visibleItemsRevision = 0
    @ObservationIgnored private var visibleItemsCache: (key: VisibleItemsKey, value: [Item])?

    struct VisibleItemsKey: Equatable {
        var revision: Int
        var tab: Tab
        var query: String
        var semanticQuery: String
        var linkGroup: LinkGroup?
        var cardGroup: UUID?
        var privateUnlocked: Bool
        var pinnedGeneration: Int
        var groupGeneration: Int
    }

    private var visibleItemsKey: VisibleItemsKey {
        VisibleItemsKey(
            revision: visibleItemsRevision,
            tab: activeTab,
            query: query,
            semanticQuery: semanticQuery,
            linkGroup: activeLinkGroup,
            cardGroup: activeCardGroup,
            privateUnlocked: isPrivateSpaceUnlocked,
            pinnedGeneration: pinnedLaneGeneration,
            groupGeneration: cardGroupGeneration
        )
    }

    /// 应用了分组筛选之后的可见条目。轨道画的是它。
    ///
    /// 带缓存：界面里有八九处会问它（空态判断、动画的 value、翻页、滚动定位…），
    /// 而每一次都要把整份库过一遍筛选、排序、钉住区重排。切页签时这些调用又
    /// 全都落在动画的每一帧上——卡顿和抖动就是这么来的。输入没变就直接返回
    /// 上一次的结果。
    var visibleItems: [Item] {
        let key = visibleItemsKey
        if let visibleItemsCache, visibleItemsCache.key == key { return visibleItemsCache.value }
        let value = computedVisibleItems
        visibleItemsCache = (key, value)
        return value
    }

    private var computedVisibleItems: [Item] {
        let base = visibleItemsIgnoringGroupFilter
        let filtered: [Item]
        if let activeCardGroup,
           let group = cardGroups.first(where: { $0.id == activeCardGroup }) {
            let members = Set(group.itemIDs)
            filtered = base.filter { members.contains($0.id) }
        } else {
            filtered = base
        }
        return orderedWithPinnedFirst(filtered)
    }

    /// 钉住的排在最前面，按钉住区自己的顺序；其余保持原来的次序。
    ///
    /// 用稳定重排而不是给它们改 `sortOrder`：钉住区的意义就是"后面来多少新
    /// 东西都不动我"，而 sortOrder 的默认值是创建时间戳，新条目天然排最前。
    /// 靠改写别人的值来维持这个不变量，改漏一次顺序就乱了。
    private func orderedWithPinnedFirst(_ items: [Item]) -> [Item] {
        let lane = pinnedLaneIDs
        guard !lane.isEmpty else { return items }
        let rank = Dictionary(uniqueKeysWithValues: lane.enumerated().map { ($0.element, $0.offset) })
        var pinned: [Item] = []
        var rest: [Item] = []
        for item in items {
            if rank[item.id] != nil { pinned.append(item) } else { rest.append(item) }
        }
        pinned.sort { (rank[$0.id] ?? 0) < (rank[$1.id] ?? 0) }
        return pinned + rest
    }

    /// 分组筛选之前的那一份。顶部那排分组自己要用它判断"这组还有没有内容"，
    /// 用 `visibleItems` 会自我循环：选中一组之后其余组全都变成空的。
    var visibleItemsIgnoringGroupFilter: [Item] {
        // 隐私页签是唯一能看到隐私内容的地方，而且必须先解锁。
        if case .privateSpace = activeTab {
            guard isPrivateSpaceUnlocked else { return [] }
            return items.filter(\.isPrivate)
        }
        // 其余任何页签、任何搜索都看不到隐私内容——包括"全部"。
        // 让它出现在"全部"里的话，解锁前后卡片数量的变化本身就暴露了它的存在。
        var result = items.filter { !$0.isPrivate }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // 搜索期间不套分类：停在"图片"页签时搜文字 Pin 会被悄悄滤掉，
        // 用户只看到"没有找到相关内容"，无从知道是分类挡的。
        if case .kind(let kind) = activeTab, trimmedQuery.isEmpty {  // 隐私页签在上面已返回
            result = result.filter { $0.kind == kind }
            if let activeLinkGroup {
                result = result.filter { linkGroup(of: $0) == activeLinkGroup }
            }
        }
        guard !trimmedQuery.isEmpty else { return result }
        if semanticQuery == trimmedQuery {
            let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.id, $0) })
            return semanticHits.compactMap { byID[$0.itemID] }
        }
        return result.filter { item in
            if item.title.localizedCaseInsensitiveContains(trimmedQuery) { return true }
            if item.tags.contains(where: { $0.localizedCaseInsensitiveContains(trimmedQuery) }) { return true }
            if item.group?.localizedCaseInsensitiveContains(trimmedQuery) == true { return true }
            if case .inline(let text) = item.holding {
                return text.localizedCaseInsensitiveContains(trimmedQuery)
            }
            return false
        }
    }

    /// 刘海下面那块补充内容现在是什么。
    ///
    /// 窗口尺寸、AppKit 命中框、SwiftUI 内容三者共用它。之前是各处分别问
    /// "有没有回答"，再加一种卡片就要在三个地方各补一次判断，漏掉任何一处
    /// 都表现为"看得到却点不到"。
    enum NotchSupplement: Equatable {
        case none
        case answer
        case todoPrompt
        case reminder
    }

    var notchSupplement: NotchSupplement {
        if activeReminder != nil { return .reminder }
        if contextAnswer != nil || contextAnswerError != nil { return .answer }
        if todoPrompt != nil { return .todoPrompt }
        return .none
    }

    /// 补充卡右端有几个按钮。没有卡片时是 0。
    var notchSupplementActionCount: Int {
        switch notchSupplement {
        case .none, .answer: 0
        case .todoPrompt: todoPrompt?.actionCount ?? 0
        case .reminder: 2
        }
    }

    var barState: BarState {
        if isDropTargeted { return .dropTargeted }
        // 提醒是用户自己定的时刻到了，压过一切被动信号。
        if activeReminder != nil { return .reminding }
        // 快捷推荐 / 回答优先于计时：它是用户刚刚明确触发的交付。
        if !contextSuggestions.isEmpty || contextAnswer != nil || contextAnswerError != nil {
            return .suggesting
        }
        if todoPrompt != nil { return .todoDraft }
        if focusTimer.phase == .running { return .timing }
        if focusTimer.phase == .paused { return .paused }
        // 正在判断这次复制要不要检索时也让刘海动起来，否则中间那一两秒
        // 完全没有反馈，看着像什么都没发生。
        if isIndexing || isAIProcessing || isResolvingContext { return .indexing }
        return .idle
    }

    var isShowingDiscardConfirmation: Bool { isConfirmingDetailDiscard }

    var workspacePhase: NotchPresentationState.WorkspacePhase {
        notchPresentation.workspacePhase
    }

    var dragPhase: NotchPresentationState.DragPhase {
        notchPresentation.dragPhase
    }

    var isExpanded: Bool { notchPresentation.isWorkspacePresented }
    var isDropTargeted: Bool { notchPresentation.showsDropFeedback }

    // MARK: - Mode and panel

    func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        guard newMode != .focus || isFeatureUnlocked(.efficiency) else {
            lastError = "效率模式当前不可用"
            return
        }
        endSearch()
        dismissDetailImmediately()
        mode = newMode
    }

    func isFeatureUnlocked(_ feature: EntitledFeature) -> Bool {
        entitlementGate.isUnlocked(feature)
    }

    func moveMode(horizontalDirection: CGFloat) {
        guard abs(horizontalDirection) > 40 else { return }
        setMode(horizontalDirection < 0 ? .focus : .stash)
    }

    func expand() {
        notchPresentation.requestOpen()
    }

    func togglePanel() {
        switch workspacePhase {
        case .hidden, .closing:
            expand()
        case .opening, .open:
            requestClose()
        }
    }

    func openSettings() {
        openSettingsAction?()
    }

    func requestOutsideClose() {
        guard isExpanded, !isPinnedOpen else { return }
        requestClose()
    }

    func requestClose() {
        // 工作台和详情是两个窗口。收起工作台不等于关闭详情，即使详情正在编辑；
        // 未保存确认只属于详情自己的关闭键。
        closeImmediately()
    }

    func requestDismissDetail() {
        if hasUnsavedChanges {
            isConfirmingDetailDiscard = true
        } else {
            dismissDetailImmediately()
        }
    }

    func confirmDiscard() {
        guard isConfirmingDetailDiscard else { return }
        isConfirmingDetailDiscard = false
        hasUnsavedChanges = false
        editingItemID = nil
        dismissDetailImmediately()
    }

    func cancelDiscard() { isConfirmingDetailDiscard = false }

    private func closeImmediately() {
        isPinnedOpen = false
        // 收起不等于放弃这次检索。原来这里无条件调 endSearch()，等于点一下别处
        // 就把正在跑的召回和流式回答全部取消——用户回来时看到的是一片空白，
        // 还以为是没搜到。所以只在**这次检索什么都没留下**时才收回搜索框：
        // 展开的 300pt 输入框会一直霸占标题栏，而里面既没有词也没有结果，
        // 下次打开看到的是一个空框而不是模式切换器。
        if !hasLiveSearch { endSearch() }
        collapseNow()
    }

    private func dismissDetailImmediately() {
        detailItem = nil
        sceneRecommendations = []
        isLoadingSceneRecommendations = false
        runningSceneAction = nil
        editingItemID = nil
        hasUnsavedChanges = false
    }

    func collapseNow() {
        // 面板一收就把隐私空间锁回去。不做这一步，解锁一次就一直开着，
        // 下次打开面板隐私内容直接摆在那儿——那把锁就只是个装饰。
        lockPrivateSpaceOnCollapse()
        notchPresentation.requestClose()
    }

    func completeWorkspaceOpen() {
        notchPresentation.completeOpen()
    }

    func completeWorkspaceClose() {
        notchPresentation.completeClose()
    }

    // MARK: - Drag lifecycle

    /// 拖入是显式意图，只展开浅投放区，不等同于点击打开完整工作台。
    func setDropTargeted(_ targeted: Bool, payloadKind: InboundPayloadKind = .unknown) {
        if targeted {
            inboundPayloadKind = payloadKind
            // 和 Core 的状态机保持同一条判据：.absorbed 只是上一次投放的余韵，
            // 不是"正在接收"。卡在这里的话连拖两个第二个就没反馈。
            guard dragPhase != .receiving else { return }
            notchPresentation.dragEntered()
            dragCompletionTask?.cancel()
        } else {
            guard dragPhase == .targeted else { return }
            notchPresentation.dragExited()
            inboundPayloadKind = .unknown
        }
    }

    @discardableResult
    func beginInboundDrop() -> Bool {
        notchPresentation.beginDrop()
    }

    /// 拖进来的文件读不出来。**先说真正的原因，再给对应的出路。**
    ///
    /// 这三种情况的处置互不相通，说错一种就等于把用户支到没用的地方去：
    ///
    /// - 权限不足：去系统设置勾完全磁盘访问权限。这是唯一能修好的那条路，
    ///   所以永远排在最前面——以前无论真实原因是什么都先讲"存到访达"，
    ///   用户照做也修不好，真正要点的开关一个字没提。
    /// - 文件已消失：别的应用清了自己的暂存目录，只能重新拖一次。
    /// - 其他读不出：多半是容器路径的老问题，建议先另存。
    func reportUnreadableDrop(_ urls: [URL], partial: IngestReport = .init()) {
        let names = urls.map(\.lastPathComponent).joined(separator: "、")
        let failures = urls.map(DroppedSourceTrust.readFailure(_:))
        let isPermission = failures.contains { $0 == .permissionDenied }
        let allMissing = !failures.isEmpty && failures.allSatisfy { $0 == .missing }

        needsFullDiskAccess = isPermission
        if isPermission {
            lastError = "没有读取「\(names)」的权限。"
                + "到「系统设置 → 隐私与安全性 → 完全磁盘访问权限」勾选 Mnemo 并重开本应用；"
                + "不想授权就先把文件存到访达，再从访达拖进来。"
        } else if allMissing {
            lastError = "「\(names)」已经不在了：拖出它的那个应用清掉了自己的暂存文件。"
                + "回到那个应用重新拖一次即可。"
        } else {
            lastError = "读不到「\(names)」：它在其他应用的私有目录里，"
                + "那里的文件随时会被清掉。先把它存到访达，再拖进来。"
        }

        var report = partial
        report.failed += urls.count
        completeInboundDrop(report)
        // 收起态看不到工作台里的提示，这类需要用户动手的失败必须展开来说。
        expand()
    }

    func completeInboundDrop(_ report: IngestReport) {
        let succeeded = report.inserted > 0 || report.reused > 0 || report.failed == 0
        notchPresentation.completeDrop(succeeded: succeeded)
        if report.inserted > 0, report.reused > 0 {
            showTransientFeedback("已收纳 \(report.inserted) 个，跳过 \(report.reused) 个重复项")
        } else if report.inserted > 0 {
            showTransientFeedback(report.inserted == 1 ? "已收进 Mnemo" : "已收纳 \(report.inserted) 个项目")
        } else if report.reused > 0 {
            showTransientFeedback("已经在 Mnemo 中，没有重复添加")
        } else if report.failed > 0 {
            // 收起态看不到工作台里的 toast，失败必须在刘海本体上有反馈，
            // 否则用户看到的就是"拖进去什么都没发生"。
            showEdgeStatus(.indexingFailed)
        }
        dragCompletionTask?.cancel()
        dragCompletionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            self?.notchPresentation.settleDrag()
            self?.inboundPayloadKind = .unknown
        }
    }

    func completeInternalDrop() {
        notchPresentation.settleDrag()
        inboundPayloadKind = .unknown
        showTransientFeedback("这个 Pin 已经收好了")
    }

    /// 一次内部拖拽的身份。
    ///
    /// 只允许一种：一张卡，或者一整个组。旧实现用两个 Optional（itemID +
    /// groupID）表达三种状态，拖组还得拿第一张成员卡冒充 payload。任何一个
    /// 清理点只清了其中一个，整个系统就把"拖组"降级成"拖第一张成员卡"。
    /// 枚举让这种非法组合在类型层面不存在。
    enum OutboundDrag: Equatable {
        case item(UUID)
        case group(UUID)

        var itemID: UUID? {
            if case .item(let id) = self { return id }
            return nil
        }
        var groupID: UUID? {
            if case .group(let id) = self { return id }
            return nil
        }
    }

    private(set) var outboundDrag: OutboundDrag?
    /// 兼容只关心"是不是一张卡"的现有界面读取。组不再冒充第一张卡。
    var draggingItemID: UUID? { outboundDrag?.itemID }
    var draggingGroupID: UUID? { outboundDrag?.groupID }
    /// 鼠标抬起立刻自增。SwiftUI 只订阅它来清高亮 / 空位，不再自己装第二套
    /// NSEvent monitor。
    private(set) var dragEndSignal = 0

    @ObservationIgnored private var dragWatchdog: Task<Void, Never>?
    @ObservationIgnored private var localDragEndMonitor: Any?
    @ObservationIgnored private var globalDragEndMonitor: Any?
    @ObservationIgnored private var dragIdentityClearTask: Task<Void, Never>?
    @ObservationIgnored private var dragGeneration = 0
    /// 拖拽期间 reload 一律挂起。乐观换位已经改了内存顺序，异步的 reload 这
    /// 时把整份 items 替换成库里还没写完的旧顺序——被拖的卡当场弹回、旁边
    /// 的卡集体位移，就是"拖动时抖动/消失"的头号来源。松手后补跑一次。
    @ObservationIgnored private var reloadDeferredDuringDrag = false
    /// 首页标题在拖拽中读到也先憋着，不 bump 版本代次——否则版本族会当着用户
    /// 的面把 PDF 折进合集，被拖的那张"消失"。松手后再让界面重算。
    @ObservationIgnored private var deferredDocumentTitleGenerationBump = false
    /// 指针此刻停在卡片轨道上。
    ///
    /// 光标压着轨道的时候绝不重排它——这是一条硬性不变量。异步归组、版本折叠
    /// 会让若干张卡合并成一摞：内容当场变短，而滚动位置还停在原来的偏移上，
    /// 屏幕上就是"卡片凭空消失 + 整条错位"。用户完全没做任何操作，只是把鼠标
    /// 移过去而已。
    var isPointerOverTrack = false {
        didSet {
            guard isPointerOverTrack != oldValue, !isPointerOverTrack else { return }
            flushDeferredStructuralWork()
        }
    }

    /// 轨道正被用户占用：拖拽中，或者指针就停在上面。
    var deferStructuralChanges: Bool { outboundDrag != nil || isPointerOverTrack }

    /// 被推迟的自动归组。挂起不能等于丢掉——否则鼠标恰好在轨道上的那几条
    /// 内容永远不会被归类，而这完全取决于当时手放在哪儿。
    @ObservationIgnored private var pendingAutoGroupIDs: [UUID] = []

    func beginOutboundDrag(_ drag: OutboundDrag) {
        dragCompletionTask?.cancel()
        dragCompletionTask = nil
        dragIdentityClearTask?.cancel()
        dragGeneration &+= 1
        outboundDrag = drag
        removeOutboundDragMonitors()

        // DropDelegate.performDrop 要在 mouseUp 之后同步读身份，所以 mouseUp 先
        // 只发视觉清理信号，身份下一拍再清。local 和 global 都装：在应用内 / 外
        // 松手各由一条负责；两条都保存并一起删，绝不留下永久监听器。
        localDragEndMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp]
        ) { [weak self] event in
            self?.finishOutboundDragInput()
            return event
        }
        globalDragEndMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp]
        ) { [weak self] _ in
            Task { @MainActor in self?.finishOutboundDragInput() }
        }

        // 看门狗：真正的兜底。
        //
        // 系统拖拽期间事件流被拖拽管理器接管，mouseUp **不一定**会送到
        // NSEvent 监听器——尤其是把东西拖进别的应用、或者拖到屏幕外取消时。
        // 漏掉那一下，outboundDrag 就永远留着：轨道以为还在拖，翻页箭头不
        // 回来、边缘感应带一直活着、投放判定全都基于一次早就结束的拖拽。
        // 按键状态是查出来的，不是等来的，所以不受事件投递影响。
        dragWatchdog?.cancel()
        dragWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, self.outboundDrag != nil else { return }
                guard NSEvent.pressedMouseButtons == 0 else { continue }
                self.finishOutboundDragInput()
                return
            }
        }
    }

    func completeOutboundDrop() {
        dragIdentityClearTask?.cancel()
        outboundDrag = nil
        dragEndSignal &+= 1
        removeOutboundDragMonitors()
        flushDeferredStructuralWork()
    }

    /// 用户放开轨道之后，把憋着的重排一次补回来：版本代次先 bump（让重算拿到
    /// 完整输入），再补跑挂起的自动归组，最后 reload。
    private func flushDeferredStructuralWork() {
        guard !deferStructuralChanges else { return }
        if deferredDocumentTitleGenerationBump {
            deferredDocumentTitleGenerationBump = false
            documentTitleGeneration &+= 1
        }
        if !pendingAutoGroupIDs.isEmpty {
            let queued = pendingAutoGroupIDs
            pendingAutoGroupIDs = []
            Task { @MainActor [weak self] in
                for id in queued { await self?.considerAutoGrouping(id) }
            }
        }
        guard reloadDeferredDuringDrag else { return }
        reloadDeferredDuringDrag = false
        Task { await reload() }
    }

    private func finishOutboundDragInput() {
        guard outboundDrag != nil else { return }
        dragEndSignal &+= 1
        removeOutboundDragMonitors()
        let generation = dragGeneration
        dragIdentityClearTask?.cancel()
        dragIdentityClearTask = Task { @MainActor [weak self] in
            // 视觉状态已由 dragEndSignal 在 mouseUp 当下清掉；身份要多留一小段
            // 给 SwiftUI 的 performDrop 读取。`Task.yield()` 只让出执行器，不保证
            // 下一轮 run loop——它可能在 delegate 之前恢复，把一次合法投放变成
            // nil。300ms 是取消 / 落到应用外时的兜底，正常投放会由
            // completeOutboundDrop 当场清掉。generation 保证不误清下一次拖拽。
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self, self.dragGeneration == generation else { return }
            self.outboundDrag = nil
            self.dragIdentityClearTask = nil
            self.flushDeferredStructuralWork()
        }
    }

    private func removeOutboundDragMonitors() {
        dragWatchdog?.cancel()
        dragWatchdog = nil
        if let localDragEndMonitor {
            NSEvent.removeMonitor(localDragEndMonitor)
            self.localDragEndMonitor = nil
        }
        if let globalDragEndMonitor {
            NSEvent.removeMonitor(globalDragEndMonitor)
            self.globalDragEndMonitor = nil
        }
    }

    // MARK: - Search, preview, and retrieval

    func beginSearch() { isSearching = true }

    /// 这次检索还在进行中吗。收起期间也算——任务并没有被取消。
    var hasLiveSearch: Bool {
        isPerformingSemanticSearch || isStreamingSearchAnswer
            || !semanticHits.isEmpty || !searchAnswer.isEmpty
    }

    /// 拿选中的文字直接出推荐：结果就落在刘海上那一行，不展开工作台。
    ///
    /// 这是快捷键的主路径。复制不再自动跑推荐，改成用户明确按下时才跑——
    /// 想要的是"顺手给我那个东西"，不是"打开搜索页自己找"。
    func recommendForSelection(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "没有选中可检索的文字"
            return
        }
        resolveClipboardContext(
            // 事件粗筛本来允许到 2,000 字；这里不该再偷偷截成 300，控制器与
            // 回答器都需要看到完整问题。各供应商 prompt 自己还有 1,000 字预算。
            text: String(trimmed.prefix(2_000)),
            kind: .text,
            fingerprint: "selection:" + Self.digest(trimmed),
            sourceItemID: nil,
            isExplicitTrigger: true
        )
    }

    func endSearch() {
        semanticSearchTask?.cancel()
        isPerformingSemanticSearch = false
        isSearching = false
        query = ""
        semanticHits = []
        retrievalRecommendations = []
        semanticQuery = ""
        understoodSearchQuery = nil
        clearSearchAnswer()
    }

    func preview(_ item: Item) {
        guard editingItemID == nil else { return }
        // Office 文档没有内置预览：双击直接交给系统默认工具（Word、Excel、WPS），
        // 比打开一个空白详情窗诚实得多。
        if (item.kind == .file || item.kind == .binary),
           let filename = item.originalFilename,
           OfficeTextExtractor.canExtract(from: URL(filePath: filename)) {
            open(item)
            return
        }
        detailItem = item
        isPDFQuestioning = false
        isAnsweringPDF = false
        pdfAnswer = nil
        pdfQuestionTask?.cancel()
        // 详情不再逐条向模型要"场景建议"：动作已经收敛成按类型固定的几个。
        // 场景识别改由剪贴板上下文事件驱动，不在这里发请求。
        sceneRecommendations = []
        isLoadingSceneRecommendations = false
        runningSceneAction = nil
    }

    /// 场景推荐先给本地确定性结果；只有配置了模型且当前内容版本与路由没有
    /// 成功缓存时才请求一次。失败在本次网络/配置周期内不重复轰炸供应商。
    ///
    /// 详情动作已固定为本地白名单，远端推荐不再自动发起。

    func open(_ item: Item) {
        if let url = item.linkURL {
            LinkOpener.open(url, preferredBrowserBundleID: browserBundleID(for: item.id))
            return
        }
        Task {
            do {
                guard let url = try await library.resolvedFileURL(for: item) else { return }
                NSWorkspace.shared.open(url)
            } catch {
                lastError = error.localizedDescription
            }
        }
    }

    func beginEditing(_ item: Item) {
        guard case .inline = item.holding else { return }
        detailItem = item
        editingItemID = item.id
        hasUnsavedChanges = false
    }

    func updateEditDirty(_ dirty: Bool, for id: UUID) {
        guard editingItemID == id else { return }
        hasUnsavedChanges = dirty
    }

    /// 卡片的默认动作。单击一律复制——取用远比查看频繁；查看走双击。
    func activate(_ item: Item) { copy(item) }

    func copy(_ item: Item) {
        Task { [weak self] in
            guard let self else { return }
            _ = await self.writeItemToClipboard(item, showsFeedback: true)
        }
    }

    /// 只有系统粘贴板确认写入后才返回 true。文件需要先异步解析真实 URL；
    /// `shouldWrite` 会在这个 await 之后再次检查所属事件是否仍是当前一代，避免
    /// 已取消的旧推荐在后台解析完成后覆盖用户刚复制的新内容。
    private func writeItemToClipboard(
        _ item: Item,
        showsFeedback: Bool,
        shouldWrite: @MainActor @escaping () -> Bool = { true }
    ) async -> Bool {
        do {
            let wrote: Bool
            switch item.holding {
            case .inline(let text):
                guard shouldWrite() else { return false }
                wrote = Clipboard.write(text)
            case .copy, .reference:
                guard let url = try await library.resolvedFileURL(for: item) else {
                    lastError = "原文件不可用，无法复制"
                    return false
                }
                guard shouldWrite() else { return false }
                // 受管副本在沙盒里是个无扩展名的哈希文件，直接放上剪贴板接收方
                // 判不出类型也给不出文件名——"显示复制成功却粘不出来"就是这个。
                wrote = Clipboard.write(fileAt: PinFileStaging.pasteboardURL(for: item, source: url))
            }
            guard wrote else {
                // 最常见的一种：条目引用的是别的应用容器里的文件（比如从微信
                // 聊天里拖出来的），那份原文件 Mnemo 读不到，也就交不出去。
                lastError = item.holding.isReference
                    ? "原文件在其他应用的目录里，Mnemo 读不到；请先把它存到访达再拖进来"
                    : "写入系统剪贴板失败"
                return false
            }
            if showsFeedback {
                let message = switch item.kind {
                case .link: "链接已复制"
                case .text: "文字已复制"
                default: "文件已复制"
                }
                showCopiedFeedback(for: item.id, message: message)
            }
            return true
        } catch let error as VaultError {
            lastError = error.description
        } catch {
            lastError = error.localizedDescription
        }
        return false
    }

    func performSceneRecommendation(_ recommendation: SceneRecommendation, on item: Item) {
        switch recommendation.id {
        case .copy:
            copy(item)
        case .open:
            open(item)
        case .preview:
            preview(item)
        case .plainText where item.kind == .image:
            runningSceneAction = .plainText
            Task { [weak self] in
                guard let self else { return }
                let chunks = (try? await library.chunks(for: item.id)) ?? []
                let recognized = chunks
                    .filter { $0.source == .imageOCR }
                    .map(\.text)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                guard self.detailItem?.id == item.id else { return }
                self.runningSceneAction = nil
                if recognized.isEmpty {
                    self.showTransientFeedback("这张图片还没有识别到可复制的文字")
                } else {
                    Clipboard.write(recognized)
                    self.showTransientFeedback("识别文字已复制")
                }
            }
        case .extractTaxNumber, .plainText, .translate, .summarize:
            guard let action = aiTransformAction else { return }
            runningSceneAction = recommendation.id
            Task { [weak self] in
                let output = await action(item, recommendation.id)
                guard let self, self.detailItem?.id == item.id else { return }
                self.runningSceneAction = nil
                if let output, !output.isEmpty {
                    Clipboard.write(output)
                    self.showTransientFeedback("处理结果已复制")
                } else {
                    self.showTransientFeedback("当前内容无法执行这个动作")
                }
            }
        case .askPDF:
            isPDFQuestioning = true
        case .createTodo:
            Task { await setTodo(item.id, enabled: true) }
        }
    }

    func askPDF(_ question: String, about item: Item) {
        let value = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard item.kind == .pdf, !value.isEmpty, let action = pdfQuestionAction else { return }
        pdfQuestionTask?.cancel()
        isAnsweringPDF = true
        pdfQuestionTask = Task { [weak self] in
            let answer = await action(item, value)
            guard !Task.isCancelled, let self, self.detailItem?.id == item.id else { return }
            self.isAnsweringPDF = false
            self.pdfAnswer = answer ?? "没有得到可用答案。请检查 PDF 问答模型配置，或换一种问法。"
            self.pdfQuestionTask = nil
        }
    }

    func setTodo(_ id: UUID, enabled: Bool) async {
        do {
            try await library.setTodo(for: id, enabled: enabled)
            await reload()
            showTransientFeedback(enabled ? "已加入待办" : "已移出待办")
        } catch {
            lastError = "待办更新失败：\(error.localizedDescription)"
        }
    }

    func allowSensitiveAI(for id: UUID) async {
        guard var item = items.first(where: { $0.id == id }) else { return }
        item.allowsSensitiveAI = true
        item.aiPrivacyBlocked = false
        do {
            try await library.update(item)
            await reload()
            if let refreshed = items.first(where: { $0.id == id }) {
                scheduleAIWork(for: refreshed)
            }
            showTransientFeedback("已仅为这个 Pin 允许 AI 处理")
        } catch {
            lastError = "隐私设置更新失败：\(error.localizedDescription)"
        }
    }

    func toggleTodoCompleted(_ id: UUID) async {
        guard var todo = todos.first(where: { $0.id == id }) else { return }
        todo.isCompleted.toggle()
        do {
            try await library.updateTodo(todo)
            await reload()
        } catch {
            lastError = "待办更新失败：\(error.localizedDescription)"
        }
    }

    func setTodoDueDate(_ id: UUID, date: Date?) async {
        guard var todo = todos.first(where: { $0.id == id }) else { return }
        todo.dueAt = date
        do {
            try await library.updateTodo(todo)
            // 改了时间就是"这条我要重新被提醒"。已送达记录按 todoID+时段 去重，
            // 不清掉的话，把时间从今早改到今晚，那条新的照样被当成"已经提醒过"。
            forgetDeliveredReminders(for: id)
            if activeReminder?.todoID == id { dismissReminder() }
            await reload()
        } catch {
            lastError = "截止日期更新失败：\(error.localizedDescription)"
        }
    }

    /// 用户从待办列表里删掉一条：连它的提取来源一起收拾干净。
    func deleteTodo(_ id: UUID) async {
        _ = await deleteTodo(id, cascadesToSource: true)
    }

    /// - Parameter cascadesToSource: 要不要顺带处理提取来源。
    ///
    ///   撤销路径**必须传 false**。撤销的意思是"刚才那一下不该发生"，而来源
    ///   是用户自己拖进来的那张截图——把它一起带走，等于用一次撤销惩罚了
    ///   一个正确的动作。
    @discardableResult
    private func deleteTodo(_ id: UUID, cascadesToSource: Bool) async -> Bool {
        // 先取来源：删完待办这条记录就没了。只有主记录真正删除后才动旁路信息，
        // 否则一次存储失败会让仍存在的待办失去来源，进而误删共享 Pin。
        let sourceID = cascadesToSource ? TodoProvenanceStore.sourceItemID(for: id) : nil
        do {
            try await library.deleteTodo(id: id)
            TodoPresentationStore.forgetTodo(id)
            TodoProvenanceStore.forget(todoID: id)
            if let sourceID { await discardExtractionSource(sourceID) }
            await reload()
            return true
        } catch {
            lastError = "删除待办失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 待办没了，它的提取来源也就没有留下的理由。
    ///
    /// 分两档，都是"用户已经表达过的意思"的自然延伸：
    ///
    /// - 来源还在库里：移进回收站。可恢复，和手动删一条 Pin 是同一个语义。
    /// - 来源已经在回收站：走清空那条路彻底清掉——检索分块（RAG）、受管副本、
    ///   记录一起消失。它本来就在等着被清，这次只是提前。
    ///
    /// 来源早就被彻底清空过时静默跳过：那不是失败，是已经达成的状态。
    private func discardExtractionSource(_ itemID: UUID) async {
        // 还有别的待办指着同一条来源就不能动它——一段聊天记录里提取出两件事，
        // 删掉其中一件不该让另一件失去出处。
        guard !TodoProvenanceStore.hasReference(to: itemID) else { return }

        do {
            guard let item = try await library.item(id: itemID) else {
                // 来源已被彻底清空过，目标状态已经达成，只收拾孤儿旁路记录。
                forgetItemSideCars(itemID)
                return
            }
            if item.state == .trashed {
                try await library.purge(id: itemID)
            } else {
                try await library.trash(id: itemID)
            }
            // 只有主记录成功进入目标状态后才清理旁路信息；失败时保留完整重试条件。
            forgetItemSideCars(itemID)
        } catch {
            lastError = "清理来源失败：\(error.localizedDescription)"
        }
    }

    /// 条目消失后，那些挂在它 ID 上的旁路记录也要一起收掉，
    /// 否则它们会以孤儿的形式留在偏好里直到下一次 reload 才被扫掉。
    private func forgetItemSideCars(_ itemID: UUID) {
        NearbyDeviceOrigin.setNearby(false, for: itemID)
        LinkCoverStore.remove(itemID)
        pendingTodoScanIDs.remove(itemID)
        cancelQueuedAI(for: itemID)
    }

    // MARK: - 人工标题与标签

    /// 库里已经用过的标签，用得多的排前面。
    ///
    /// 打标签这件事最烦的不是打字，是**每次都要重新想一遍上次叫什么**——
    /// 「阿里云」和「阿里云密钥」分成两个标签，检索时就少一半。把用过的摆出来
    /// 点一下，比让用户凭记忆重打一遍强得多。
    var frequentTags: [String] {
        var counts: [String: Int] = [:]
        for item in items where !item.isPrivate {
            for tag in item.tags { counts[tag, default: 0] += 1 }
        }
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(12)
            .map(\.key)
    }


    /// 用户亲手改的标题 / 加的标签。
    ///
    /// 改完立刻排进索引队列：这句话要进向量库才算数，否则它只存在于界面上，
    /// 模型看不到、语义检索也召不回——而备注常常正是用户唯一记得住的说法。
    func setUserAnnotation(_ id: UUID, title: String?, tags: [String]) async {
        do {
            try await library.setUserAnnotation(id: id, title: title, tags: tags)
            await reload()
            if let item = items.first(where: { $0.id == id }) {
                enqueueIndex(item.id, item: item)
                showTransientFeedback("已更新，正在重建检索")
            }
        } catch {
            lastError = "保存失败：\(error.localizedDescription)"
        }
    }

    func openLinkedItem(for todo: Todo) {
        guard let itemID = todo.linkedItemID,
              let item = items.first(where: { $0.id == itemID }) else { return }
        setMode(.stash)
        preview(item)
    }

    func addStandaloneTodo(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try await library.addTodo(title: trimmed)
            await reload()
            rescheduleReminders()
        } catch {
            lastError = "添加待办失败：\(error.localizedDescription)"
        }
    }

    // MARK: - 剪贴板 → 待办

    /// 把一段刚进来的文字（或截图的 OCR 结果）过一遍待办提取。
    ///
    /// 提取本身是本地正则，不花任何调用；真正需要克制的是**打扰**。所以这里
    /// 只有两种结局，没有第三种：
    ///
    /// - 证据确凿（取餐码、取件码这类字面命中）：**直接建**，刘海上闪一下
    ///   告诉你建了什么，右边留一个叉可以撤销；
    /// - 拿不准（标题是从整句里抠出来的）：弹一个对号一个叉，你点了才算。
    ///
    /// 除此之外一律沉默——同一件事只提一次，忽略过就不再提。
    func considerTodoDraft(
        in text: String,
        sourceItemID: UUID? = nil,
        fromNearbyDevice: Bool = false,
        now: Date = .now
    ) {
        guard todoIntakeEnabled, isFeatureUnlocked(.efficiency) else { return }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.count >= 4 else { return }
        // 同一条来源只排一次。索引完成、网络恢复、启动补跑都可能把同一张截图
        // 送过来，没有这道去重就会对同一段 OCR 反复付费。
        if let sourceItemID,
           (activeTodoIntakeSourceID == sourceItemID
            || todoIntakeQueue.contains(where: { $0.sourceItemID == sourceItemID })) { return }

        todoIntakeQueue.append(TodoIntakeJob(
            text: body,
            sourceItemID: sourceItemID,
            fromNearbyDevice: fromNearbyDevice,
            enqueuedAt: now
        ))
        // 积压超过这个数说明用户在批量粘贴，最老的那些已经没人关心了。
        if todoIntakeQueue.count > 8 {
            todoIntakeQueue.removeFirst(todoIntakeQueue.count - 8)
        }
        drainTodoIntake()
    }

    /// 串行处理队列。
    ///
    /// 这里刻意**不取消**正在跑的那一个：模型调用是秒级的，而剪贴板事件常常
    /// 三四秒一个。旧实现用 `cancel()` 保留最后一次，结果两张前后脚到达的截图
    /// 里，第一张的理解总是被第二张打断——OCR 明明成功，候选却凭空消失。
    private func drainTodoIntake() {
        guard todoIntakeTask == nil, !todoIntakeQueue.isEmpty else { return }
        todoIntakeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                self.todoIntakeTask = nil
                // 处理期间可能又有新内容进来；自己接着跑完。
                if !self.todoIntakeQueue.isEmpty { self.drainTodoIntake() }
            }
            while self.todoIntakeEnabled, !self.todoIntakeQueue.isEmpty {
                let job = self.todoIntakeQueue.removeFirst()
                self.activeTodoIntakeSourceID = job.sourceItemID
                let generation = self.todoIntakeGeneration
                await self.processTodoIntake(job, generation: generation)
                self.activeTodoIntakeSourceID = nil
            }
        }
    }

    /// 处理一条输入：本地提取 → 模型理解 → 呈现。
    ///
    /// 三种结局分别对应三种善后：
    /// - 模型答了：这条来源就算处理完，从待扫描名单里划掉；
    /// - 没配路由：同样划掉——重试一百次也是同样结果，只用本地规则；
    /// - 这次失败：**留在名单里**，等网络恢复或下次启动再来一遍。
    private func processTodoIntake(_ job: TodoIntakeJob, generation: UInt64) async {
        let text = job.text
        let now = job.enqueuedAt
        let snapshot = todos
        let localDrafts = await Task.detached(priority: .utility) {
            ClipboardTodoExtractor.drafts(from: text, now: now)
        }.value
        let localPlans = TodoReconciler.plans(
            text: text,
            drafts: localDrafts,
            todos: snapshot,
            now: now,
            limit: TodoRevisionPrompt.maximumDecisionCount
        )

        var plans: [TodoRevisionPlan] = []
        var shouldSettleSource = true

        if let interpret = todoRevisionAction {
            // 模型是主理解器：一轮可以返回多个互相独立的动作。每一项都在本地
            // 单独验证、对回本轮候选并去重，坏掉一项不会吞掉同批其他事项。
            let candidates = await revisionCandidates(from: snapshot)
            switch await interpret(text, candidates) {
            case .decided(let decisions):
                plans = normalizedPlans(
                    from: decisions.compactMap {
                        self.plan(
                            from: $0,
                            candidates: candidates,
                            sourceText: text,
                            now: now
                        )
                    }
                )
                // 本地逐字命中的结构化码比模型漏判更可靠。只补模型尚未覆盖的
                // 确凿码类，不用本地场景词复活普通日程。
                plans = normalizedPlans(from: plans + localPlans.filter(\.isCertain))
                // 模型一条都没给，本地却有凭据：以本地为准。
                //
                // "答了但答的是空"和"没答"在结果上分不开，而本地这一侧的门槛
                // 并不低——要有明确的未来日期，还要么命中线索词、要么整段排成
                // 一张日程清单。一张写着四条日程的通知截图，模型偶尔会整段
                // 略过；那时候把本地结果一起丢掉，用户看到的就是"什么都没识别"。
                if plans.isEmpty { plans = localPlans }
            case .unavailable:
                plans = localPlans
            case .failed(let reason):
                ContextTrace.log("待办理解失败，保留重试：\(reason)")
                plans = localPlans
                shouldSettleSource = false
            }
        } else {
            plans = localPlans
        }

        // 模型调用期间用户可能关闭了识别或主动收起全部候选。旧一轮不能越过
        // 这道 generation barrier 去自动创建，也不能把已经清空的队列重新弹出来。
        guard todoIntakeEnabled, generation == todoIntakeGeneration else { return }
        if shouldSettleSource, let sourceItemID = job.sourceItemID {
            pendingTodoScanIDs.remove(sourceItemID)
        }
        guard !plans.isEmpty else { return }
        await present(
            plans,
            sourceItemID: job.sourceItemID,
            fromNearbyDevice: job.fromNearbyDevice
        )
    }

    /// 把还没理解成功的截图重新排队。
    ///
    /// 启动和网络恢复各调一次。OCR 分块已经在库里，所以这条重试不需要再跑
    /// 一次识别，也不会触碰任何相机或磁盘之外的东西。
    func resumePendingTodoScans() {
        guard todoIntakeEnabled, !pendingTodoScanIDs.isEmpty else { return }
        let retryable = pendingTodoScanIDs
        Task { [weak self] in
            guard let self else { return }
            for id in retryable {
                await self.considerTodoDraftFromIndexedImage(id)
            }
        }
    }

    /// 交给模型的现有待办清单。
    ///
    /// 三件事同时做到：每次都带上清单（否则模型只能一律新建）、按编号给
    /// （真实 ID 不出域）、以及在源还在时附上来源摘录——待办标题是当初做
    /// 减法抠出来的，信息有损，只看标题很难判断"是不是同一件事"。
    private func revisionCandidates(from todos: [Todo]) async -> [TodoRevisionCandidate] {
        let open = todos
            .filter { !$0.isCompleted }
            .sorted {
                let lhsDue = $0.dueAt ?? .distantFuture
                let rhsDue = $1.dueAt ?? .distantFuture
                if lhsDue != rhsDue { return lhsDue < rhsDue }
                return $0.id.uuidString < $1.id.uuidString
            }
            .prefix(12)

        var sourceContextCache: [UUID: String] = [:]
        var result: [TodoRevisionCandidate] = []
        for (offset, todo) in open.enumerated() {
            var context: String?
            // 源在回收站里也算还在——它随时可能被还原。只有彻底清空之后
            // 才没有上下文可给，那时我们手上确实什么都没有。
            if let itemID = TodoProvenanceStore.sourceItemID(for: todo.id) {
                if let cached = sourceContextCache[itemID] {
                    context = cached
                } else if let item = try? await library.item(id: itemID) {
                    let chunks = (try? await library.chunks(for: itemID)) ?? []
                    let body = chunks
                        .sorted { $0.ordinal < $1.ordinal }
                        .prefix(2)
                        .map(\.text)
                        .joined(separator: " ")
                    let value = ([item.title, body].filter { !$0.isEmpty }).joined(separator: " · ")
                    sourceContextCache[itemID] = value
                    context = value
                }
            }
            result.append(TodoRevisionCandidate(
                index: offset + 1,
                todoID: todo.id,
                title: todo.title,
                dueAt: todo.dueAt,
                sourceContext: context
            ))
        }
        return result
    }

    /// 把模型的判断翻译成一条提案。
    ///
    /// 编号越界在解析层已经挡掉了，这里只做最后一次对表：编号必须能落回一个
    /// **本轮真实给出过**的候选。模型改判的是动作，不是有没有这条待办。
    private func plan(
        from decision: TodoRevisionDecision,
        candidates: [TodoRevisionCandidate],
        sourceText: String,
        now: Date
    ) -> TodoRevisionPlan? {
        func candidate(_ index: Int?) -> TodoRevisionCandidate? {
            guard let index else { return nil }
            return candidates.first { $0.index == index }
        }

        // 模型自报"不需要确认"不是授权，本地可核对的事实才是。
        //
        // 有码且逐字对上时，这就是一个确凿的本地事实（取餐码、订单号都写在
        // 原文里），直接执行并留一个叉可撤销；没有码时才回落到"引用够像 +
        // 模型也说不必确认"。破坏性动作永远要用户点头。
        let evidenceVerified = decision.hasVerifiableEvidence(in: sourceText)
        let hasVerifiedCode = decision.code?.isEmpty == false && evidenceVerified
        let requiresExplicitConfirmation: Bool = {
            switch decision.action {
            case .rename, .complete, .cancel: true
            case .create, .reschedule, .none: false
            }
        }()
        let safeToAutoApply = !requiresExplicitConfirmation
            && evidenceVerified
            && (hasVerifiedCode || !decision.needsConfirmation)

        switch decision.action {
        case .none:
            return nil

        case .create:
            guard let title = decision.title, !title.isEmpty else { return nil }
            let canonicalTitle = title.lowercased()
                .replacingOccurrences(
                    of: #"[\s\p{P}\p{S}]+"#,
                    with: "",
                    options: .regularExpression
                )
            let dueSlot = decision.dueAt
                .map { String(Int($0.timeIntervalSince1970 / 300)) } ?? "none"
            let draft = TodoDraft(
                id: "model:\(canonicalTitle):\(dueSlot):\((decision.code ?? "").lowercased())",
                title: title,
                dueAt: decision.dueAt,
                source: todoDraftSource(for: decision.kind),
                reason: decision.reason.isEmpty ? "模型判断这是一件新的事" : decision.reason,
                code: decision.code
            )
            return TodoRevisionPlan(
                id: draft.id,
                revision: .create(draft),
                title: title,
                summary: draft.reason,
                isCertain: safeToAutoApply,
                kind: decision.kind,
                service: decision.service,
                code: decision.code
            )

        case .reschedule:
            guard let target = candidate(decision.index), let dueAt = decision.dueAt,
                  TodoReconciler.differsMeaningfully(target.dueAt, dueAt) else { return nil }
            return TodoRevisionPlan(
                id: "reschedule:\(target.todoID.uuidString):\(Int(dueAt.timeIntervalSince1970 / 300))",
                revision: .reschedule(
                    todoID: target.todoID,
                    title: target.title,
                    from: target.dueAt,
                    to: dueAt
                ),
                title: target.title,
                summary: "改到 " + TodoReminderPolicy.relativeDescription(of: dueAt, now: now),
                isCertain: safeToAutoApply,
                kind: decision.kind,
                service: decision.service,
                code: decision.code
            )

        case .rename:
            guard let target = candidate(decision.index), let title = decision.title else {
                return nil
            }
            let retimed = decision.dueAt.flatMap {
                TodoReconciler.differsMeaningfully(target.dueAt, $0) ? $0 : nil
            }
            // 标题和时间都没变就不是一次改动，别弹一张什么都不做的卡。
            guard title != target.title || retimed != nil else { return nil }
            return TodoRevisionPlan(
                id: "rename:\(target.todoID.uuidString):\(title.lowercased()):"
                    + (retimed.map { String(Int($0.timeIntervalSince1970 / 300)) } ?? "none"),
                revision: .rename(
                    todoID: target.todoID,
                    from: target.title,
                    to: title,
                    dueAt: retimed,
                    previousDueAt: target.dueAt
                ),
                title: title,
                summary: "改名自「\(target.title)」",
                isCertain: safeToAutoApply,
                kind: decision.kind,
                service: decision.service,
                code: decision.code
            )

        case .complete:
            guard let target = candidate(decision.index) else { return nil }
            return TodoRevisionPlan(
                id: "complete:\(target.todoID.uuidString)",
                revision: .complete(todoID: target.todoID, title: target.title),
                title: target.title,
                summary: "标记为已完成",
                isCertain: safeToAutoApply,
                kind: decision.kind,
                service: decision.service,
                code: decision.code
            )

        case .cancel:
            guard let target = candidate(decision.index) else { return nil }
            return TodoRevisionPlan(
                id: "cancel:\(target.todoID.uuidString)",
                revision: .cancel(todoID: target.todoID, title: target.title),
                title: target.title,
                summary: "这条待办被取消了",
                isCertain: safeToAutoApply,
                kind: decision.kind,
                service: decision.service,
                code: decision.code
            )
        }
    }

    /// 相同提案只留一条，同一条旧待办一批里最多修改一次，并把模型输出总数
    /// 钉在安全上限。创建项按自己的稳定 ID 去重。
    private func normalizedPlans(from input: [TodoRevisionPlan]) -> [TodoRevisionPlan] {
        var result: [TodoRevisionPlan] = []
        var seenPlanIDs: Set<String> = []
        var touchedTodoIDs: Set<UUID> = []
        for plan in input {
            guard seenPlanIDs.insert(plan.id).inserted else { continue }
            if let todoID = plan.revision.todoID,
               !touchedTodoIDs.insert(todoID).inserted { continue }
            result.append(plan)
            if result.count == TodoRevisionPrompt.maximumDecisionCount { break }
        }
        return result
    }

    private func todoDraftSource(
        for kind: TodoRevisionDecision.Kind
    ) -> TodoDraft.Source {
        switch kind {
        case .foodPickup: .pickupCode
        case .packagePickup, .delivery: .delivery
        case .deadline: .deadline
        case .appointment, .travel, .general: .appointment
        }
    }

    /// 同一输入里的确定项全部独立执行；待确认项顺序展示。两个任务因此不会
    /// 互相覆盖，也不会把两个撤销语义强塞进一张只有一个叉的卡里。
    private func present(
        _ plans: [TodoRevisionPlan],
        sourceItemID: UUID?,
        fromNearbyDevice: Bool
    ) async {
        let deviceKind = sourceItemID.flatMap(NearbyDeviceOrigin.kind(of:)) ?? .unknown
        // 来源 Pin 目前只有一个展示徽章；固定选择本批第一条有意义的元数据，
        // 避免遍历多任务时变成“最后一条碰巧覆盖前面”的不稳定结果。
        if let sourceItemID,
           let primary = plans.first(where: { TodoPresentationMetadata(plan: $0).isMeaningful }) {
            TodoPresentationStore.record(itemID: sourceItemID, plan: primary)
        }
        for plan in plans {
            guard todoIntakeEnabled, !handledTodoDraftIDs.contains(plan.id) else { continue }
            ContextTrace.log(
                "待办提案 \(plan.summary)（\(plan.isCertain ? "确凿" : "待确认")）：\(plan.title)"
            )

            let autoCreateOverride: Bool = {
                guard todoAutoCreateEnabled else { return false }
                if case .create = plan.revision { return true }
                return false
            }()
            let mayAutoApply = !plan.revision.requiresExplicitConfirmation
                && (plan.isCertain || autoCreateOverride)
            if mayAutoApply {
                guard let undo = await apply(plan, sourceItemID: sourceItemID) else { continue }
                handledTodoDraftIDs.insert(plan.id)
                enqueueTodoPrompt(.init(
                    prompt: .created(plan, undo: undo),
                    fromNearbyDevice: fromNearbyDevice,
                    deviceKind: deviceKind
                ))
            } else {
                handledTodoDraftIDs.insert(plan.id)
                enqueueTodoPrompt(.init(
                    prompt: .asking(plan, sourceItemID: sourceItemID),
                    fromNearbyDevice: fromNearbyDevice,
                    deviceKind: deviceKind
                ))
            }
        }
        if handledTodoDraftIDs.count > 500 {
            handledTodoDraftIDs = Set(handledTodoDraftIDs.shuffled().prefix(200))
        }
    }

    private var canShowTodoPrompt: Bool {
        activeReminder == nil
            && contextSuggestions.isEmpty
            && contextAnswer == nil
            && contextAnswerError == nil
    }

    private func enqueueTodoPrompt(_ queued: QueuedTodoPrompt) {
        guard !containsQueuedTodoPlan(queued.prompt.plan.id) else { return }
        // 所有新项先进入队尾，再由同一个入口决定何时展示，避免当前项正在写盘时
        // 新到候选越过更早的排队项。
        queuedTodoPrompts.append(queued)
        showNextTodoPromptIfNeeded()
    }

    private func containsQueuedTodoPlan(_ id: String) -> Bool {
        todoPrompt?.plan.id == id
            || queuedTodoPrompts.contains(where: { $0.prompt.plan.id == id })
    }

    private func showTodoPrompt(_ queued: QueuedTodoPrompt) {
        todoPrompt = queued.prompt
        todoDraftCameFromNearbyDevice = queued.fromNearbyDevice
        todoDraftDeviceKind = queued.deviceKind
        switch queued.prompt {
        case .created: scheduleTodoPromptDismissal(after: 6)
        case .asking: scheduleTodoPromptDismissal(after: 12)
        }
    }

    private func showNextTodoPromptIfNeeded() {
        guard todoPrompt == nil, canShowTodoPrompt, !queuedTodoPrompts.isEmpty else { return }
        showTodoPrompt(queuedTodoPrompts.removeFirst())
    }

    /// 提醒 / 回答结束后恢复被它遮住的待办候选，或展示队列头。
    private func competingNotchContentDidEnd() {
        resumeTodoPromptIfNeeded()
    }

    /// 执行一条提案，返回撤销所需的信息。已有待办在执行前重新核对标题、完成
    /// 状态和旧时间；候选等待期间用户若已经手动修改，旧计划就不再覆盖新状态。
    private func apply(_ plan: TodoRevisionPlan, sourceItemID: UUID?) async -> TodoUndo? {
        switch plan.revision {
        case .create(let draft):
            do {
                // 截止时间和主记录一次 upsert，避免“标题建成了、设时间失败”后留下
                // 一个没有来源、没有展示信息、也没有撤销入口的半成品。
                let todo = Todo(title: draft.title, dueAt: draft.dueAt)
                try await library.updateTodo(todo)
                if let sourceItemID {
                    TodoProvenanceStore.record(todoID: todo.id, sourceItemID: sourceItemID)
                }
                TodoPresentationStore.record(todoID: todo.id, plan: plan)
                await reload()
                rescheduleReminders()
                return .deleteTodo(todo.id)
            } catch {
                lastError = "加入待办失败：\(error.localizedDescription)"
                return nil
            }

        case .reschedule(let id, let title, let from, let to):
            guard var todo = todos.first(where: { $0.id == id }),
                  !todo.isCompleted,
                  todo.title == title,
                  !TodoReconciler.differsMeaningfully(todo.dueAt, from) else {
                lastError = "待办已发生变化，请根据最新状态重新识别"
                return nil
            }
            let previousMetadata = TodoPresentationStore.todo(id)
            todo.dueAt = to
            do {
                try await library.updateTodo(todo)
            } catch {
                lastError = "截止日期更新失败：\(error.localizedDescription)"
                return nil
            }
            TodoPresentationStore.record(todoID: id, plan: plan)
            await reload()
            rescheduleReminders()
            return .restoreDueDate(id, from, previousMetadata)

        case .rename(let id, let from, let to, let dueAt, let previousDueAt):
            guard var todo = todos.first(where: { $0.id == id }),
                  !todo.isCompleted,
                  todo.title == from,
                  !TodoReconciler.differsMeaningfully(todo.dueAt, previousDueAt) else {
                lastError = "待办已发生变化，请根据最新状态重新识别"
                return nil
            }
            let previousMetadata = TodoPresentationStore.todo(id)
            todo.title = to
            if let dueAt { todo.dueAt = dueAt }
            do {
                try await library.updateTodo(todo)
            } catch {
                lastError = "待办更新失败：\(error.localizedDescription)"
                return nil
            }
            TodoPresentationStore.record(todoID: id, plan: plan)
            await reload()
            rescheduleReminders()
            return .restoreTitle(id, from, previousDueAt, previousMetadata)

        case .complete(let id, let title):
            guard var todo = todos.first(where: { $0.id == id }),
                  !todo.isCompleted, todo.title == title else {
                lastError = "待办已发生变化，请根据最新状态重新识别"
                return nil
            }
            todo.isCompleted = true
            do {
                try await library.updateTodo(todo)
            } catch {
                lastError = "待办更新失败：\(error.localizedDescription)"
                return nil
            }
            TodoPresentationStore.record(todoID: id, plan: plan)
            await reload()
            rescheduleReminders()
            return .confirmed

        case .cancel(let id, let title):
            guard let todo = todos.first(where: { $0.id == id }),
                  !todo.isCompleted, todo.title == title else {
                lastError = "待办已发生变化，请根据最新状态重新识别"
                return nil
            }
            guard await deleteTodo(id, cascadesToSource: true) else { return nil }
            rescheduleReminders()
            return .confirmed
        }
    }

    /// 卡片只有真的处于最高优先级、可见且可点击时才开始倒计时。被提醒或回答
    /// 盖住时暂停，避免用户从未见过候选，它却已经超时消失。
    private func scheduleTodoPromptDismissal(after seconds: Double) {
        todoDraftDismissTask?.cancel()
        todoDraftDismissTask = Task { [weak self] in
            var remaining = seconds
            while remaining > 0 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                guard self.canShowTodoPrompt, self.todoPrompt != nil else { continue }
                remaining -= 0.25
            }
            guard let self else { return }
            self.removeCurrentTodoPrompt()
            self.showNextTodoPromptIfNeeded()
        }
    }

    /// 对号。写入期间保留当前卡作为 FIFO 栅栏；成功才反馈并前进，失败则留在
    /// 当前项让用户看见错误并可重试或点叉跳过。
    func confirmTodoPrompt() {
        guard !isMutatingTodoPrompt,
              case .asking(let plan, let sourceItemID)? = todoPrompt else { return }
        isMutatingTodoPrompt = true
        todoDraftDismissTask?.cancel()
        Task { [weak self] in
            guard let self else { return }
            defer { self.isMutatingTodoPrompt = false }
            guard case .asking(let current, _)? = self.todoPrompt,
                  current.id == plan.id else { return }
            guard await self.apply(plan, sourceItemID: sourceItemID) != nil else {
                self.scheduleTodoPromptDismissal(after: 12)
                return
            }
            self.removeCurrentTodoPrompt()
            self.showTransientFeedback("\(plan.summary)：\(plan.title)")
            self.showNextTodoPromptIfNeeded()
        }
    }

    /// 叉。`.asking` 时是“这次不办”，`.created` 时是“撤销刚才那一下”。
    func rejectTodoPrompt() {
        guard !isMutatingTodoPrompt, let prompt = todoPrompt else { return }
        todoDraftDismissTask?.cancel()
        guard case .created(let plan, let undo) = prompt else {
            removeCurrentTodoPrompt()
            showNextTodoPromptIfNeeded()
            return
        }
        isMutatingTodoPrompt = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isMutatingTodoPrompt = false }
            guard case .created(let current, _)? = self.todoPrompt,
                  current.id == plan.id else { return }
            guard await self.undo(undo) else {
                self.scheduleTodoPromptDismissal(after: 6)
                return
            }
            self.removeCurrentTodoPrompt()
            self.rescheduleReminders()
            self.showTransientFeedback("已撤销：\(plan.title)")
            self.showNextTodoPromptIfNeeded()
        }
    }

    private func undo(_ undo: TodoUndo) async -> Bool {
        switch undo {
        case .deleteTodo(let id):
            // 撤销自动新建只收回待办，不动来源；删除成功后 helper 才会忘记溯源。
            return await deleteTodo(id, cascadesToSource: false)

        case .restoreDueDate(let id, let date, let metadata):
            guard var todo = todos.first(where: { $0.id == id }) else { return false }
            todo.dueAt = date
            do { try await library.updateTodo(todo) }
            catch {
                lastError = "撤销失败：\(error.localizedDescription)"
                return false
            }
            TodoPresentationStore.restore(todoID: id, metadata: metadata)
            await reload()
            return true

        case .restoreTitle(let id, let title, let dueAt, let metadata):
            guard var todo = todos.first(where: { $0.id == id }) else { return false }
            todo.title = title
            todo.dueAt = dueAt
            do { try await library.updateTodo(todo) }
            catch {
                lastError = "撤销失败：\(error.localizedDescription)"
                return false
            }
            TodoPresentationStore.restore(todoID: id, metadata: metadata)
            await reload()
            return true

        case .confirmed:
            return true
        }
    }

    /// 点到外面只处理眼前真正可见的卡。提醒覆盖待办时，外点收起提醒并恢复
    /// 原候选；待办自身可见时才跳过当前一项，后续 FIFO 仍保留。
    func dismissNotchCards() {
        if activeReminder != nil {
            dismissReminder()
            resumeTodoPromptIfNeeded()
            return
        }
        if todoPrompt != nil, canShowTodoPrompt, !isMutatingTodoPrompt {
            removeCurrentTodoPrompt()
            showNextTodoPromptIfNeeded()
        }
    }

    private func removeCurrentTodoPrompt() {
        todoDraftDismissTask?.cancel()
        todoDraftDismissTask = nil
        todoPrompt = nil
        todoDraftCameFromNearbyDevice = false
        todoDraftDeviceKind = .unknown
    }

    private func clearTodoPrompt() {
        removeCurrentTodoPrompt()
        queuedTodoPrompts.removeAll()
    }

    private func cancelTodoIntakeAndClearPrompts() {
        todoIntakeGeneration &+= 1
        todoIntakeTask?.cancel()
        activeTodoIntakeSourceID = nil
        todoIntakeQueue.removeAll()
        clearTodoPrompt()
    }

    private func resumeTodoPromptIfNeeded() {
        if let todoPrompt {
            switch todoPrompt {
            case .created: scheduleTodoPromptDismissal(after: 6)
            case .asking: scheduleTodoPromptDismissal(after: 12)
            }
        } else {
            showNextTodoPromptIfNeeded()
        }
    }

    // MARK: - 待办提醒

    /// 轮询一拍：有没有待办到点了。
    ///
    /// 系统通知由 `TodoReminderCenter` 提前排好，这条路径只负责刘海上的那张卡；
    /// 两边共用 `TodoReminderPolicy`，所以不会一个响一个不响。
    func tickReminders(now: Date = .now) {
        guard reminderSettings.isEnabled, reminderSettings.usesNotchAlert else { return }
        guard activeReminder == nil else { return }
        let due = TodoReminderPolicy.due(
            todos: todos,
            settings: reminderSettings,
            now: now,
            delivered: deliveredReminderKeys
        )
        guard let next = due.first else { return }
        markReminderDelivered(next)
        activeReminder = next
        scheduleReminderDismissal()
    }

    /// 系统通知点开后回到这里：把同一条提醒也在刘海上显示出来，
    /// 用户不必再去找那条待办在哪。
    func presentReminder(forTodoID id: UUID) {
        guard let todo = todos.first(where: { $0.id == id }), let dueAt = todo.dueAt else { return }
        let reminder = TodoReminder(
            todoID: todo.id,
            title: todo.title,
            dueAt: dueAt,
            trigger: Date.now >= dueAt ? .overdue : .upcoming,
            slot: 0
        )
        markReminderDelivered(reminder)
        activeReminder = reminder
        scheduleReminderDismissal()
    }

    /// 忘掉这条待办的所有"已提醒"记录。
    ///
    /// 去重键是 todoID + 触发类型 + 时段号。改时间会换出一个新的时段号，
    /// 多数情况下自然就会重新提醒；但把时间在**同一个时段内**挪动（今天 9:00
    /// 改到今天 9:30）不会换号，那条新的会被当成已经提醒过而永远不响。
    /// 用户手动改过时间，语义上就是"重新提醒我"，一律清干净最省事。
    private func forgetDeliveredReminders(for todoID: UUID) {
        let prefix = todoID.uuidString + ":"
        let remaining = deliveredReminderKeys.filter { !$0.hasPrefix(prefix) }
        guard remaining.count != deliveredReminderKeys.count else { return }
        deliveredReminderKeys = remaining
        UserDefaults.standard.set(Array(deliveredReminderKeys), forKey: Self.deliveredRemindersKey)
    }

    private func markReminderDelivered(_ reminder: TodoReminder) {
        deliveredReminderKeys.insert(reminder.deduplicationKey)
        // 按"这条待办还在不在"来清，而不是按数量截断。
        //
        // 截断听起来更省事，但键里带着时间槽号，字典序和时间顺序无关——
        // 随手截掉的很可能正是当前这一槽的键，结果同一条提醒立刻又响一次。
        // 待办删掉或完成之后，它的历史键才真正没用了。
        if deliveredReminderKeys.count > 400 {
            let live = Set(todos.filter { !$0.isCompleted }.map(\.id.uuidString))
            deliveredReminderKeys = deliveredReminderKeys.filter { key in
                guard let head = key.split(separator: ":").first else { return false }
                return live.contains(String(head))
            }
        }
        UserDefaults.standard.set(
            Array(deliveredReminderKeys),
            forKey: Self.deliveredRemindersKey
        )
    }

    private func scheduleReminderDismissal(after seconds: Double = 15) {
        reminderDismissTask?.cancel()
        reminderDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.activeReminder = nil
            self?.competingNotchContentDidEnd()
        }
    }

    /// 收起卡片，但不改待办状态。逾期重复仍会在下一个间隔再提。
    func dismissReminder() {
        reminderDismissTask?.cancel()
        activeReminder = nil
        competingNotchContentDidEnd()
    }

    func completeActiveReminder() {
        guard let reminder = activeReminder else { return }
        dismissReminder()
        Task { [weak self] in
            guard let self else { return }
            await self.toggleTodoCompleted(reminder.todoID)
            self.rescheduleReminders()
            self.showTransientFeedback("已完成：\(reminder.title)")
        }
    }

    /// 稍后提醒：把截止时间整体后移，而不是只把卡片收起来。
    ///
    /// 只收卡片的话，逾期重复会按原来的槽继续算，用户点"稍后"反而可能几分钟
    /// 后又被提一次——那不是"稍后"，是"再烦我一遍"。
    func snoozeActiveReminder(minutes: Int = 10) {
        guard let reminder = activeReminder else { return }
        dismissReminder()
        let target = TodoReminderPolicy.snoozeDate(minutes: minutes)
        Task { [weak self] in
            guard let self else { return }
            await self.setTodoDueDate(reminder.todoID, date: target)
            self.rescheduleReminders()
            self.showTransientFeedback("\(minutes) 分钟后再提醒")
        }
    }

    /// 待办集合有变动时重排系统通知。
    func rescheduleReminders() {
        reminderScheduleDidChange?(todos, reminderSettings)
    }

    /// 上一次排期时待办的样子。见 `reload()` 里的说明。
    @ObservationIgnored private var lastReminderFingerprint: String?

    /// 排期依赖的字段：谁、什么时候到期、做完没有、标题（通知正文用它）。
    /// 顺序无关，所以先排序——单纯换个显示顺序不该触发一次重排。
    private static func reminderFingerprint(_ todos: [Todo]) -> String {
        todos.map { todo in
            [
                todo.id.uuidString,
                todo.dueAt.map { String(Int($0.timeIntervalSince1970)) } ?? "-",
                todo.isCompleted ? "1" : "0",
                todo.title,
            ].joined(separator: "\u{1}")
        }
        .sorted()
        .joined(separator: "\u{2}")
    }

    private func showCopiedFeedback(for id: UUID, message: String) {
        feedbackTask?.cancel()
        copiedItemID = id
        feedbackMessage = message
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.copiedItemID = nil
            self?.feedbackMessage = nil
        }
    }

    func showTransientFeedback(_ message: String) {
        feedbackTask?.cancel()
        feedbackMessage = message
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            self?.feedbackMessage = nil
        }
    }

    func dismissError() { lastError = nil }

    /// 直接跳到「完全磁盘访问权限」那一页，不让用户自己在设置里翻。
    func openFullDiskAccessSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 剪贴板上下文推荐

    /// 复制了东西之后判断一次：这像不像是在索取库里已有的材料。
    ///
    /// 三道闸门依次收窄，越往后越贵：本地粗筛 → 去重 → 模型路由。只有全过了
    /// 才会去召回和重排，普通的复制不会烧 token，也不会弹东西打断人。
    /// 新一次 Command-G 在读取前台选区前就宣布所有权。不能等 600ms 捕获成功后
    /// 才取消旧回答：旧回答可能在等待期间自动写剪贴板，被误认成新选区。
    func beginExplicitRecommendationCapture() {
        // 这一刻不做任何 AX 抓取：微信 / Electron 的 AX 查询是同步跨进程调用，
        // 放在读取选区之前会把选区读取挤到 Cmd-C 甚至“上一次记忆选区”回退，
        // 于是检索到的是上一轮的东西。插入目标改到拿到选区之后再抓。
        pendingAnswerInsertion = nil
        pendingAnswerInsertionWasCurrentSelection = false
        contextTask?.cancel()
        contextTask = nil
        contextDismissTask?.cancel()
        contextDismissTask = nil
        contextGeneration &+= 1
        isResolvingContext = true
        contextSuggestions = []
        contextAnswer = nil
        contextAnswerError = nil
        clearContextReasoning()
        didAutoCopyContextAnswer = false
        contextAnswerDelivery = nil
        isStreamingContextAnswer = false
        isContextAnswerIncomplete = false
    }

    /// 选区已经确认属于本轮之后才登记输入框目标：顺序颠倒会伤到检索本身。
    func confirmExplicitRecommendationSelection(
        _ text: String,
        insertionTarget: @autoclosure () -> FocusedInputTarget?,
        isCurrentSelection: Bool
    ) {
        guard isCurrentSelection, var target = insertionTarget() else {
            pendingAnswerInsertion = nil
            pendingAnswerInsertionWasCurrentSelection = false
            return
        }
        target.bindVerifiedSelection(text)
        pendingAnswerInsertion = target
        pendingAnswerInsertionWasCurrentSelection = true
    }

    func failExplicitRecommendationCapture(_ message: String) {
        pendingAnswerInsertion = nil
        pendingAnswerInsertionWasCurrentSelection = false
        isResolvingContext = false
        lastError = message
    }

    func resolveClipboardContext(
        text: String,
        kind: ItemKind,
        fingerprint: String,
        sourceItemID: UUID?,
        isExplicitTrigger: Bool = false
    ) {
        guard let action = clipboardContextAction, isFeatureUnlocked(.ai) else { return }
        // 被动复制不是“我在等回答”，绝不能往别人的输入框里写字。
        if !isExplicitTrigger {
            pendingAnswerInsertion = nil
            pendingAnswerInsertionWasCurrentSelection = false
        }
        let event = ClipboardContextEvent(
            fingerprint: fingerprint,
            kind: kind,
            text: text,
            sourceApplication: NSWorkspace.shared.frontmostApplication?.localizedName
        )
        guard ClipboardContextGate.shouldConsider(event) else {
            ContextTrace.log("粗筛拦下：长度 \(event.text.count)")
            return
        }

        let key = ContextualProcessingKey(
            contentFingerprint: fingerprint,
            sourceContext: event.sourceApplication ?? "",
            libraryVersion: Self.contextLibraryVersion(items),
            route: contextRouteFingerprintAction?()
                ?? sceneRecommendationRouteFingerprintAction?()
                ?? ""
        )

        contextTask?.cancel()
        contextDismissTask?.cancel()
        contextDismissTask = nil
        contextGeneration &+= 1
        let generation = contextGeneration
        // 新事件开始就撤下旧事件的卡片。否则新请求最终无结果时，旧卡片的关闭
        // 计时器已经取消，它会永久冒充当前推荐。
        contextSuggestions = []
        contextAnswer = nil
        contextAnswerError = nil
        didAutoCopyContextAnswer = false
        contextAnswerDelivery = nil
        isStreamingContextAnswer = false
        isContextAnswerIncomplete = false
        clearContextReasoning()

        // 同一份内容、同一个来源、同一份库、同一个路由不再问模型。但**再复制
        // 一次同一句话是"再给我看一遍"**，不是让它静默——直接复用上次的结论
        // 立刻重放，既不烧 token 也不会出现"刚才有、这次没反应"。
        if let cached = contextResolutionCache[key] {
            ContextTrace.log("命中上次结论，直接重放")
            // 缓存只省控制器调用，回答仍会重新基于本轮证据生成。旧代码忘了恢复
            // resolving 状态，第二次按快捷键要等十几秒却完全没有动画，用户只能继续
            // 重按；每次重按又取消前一轮，于是看起来像“第二次永远触发不了”。
            isResolvingContext = true
            contextTask = Task { [weak self] in
                guard let self else { return }
                await self.publishContextResolution(
                    cached,
                    generation: generation,
                    sourceItemID: sourceItemID
                )
            }
            return
        }

        isResolvingContext = true
        let snapshot = items
        contextTask = Task { [weak self] in
            guard let self else { return }
            let resolution = await action(event, snapshot, sourceItemID, isExplicitTrigger)
            guard !Task.isCancelled, generation == self.contextGeneration else { return }
            // 只有真的得出结论（是检索诉求 / 给出了推荐）才值得记住。一次都没跑通
            // 就写进缓存，等于这句话再也不会有第二次机会。
            if resolution.isRetrievalQuery || !resolution.suggestions.isEmpty
                || resolution.answerRequest != nil {
                self.rememberContextResolution(resolution, for: key)
            }
            await self.publishContextResolution(
                resolution,
                generation: generation,
                sourceItemID: sourceItemID
            )
        }
    }

    /// 把一次结论落到界面和剪贴板上。新鲜结果与缓存重放走同一条路径，
    /// 所以"第二次复制"和"第一次复制"的行为完全一致。
    private func publishContextResolution(
        _ resolution: ContextResolution,
        generation: Int,
        sourceItemID: UUID?
    ) async {
        // 一句"帮我发下那篇论文"只是用来检索的，不是要收藏的内容。
        // 让它留在剪贴板轨道里会把真正想存的东西挤掉，也脏了库。
        if resolution.isRetrievalQuery, let sourceItemID {
            await discardCapturedQuery(sourceItemID)
        }
        guard !Task.isCancelled, generation == contextGeneration else { return }

        var suggestions = resolution.suggestions
        if let question = resolution.answerRequest,
           !resolution.answerEvidenceItemIDs.isEmpty {
            // 回答与文件推荐是互斥输出；证据 Pin 永远不投影为可点击文件行。
            contextSuggestions = []
            let route = AnswerDeliveryPolicy.route(
                prefersFocusedInput: prefersAnswerInFocusedInputAction?() ?? true,
                focus: pendingAnswerInsertionWasCurrentSelection
                    ? pendingAnswerInsertion?.snapshot : nil
            )
            ContextTrace.log(
                "快捷回答交付路线=\(route) 目标=\(pendingAnswerInsertion?.diagnosticKind ?? "none") "
                + "选区已验证=\(pendingAnswerInsertionWasCurrentSelection)"
            )
            if route == .focusedInput,
               let target = pendingAnswerInsertion,
               let streamAction = contextAnswerStreamAction {
                await streamAnswerIntoFocusedInput(
                    question: question,
                    itemIDs: resolution.answerEvidenceItemIDs,
                    target: target,
                    stream: streamAction,
                    generation: generation
                )
                if generation == contextGeneration {
                    pendingAnswerInsertion = nil
                    pendingAnswerInsertionWasCurrentSelection = false
                }
                return
            }
            // 与唯一文件自动交付一致：生成成功后直接准备到剪贴板。`Clipboard.write`
            // 会登记所有 Mnemo 自写 changeCount，不会把回答重新收进最近五条。
            // generation 在每个 await 之后都要复查，旧回答绝不能覆盖新一轮结果。
            await deliverAnswerToClipboard(
                question: question,
                itemIDs: resolution.answerEvidenceItemIDs,
                generation: generation
            )
            if generation == contextGeneration {
                pendingAnswerInsertion = nil
                pendingAnswerInsertionWasCurrentSelection = false
            }
            // 回答由用户显式触发，不应 12 秒一到就从眼前消失；关闭按钮仍可清掉。
            return
        }

        let requestedAutoCopy = resolution.autoCopyText != nil || resolution.autoCopyItemID != nil
        var autoCopySucceeded = false
        if let text = resolution.autoCopyText {
            autoCopySucceeded = Clipboard.write(text)
            if !autoCopySucceeded { lastError = "写入系统剪贴板失败" }
        } else if let id = resolution.autoCopyItemID,
                  let target = items.first(where: { $0.id == id }) {
            autoCopySucceeded = await writeItemToClipboard(
                target,
                showsFeedback: false,
                shouldWrite: { [weak self] in
                    guard let self else { return false }
                    return generation == self.contextGeneration
                }
            )
        }
        guard !Task.isCancelled, generation == contextGeneration else { return }
        // `didAutoCopy` 描述已经发生的事实，而不是准备执行的意图。文件 URL
        // 解析或系统粘贴板写入失败时保留普通推荐按钮，绝不提前显示对号。
        if requestedAutoCopy, !autoCopySucceeded {
            suggestions = suggestions.map { suggestion in
                var suggestion = suggestion
                suggestion.didAutoCopy = false
                return suggestion
            }
        }

        isResolvingContext = false
        contextTask = nil
        // 空结果也要原子发布；新一代无推荐就是清空，不能保留旧卡片。
        contextSuggestions = suggestions
        guard !suggestions.isEmpty else { return }
        scheduleContextDismiss()
    }

    /// 边生成边写进前台输入框。
    ///
    /// 这条路径存在的唯一理由是等待感：证据读完之后，用户还要等整段回答生成完
    /// 才看到东西。逐段写进光标处，第一句话到达就能读。
    ///
    /// 任何一步不成立都不硬来：焦点已经不在原来那个控件上（用户切走了）就退回
    /// 剪贴板；写之前先把选区折叠到末尾，绝不覆盖用户刚打的问题；第一段没写进去
    /// 就当作从来没走过这条路。模型截断、网络失败或新一轮接管时，只在光标仍
    /// 完全匹配的前提下撤回本轮半成品；用户动过光标就停手，绝不猜着删除。
    /// 流式回答的生产者与打字机消费者之间的缓冲。
    @MainActor
    private final class AnswerStreamBuffer {
        /// 还没打出去的字。
        var pending = ""
        /// 完整回答，用于卡片与剪贴板降级。
        var answer = ""
        var finished = false
        var failure: (any Error)?
    }

    /// 键盘事件路径用于微信等聊天输入框。任何 CR/LF 都压成普通空格，
    /// 防止聊天应用把换行键解释成发送；卡片里的回答仍保留原始排版。
    private static func chatSafeInsertionText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "  ")
            .replacingOccurrences(of: "\n", with: "  ")
            .replacingOccurrences(of: "\r", with: "  ")
    }

    private func streamAnswerIntoFocusedInput(
        question: String,
        itemIDs: [UUID],
        target: FocusedInputTarget,
        stream: (String, [UUID], [Item]) -> AsyncThrowingStream<AIStreamChunk, any Error>,
        generation: Int
    ) async {
        guard var insertionSession = await target.prepareForInsertion() else {
            ContextTrace.log(
                "快捷回答改走剪贴板：目标(\(target.diagnosticKind))在写入前不成立，"
                + "前台=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")"
            )
            await deliverAnswerToClipboard(
                question: question,
                itemIDs: itemIDs,
                generation: generation
            )
            return
        }
        var insertedCharacters = 0
        var isInserting = true

        isStreamingContextAnswer = true
        contextAnswerDelivery = .focusedInput
        didAutoCopyContextAnswer = false
        isContextAnswerIncomplete = false

        func write(_ text: String) {
            guard isInserting else { return }
            switch insertionSession.insert(text) {
            case .inserted:
                insertedCharacters = insertionSession.insertedCharacterCount
            case .insertedButCannotContinue:
                // 文字已经落地，只是光标没能跟上；真实计数必须保留。
                insertedCharacters = insertionSession.insertedCharacterCount
                isInserting = false
            case .failedBeforeInsertion:
                isInserting = false
                // 一个字都没落地：别让卡片继续说"正在写进输入框"。
                if insertedCharacters == 0 { contextAnswerDelivery = nil }
            }
        }

        // 生产者只管把增量塞进缓冲；出字节奏完全交给下面的打字机循环，
        // 否则模型"一句一坨"地到达，写进输入框就是一坨一坨往外蹦。
        let buffer = AnswerStreamBuffer()
        let usesKeyboard = insertionSession.usesKeyboardEvents
        let deltas = stream(question, itemIDs, items)
        let producer = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                for try await chunk in deltas {
                    guard !Task.isCancelled, generation == self.contextGeneration else { break }
                    // 思考过程只上卡片，绝不进输入框：写进去的字撤不回来。
                    guard case .text(let delta) = chunk else {
                        if case .reasoning(let value) = chunk {
                            self.appendContextReasoning(value, generation: generation)
                        }
                        continue
                    }
                    buffer.answer += delta
                    buffer.pending += usesKeyboard ? Self.chatSafeInsertionText(delta) : delta
                    // 正在往输入框里打字时不碰卡片：答案已经在用户眼前了，
                    // 再展开刘海显示一遍纯属多余。只有写不进去才需要卡片兜底。
                    if self.isResolvingContext { self.isResolvingContext = false }
                }
            } catch {
                buffer.failure = error
            }
            buffer.finished = true
        }

        while !buffer.finished || !buffer.pending.isEmpty {
            guard !Task.isCancelled, generation == contextGeneration else {
                producer.cancel()
                _ = insertionSession.rollback()
                isStreamingContextAnswer = false
                return
            }
            let count = AnswerTypewriter.charactersToEmit(backlog: buffer.pending.count)
            if count > 0 {
                let piece = String(buffer.pending.prefix(count))
                buffer.pending.removeFirst(piece.count)
                write(piece)
            }
            // 写不进去了才把内容摆到卡片上，让用户还能拿到答案。
            if !isInserting { contextAnswer = buffer.answer }
            try? await Task.sleep(for: .seconds(AnswerTypewriter.tickInterval))
        }
        producer.cancel()

        let answer = buffer.answer
        let failure = buffer.failure

        guard !Task.isCancelled, generation == contextGeneration else {
            _ = insertionSession.rollback()
            return
        }
        isResolvingContext = false
        isStreamingContextAnswer = false
        contextTask = nil

        guard !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            contextAnswer = nil
            contextAnswerDelivery = nil
            contextAnswerError = if let failure {
                "回答生成失败：\(failure.localizedDescription)"
            } else {
                "没有生成完整答案，请检查模型配置后重试"
            }
            return
        }
        isContextAnswerIncomplete = failure != nil

        guard !isInserting else {
            // 全程写进去了：正常结束不碰剪贴板，用户的复制内容原样留着。
            guard let failure else {
                // 答案已经在输入框里，刘海不必再展开显示一遍：直接收干净。
                contextAnswer = nil
                contextAnswerError = nil
                contextAnswerDelivery = nil
                competingNotchContentDidEnd()
                return
            }
            contextAnswer = answer
            // 模型截断 / 网络中断不能把半句冒充成完成。用户没有碰过光标时，
            // 安全撤回 Mnemo 自己这一轮插入的字；若用户已经动过，则绝不猜着删。
            let rolledBack = insertionSession.rollback()
            contextAnswerDelivery = nil
            didAutoCopyContextAnswer = false
            if rolledBack { contextAnswer = nil }
            contextAnswerError = rolledBack
                ? "回答未完成，已撤回输入框中的半成品：\(failure.localizedDescription)"
                : "回答未完成，输入框中保留已写部分：\(failure.localizedDescription)"
            return
        }
        // 焦点 / 光标改变后不再碰那个控件。只有流正常结束，当前累积文本才是
        // 完整回答、可以安全降级到剪贴板；截断或网络失败绝不能给它贴“完整”标签。
        if let failure {
            didAutoCopyContextAnswer = false
            contextAnswerDelivery = nil
            contextAnswerError = insertedCharacters > 0
                ? "回答未完成，输入框中保留已写部分：\(failure.localizedDescription)"
                : "回答未完成：\(failure.localizedDescription)"
            return
        }
        didAutoCopyContextAnswer = Clipboard.write(answer)
        contextAnswerDelivery = didAutoCopyContextAnswer ? .clipboard : nil
        switch AnswerDeliveryPolicy.recovery(insertedCharacters: insertedCharacters) {
        case .switchToClipboard:
            contextAnswerError = didAutoCopyContextAnswer
                ? nil
                : "写入系统剪贴板失败，可再次点击复制"
        case .finishInClipboard:
            contextAnswerError = didAutoCopyContextAnswer
                ? "只写进一部分，完整回答已进剪贴板"
                : "只写进一部分，可点击复制取完整回答"
        }
    }

    /// 输入框这条路走不通时的落点：整段生成完再进剪贴板，行为与从前一致。
    private func deliverAnswerToClipboard(
        question: String,
        itemIDs: [UUID],
        generation: Int
    ) async {
        guard let answerAction = contextAnswerAction else {
            isResolvingContext = false
            contextAnswerError = "快捷回答未启用"
            return
        }
        let answer = await answerAction(question, itemIDs, items)
        guard !Task.isCancelled, generation == contextGeneration else { return }
        isResolvingContext = false
        contextTask = nil
        if let delivery = RecommendationAutoCopyPolicy.answerDelivery(
            answer: answer,
            write: Clipboard.write
        ) {
            contextAnswer = delivery.answer
            didAutoCopyContextAnswer = delivery.didWrite
            isContextAnswerIncomplete = false
            contextAnswerDelivery = delivery.didWrite ? .clipboard : nil
            contextAnswerError = delivery.errorMessage
        } else {
            contextAnswer = nil
            didAutoCopyContextAnswer = false
            isContextAnswerIncomplete = false
            contextAnswerDelivery = nil
            contextAnswerError = "没有生成完整答案，请检查模型配置后重试"
        }
    }

    /// 结论缓存有上限：一次会话里每复制一样新东西都会产生一个键，
    /// 无上限地留着就是一条只增不减的内存曲线。
    private func rememberContextResolution(
        _ resolution: ContextResolution,
        for key: ContextualProcessingKey
    ) {
        if contextResolutionCache[key] == nil { contextResolutionOrder.append(key) }
        contextResolutionCache[key] = resolution
        while contextResolutionOrder.count > Self.contextResolutionCacheLimit {
            contextResolutionCache.removeValue(forKey: contextResolutionOrder.removeFirst())
        }
    }

    /// 去重版本覆盖真实可检索内容，而不是只看条目数量。条目数量相同但 OCR、
    /// 标题、标签或文件内容更新后，同一句请求必须重新检索。
    private static func contextLibraryVersion(_ items: [Item]) -> String {
        let canonical = items.sorted { $0.id.uuidString < $1.id.uuidString }.map { item in
            [
                item.id.uuidString,
                item.modifiedAt.timeIntervalSinceReferenceDate.description,
                item.contentHash ?? "",
                item.embeddingModelID ?? "",
                item.indexedAt?.timeIntervalSinceReferenceDate.description ?? "",
                item.title,
                item.kind.rawValue,
                item.group ?? "",
                item.tags.sorted().joined(separator: ","),
            ].joined(separator: "|")
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// 这次复制是不是纯粹的检索请求：本地已经能判定，就不该进最近五条。
    /// 只有上下文管线真的会跑（AI 已解锁且已接线）时才跳过入库，否则内容会
    /// 既不被检索也不被保存。
    private func isRetrievalOnlyClipboardQuery(_ text: String) -> Bool {
        guard clipboardContextAction != nil, isFeatureUnlocked(.ai) else { return false }
        return ContextIntentParser.shouldSuppressPassiveCapture(
            ClipboardContextEvent(fingerprint: "", kind: .text, text: text)
        )
    }

    private static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 这段文本是不是一条指向真实文件的路径。
    private static func isExistingFilePath(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), !trimmed.contains("\n"), trimmed.count < 4_096 else {
            return false
        }
        return FileManager.default.fileExists(atPath: trimmed)
    }

    /// 剪贴板场景识别的诊断日志。
    ///
    /// 这条链上有五道闸门（粗筛 / 意图 / 去重 / 模型路由 / 候选与置信度），
    /// 全部静默返回。不打日志就只能靠猜是卡在哪一道。频率很低——只在剪贴板
    /// 变化时才会走到，而且只记结论，不记内容本身。
    enum ContextTrace {
        // 这条链上的每一道闸门都是静默返回，NSLog 在打包后的应用里又基本看不到，
        // 出问题时等于没有诊断。和投放诊断写进同一份文件，只记结论不记内容。
        @MainActor
        static func log(_ message: String) {
            NSLog("[MnemoContext] %@", message)
            DropTrace.log("上下文 " + message)
        }
    }

    /// 判断这次复制是不是"用来找东西的"，是就别留进剪贴板轨道。
    ///
    /// 本地能判定就不问模型；判不出但形态像一句短话时才花一次调用——说法无穷
    /// 无尽，词表永远追不上。判不出、调用失败或没配模型一律保留：多留一条只是
    /// 占个格子，删错了是用户真想存的东西没了。
    func classifyCopiedTextIfNeeded(text: String, itemID: UUID) {
        guard let classify = queryClassifierAction, isFeatureUnlocked(.ai) else { return }
        let event = ClipboardContextEvent(fingerprint: "", kind: .text, text: text)
        guard ContextIntentParser.looksLikeShortPhrase(event) else { return }

        let key = Self.digest(text)
        guard classifiedQueries.insert(key).inserted else { return }
        queryClassifyTask?.cancel()
        queryClassifyTask = Task { [weak self] in
            guard let self else { return }
            let isQuery = await classify(text)
            guard !Task.isCancelled else {
                self.classifiedQueries.remove(key)
                return
            }
            ContextTrace.log("复制内容判定 isQuery=\(isQuery)")
            guard isQuery else { return }
            await self.discardCapturedQuery(itemID)
        }
    }

    /// 把"只是用来检索的那次复制"从库里去掉。它从来没打算被收藏。
    private func discardCapturedQuery(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }),
              item.origin == .clipboard, !item.isPinned else { return }
        cancelQueuedAI(for: id)
        try? await library.trash(id: id)
        await reload()
    }

    func acceptContextSuggestion(_ suggestion: ContextSuggestion) {
        guard let item = items.first(where: { $0.id == suggestion.itemID }) else {
            lastError = "这条推荐指向的内容已不在库里"
            return
        }
        let generation = contextGeneration
        contextSuggestions = contextSuggestions.map { current in
            guard current.itemID == suggestion.itemID else { return current }
            var pending = current
            pending.isCopying = true
            pending.copyError = nil
            return pending
        }
        Task { [weak self] in
            guard let self else { return }
            let wrote = await self.writeItemToClipboard(item, showsFeedback: false)
            guard generation == self.contextGeneration else { return }
            self.contextSuggestions = self.contextSuggestions.map { current in
                guard current.itemID == suggestion.itemID else { return current }
                var finished = current
                finished.isCopying = false
                if wrote {
                    finished.didAutoCopy = true
                } else {
                    finished.copyError = self.lastError ?? "复制失败"
                }
                return finished
            }
            if wrote { self.scheduleContextDismiss(after: 1.6) }
        }
    }

    func copyContextAnswer() {
        guard let answer = RecommendationAutoCopyPolicy.completedAnswer(contextAnswer) else { return }
        if Clipboard.write(answer) {
            didAutoCopyContextAnswer = true
            contextAnswerDelivery = .clipboard
            contextAnswerError = isContextAnswerIncomplete
                ? "当前已生成内容已复制，回答仍未完成"
                : nil
            showTransientFeedback(isContextAnswerIncomplete ? "当前内容已复制" : "回答已复制")
        } else {
            didAutoCopyContextAnswer = false
            contextAnswerError = isContextAnswerIncomplete
                ? "回答未完成，当前内容复制失败，可再次点击复制"
                : "写入系统剪贴板失败，可再次点击复制"
        }
    }

    func dismissContextSuggestion() {
        pendingAnswerInsertion = nil
        pendingAnswerInsertionWasCurrentSelection = false
        contextAnswerDelivery = nil
        isStreamingContextAnswer = false
        isContextAnswerIncomplete = false
        contextDismissTask?.cancel()
        contextDismissTask = nil
        contextTask?.cancel()
        contextTask = nil
        contextGeneration &+= 1
        isResolvingContext = false
        contextSuggestions = []
        contextAnswer = nil
        contextAnswerError = nil
        didAutoCopyContextAnswer = false
        clearContextReasoning()
        competingNotchContentDidEnd()
    }

    private func scheduleContextDismiss(after seconds: Double = 12) {
        contextDismissTask?.cancel()
        contextDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.contextSuggestions = []
            self?.contextAnswer = nil
            self?.contextAnswerError = nil
            self?.didAutoCopyContextAnswer = false
            self?.contextAnswerDelivery = nil
            self?.isContextAnswerIncomplete = false
            self?.contextDismissTask = nil
            self?.competingNotchContentDidEnd()
        }
    }

    // MARK: - Focus timer

    static let minFocusDurationMinutes = 5
    static let maxFocusDurationMinutes = 120

    /// 表盘滚轮/拖动调时长。计时中不允许改，避免和正在跑的结束时刻打架。
    func nudgeFocusDuration(by steps: Int) {
        guard focusTimer.phase == .idle, steps != 0 else { return }
        focusDurationMinutes = min(
            Self.maxFocusDurationMinutes,
            max(Self.minFocusDurationMinutes, focusDurationMinutes + steps)
        )
    }

    func startFocus() {
        focusTimer.start(duration: TimeInterval(focusDurationMinutes * 60))
        refreshFocusTimer()
    }

    func toggleFocusPause() {
        switch focusTimer.phase {
        case .idle: startFocus()
        case .running: focusTimer.pause()
        case .paused: focusTimer.resume()
        }
        refreshFocusTimer()
    }

    func cancelFocus() {
        focusTimer.cancel()
        timerRemaining = nil
    }

    func refreshFocusTimer(now: Date = .now) {
        let startedAt = focusTimer.startedAt
        let plannedDuration = focusTimer.duration
        if focusTimer.settle(now: now) {
            timerRemaining = nil
            feedbackMessage = "专注完成"
            showEdgeStatus(.focusCompleted)
            if let startedAt {
                let session = FocusSession(
                    startedAt: startedAt,
                    completedAt: now,
                    plannedDuration: plannedDuration
                )
                Task { [weak self] in
                    guard let self else { return }
                    do {
                        try await library.recordFocusSession(session)
                        focusSessions.insert(session, at: 0)
                        focusHeatmap = FocusHistory.summaries(sessions: focusSessions, days: 91)
                    } catch {
                        lastError = "保存专注记录失败：\(error.localizedDescription)"
                    }
                }
            }
            return
        }
        timerRemaining = focusTimer.remaining(at: now)
    }

    // MARK: - Ingest and persistence

    func reload() async {
        // 拖拽进行中不改写 items。索引完成、链接元数据、待办扫描都会触发
        // reload；让它们落进松手后的那一次。
        guard outboundDrag == nil else {
            reloadDeferredDuringDrag = true
            return
        }
        await drainReorderPersistence()
        do {
            items = try await library.items()
            trashedItems = try await library.items(includingTrashed: true)
                .filter { $0.state == .trashed }
            // 隐私条目删掉之后仍然是隐私的：锁着的时候回收站里也不能出现，
            // 否则"删除"成了绕过锁的捷径。
            if !isPrivateSpaceUnlocked { trashedItems.removeAll(where: \.isPrivate) }
            let retainedSceneIDs = Set(items.map(\.id)).union(trashedItems.map(\.id))
            let oldSceneCount = sceneRecommendationCache.count
            sceneRecommendationCache = sceneRecommendationCache.filter { retainedSceneIDs.contains($0.key) }
            if sceneRecommendationCache.count != oldSceneCount { persistSceneRecommendationCache() }
            todos = try await library.todos()
            todoItems = Self.sortedTodos(todos)
            // 提醒重排放在这里，而不是散在每个改待办的地方。
            //
            // 之前是各路径各自调用，于是三条路都漏了：改截止时间不重排（提醒
            // 还按旧时间响，或者干脆不响）、勾完成不重排（做完的事继续提醒）、
            // 删待办也不重排（一条已经不存在的待办到点了还弹）。这类"哪条路
            // 忘了叫一声"的 bug 在这个项目里已经出现过好几回，唯一治得住的
            // 办法是让它不依赖调用方的记性。
            //
            // 只在真的变了的时候重排：reload 每次收纳内容都会跑，无脑重排会
            // 把系统通知反复清空重建。指纹覆盖排期依赖的全部字段。
            refreshDocumentTitles()
            let fingerprint = Self.reminderFingerprint(todos)
            if fingerprint != lastReminderFingerprint {
                lastReminderFingerprint = fingerprint
                rescheduleReminders()
            }
            focusSessions = try await library.focusSessions(
                since: Calendar.current.date(byAdding: .day, value: -100, to: .now)
            )
            focusHeatmap = FocusHistory.summaries(sessions: focusSessions, days: 91)
            let usage = await library.storageUsage()
            activeStorageBytes = usage.active
            trashStorageBytes = usage.trashed
            if let id = detailItem?.id {
                detailItem = items.first { $0.id == id }
            }
            if !tabs.contains(activeTab) { activeTab = .all }
            // 回收站里的条目不算删除——它随时可能被还原，溯源要跟着一起留。
            let survivingItemIDs = Set(items.map(\.id)).union(trashedItems.map(\.id))
            NearbyDeviceOrigin.prune(keeping: survivingItemIDs)
            LinkSourceBrowserStore.prune(keeping: survivingItemIDs)
            linkCoverGenerations = linkCoverGenerations.filter {
                survivingItemIDs.contains($0.key)
            }
            if CardGroupStore.prune(keeping: survivingItemIDs) {
                cardGroupGeneration &+= 1
                cardGroupIndexCache = nil
            }
            if PinnedLaneStore.prune(keeping: survivingItemIDs) {
                pinnedLaneGeneration &+= 1
            }
            let survivingTodoIDs = Set(todos.map(\.id))
            TodoProvenanceStore.prune(
                todoIDs: survivingTodoIDs,
                itemIDs: survivingItemIDs
            )
            TodoPresentationStore.prune(
                todoIDs: survivingTodoIDs,
                itemIDs: survivingItemIDs
            )
            backfillLinkCovers()
            // 抽取器变好之后，把当年抽空了的链接补抓一遍。只跑一次。
            Task { await backfillFailedLinkExtractions() }
        } catch {
            lastError = "读取失败：\(error.localizedDescription)"
        }
    }

    func restoreFromTrash(_ id: UUID) async {
        do {
            try await library.restore(id: id)
            await reload()
            showTransientFeedback("已恢复 Pin")
        } catch {
            lastError = "恢复失败：\(error.localizedDescription)"
        }
    }

    func emptyTrash() async {
        do {
            let result = try await library.emptyTrash()
            await reload()
            if let failure = result.failures.first {
                lastError = failure.description
            } else {
                showTransientFeedback("已清理 \(result.purged) 个 Pin")
            }
        } catch {
            lastError = "清空回收站失败：\(error.localizedDescription)"
        }
    }

    func exportLibraryArchive() async {
        guard !isProcessingArchive else { return }
        let panel = NSSavePanel()
        panel.title = "导出 Mnemo 整库备份"
        panel.prompt = "导出"
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "Mnemo-\(Date.now.formatted(.iso8601.year().month().day())).pinlandarchive"
        panel.allowedContentTypes = [UTType(filenameExtension: "pinlandarchive") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isProcessingArchive = true
        defer { isProcessingArchive = false }
        do {
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "development"
            try await LibraryArchiveManager.shared.export(
                library: library,
                to: url,
                appVersion: version
            )
            showTransientFeedback("整库备份已导出")
        } catch {
            lastError = "导出失败：\(error.localizedDescription)"
        }
    }

    func importLibraryArchive() async {
        guard !isProcessingArchive else { return }
        let panel = NSOpenPanel()
        panel.title = "导入 Mnemo 整库备份"
        panel.prompt = "导入"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "pinlandarchive") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        isProcessingArchive = true
        defer { isProcessingArchive = false }
        do {
            let result = try await LibraryArchiveManager.shared.import(library: library, from: url)
            await reload()
            let imported = Set(result.importedItemIDs)
            for item in items where imported.contains(item.id) && item.state == .active {
                // 归档保留标题与组织信息，只重建未随设备迁移的本地向量。
                enqueueIndex(item.id)
            }
            showTransientFeedback("已导入 \(result.importedItemIDs.count) 个 Pin")
        } catch {
            lastError = "导入失败：\(error.localizedDescription)"
        }
    }

    func startupMaintenance() async {
        await cleanupAbandonedImportFiles()
        do {
            let reconciliation = try await library.reconcileVault()
            if let missing = reconciliation.missingCopies.first {
                lastError = "有受管副本缺失：\(missing.prefix(8))"
            }
            // 条目彻底删掉了、分块还留着的话，被删的内容会继续出现在检索
            // 结果里。正常路径不产生孤儿，这里是兜底的不变量检查。
            let orphans = try await library.purgeOrphanChunks()
            if orphans > 0 { ContextTrace.log("清掉 \(orphans) 条孤儿分块") }
            let result = try await library.purgeExpired()
            if !result.failures.isEmpty { lastError = result.failures.first?.description }
            _ = try await library.trashMissingReferences()
        } catch {
            lastError = "清理失败：\(error.localizedDescription)"
        }
        await reload()
        seedPendingAIWork()
        resumeAIEnrichment()
        resumeIndexing()
        // 上次退出时还没理解成功的截图：OCR 已在库里，这里只补模型那一步。
        resumePendingTodoScans()
    }

    private func cleanupAbandonedImportFiles(now: Date = .now) async {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.temporaryDirectory
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in entries {
                let name = url.lastPathComponent
                // 改名前已经写进 vault 的文件还带着 pinland- 前缀，两种都要认。
                guard let prefix = ["mnemo-clipboard-", "pinland-clipboard-", "mnemo-", "pinland-"]
                    .first(where: { name.hasPrefix($0) })
                else { continue }
                let remainder = String(name.dropFirst(prefix.count))
                guard let dot = remainder.firstIndex(of: "."),
                      UUID(uuidString: String(remainder[..<dot])) != nil,
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let modified = values.contentModificationDate,
                      now.timeIntervalSince(modified) >= 3_600 else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }.value
    }

    private static func sortedTodos(_ values: [Todo]) -> [Todo] {
        values.sorted {
            if $0.isCompleted != $1.isCompleted { return !$0.isCompleted }
            if $0.dueAt != $1.dueAt {
                return ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture)
            }
            return $0.createdAt > $1.createdAt
        }
    }

    func refreshReferenceHealth() async {
        let trace = PerformanceTrace.begin("ReferenceAudit")
        defer { PerformanceTrace.end("ReferenceAudit", id: trace) }
        do {
            // 剪贴板只按条数淘汰：永远保留最近 N 条未固定的，不再按时间过期。
            // 时间过期会在用户没做任何事的情况下悄悄删掉还在 5 条以内的条目。
            let expiredClipboard = try await library.trimClipboardHistory(
                limit: 5,
                independentIDs: NearbyDeviceOrigin.itemIDs
            )
            let audit = try await library.auditReferences()
            if let detailID = detailItem?.id, audit.removed.contains(where: { $0.id == detailID }) {
                dismissDetailImmediately()
            }
            for item in audit.removed { cancelQueuedAI(for: item.id) }
            for item in audit.contentChanged {
                invalidateSceneRecommendationCache(for: item.id)
                scheduleAIWork(for: item)
            }
            for item in expiredClipboard { cancelQueuedAI(for: item.id) }
            guard !expiredClipboard.isEmpty || !audit.removed.isEmpty || !audit.contentChanged.isEmpty else {
                return
            }
            await reload()
            if !audit.removed.isEmpty {
                showTransientFeedback(audit.removed.count == 1
                    ? "原文件已删除，对应 Pin 已移除"
                    : "\(audit.removed.count) 个原文件已删除，对应 Pin 已移除")
            } else {
                showTransientFeedback(audit.contentChanged.count == 1
                    ? "原文件已更新，正在刷新索引"
                    : "\(audit.contentChanged.count) 个原文件已更新，正在刷新索引")
            }
        } catch {
            lastError = "检查文件引用失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func ingest(
        urls: [URL],
        preference: FileIngestPreference = .referenceFirst,
        sourcePath: String? = nil
    ) async -> IngestReport {
        var report = IngestReport()
        var knownIDs = Set(items.map(\.id))
        for url in urls {
            do {
                let item = try await library.ingest(
                    fileAt: url,
                    preference: preference,
                    sourcePath: sourcePath
                )
                if knownIDs.contains(item.id) {
                    report.reused += 1
                    // 显式拖入可能复用自动捕获的临时条目。Library 已把它提升为
                    // manual + pinned；即使没有新增 ID，也必须现在开始完整处理。
                    scheduleAIWork(for: item)
                } else {
                    report.inserted += 1
                    knownIDs.insert(item.id)
                    scheduleAIWork(for: item)
                }
            } catch let error as VaultError {
                report.failed += 1
                lastError = error.description
            } catch {
                report.failed += 1
                lastError = error.localizedDescription
            }
        }
        await reload()
        return report
    }

    @discardableResult
    func ingest(text: String) async -> IngestReport {
        var report = IngestReport()
        let knownIDs = Set(items.map(\.id))
        // 记来源要在 await 之前取：Mnemo 是 LSUIElement，不抢焦点，所以
        // 拖拽 / 复制的那一刻前台仍然是源应用；等入库完再问就可能已经变了。
        let sourceBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        do {
            let item = try await library.ingest(text: text)
            if LinkSourceBrowserStore.record(itemID: item.id, sourceBundleID: sourceBundleID) {
                // 同一条链接从另一个浏览器再次收纳，id 会复用，但它的"回哪个
                // 浏览器"已经变了。按 id 缓存不清就一直显示旧浏览器图标。
                linkBrowserCache[item.id] = nil
            }
            if knownIDs.contains(item.id) {
                report.reused = 1
                scheduleAIWork(for: item)
            } else {
                report.inserted = 1
                scheduleAIWork(for: item)
            }
        } catch {
            report.failed = 1
            lastError = error.localizedDescription
        }
        await reload()
        return report
    }

    func ingestClipboard() async {
        guard let payload = Clipboard.read() else {
            lastError = "剪贴板里没有可收纳的内容"
            return
        }
        await ingest(payload: payload)
    }

    /// 系统剪贴板监听写入临时轨道。默认只保存，不跑 OCR / AI / Embedding；
    /// 用户固定后才处理。设置开关开启时可恢复"自动捕获即处理"的旧行为。
    /// - Parameter changeCount: 触发这次捕获的 `NSPasteboard.changeCount`。
    ///   通用剪贴板的内容是异步到达的，读取要拿着这个号码等，
    ///   等待期间号码再变就说明用户又复制了别的，这一轮作废。
    func captureClipboardHistory(changeCount: Int? = nil) async {
        let arrival = await Clipboard.readAwaitingRemoteArrival(
            changeCount: changeCount ?? NSPasteboard.general.changeCount
        )
        guard let arrival else { return }
        let payload = arrival.payload
        let isRemote = arrival.isRemote
        do {
            var captured: [Item] = []
            switch payload {
            case .text(let text):
                // 复制一条文件路径不是"记一段文字"。它既没有阅读价值，又会把
                // 真正想留的东西挤出那五条剪贴板轨道。
                guard !Self.isExistingFilePath(text) else { return }
                // "给我发一张央视新闻报道牛来的图片"是一句查询，不是要收藏的内容。
                // 本地就能判定时**根本不入库**，而不是先记一条再异步删掉——后者
                // 会让请求文字在顶部闪现，也依赖删除那一步一定跑到。
                //
                // 但待办提取和"要不要入库"没有关系：一段文字可能因为被判成检索
                // 诉求而不入库，里面的取餐码却仍然值得变成一条待办。所以两条
                // 分支各自都要提取，只是不入库那一条没有可溯源的 Pin。
                if isRetrievalOnlyClipboardQuery(text) {
                    ContextTrace.log("本地判定为检索诉求，不入库")
                    // 手机同步过来的内容没有"等一个动作"可言；Mac 本机复制的
                    // 一律等固定，见下面那条分支的说明。
                    if isRemote { considerTodoDraft(in: text, fromNearbyDevice: true) }
                    return
                }
                let item = try await library.ingest(
                    text: text,
                    origin: .clipboard,
                    isPinned: false
                )
                captured.append(item)
                // **Mac 本机复制的文字不在这里理解**，和本机截图同一条规则：
                // 等用户固定之后才算"要留下的东西"。
                //
                // 之前这行是无条件的，等于每复制一段文字就发一次模型请求——
                // 而剪贴板上绝大多数内容和待办毫无关系。手机同步过来的例外：
                // 内容来自另一台设备，Mac 上根本没有动作可等。
                if isRemote {
                    considerTodoDraft(
                        in: text,
                        sourceItemID: item.id,
                        fromNearbyDevice: true
                    )
                }
                // 复制**不再触发推荐**——推荐由 ⌘G 主动发起。这里只判去留：
                // 有些应用一选中文字就自动写剪贴板，那些片段大多是"我在找什么"，
                // 留下来会把真正想存的挤出那五条。
                if processesTemporaryClipboard {
                    classifyCopiedTextIfNeeded(text: text, itemID: item.id)
                }
            case .files:
                // 复制一个文件通常只是"我要把它粘到别处"，不是"帮我记住它"。
                // 被动监听到的文件一律不入库；真想收下来有两条明确的路：
                // 拖进刘海，或者按 ⌘P / 菜单里的「收纳剪贴板」。
                // 剪贴板轨道因此只留截图与文字——那两类才是复制完就找不回的。
                ContextTrace.log("剪贴板文件不入库，等待主动拖入或显式收纳")
                return
            case .image(let data, let fileExtension):
                // 见下：手机来的图在入库后立刻识别，本机的等固定。
                let temporaryURL = FileManager.default.temporaryDirectory
                    .appending(path: "mnemo-clipboard-\(UUID().uuidString).\(fileExtension)")
                try data.write(to: temporaryURL, options: .atomic)
                defer { try? FileManager.default.removeItem(at: temporaryURL) }
                let imageItem = try await library.ingest(
                    fileAt: temporaryURL,
                    preference: .copyRequired,
                    origin: .clipboard,
                    isPinned: false
                )
                captured.append(imageItem)
                // 本机截图**不在这里**识别。
                //
                // 被动扫描每一张复制的图，等于用一个新功能推翻"临时轨道只保留、
                // 不处理"这个已经做出的选择，还给每次复制加一次全精度 OCR。
                // 本机的识别时机是用户按下固定的那一刻——那是明确的"我要留着它"，
                // 也正好是这条管线本来就会跑 OCR 的时候。见 `setClipboardPin`。
                //
                // 手机同步过来的走另一条路：见下面的 `isRemote` 分支。
            }
            // 按**最新一次捕获**归到手机或 Mac 轨道。Library 对重复内容会复用
            // 原条目，所以本机再次复制一段手机来过的文字时也必须清掉手机标记。
            //
            // 设备类型只从截图形态推断，且只影响角标画哪个图标——系统没有公开
            // 通用剪贴板的来源型号，编一个出来不如老实显示"其他苹果设备"。
            let deviceKind: NearbyDeviceKind = {
                guard isRemote, case .image(let data, _) = payload,
                      let image = NSImage(data: data) else { return .unknown }
                let pixels = image.representations.first.map {
                    CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
                } ?? image.size
                return NearbyDeviceKind.inferred(fromPixelSize: pixels)
            }()
            for item in captured {
                NearbyDeviceOrigin.setNearby(isRemote, kind: deviceKind, for: item.id)
            }
            let processNewCaptures = ClipboardContentProcessingPolicy
                .authorizesNewTemporaryCapture(isEnabled: processesTemporaryClipboard)
            // 手机内容是独立的“到达即识别”路径，但**复用同一条索引管线**：
            // Vision OCR、图片标签、可选视觉描述、Embedding 都只跑一次，随后 RAG
            // 与待办理解读取同一批分块。Mac 临时截图仍然等用户 Pin 后才处理。
            if processNewCaptures || isRemote {
                for item in captured {
                    authorizeTemporaryProcessing(item.id)
                    // 重复内容也可能是开关开启后的新捕获事件；此时从这一刻起授权。
                    // 手机来的图已经带上来源标记，`scheduleAIWork` 会据此排队。
                    scheduleAIWork(for: item)
                }
            }
            let evicted = try await library.trimClipboardHistory(
                limit: 5,
                independentIDs: NearbyDeviceOrigin.itemIDs
            )
            for item in evicted { cancelQueuedAI(for: item.id) }
            await reload()
            // 手机截图的待办理解不在这里另跑 OCR。`pendingTodoScanIDs` 会在既有
            // 索引完成时读取 `.imageOCR` 分块；这批分块同时供自然语言 RAG 使用。
        } catch {
            lastError = "剪贴板历史记录失败：\(error.localizedDescription)"
        }
    }

    func pinClipboardItem(_ id: UUID) async {
        await setClipboardPin(id, isPinned: true)
    }

    func toggleClipboardPin(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        await setClipboardPin(id, isPinned: !item.isPinned)
    }

    /// 卡片手动排序：本地立刻换位（动画才跟得上手感），持久化走后台。
    /// after=false 落在 anchor 前面，true 落在它后面。
    ///
    /// 持久化用的 before 目标是在**全量顺序**里算的——分类页签过滤掉谁，
    /// 都不该改变这次拖动的位置语义。
    /// 所有排序写盘共用一条串行链。普通卡与整组若各起独立 Task，会交错写入
    /// 同一组 sortOrder；屏幕上已经是新顺序，库里却可能最后落成旧顺序，下一次
    /// reload 就回弹。链在 MainActor 上同步接长，调用顺序就是用户操作顺序。
    @ObservationIgnored private var reorderPersistenceTask: Task<Void, Never>?
    /// 这条链接长过几次。`reload` 靠它判断排空期间有没有又来了新的换位。
    @ObservationIgnored private var reorderEnqueueCount = 0

    private func enqueueReorderPersistence(
        _ operation: @escaping @MainActor () async throws -> Void
    ) {
        let previous = reorderPersistenceTask
        reorderEnqueueCount &+= 1
        reorderPersistenceTask = Task { @MainActor [weak self] in
            _ = await previous?.result
            guard !Task.isCancelled else { return }
            do {
                try await operation()
            } catch {
                // 不在链内直接 await reload：reload 要排空这条链，而我们就是
                // 链本身，会自己等自己。另起一个任务，等这一环结束再读。
                Task { @MainActor [weak self] in await self?.reload() }
            }
        }
    }

    /// 等排序写盘全部落地。
    ///
    /// 库是顺序的唯一权威，但它得先追上内存：写盘还在链上排队时读库，读到的
    /// 是旧顺序，刚拖好的卡会当场弹回去。排空期间用户可能又拖了一次（链又
    /// 接长了），所以循环到不再增长为止。
    private func drainReorderPersistence() async {
        var seen = -1
        while reorderEnqueueCount != seen, let tail = reorderPersistenceTask {
            seen = reorderEnqueueCount
            _ = await tail.result
        }
    }

    func moveItem(_ id: UUID, anchor targetID: UUID, after: Bool) {
        guard let plan = reorderLocally(id, anchor: targetID, after: after) else { return }
        enqueueReorderPersistence { [library] in
            try await library.moveItem(plan.id, before: plan.beforeID)
        }
    }

    /// 本地换位，返回这一步要怎么持久化。
    ///
    /// 拆出来是为了让**整组移动**可以先把本地顺序一次排好、再串行落盘。
    /// 之前整组是"挪一张、发一次写盘"重复 N 遍：N 个 Task 并发跑，各自按
    /// 自己那一刻的邻居算落点，写进库里的顺序和屏幕上的对不上；下一次
    /// reload 一拉，整组又跳回去。用户看到的就是"先蹦出来一张卡，把它放回去
    /// 之后组才跟过来"。
    @discardableResult
    private func reorderLocally(
        _ id: UUID, anchor targetID: UUID, after: Bool
    ) -> (id: UUID, beforeID: UUID?)? {
        guard id != targetID,
              let from = items.firstIndex(where: { $0.id == id }),
              items.contains(where: { $0.id == targetID }) else { return nil }
        let item = items.remove(at: from)
        var anchorIndex = items.firstIndex(where: { $0.id == targetID })!
        if after { anchorIndex += 1 }
        items.insert(item, at: anchorIndex)
        let beforeID = anchorIndex + 1 < items.count ? items[anchorIndex + 1].id : nil
        return (id, beforeID)
    }

    private func setClipboardPin(_ id: UUID, isPinned: Bool) async {
        do {
            try await library.setClipboardPin(id: id, isPinned: isPinned)
            if isPinned, let promoted = try? await library.item(id: id) {
                // 固定就是用户确认"值得留下"：现在才运行 OCR / 图片理解 / Embedding，
                // 待办理解的排队也在 `scheduleAIWork` 里一并完成。
                scheduleAIWork(for: promoted)
            }
            if !isPinned {
                // 放回滚动轨道之后立刻按容量结算：否则它会以"临时"的身份多待
                // 一会儿，下一次复制时才被挤掉，看着像没生效。
                let evicted = try await library.trimClipboardHistory(
                    limit: 5,
                    independentIDs: NearbyDeviceOrigin.itemIDs
                )
                for item in evicted { cancelQueuedAI(for: item.id) }
            }
            await reload()
            showTransientFeedback(isPinned ? "已锁定保留" : "已放回临时轨道")
        } catch {
            lastError = "\(isPinned ? "固定" : "取消固定")失败：\(error.localizedDescription)"
        }
    }

    @discardableResult
    func ingest(payload: Clipboard.Payload) async -> IngestReport {
        switch payload {
        case .text(let text):
            return await ingest(text: text)
        case .files(let urls):
            return await ingest(urls: urls)
        case .image(let data, let fileExtension):
            let temporaryURL = FileManager.default.temporaryDirectory
                .appending(path: "mnemo-\(UUID().uuidString).\(fileExtension)")
            do {
                try data.write(to: temporaryURL, options: .atomic)
                let report = await ingest(urls: [temporaryURL], preference: .copyRequired)
                try? FileManager.default.removeItem(at: temporaryURL)
                return report
            } catch {
                lastError = "图片收纳失败：\(error.localizedDescription)"
                return IngestReport(failed: 1)
            }
        }
    }

    func trash(_ id: UUID) async {
        let title = items.first(where: { $0.id == id })?.title
        let groupSnapshot = cardGroup(of: id)
        do {
            try await library.trash(id: id)
            cancelQueuedAI(for: id)
            // 用户明确删除这张卡，就立即把它从分组摘掉。CardGroupStore.detach
            // 自带「剩一张自动解散」，不再等自动 prune 猜用户意图。
            if groupSnapshot != nil {
                CardGroupStore.detach(id)
                cardGroupGeneration &+= 1
                cardGroupIndexCache = nil
                clearStaleCardGroupSelection()
            }
            recentlyTrashedID = id
            recentlyTrashedTitle = title
            recentlyTrashedGroup = groupSnapshot
            feedbackMessage = nil
            scheduleUndoDismiss()
        } catch {
            lastError = error.localizedDescription
        }
        if detailItem?.id == id { dismissDetailImmediately() }
        await reload()
    }

    /// 撤销提示不能一直挂在那儿挡着卡片。给够看清和反应的时间就收掉，
    /// 条目仍在回收站里，随时能恢复。
    private func scheduleUndoDismiss() {
        undoDismissTask?.cancel()
        undoDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.recentlyTrashedID = nil
            self?.recentlyTrashedTitle = nil
            self?.recentlyTrashedGroup = nil
            self?.undoDismissTask = nil
        }
    }

    func undoLastTrash() async {
        undoDismissTask?.cancel()
        undoDismissTask = nil
        guard let id = recentlyTrashedID else { return }
        do {
            try await library.restore(id: id)
            let groupSnapshot = recentlyTrashedGroup
            recentlyTrashedID = nil
            recentlyTrashedTitle = nil
            recentlyTrashedGroup = nil
            await reload()
            if let groupSnapshot {
                CardGroupStore.restoreMembership(
                    id, from: groupSnapshot, keeping: Set(items.map(\.id))
                )
                cardGroupGeneration &+= 1
                cardGroupIndexCache = nil
                normalizeGroupMembers(groupSnapshot.id, around: id)
            }
            showTransientFeedback("已恢复 Pin")
        } catch {
            lastError = "恢复失败：\(error.localizedDescription)"
        }
    }

    func trashSelected() async {
        guard let id = detailItem?.id else { return }
        await trash(id)
    }

    /// 临时剪贴板条目默认不参与任何重处理。人工拖入 / 显式收纳都是
    /// origin=.manual；临时复制是 origin=.clipboard && !isPinned，来源边界清楚。
    private func shouldProcessContent(_ item: Item) -> Bool {
        // 隐私条目不参与任何内容处理：不建索引、不问模型、不抓封面、不提待办。
        // 移进来时已经把分块删了，这里保证不会有人再把它建回去。
        guard !item.isPrivate else { return false }
        return ClipboardContentProcessingPolicy.shouldProcess(
            origin: item.origin,
            isPinned: item.isPinned,
            wasAuthorizedAtCapture: processableTemporaryIDs.contains(item.id)
        )
    }

    private func authorizeTemporaryProcessing(_ id: UUID) {
        guard processableTemporaryIDs.insert(id).inserted else { return }
        persistTemporaryProcessingAuthorizations()
    }

    private func revokeTemporaryProcessing(_ id: UUID) {
        guard processableTemporaryIDs.remove(id) != nil else { return }
        persistTemporaryProcessingAuthorizations()
    }

    private func persistTemporaryProcessingAuthorizations() {
        UserDefaults.standard.set(
            processableTemporaryIDs.map(\.uuidString).sorted(),
            forKey: Self.processableTemporaryIDsKey
        )
    }

    private func scheduleAIWork(for item: Item) {
        guard shouldProcessContent(item) else { return }
        scheduleLinkMetadata(for: item)
        enqueueTodoScanIfNeeded(item)
        enqueueAI(item)
        enqueueIndex(item.id, item: item)
    }

    /// 这张图值不值得在索引完成后看一眼有没有待办。
    ///
    /// 只有一条判据：**用户是不是已经表达了"留下它"**。四条来路对应两种情况：
    ///
    /// | 来路 | isPinned | 自动识别 |
    /// | --- | --- | --- |
    /// | 拖进刘海 | true（Library 默认） | 是 |
    /// | ⌘P 主动收纳 | true（同一条 ingest） | 是 |
    /// | iPhone / iPad 同步 | false，但有设备标记 | 是 |
    /// | Mac 复制的临时截图 | false，无标记 | 否，等固定 |
    ///
    /// 前三种用户都已经做过一个明确动作（或内容根本来自另一台设备，Mac 上
    /// 没有动作可等）；只有本机随手复制的截图量大且多为过路内容，才留给固定。
    ///
    /// 这个判断以前散在"捕获"和"固定"两处，于是拖入和 ⌘P 收纳的截图
    /// **从来没有被理解过**——而拖入恰恰是比固定更强的保留意图。
    private func enqueueTodoScanIfNeeded(_ item: Item) {
        guard todoIntakeEnabled,
              TodoRecognitionPolicy.shouldRecognize(
                isPinned: item.isPinned,
                isFromNearbyDevice: NearbyDeviceOrigin.contains(item.id)
              ) else { return }
        switch item.kind {
        case .image:
            // 图片要等索引把 OCR 文字建好，排进名单由索引完成时回调。
            guard screenshotTodoScanEnabled else { return }
            pendingTodoScanIDs.insert(item.id)
        case .text:
            // 文字是内联的，没有"等 OCR"这一步，直接理解。
            // 固定一条剪贴板文字就是明确的"留下它"，和固定截图同一个语义。
            guard case .inline(let body) = item.holding else { return }
            considerTodoDraft(
                in: body,
                sourceItemID: item.id,
                fromNearbyDevice: NearbyDeviceOrigin.contains(item.id)
            )
        case .pdf, .link, .file, .binary:
            break
        }
    }

    private func scheduleLinkMetadata(
        for item: Item,
        forceRefresh: Bool = false,
        updateTitle: Bool = true
    ) {
        guard shouldProcessContent(item) else { return }
        // 标题只在还没定下来时补，封面则是"没有就补"——两件事的触发条件不同。
        // 原来共用 titledLocally 一个判据，导致标题一旦解析出来，封面就永远
        // 没机会再抓，已有的链接全是通用图标。
        let needsCover = forceRefresh || LinkCoverStore.cachedImage(for: item.id) == nil
        guard item.kind == .link,
              forceRefresh || item.titledLocally || needsCover,
              linkMetadataTasks[item.id] == nil,
              let url = item.linkURL else {
            return
        }
        linkMetadataTasks[item.id] = Task { [weak self] in
            let preview = await LinkCoverStore.fetch(for: url)
            guard !Task.isCancelled, let self else { return }
            defer { self.linkMetadataTasks[item.id] = nil }

            // 封面和标题各自独立：抓到哪个算哪个。
            var changed = false
            if let cover = preview.cover, LinkCoverStore.store(cover, for: item.id) {
                changed = true
            }
            var current = (try? await self.library.items())?.first(where: { $0.id == item.id })
            if updateTitle, let title = preview.title,
               current?.holding == item.holding, current?.titledLocally == true {
                current?.title = title
                if let current {
                    try? await self.library.update(current)
                    changed = true
                }
            }
            if changed {
                self.linkCoverGenerations[item.id, default: 0] &+= 1
                await self.reload()
            }
        }
    }

    /// 给还没有封面的链接补抓。一次最多几个，避免一打开就并发几十个请求。
    private func backfillLinkCovers() {
        var budget = 4
        for item in items where item.kind == .link && budget > 0 {
            guard shouldProcessContent(item),
                  LinkCoverStore.cachedImage(for: item.id) == nil,
                  linkMetadataTasks[item.id] == nil else { continue }
            budget -= 1
            scheduleLinkMetadata(for: item)
        }
    }

    private func enqueueAI(_ item: Item) {
        guard shouldProcessContent(item), needsAIEnrichment(item) else { return }
        if !pendingAIIDs.contains(item.id) {
            pendingAIIDs.append(item.id)
            persistAIQueue()
        }
        resumeAIEnrichment()
    }

    func resumeAIEnrichment() {
        refreshAISettlementIfRoutingChanged()
        guard aiQueueTask == nil, !pendingAIIDs.isEmpty, let action = aiEnrichmentAction else { return }
        aiQueueTask = Task { [weak self] in
            guard let self else { return }
            self.isAIProcessing = true
            var attempted: Set<UUID> = []
            defer {
                let shouldResume = Task.isCancelled && !self.pendingAIIDs.isEmpty
                self.isAIProcessing = false
                self.activeAIItemID = nil
                self.aiQueueTask = nil
                if shouldResume { self.resumeAIEnrichment() }
            }
            while !Task.isCancelled,
                  let id = self.pendingAIIDs.first(where: { !attempted.contains($0) }) {
                attempted.insert(id)
                guard let item = try? await self.library.item(id: id),
                      self.shouldProcessContent(item), self.needsAIEnrichment(item) else {
                    self.removePendingAI(id)
                    continue
                }
                // 图片/PDF/文件要先有本地索引（OCR、视觉标签、页块文本）再命名：
                // 没有提取文本时 prompt 只有"类型+文件名"，模型只能回一个通用标题。
                // 留在队列里，索引完成的钩子会重新唤起这轮处理。
                if [.image, .pdf, .file].contains(item.kind) {
                    let chunks = (try? await self.library.chunks(for: id)) ?? []
                    if chunks.isEmpty { continue }
                }
                self.activeAIItemID = id
                let trace = PerformanceTrace.begin("AIEnrichment")
                let enrichment = await action(item)
                PerformanceTrace.end("AIEnrichment", id: trace)
                guard !Task.isCancelled else { return }
                guard let enrichment,
                      var current = try? await self.library.item(id: id),
                      current.state == .active,
                      current.holding == item.holding else { continue }

                if enrichment.didGenerateTitle {
                    current.title = enrichment.title
                    current.titledLocally = false
                }
                if enrichment.didGenerateClassification {
                    current.group = enrichment.group
                    current.tags = enrichment.tags
                }
                current.aiPrivacyBlocked = enrichment.wasPrivacyBlocked
                do {
                    try await self.library.update(current)
                    // 模型这一轮真的回答了，就不再自动追问。分类没出结果多半是
                    // 那个功能压根没配路由，不是这次失败——再问一百次也是同样
                    // 的结果，只是每次都要付一次命名的钱。
                    self.markAISettled(id)
                    self.removePendingAI(id)
                    await self.reload()
                } catch {
                    self.lastError = "AI 整理结果写入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func seedPendingAIWork() {
        var changed = false
        let activeIDs = Set(items.map(\.id))
        let settled = aiSettledIDs.intersection(activeIDs)
        if settled != aiSettledIDs { aiSettledIDs = settled; persistAISettled() }
        let filtered = pendingAIIDs.filter { activeIDs.contains($0) }
        if filtered != pendingAIIDs { pendingAIIDs = filtered; changed = true }
        for item in items where shouldProcessContent(item)
            && needsAIEnrichment(item) && !pendingAIIDs.contains(item.id) {
            pendingAIIDs.append(item.id)
            changed = true
        }
        if changed { persistAIQueue() }
    }

    private func needsAIEnrichment(_ item: Item) -> Bool {
        guard item.state == .active,
              !item.aiPrivacyBlocked || item.allowsSensitiveAI,
              !aiSettledIDs.contains(item.id) else { return false }
        return item.titledLocally || (item.group == nil && item.tags.isEmpty)
    }

    private func cancelQueuedAI(for id: UUID) {
        revokeTemporaryProcessing(id)
        removePendingAI(id)
        if activeAIItemID == id { aiQueueTask?.cancel() }
        linkMetadataTasks[id]?.cancel()
        linkMetadataTasks[id] = nil
        LinkCoverStore.remove(id)
        removePendingIndex(id)
    }

    /// 路由变了就把"已问过"清空，让之前只完成一半的条目有机会补跑。
    ///
    /// 挂在指纹上而不是"任何设置变化"：设置页里改个图标也会走 persist，
    /// 那不该让整个库重跑一遍命名。
    private func refreshAISettlementIfRoutingChanged() {
        guard let fingerprint = aiRoutingFingerprintAction?() else { return }
        guard fingerprint != aiSettledFingerprint else { return }
        aiSettledFingerprint = fingerprint
        aiSettledIDs.removeAll()
        UserDefaults.standard.set(fingerprint, forKey: Self.aiSettledFingerprintKey)
        persistAISettled()
        seedPendingAIWork()
    }

    private func markAISettled(_ id: UUID) {
        guard aiSettledIDs.insert(id).inserted else { return }
        persistAISettled()
    }

    private func persistAISettled() {
        UserDefaults.standard.set(
            aiSettledIDs.map(\.uuidString),
            forKey: Self.aiSettledKey
        )
    }

    private func removePendingAI(_ id: UUID) {
        guard pendingAIIDs.contains(id) else { return }
        pendingAIIDs.removeAll { $0 == id }
        persistAIQueue()
    }

    private func persistAIQueue() {
        UserDefaults.standard.set(pendingAIIDs.map(\.uuidString), forKey: Self.aiQueueKey)
    }

    func resumeIndexing() {
        indexRetryTask?.cancel()
        indexRetryTask = nil
        // 没配 embedding 时条目会带着"未索引"出队，不再空转重跑 OCR 与
        // 视觉调用。等用户配好了，凭 indexedAt == nil 把它们重新捡回来。
        if pendingIndexIDs.isEmpty {
            for item in items where item.indexedAt == nil && shouldProcessContent(item) {
                pendingIndexIDs.append(item.id)
            }
            if !pendingIndexIDs.isEmpty { persistIndexQueue() }
        }
        guard indexQueueTask == nil, !pendingIndexIDs.isEmpty, contentIndexAction != nil else { return }
        indexQueueTask = Task { [weak self] in
            guard let self else { return }
            self.isIndexing = true
            var automaticRetryAfter: TimeInterval?
            defer {
                self.isIndexing = false
                self.indexQueueTask = nil
                if let automaticRetryAfter {
                    self.scheduleIndexRetry(suggestedDelay: automaticRetryAfter)
                } else {
                    self.indexRetryAttempt = 0
                }
            }
            var attempted: Set<UUID> = []
            while !Task.isCancelled,
                  let id = self.pendingIndexIDs.first(where: { !attempted.contains($0) }) {
                attempted.insert(id)
                guard let item = try? await self.library.item(id: id),
                      self.shouldProcessContent(item) else {
                    self.removePendingIndex(id)
                    continue
                }
                guard let action = self.contentIndexAction else { return }
                let forceRefreshLink = self.forcedLinkRefreshIDs.contains(id)
                let result = await action(item, forceRefreshLink)
                let isManualRefresh = self.manualLinkRefreshIDs.contains(id)
                if !result.completed && !result.waitingForEmbedding {
                    // 边缘警示灯是给**用户自己发起**的动作准备的（见拖入失败那处
                    // 注释：收起态看不到 toast，得在刘海本体上有反馈）。后台自动
                    // 补抓旧链接失败是常态——分享 token 过期、页面已删、站点限流，
                    // 用户什么都没做却每次启动被闪一次黄边，那是误报不是反馈。
                    if !forceRefreshLink || isManualRefresh {
                        self.showEdgeStatus(.indexingFailed)
                    }
                    if forceRefreshLink {
                        // 新版抓取失败，旧分块/向量仍原样保留。清掉本轮强制标记，
                        // 自动修复由下次启动按尝试次数再排；手动修复给出明确结果。
                        self.forcedLinkRefreshIDs.remove(id)
                        self.persistForcedLinkRefreshes()
                        self.removePendingIndex(id)
                        if self.knownInvalidLinkPageIDs.remove(id) != nil {
                            await self.discardKnownInvalidLinkPage(id)
                            self.persistKnownInvalidLinkPages()
                        }
                        if self.manualLinkRefreshIDs.remove(id) != nil {
                            self.showTransientFeedback("重新解析失败，已保留原检索内容")
                        }
                    }
                }
                if result.dimensionChanged {
                    let allItems = (try? await self.library.items()) ?? []
                    let allIDs = allItems.filter(self.shouldProcessContent).map(\.id)
                    for candidate in allIDs where !self.pendingIndexIDs.contains(candidate) {
                        self.pendingIndexIDs.append(candidate)
                    }
                    self.persistIndexQueue()
                }
                if result.completed && !result.waitingForEmbedding {
                    let wasForced = self.forcedLinkRefreshIDs.remove(id) != nil
                    let wasManual = self.manualLinkRefreshIDs.remove(id) != nil
                    self.persistForcedLinkRefreshes()
                    if self.knownInvalidLinkPageIDs.remove(id) != nil {
                        self.persistKnownInvalidLinkPages()
                    }
                    if wasManual {
                        // 用户自己按的重新解析：清零，让后续自动补抓仍有额度。
                        self.clearLinkReparseAttempt(id)
                    } else if wasForced {
                        // 自动补抓**成功**了——这一版解析器对这条链接的结果就是
                        // 这样。可"最长段落 < 120 字"这条启发式判的是"看着像没
                        // 抓到正文"，控制台页、定价页、视频页本来就没有长段落，
                        // 抓成功后依旧满足它。原来在这里清零计数，于是下次开机
                        // 同一批链接又被选中：绿点每次开机都转一圈，抓的全是已经
                        // 抓好的页面，"每条最多试三次"对成功的条目从未生效。
                        // 记满次数把它摘出候选，等 linkExtractionRevision 变了
                        // 整表清空时再统一重来。
                        self.saturateLinkReparseAttempt(id)
                    }
                    self.removePendingIndex(id)
                    if wasForced, let refreshed = try? await self.library.item(id: id) {
                        // 正文先成功，再抓封面。取消同 ID 可能还在排队的旧元数据
                        // 任务，确保 forceRefresh 真的执行；被取消任务在写文件前会
                        // 检查 Task.isCancelled，不会反过来覆盖新封面。
                        self.linkMetadataTasks[id]?.cancel()
                        self.linkMetadataTasks[id] = nil
                        self.scheduleLinkMetadata(
                            for: refreshed,
                            forceRefresh: true,
                            updateTitle: false
                        )
                    }
                    if wasManual {
                        self.showTransientFeedback("链接内容、标题和 RAG 已更新")
                    }
                }
                if let delay = result.autoRetryAfter {
                    automaticRetryAfter = min(automaticRetryAfter ?? delay, delay)
                }
                if result.completed {
                    // OCR/页块文本现在可用了：此前因缺索引被推迟的命名可以真正
                    // 跑出有意义的结果。留在队列里的条目会在这一轮被处理。
                    if let fresh = try? await self.library.item(id: id),
                       self.needsAIEnrichment(fresh) {
                        self.enqueueAI(fresh)
                    }
                    await self.considerTodoDraftFromIndexedImage(id)
                    await self.considerAutoGrouping(id)
                    await self.reload()
                }
            }
        }
    }

    /// 一张**被显式留下**的截图建好 OCR 之后，看看里面有没有待办。
    ///
    /// 名单由 `setClipboardPin` / 入库时的固定动作填，而不是靠"创建时间够新"
    /// 去猜。用时间猜有两头都不对的问题：重建索引会把全库的老图重新跑一遍，
    /// 那时候弹一串候选卡纯属骚扰；而固定一张昨天的截图又会因为超时被跳过，
    /// 正好是用户刚刚明确表示要留的那一张。
    private func considerTodoDraftFromIndexedImage(_ id: UUID) async {
        // 只判断"在不在名单里"，**不在这里划掉**。真正的结算发生在模型给出
        // 答复之后：过去在发请求前就 remove，一次网络失败这张截图就再也回不来了。
        guard pendingTodoScanIDs.contains(id), todoIntakeEnabled,
              screenshotTodoScanEnabled,
              let item = try? await library.item(id: id),
              item.kind == .image else { return }
        let chunks = (try? await library.chunks(for: id)) ?? []
        // 画面描述是模型写的散文，里面的数字不可当证据；只认 OCR 出来的原文。
        let text = chunks
            .filter { $0.source != .imageCaption }
            .sorted { $0.ordinal < $1.ordinal }
            .map(\.text)
            .joined(separator: "\n")
        guard !text.isEmpty else { return }
        considerTodoDraft(
            in: text,
            sourceItemID: id,
            fromNearbyDevice: NearbyDeviceOrigin.contains(id)
        )
    }


    private func scheduleIndexRetry(suggestedDelay: TimeInterval) {
        guard indexRetryTask == nil, !pendingIndexIDs.isEmpty else { return }
        let exponent = min(indexRetryAttempt, 7)
        let backoff = min(300, max(suggestedDelay, pow(2, Double(exponent + 1))))
        indexRetryAttempt += 1
        indexRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(backoff))
            guard !Task.isCancelled, let self else { return }
            self.indexRetryTask = nil
            self.resumeIndexing()
        }
    }

    // MARK: - 链接重新解析

    private static let linkReparseAttemptsKey = "Pinland.linkReparseAttempts.v1"
    private static let linkExtractionRevisionKey = "Pinland.linkExtractionRevision"
    /// 每次结构化抽取规则有实质升级就递增。升级后旧失败次数作废，所有用户的
    /// 老卡自动获得新规则的重试机会；不再靠开发机手工 `defaults delete`。
    private static let linkExtractionRevision = 4
    /// 同一条最多补抓几次。抓不到的链接确实存在（付费墙、已删除、纯视频），
    /// 不能每次开机都去骚扰人家；但也不能一次失败就永久放弃。
    private static let linkReparseMaxAttempts = 3
    /// 每次升级最多补 32 条；当前库规模能一次覆盖。网络和索引仍由全局单通道
    /// 串行执行，不会因为候选多就并发轰站点。
    private static let linkReparseBatch = 32

    /// 重新解析一条链接并原子替换 RAG。
    ///
    /// 旧正文、旧向量、旧封面都保留到新版完整成功。网络或 Embedding 失败时，
    /// 用户仍能搜到上一版；成功时由索引器一次事务替换分块 + 聚合向量 + 标题。
    func reparseLink(_ itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }), item.kind == .link else { return }
        Task { @MainActor in
            // 手动点击就是明确授权处理这条内容；临时剪贴板链接也不应被
            // shouldProcessContent 拒绝。
            authorizeTemporaryProcessing(itemID)

            // 先停住当前串行索引任务，避免同一条链接同时跑新旧两个版本。
            let running = indexQueueTask
            running?.cancel()
            _ = await running?.result
            indexQueueTask = nil
            indexRetryTask?.cancel()
            indexRetryTask = nil
            let metadataTask = linkMetadataTasks[itemID]
            metadataTask?.cancel()
            _ = await metadataTask?.result
            linkMetadataTasks[itemID] = nil

            // 标为强制刷新：索引器会忽略已存在的 linkPage，但不会删它；只有
            // 新正文和向量都成功后才原子替换。
            forcedLinkRefreshIDs.insert(itemID)
            manualLinkRefreshIDs.insert(itemID)
            persistForcedLinkRefreshes()
            pendingIndexIDs.removeAll { $0 == itemID }
            pendingIndexIDs.insert(itemID, at: 0)
            persistIndexQueue()

            // 手动重试不受自动补抓的三次上限影响。
            var attempts = (UserDefaults.standard.dictionary(forKey: Self.linkReparseAttemptsKey)
                as? [String: Int]) ?? [:]
            attempts[itemID.uuidString] = nil
            UserDefaults.standard.set(attempts, forKey: Self.linkReparseAttemptsKey)

            // 先更新正文/RAG；成功后再刷新封面，避免封面请求排在正文前面。
            resumeIndexing()
            showTransientFeedback("正在重新解析并原子更新检索内容")
        }
    }

    /// 把链接排进强制刷新队列。迁移/自动补抓不打断正在运行的索引；下一条会按
    /// 串行队列处理。同一 ID 去重，避免 reload 连续触发时重复请求。
    private func queueForcedLinkRefresh(_ itemID: UUID, prioritize: Bool = false) {
        forcedLinkRefreshIDs.insert(itemID)
        persistForcedLinkRefreshes()
        pendingIndexIDs.removeAll { $0 == itemID }
        if prioritize { pendingIndexIDs.insert(itemID, at: 0) }
        else { pendingIndexIDs.append(itemID) }
        persistIndexQueue()
    }

    /// 抽取失败时本地命名存下的占位标题。抓到真标题后这些该被换掉。
    static func isFailedExtractionTitle(_ title: String) -> Bool {
        LinkTextExtraction.isFailurePlaceholderTitle(title)
    }

    /// 只清掉网页正文那一类分块，用户备注、OCR 之类的不受影响。
    private func clearLinkPageContent(of item: Item) async {
        let keep = ((try? await library.chunks(for: item.id)) ?? [])
            .filter { $0.source != .linkPage }
        try? await library.replaceChunks(for: item.id, with: keep)
        var refreshed = item
        refreshed.indexedAt = nil
        try? await library.update(refreshed)
    }

    /// 把当年抽空了的链接补抓一遍。
    ///
    /// 不用"跑过一次就永远不再跑"的标记：那个写法在抓取失败时同样算跑过——
    /// 而失败恰恰是最需要重来的情况（批量重抓时撞上限流几乎是必然）。改成
    /// **按条计次**：只挑正文确实是空的，每条最多试三次，每次开机最多几条。
    /// 抓到了自然就不再是候选，抓不到的也不会没完没了。
    /// 本次启动跑过没有。挂在 reload 尾部会被调用几十次——reload 本身很频繁
    /// （收纳、索引完成、元数据回来都会触发），每次都把整库链接的分块查一遍
    /// 纯属浪费，日志里也全是"本轮 0 条"。
    @ObservationIgnored private var didBackfillLinksThisLaunch = false

    func backfillFailedLinkExtractions() async {
        guard !didBackfillLinksThisLaunch else { return }
        didBackfillLinksThisLaunch = true
        let defaults = UserDefaults.standard
        var attempts = (defaults.dictionary(forKey: Self.linkReparseAttemptsKey)
            as? [String: Int]) ?? [:]
        if defaults.integer(forKey: Self.linkExtractionRevisionKey) < Self.linkExtractionRevision {
            attempts = [:]
            defaults.set(attempts, forKey: Self.linkReparseAttemptsKey)
            defaults.set(Self.linkExtractionRevision, forKey: Self.linkExtractionRevisionKey)
        }
        let links = items.filter { $0.kind == .link && shouldProcessContent($0) }
        guard !links.isEmpty else { return }

        var candidates: [Item] = []
        for link in links where attempts[link.id.uuidString, default: 0] < Self.linkReparseMaxAttempts {
            let page = ((try? await library.chunks(for: link.id)) ?? [])
                .filter { $0.source == .linkPage }
            let longest = page
                .flatMap { $0.text.split(whereSeparator: \.isNewline) }
                .map(\.count)
                .max() ?? 0
            let platform = link.linkURL.flatMap(LinkPlatform.resolve)
            let isXiaohongshuLoginWall = platform == .xiaohongshu
                && page.contains { SiteContentExtraction.Xiaohongshu.isLoginWall($0.text) }
            // 小红书/Discourse 的结构化内容可能本来就很短（几十字帖子也完全
            // 合法），不能按通用网页 120 字门槛反复重抓。有 linkPage 且不是
            // 已知登录墙/失败标题就算成功；普通网页仍用段落长度判断导航噪音。
            let structuralPlatform = platform == .xiaohongshu || platform == .linuxdo
            let bodyMissing = structuralPlatform ? page.isEmpty
                : longest < LinkTextExtraction.proseParagraphLength
            let needsRepair = bodyMissing
                || Self.isFailedExtractionTitle(link.title)
                || isXiaohongshuLoginWall
            guard needsRepair else { continue }
            if isXiaohongshuLoginWall { knownInvalidLinkPageIDs.insert(link.id) }
            candidates.append(link)
            if candidates.count >= Self.linkReparseBatch { break }
        }
        guard !candidates.isEmpty else { return }
        persistKnownInvalidLinkPages()

        // 逆序插到队首，最终保持 candidates 原顺序；正文修复优先于原有待办，
        // 所有请求仍由 LinkFetchScheduler 单通道串行。
        for item in candidates.reversed() {
            attempts[item.id.uuidString, default: 0] += 1
            queueForcedLinkRefresh(item.id, prioritize: true)
        }
        defaults.set(attempts, forKey: Self.linkReparseAttemptsKey)
        resumeIndexing()
    }

    private func persistKnownInvalidLinkPages() {
        UserDefaults.standard.set(
            knownInvalidLinkPageIDs.map(\.uuidString).sorted(),
            forKey: Self.knownInvalidLinkPageKey
        )
    }

    /// 删除已经确认是登录墙的网页分块，并同步清空聚合向量；用户备注和 URL
    /// 分块保留。用原子 API，绝不留下“分块已删但 Item 仍指向旧向量”的状态。
    private func discardKnownInvalidLinkPage(_ itemID: UUID) async {
        guard var item = try? await library.item(id: itemID) else { return }
        let keep = ((try? await library.chunks(for: itemID)) ?? [])
            .filter { $0.source != .linkPage }
        item.vector = nil
        item.contentHash = keep.map(\.contentHash).joined(separator: ":")
        item.embeddingModelID = nil
        item.indexedAt = nil
        try? await library.replaceChunks(for: itemID, with: keep, updating: item)
    }

    /// 记满自动补抓次数：这条链接在当前解析版本下不必再被启发式选中。
    private func saturateLinkReparseAttempt(_ itemID: UUID) {
        var attempts = (UserDefaults.standard.dictionary(forKey: Self.linkReparseAttemptsKey)
            as? [String: Int]) ?? [:]
        guard attempts[itemID.uuidString, default: 0] < Self.linkReparseMaxAttempts else { return }
        attempts[itemID.uuidString] = Self.linkReparseMaxAttempts
        UserDefaults.standard.set(attempts, forKey: Self.linkReparseAttemptsKey)
    }

    private func clearLinkReparseAttempt(_ itemID: UUID) {
        var attempts = (UserDefaults.standard.dictionary(forKey: Self.linkReparseAttemptsKey)
            as? [String: Int]) ?? [:]
        guard attempts.removeValue(forKey: itemID.uuidString) != nil else { return }
        UserDefaults.standard.set(attempts, forKey: Self.linkReparseAttemptsKey)
    }

    private func enqueueIndex(_ id: UUID, item suppliedItem: Item? = nil) {
        guard !pendingIndexIDs.contains(id),
              let item = suppliedItem ?? items.first(where: { $0.id == id }),
              shouldProcessContent(item) else { return }
        pendingIndexIDs.append(id)
        persistIndexQueue()
        resumeIndexing()
    }

    private func removePendingIndex(_ id: UUID) {
        guard pendingIndexIDs.contains(id) else { return }
        pendingIndexIDs.removeAll { $0 == id }
        persistIndexQueue()
    }

    private func persistIndexQueue() {
        UserDefaults.standard.set(pendingIndexIDs.map(\.uuidString), forKey: Self.indexQueueKey)
    }

    private func persistForcedLinkRefreshes() {
        UserDefaults.standard.set(
            forcedLinkRefreshIDs.map(\.uuidString).sorted(),
            forKey: Self.forcedLinkRefreshKey
        )
    }

    private func showEdgeStatus(_ signal: EdgeStatusSignal) {
        guard edgeStatusEffectsEnabled else { return }
        edgeStatusTask?.cancel()
        edgeStatusSignal = signal
        edgeStatusTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4.5))
            guard !Task.isCancelled else { return }
            self?.edgeStatusSignal = nil
            self?.edgeStatusTask = nil
        }
    }

    func submitSemanticSearch() {
        scheduleSemanticSearch(delay: .zero, allowsNetwork: true)
    }

    private func scheduleSemanticSearch(
        delay: Duration = .milliseconds(450),
        allowsNetwork: Bool = false
    ) {
        semanticSearchTask?.cancel()
        isPerformingSemanticSearch = false
        retrievalRecommendations = []
        clearSearchAnswer()
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let action = semanticSearchAction else {
            semanticHits = []
            semanticQuery = ""
            understoodSearchQuery = nil
            return
        }
        semanticSearchTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.isPerformingSemanticSearch = true
            let trace = PerformanceTrace.begin("SemanticSearch")
            defer { PerformanceTrace.end("SemanticSearch", id: trace) }
            let snapshot = self.aiEligibleItems
            let run = await action(value, snapshot, allowsNetwork)
            guard !Task.isCancelled,
                  self.query.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return }
            self.semanticHits = run.hits
            self.retrievalRecommendations = run.recommendations
            self.semanticQuery = value
            self.understoodSearchQuery = run.understoodQuery
            self.isPerformingSemanticSearch = false
            self.semanticSearchTask = nil
            if allowsNetwork {
                self.streamSearchAnswer(
                    for: value,
                    candidates: run.candidates,
                    recency: run.understoodQuery.recency
                )
            }
        }
    }

    /// 回车才发起：输入过程中的去抖检索只更新本地结果，不烧 token。
    private func streamSearchAnswer(
        for value: String,
        candidates: [RetrievalRankingCandidate],
        recency: RecencyPreference?
    ) {
        searchAnswerTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        searchAnswer = ""
        searchAnswerError = nil
        clearContextReasoning()
        // 每一条走不下去的路径都必须说出原因。静默 return 的后果就是界面上
        // 什么都不显示，用户无从判断是"库里没有"还是"根本没跑起来"。
        guard let action = searchAnswerStreamAction else {
            isStreamingSearchAnswer = false
            searchAnswerError = "AI 检索未启用，当前只有本地关键词结果"
            return
        }
        guard !candidates.isEmpty else {
            isStreamingSearchAnswer = false
            searchAnswerError = items.isEmpty
                ? "库里还没有内容可供检索"
                : "本地没有筛出候选，换一种描述再试"
            return
        }
        isStreamingSearchAnswer = true
        searchAnswerTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await event in action(value, candidates, recency) {
                    guard !Task.isCancelled,
                          generation == self.searchGeneration,
                          self.query.trimmingCharacters(in: .whitespacesAndNewlines) == value else { return }
                    switch event {
                    case .reasoning(let text):
                        self.replaceSearchReasoning(text, generation: generation)
                    case .summary(let text):
                        // 正文开始落地就说明想完了，折叠起来把地方让给答案。
                        self.settleContextReasoning()
                        self.publishSearchAnswer(text, generation: generation)
                    case .recommendations(let selection):
                        guard case .selected(let recommendations) = selection else {
                            // 格式损坏不是模型明确的空选择；保留本地命中，并告诉用户
                            // 当前卡片是降级结果，不能静默删空或误称 AI 已确认。
                            self.searchAnswerError = "模型返回格式不完整，下面保留本地检索结果"
                            continue
                        }
                        // 这是流收尾后的机器可读最终选择。空数组也是有效结论：
                        // 模型认为本地候选都不相关时，必须清掉预选卡，不能继续展示。
                        self.retrievalRecommendations = recommendations
                        // 候选里有本地零命中的条目（没配 embedding 时全靠模型判断）。
                        // 不先把它们补成 hit，reorder 会按 ID 查不到而直接丢掉，
                        // 结果就是模型明明选中了，界面还显示"没有找到相关内容"。
                        var hits = self.semanticHits
                        let known = Set(hits.map(\.itemID))
                        let titleByID = Dictionary(
                            uniqueKeysWithValues: self.items.map { ($0.id, $0.title) }
                        )
                        for recommendation in recommendations where !known.contains(recommendation.itemID) {
                            guard let title = titleByID[recommendation.itemID] else { continue }
                            hits.append(SemanticSearchHit(
                                itemID: recommendation.itemID,
                                snippet: recommendation.reason.isEmpty ? title : recommendation.reason,
                                score: 0
                            ))
                        }
                        self.semanticHits = AgenticRetrieval.selectedHits(from: hits, using: recommendations)
                    }
                }
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                // 收尾必须立刻把缓冲里的最后一段冲出去，否则末尾会缺一截。
                self.searchAnswerFlushTask?.cancel()
                self.searchAnswerFlushTask = nil
                self.flushSearchAnswer()
                self.isStreamingSearchAnswer = false
                self.searchAnswerTask = nil
                self.settleContextReasoning()
                // 流正常结束却一个字都没有：模型返回了空内容。也要说出来，
                // 否则回答区会闪一下就消失。
                if self.searchAnswer.isEmpty, self.searchAnswerError == nil {
                    // 只想不答是另一回事：思考在卡片上摆着，别说成"没有返回内容"。
                    self.searchAnswerError = self.contextReasoning.isEmpty
                        ? "模型没有返回内容，下面是本地检索结果"
                        : "模型只输出了思考过程，没有给出结论；可展开思考查看"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, generation == self.searchGeneration else { return }
                self.settleContextReasoning()
                self.isStreamingSearchAnswer = false
                self.searchAnswerError = Self.describeSearchAnswerFailure(error)
                self.searchAnswerTask = nil
            }
        }
    }

    private static func describeSearchAnswerFailure(_ error: any Error) -> String {
        switch error {
        case AIExecutionError.routeNotConfigured, AIExecutionError.modelNotConfigured:
            "还没有为搜索配置模型，当前只有本地检索结果"
        case ProviderError.missingCredential, ProviderError.invalidCredential:
            "模型密钥无效，当前只有本地检索结果"
        default:
            "AI 检索失败：\(error.localizedDescription)"
        }
    }

    /// 把增量合并到 ~20fps 再上屏。模型一秒能吐几十个 token，逐个刷新会让
    /// 整段文本反复重排，看着就是在抖。
    /// 搜索页那条流给的是累计思考，替换而不是追加。
    private func replaceSearchReasoning(_ text: String, generation: Int) {
        guard generation == searchGeneration, !text.isEmpty else { return }
        if contextReasoningPhase == .none {
            contextReasoningStartedAt = .now
            contextReasoningDuration = nil
            isContextReasoningExpanded = false
        }
        contextReasoningPhase = .thinking
        contextReasoning = text.count > Self.maximumReasoningCharacters
            ? String(text.suffix(Self.maximumReasoningCharacters))
            : text
    }

    private func publishSearchAnswer(_ text: String, generation: Int) {
        guard generation == searchGeneration else { return }
        pendingSearchAnswer = text
        guard searchAnswerFlushTask == nil else { return }
        searchAnswerFlushTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return
            }
            guard let self, !Task.isCancelled, generation == self.searchGeneration else { return }
            self.searchAnswerFlushTask = nil
            self.flushSearchAnswer()
        }
    }

    private func flushSearchAnswer() {
        guard let pending = pendingSearchAnswer else { return }
        pendingSearchAnswer = nil
        searchAnswer = pending
    }

    private func clearSearchAnswer() {
        searchGeneration &+= 1
        searchAnswerFlushTask?.cancel()
        searchAnswerFlushTask = nil
        pendingSearchAnswer = nil
        searchAnswerTask?.cancel()
        searchAnswerTask = nil
        searchAnswer = ""
        searchAnswerError = nil
        clearContextReasoning()
        isStreamingSearchAnswer = false
    }

    func semanticHit(for itemID: UUID) -> SemanticSearchHit? {
        semanticHitIndex[itemID]
    }

    func retrievalRecommendation(for itemID: UUID) -> RetrievalRecommendation? {
        retrievalRecommendationIndex[itemID]
    }

    func commitEdit(_ id: UUID, text: String) async {
        do {
            let changed = try await library.edit(id: id, newText: text)
            editingItemID = nil
            hasUnsavedChanges = false
            await reload()
            if changed, let item = items.first(where: { $0.id == id }) {
                invalidateSceneRecommendationCache(for: id)
                scheduleAIWork(for: item)
            }
        } catch {
            lastError = error.localizedDescription
            await reload()
        }
    }

    private func invalidateSceneRecommendationCache(for id: UUID) {
        if sceneRecommendationCache.removeValue(forKey: id) != nil {
            persistSceneRecommendationCache()
        }
    }

    private func persistSceneRecommendationCache() {
        let encoded = Dictionary(uniqueKeysWithValues: sceneRecommendationCache.map {
            ($0.key.uuidString, $0.value)
        })
        if let data = try? JSONEncoder().encode(encoded) {
            UserDefaults.standard.set(data, forKey: Self.sceneCacheKey)
        }
    }

    private static func sceneContentFingerprint(_ item: Item) -> String {
        let source: String
        switch item.holding {
        case .inline(let text):
            source = "inline|\(text)"
        case .copy(let hash, let size):
            source = "copy|\(hash)|\(size)"
        case .reference(_, let size):
            source = [
                "reference",
                item.originalSourcePath ?? "",
                item.sourceModificationDate?.timeIntervalSince1970.description ?? "",
                item.sourceFileSize?.description ?? size.description,
            ].joined(separator: "|")
        }
        return SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
