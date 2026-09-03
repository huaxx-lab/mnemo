import Foundation

/// 一次对待办集合的改动提案。
///
/// 聊天记录是**流式**的：先说"三点开会"，半小时后说"改四点"，第二天说
/// "这周不开了"。只会 `create` 的提取器面对这种输入会攒出三条互相矛盾的
/// 待办，而用户真正想要的是同一条被改了两次。
public enum TodoRevision: Sendable, Equatable {
    case create(TodoDraft)
    case reschedule(todoID: UUID, title: String, from: Date?, to: Date)
    /// 改说法，可以顺带定下时间。
    ///
    /// "改两个图，明天"既换了标题也给了期限；拆成两条提案会让用户点两次，
    /// 而它们描述的是同一次改动。`previousDueAt` 留给撤销用。
    case rename(todoID: UUID, from: String, to: String, dueAt: Date?, previousDueAt: Date?)
    case complete(todoID: UUID, title: String)
    case cancel(todoID: UUID, title: String)

    public var todoID: UUID? {
        switch self {
        case .create: nil
        case .reschedule(let id, _, _, _), .rename(let id, _, _, _, _),
             .complete(let id, _), .cancel(let id, _): id
        }
    }

    /// 撤销这一步需要把待办恢复成什么样。`nil` 表示"删掉刚建的那条"。
    public var isDestructive: Bool {
        switch self {
        case .cancel: true
        case .create, .reschedule, .rename, .complete: false
        }
    }

    /// 哪些动作必须由用户明确点 ✓。设置里的“不询问，直接加入待办”只针对
    /// “加入”，不能顺带授权改名、完成或删除已有事项。
    public var requiresExplicitConfirmation: Bool {
        switch self {
        case .rename, .complete, .cancel: true
        case .create, .reschedule: false
        }
    }
}

/// 提案连同它的展示文案与把握程度。
public struct TodoRevisionPlan: Sendable, Equatable, Identifiable {
    public var id: String
    public var revision: TodoRevision
    /// 卡片主标题。
    public var title: String
    /// 卡片副标题：为什么提这一条。
    public var summary: String
    /// 够不够确凿到"直接做，只留撤销"。模型结论还必须通过原文证据验证。
    public var isCertain: Bool
    /// 卡片视觉类型。只影响图标、品牌色和措辞，不参与识别资格。
    public var kind: TodoRevisionDecision.Kind
    /// 平台/商家原名，例如麦当劳、京东、菜鸟。
    public var service: String?
    /// 订单号/取餐码/取件码，已经逐字从原文验证。
    public var code: String?

    public init(
        id: String,
        revision: TodoRevision,
        title: String,
        summary: String,
        isCertain: Bool,
        kind: TodoRevisionDecision.Kind = .general,
        service: String? = nil,
        code: String? = nil
    ) {
        self.id = id
        self.revision = revision
        self.title = title
        self.summary = summary
        self.isCertain = isCertain
        self.kind = kind
        self.service = service
        self.code = code
    }
}

/// 把"新看到的一段话"和"已经存在的待办"对上号。
///
/// 全部本地、确定性。模型那一层（`AIFeature.todoRevision`）只在这之后参与，
/// 而且只能在**这里给出的候选 ID** 里选——它可以改判动作，不能凭空指认一条
/// 待办，更不能编一个 ID 出来。这条边界和 `ContextualAutoCopy` 是同一条。
public enum TodoReconciler {

    /// 一段话在对已有待办做什么。
    public enum Intent: String, Sendable, Equatable {
        case reschedule
        case cancel
        case complete
    }

    private static let rescheduleCues = [
        "改到", "改成", "改为", "推迟到", "推迟至", "延期到", "延期至", "顺延到",
        "提前到", "提前至", "挪到", "调整到", "调到", "变更为", "改期",
    ]

    private static let cancelCues = [
        "取消", "作废", "撤销", "终止", "停办", "不办了", "先不做",
        "不用交", "不用做", "不用去", "不做了", "不用了", "不开了", "不上了", "鸽了",
    ]

    private static let completeCues = [
        "已完成", "已提交", "已交", "交了", "搞定了", "做完了", "完成了",
        "交上去了", "已办结", "弄好了", "取到了", "拿到了",
    ]

    /// 说的是别人，不是你。
    ///
    /// "隔壁组的开题报告交了"和"开题报告交了"在词表眼里一模一样，但前者不该
    /// 把你的待办划掉。这类主语线索是本地唯一能可靠区分的信号——出现即退出，
    /// 把判断让给模型或者干脆不做。
    private static let thirdPartyCues = [
        "听说", "据说", "别人", "他们", "她们", "隔壁", "其他组", "别的组",
        "同学说", "有人", "某某", "转发", "帮转",
    ]

    /// 标题相似到什么程度算"同一件事"。
    ///
    /// 相似度定义为**待办标题里最长的一段连续文字，有多大比例原样出现在这段
    /// 话里**。连续是关键：中文里"组会"连着出现才说明在讲同一件事，"组"和
    /// "会"各自散落在句子里毫无意义。
    ///
    /// 阈值定在 0.28，是为了接住"在305开组会"对上"组会改到四点"这种情况——
    /// 命中的两个字只占标题的 2/7，但它就是这条待办的全部语义内容。代价由
    /// 别处补偿：弱匹配一律要用户点头，同分并列判为有歧义直接放弃。
    public static let matchThreshold: Float = 0.28
    /// 强匹配：标题大半原样出现在话里。到这个程度才允许不问就改。
    public static let strongMatchThreshold: Float = 0.6

    /// 太通用、不足以指认任何一件事的片段。
    ///
    /// "提交材料"和待办"提交开题报告"共有"提交"两个字，比例上够得着阈值，
    /// 但这两个字对上号毫无意义——它出现在一半的待办里。这类片段单独命中
    /// 时直接判 0，必须靠更长的重合才算数。
    private static let genericFragments: Set<String> = [
        "提交", "完成", "开会", "会议", "通知", "提醒", "时间", "今天", "明天",
        "作业", "报告", "上课", "考试", "截止", "任务", "事情", "准备", "参加",
        "记得", "记录", "材料", "文件", "内容", "问题",
    ]

    /// 正文的二字组索引。
    ///
    /// 存在的唯一理由是性能：相似度本身是 O(标题长 × 正文长) 的动态规划，
    /// 一段聊天记录对上几十条待办就是上百万次比较，实测单次协调要 48 毫秒，
    /// 放在剪贴板路径上会直接丢帧。绝大多数待办和这段话连一个二字组都不共享，
    /// 用一次 O(标题长) 的集合查询就能筛掉，动态规划只对剩下的一两条跑。
    struct TextIndex {
        private let bigrams: Set<String>
        let text: String

        init(_ text: String) {
            let lowered = text.lowercased()
            self.text = lowered
            var set: Set<String> = []
            let characters = Array(lowered)
            if characters.count >= 2 {
                for index in 0..<(characters.count - 1) {
                    set.insert(String(characters[index...(index + 1)]))
                }
            }
            bigrams = set
        }

        func mayMatch(_ title: String) -> Bool {
            let characters = Array(title.lowercased())
            guard characters.count >= 2 else { return false }
            for index in 0..<(characters.count - 1)
            where bigrams.contains(String(characters[index...(index + 1)])) {
                return true
            }
            return false
        }
    }

    /// 待办标题和这段话有多像。见 `matchThreshold` 的定义说明。
    public static func similarity(title: String, text: String) -> Float {
        similarity(title: title, index: TextIndex(text))
    }

    static func similarity(title: String, index: TextIndex) -> Float {
        guard index.mayMatch(title) else { return 0 }
        // 标题长度封顶：超长标题的动态规划代价没有上限，而超出的部分对
        // "是不是同一件事"也不再提供信息。
        let title = Array(title.lowercased().prefix(48))
        let text = Array(index.text)
        guard title.count >= 2, !text.isEmpty else { return 0 }

        // 滚动两行的动态规划，只求最长公共连续子串的长度和位置。
        var previous = [Int](repeating: 0, count: text.count + 1)
        var current = previous
        var longest = 0
        var longestEnd = 0
        for i in 1...title.count {
            for j in 1...text.count {
                current[j] = title[i - 1] == text[j - 1] ? previous[j - 1] + 1 : 0
                if current[j] > longest {
                    longest = current[j]
                    longestEnd = i
                }
            }
            swap(&previous, &current)
            current.replaceSubrange(0..<current.count, with: repeatElement(0, count: current.count))
        }
        // 单字重合是巧合，不是相似。
        guard longest >= 2 else { return 0 }
        let fragment = String(title[(longestEnd - longest)..<longestEnd])
        // 纯数字重合（"305" 撞上 "2025"）同样不说明什么。
        guard !fragment.allSatisfy({ $0.isNumber }) else { return 0 }
        // 只重合了一个通用词时不算命中，除非重合得更长。
        if longest <= 2, genericFragments.contains(fragment) { return 0 }
        return Float(longest) / Float(title.count)
    }

    public static func intent(in text: String) -> Intent? {
        // 主语不是你的时候一律不动手。误判的代价是把别人的进度记到你头上，
        // 而这种错要等到错过截止那天才会被发现。
        guard !thirdPartyCues.contains(where: { text.contains($0) }) else { return nil }
        // 顺序有讲究：「取消」比「改到」更强——"会议取消，改到下周再说"说的是
        // 这次不开了，不是改期。
        if cancelCues.contains(where: { text.contains($0) }) { return .cancel }
        if completeCues.contains(where: { text.contains($0) }) { return .complete }
        if rescheduleCues.contains(where: { text.contains($0) }) { return .reschedule }
        return nil
    }

    /// 在未完成待办里找这段话说的是哪一条。
    ///
    /// 返回最高分那条以及它的分数。命中多条同分时返回 nil——有歧义就该问，
    /// 不该挑一个。
    public static func match(
        text: String,
        in todos: [Todo]
    ) -> (todo: Todo, score: Float)? {
        let open = todos.filter { !$0.isCompleted }
        guard !open.isEmpty else { return nil }

        // 索引只建一次，几十条待办共用。
        let index = TextIndex(String(text.prefix(1_200)))
        let scored = open
            .map { (todo: $0, score: similarity(title: $0.title, index: index)) }
            .filter { $0.score >= matchThreshold }
            .sorted { $0.score > $1.score }
        guard let best = scored.first else { return nil }
        // 并列第一说明这段话对两条待办一样像，那就是有歧义。
        if scored.count > 1, abs(scored[1].score - best.score) < 0.01 { return nil }
        return best
    }

    /// 本地层一次返回多条互相独立的提案。
    ///
    /// 旧的 `plan` 保留单项语义；批量入口负责逐条协调、去重，并确保同一条
    /// 现有待办在一批里最多被修改一次。模型不可用时，多行通知也不会再因为
    /// 调用方只取 `drafts.first` 而丢掉第二件事。
    public static func plans(
        text: String,
        drafts: [TodoDraft],
        todos: [Todo],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent,
        limit: Int = 5
    ) -> [TodoRevisionPlan] {
        guard limit > 0 else { return [] }

        var result: [TodoRevisionPlan] = []
        var seenIDs: Set<String> = []
        var touchedTodoIDs: Set<UUID> = []
        func append(_ plan: TodoRevisionPlan?) {
            guard let plan, seenIDs.insert(plan.id).inserted else { return }
            if let todoID = plan.revision.todoID,
               !touchedTodoIDs.insert(todoID).inserted { return }
            result.append(plan)
        }

        // 改期 / 完成 / 取消不需要先提取出一个新 draft，也必须有机会生效。
        append(plan(text: text, draft: nil, todos: todos, now: now, calendar: calendar))
        for draft in drafts where result.count < limit {
            append(plan(text: text, draft: draft, todos: todos, now: now, calendar: calendar))
        }
        return Array(result.prefix(limit))
    }

    private static func presentationKind(for source: TodoDraft.Source) -> TodoRevisionDecision.Kind {
        switch source {
        case .pickupCode: .foodPickup
        case .delivery: .packagePickup
        case .deadline: .deadline
        case .appointment: .appointment
        }
    }

    /// 本地能得出的唯一结论。得不出就返回 nil，交给上层决定要不要问模型。
    public static func plan(
        text: String,
        draft: TodoDraft?,
        todos: [Todo],
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> TodoRevisionPlan? {
        if let revision = revisionPlan(text: text, todos: todos, now: now, calendar: calendar) {
            return revision
        }

        // 这段话在改一件**已有**的事，但清单里找不到对应的那条。
        //
        // 此时正确的行为是什么都不做，而不是退回去新建。"组会改到四点"被当成
        // 新待办建出来，标题会是"组会改到"这种半截话，而且它描述的那件事
        // 用户手上根本没有——凭空多一条比漏一条更难收拾。
        guard intent(in: text) == nil else { return nil }

        guard let draft else { return nil }

        // 没有改期措辞，但提取出的这件事和某条已有待办是同一件，只是时间不同。
        // 典型是老师把同一件事又说了一遍并顺手改了日期，没写"改到"。
        if let hit = match(text: draft.title, in: todos),
           let newDate = draft.dueAt,
           differsMeaningfully(hit.todo.dueAt, newDate) {
            return TodoRevisionPlan(
                id: "reschedule:\(hit.todo.id.uuidString):\(slot(of: newDate))",
                revision: .reschedule(
                    todoID: hit.todo.id,
                    title: hit.todo.title,
                    from: hit.todo.dueAt,
                    to: newDate
                ),
                title: hit.todo.title,
                // 没有明说"改到"，只是时间对不上。这种一律问，不自作主张。
                summary: "时间改为 " + TodoReminderPolicy.relativeDescription(of: newDate, now: now),
                isCertain: false,
                kind: presentationKind(for: draft.source),
                code: draft.code
            )
        }

        // 同一件事、同一个时间：已经有了，不重复建。
        if let hit = match(text: draft.title, in: todos),
           !differsMeaningfully(hit.todo.dueAt, draft.dueAt) {
            return nil
        }

        return TodoRevisionPlan(
            id: draft.id,
            revision: .create(draft),
            title: draft.title,
            summary: draft.reason,
            isCertain: draft.isCertain,
            kind: presentationKind(for: draft.source),
            code: draft.code
        )
    }

    private static func revisionPlan(
        text: String,
        todos: [Todo],
        now: Date,
        calendar: Calendar
    ) -> TodoRevisionPlan? {
        guard let intent = intent(in: text), let hit = match(text: text, in: todos) else {
            return nil
        }
        let todo = hit.todo
        switch intent {
        case .reschedule:
            guard let reference = ChineseDateParser.firstDate(in: text, now: now, calendar: calendar),
                  differsMeaningfully(todo.dueAt, reference.date) else { return nil }
            let target = reference.hasExplicitTime
                ? reference.date
                : ChineseDateParser.endOfDay(reference.date, calendar: calendar)
            return TodoRevisionPlan(
                id: "reschedule:\(todo.id.uuidString):\(slot(of: target))",
                revision: .reschedule(
                    todoID: todo.id,
                    title: todo.title,
                    from: todo.dueAt,
                    to: target
                ),
                title: todo.title,
                summary: "改到 " + TodoReminderPolicy.relativeDescription(of: target, now: now),
                // 明说了"改到"，而且这段话原样含着那条待办的标题：够确凿。
                // 改期是可逆的，卡片上那个叉就是撤销。
                isCertain: hit.score >= strongMatchThreshold
            )
        case .complete:
            return TodoRevisionPlan(
                id: "complete:\(todo.id.uuidString)",
                revision: .complete(todoID: todo.id, title: todo.title),
                title: todo.title,
                summary: "标记为已完成",
                // 完成是可逆的，但"谁完成了"这件事误判起来很难被发现——
                // 待办悄悄消失，用户直到错过才知道。一律问。
                isCertain: false
            )
        case .cancel:
            return TodoRevisionPlan(
                id: "cancel:\(todo.id.uuidString)",
                revision: .cancel(todoID: todo.id, title: todo.title),
                title: todo.title,
                summary: "这条待办被取消了",
                // 删除不可逆，永远问。
                isCertain: false
            )
        }
    }

    /// 两个时间算不算"真的改了"。
    ///
    /// 五分钟的容差：解析同一句话两次可能因为"现在"不同差几秒，那不是改期。
    public static func differsMeaningfully(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): false
        case (nil, .some), (.some, nil): true
        case (.some(let a), .some(let b)): abs(a.timeIntervalSince(b)) > 300
        }
    }

    private static func slot(of date: Date) -> Int {
        Int(date.timeIntervalSince1970 / 300)
    }
}
