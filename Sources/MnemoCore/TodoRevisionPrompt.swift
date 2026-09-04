import Foundation

/// 交给模型的一条现有待办。
///
/// `index` 是**给模型看的编号**，从 1 开始；`todoID` 模型永远看不到。
/// 这不是排版讲究，是安全边界：模型只能在编号里选，选不出编号就等于没选中，
/// 它没有任何途径凭空指认一条待办，也编不出一个能落到库里的 ID。
/// 和 `ContextualAutoCopy` 是同一条原则——模型可以排序和解释，不能把
/// "本地没有的事实"变成真的。
public struct TodoRevisionCandidate: Sendable, Equatable {
    public var index: Int
    public var todoID: UUID
    public var title: String
    public var dueAt: Date?
    /// 这条待办当初是从哪条 Pin 提取的、那条 Pin 现在还能读到什么。
    ///
    /// 只在源还在库里（包括在回收站里）时才有值。回收站里的源随时可能被
    /// 还原，所以不算删除；只有彻底清空之后这里才是 nil——那时我们手上
    /// 也确实没有任何内容可给，而且不该留副本。
    public var sourceContext: String?

    public init(
        index: Int,
        todoID: UUID,
        title: String,
        dueAt: Date? = nil,
        sourceContext: String? = nil
    ) {
        self.index = index
        self.todoID = todoID
        self.title = title
        self.dueAt = dueAt
        self.sourceContext = sourceContext
    }
}

/// 模型对"这段新文字要对待办做什么"的判断。
public struct TodoRevisionDecision: Sendable, Equatable {
    public enum Action: String, Sendable, Equatable, Codable {
        case create, reschedule, rename, complete, cancel, none
    }

    /// 用于卡片展示与提醒措辞，不参与“要不要识别”的门控。
    /// 未知场景用 general，绝不为了覆盖新场景继续扩一张关键词表。
    public enum Kind: String, Sendable, Equatable, Codable {
        case general
        case foodPickup
        case packagePickup
        case delivery
        case travel
        case deadline
        case appointment
    }

    public var action: Action
    /// 命中的候选编号。`create` / `none` 时为 nil。
    public var index: Int?
    public var title: String?
    public var dueAt: Date?
    public var reason: String
    public var kind: Kind
    /// 商家/平台原名，例如“麦当劳”“肯德基”“菜鸟”。只用于视觉适配。
    public var service: String?
    /// 订单号、取餐码、取件码等。必须来自原文，不允许模型改写。
    public var code: String?
    /// 支撑本次判断的最短原文片段。调用方必须逐字验证它确实存在。
    public var evidence: String?
    /// 模型认为需要用户点 ✓/✕。即使为 false，证据验证失败或动作有破坏性时
    /// 调用方仍会强制确认；模型自报不能绕过本地安全边界。
    public var needsConfirmation: Bool

    public init(
        action: Action,
        index: Int? = nil,
        title: String? = nil,
        dueAt: Date? = nil,
        reason: String = "",
        kind: Kind = .general,
        service: String? = nil,
        code: String? = nil,
        evidence: String? = nil,
        needsConfirmation: Bool = true
    ) {
        self.action = action
        self.index = index
        self.title = title
        self.dueAt = dueAt
        self.reason = reason
        self.kind = kind
        self.service = service
        self.code = code
        self.evidence = evidence
        self.needsConfirmation = needsConfirmation
    }

    /// 这条判断能不能不问用户就执行。
    ///
    /// 判据分两级，对应两种强度完全不同的事实：
    ///
    /// 1. **码逐字对上**——最强。那串数字是用户要照着念的，它出现在原文里
    ///    就是一个可核对的本地事实，比模型任何自报置信度都硬。有它就够了。
    /// 2. **没有码时**：要求引用足够像原文，并且模型自己也说不必确认。
    ///
    /// 为什么不再要求引用逐字相同：原文是 OCR 出来的，本身带错字——库里那张
    /// 麦当劳截图识别出的是"餐厅配䬸中…在取督时现场制作"。模型引用时会顺手
    /// 把错字纠正回来，于是逐字比对必然失败，所有截图候选都被降级成"要问一句"，
    /// 弹十二秒就过期。压平空白治不了错字，得换判据。
    public func hasVerifiableEvidence(in source: String) -> Bool {
        let haystack = Self.flattened(source)
        if let code, !code.isEmpty {
            // 码必须一位不差。对不上说明模型在编，直接否决。
            return haystack.localizedCaseInsensitiveContains(Self.flattened(code))
        }
        guard let evidence, evidence.count >= 4 else { return false }
        return Self.overlapRatio(of: Self.flattened(evidence), in: haystack) >= 0.6
    }

    /// 引用里最长的一段连续文字，占引用本身多大比例。
    ///
    /// 容忍零星错字与纠正，但拦得住整句编造：模型凭空写出来的句子在原文里
    /// 找不到任何像样的连续片段，比例会远低于阈值。
    static func overlapRatio(of needle: String, in haystack: String) -> Double {
        let needle = Array(needle.lowercased())
        let haystack = Array(haystack.lowercased())
        guard !needle.isEmpty, !haystack.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: haystack.count + 1)
        var current = previous
        var longest = 0
        for i in 1...needle.count {
            for j in 1...haystack.count {
                current[j] = needle[i - 1] == haystack[j - 1] ? previous[j - 1] + 1 : 0
                if current[j] > longest { longest = current[j] }
            }
            swap(&previous, &current)
            current.replaceSubrange(0..<current.count, with: repeatElement(0, count: current.count))
        }
        return Double(longest) / Double(needle.count)
    }

    /// 把所有连续空白（含换行）压成一个空格，并去掉首尾。
    static func flattened(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 一次待办理解的结局。
///
/// 三种情况必须分开，否则上层无法决定"要不要重试"：
///
/// - `decided`：模型真的答了（包括它明确说"这不是待办"）；
/// - `unavailable`：没配路由、内容太短——不是失败，重试一百次也是同样结果；
/// - `failed`：网络、限流、格式错误——**内容本身可能是待办**，值得稍后再来一次。
///
/// 过去这三种都被压成一个 `nil`，于是一次网络抖动就等于永久丢掉一条待办，
/// 用户看到的就是"同样的截图，有时出、有时不出"。
public enum TodoInterpretation: Sendable, Equatable {
    /// 一次输入可以同时新建、改期或完成多件事。空数组表示模型明确判断没有待办。
    case decided([TodoRevisionDecision])
    case unavailable
    case failed(reason: String)
}

/// 待办协调的提示词与解析。
///
/// 放在 Core 而不是设置层：few-shot 的那几个例子决定了这个功能的行为边界，
/// 它和阈值、闸门一样属于领域规则，应该能被直接测、能被评测语料覆盖。
public enum TodoRevisionPrompt {

    /// 单次输入最多执行这么多原子动作。限制在解析层，不依赖模型自觉。
    public static let maximumDecisionCount = 5

    public static let system = """
    你是 Mnemo 的待办理解器。输入可能是用户复制的普通文字，也可能是截图 OCR，\
    其中会混入状态栏时间、聊天时间戳、广告、商品信息和历史对话。你必须理解语义，\
    判断它是否表达用户未来要做的事，或者是否在修改现有待办。

    返回一个 JSON 对象，顶层只有 decisions 数组：
    {"decisions":[
      {"action":"create|reschedule|rename|complete|cancel",
       "todo":已有待办编号或null,
       "title":"简短可执行标题或null",
       "dueAt":"ISO 8601带时区或null",
       "kind":"general|foodPickup|packagePickup|delivery|travel|deadline|appointment",
       "service":"商家或平台原名或null",
       "code":"订单号/取餐码/取件码或null",
       "evidence":"支撑这一项判断的最短原文片段",
       "needsConfirmation":true|false,
       "reason":"一句短理由"}
    ]}

    严格规则：
    1. 只返回 JSON，不要 Markdown；没有任何待办时返回 {"decisions":[]}。
    2. 一件可以独立完成、改期或删除的事就是一个 decision。并列动作必须拆开，不能概括成一条；最多返回 5 条，不要重复。
    3. 同一个时间修饰多个并列动作时，每一条都填写同一个绝对 dueAt。例如“今天做 A 并做 B”要返回两个 create，日期相同。
    4. 一段输入可以同时修改旧待办和新建另一件事；不要因为只能选一个动作而丢掉其余内容。
    5. 是否是待办由语义决定，不依赖固定场景词。像“明天八点赶回合肥”“明天改两个图”都是待办。
    6. OCR 里的手机时间、聊天时间戳、页面发布日期、广告有效期本身不是待办。
    7. 餐饮页面出现“配餐中/待取餐/可取餐”和订单号时，识别为 foodPickup；订单号可作为 code。
    8. 只有说话人自己的计划、对自己的要求、已下的订单/包裹状态才算。转述别人一律忽略。
    9. todo 只能填清单里已有编号；真实 ID 不可见，也不允许猜。create 的 todo 必须为 null。
    10. 输入已把相对时间转换成绝对时间；绝对时间是唯一依据，禁止自行重算“明天/昨天/周五”。标成“界面时间锚点”的不是任务。
    10a. 只有日期、没有具体钟点时，按语境定钟点，不要一律填 23:59：
        - 原文写了“上午/早上/中午/下午/傍晚/晚上”，就用它对应的钟点（上午 09:00、中午 12:00、下午 14:00、傍晚 18:00、晚上 19:00）；
        - 没有任何时段词时，要交的东西（截止、提交、报名、缴费）用当天 23:59，要去的场合（开会、典礼、见面、上课、体检）用当天 09:00。
        判断依据只能是原文里出现的词，不要凭空假设一个开始时间。
    11. evidence 必须逐字复制自“原始文字”，并且只支撑当前这一项；不能概括、不能改写。
    12. code 必须逐字来自原文，不能纠正或补位。无法确定就 null。
    13. 取消、完成相关动作 needsConfirmation 必须 true。
    14. 语义明确且证据直接时 needsConfirmation=false；有指代、主体不清、OCR歧义或时间歧义时 true。
    15. 拿不准是不是任务就不要加入 decisions。误建一条比漏掉一条更糟。
    16. 如果文字讲的是清单里已有的那件事，不要因为“已经有了”就忽略：时间变了用 reschedule，说法/范围变了用 rename，说做完了用 complete。rename 可以同时带新的 dueAt，不要把同一条旧待办拆成两次修改。
    """
    /// 工具版的系统提示词。
    ///
    /// 和上面那版 JSON 的区别不只是输出形式：这一版**不再预先把时间算好塞给
    /// 模型**。旧做法是本地先把"明天早上七点"换算成绝对时间写进文本，再规定
    /// "绝对时间是唯一依据、禁止自行重算"——于是本地每一次读错都变成模型无法
    /// 纠正的事实。实测"今天下午八点开会，明天早上七点买咖啡"曾被换算成
    /// 「明天 下午八点」和「今天 早上七点」，两个时间在子句之间交叉配对全错，
    /// 模型只能照着错的答。
    ///
    /// 改成工具之后，分工换了个方向：**哪半句时间属于哪件事**由模型判断（它
    /// 懂语义），**那半句是几点**由本地算（日期算术是模型最容易错的地方）。
    public static let toolSystem = """
    你是 Mnemo 的待办理解器。输入可能是用户复制的普通文字，也可能是截图 OCR，\
    其中会混入状态栏时间、聊天时间戳、广告、商品信息和历史对话。你要理解语义，\
    判断它是否表达用户未来要做的事，或者是否在修改现有待办，然后**调用工具**\
    把结论表达出来。

    ── 时间的硬性规定（最重要，违反即视为错误）──
    1. 开始判断之前，**必须先调用 current_time** 拿到今天是几号、现在几点、星期几。
       不许凭空假设日期。
    2. 任何待办只要带时间，**必须调用 resolve_time 换算**，把 dueAt 填成它返回的
       absolute 值。**严禁自己写 ISO 时间字符串**，也严禁自己推算"明天是几号"。
    3. 每件事**分别**调用一次 resolve_time，只传属于它自己的那半句时间。
       "今天下午八点开会，明天早上七点买咖啡"要调用两次：一次传「今天下午八点」，
       一次传「明天早上七点」。绝不能把两件事的时间合起来问，也不能把一件事的
       日期配到另一件事的钟点上。
    4. resolve_time 返回 resolved=false 说明那句话里没有可换算的时间，
       这条待办就不填 dueAt，不要硬编一个。

    ── 判断规则 ──
    5. 一件可以独立完成、改期或删除的事就调用一次 create_todo。并列动作必须拆开，
       不能概括成一条；一轮最多 5 条。
    6. 一段输入可以同时修改旧待办和新建另一件事，不要因为只能做一件而丢掉其余内容。
    7. 是否是待办由语义决定，不依赖固定场景词。"明天八点赶回合肥""明天改两个图"都是待办。
    8. 手机状态栏时间、聊天时间戳、页面发布日期、广告有效期本身不是待办。
    9. 只有说话人自己的计划、对自己的要求、已下的订单/包裹状态才算。转述别人一律忽略。
    10. todo 参数只能填清单里已有的编号，不许猜，也不许编。
    11. evidence 必须逐字复制自原文，并且只支撑当前这一条；不能概括、不能改写。
    12. code 必须逐字来自原文，不能纠正或补位。无法确定就不填。
    13. 取消、完成 needsConfirmation 必须 true；有指代、主体不清、OCR 歧义时也要 true。
    14. 拿不准是不是任务就不要调用任何 create/reschedule/complete/cancel。
        误建一条比漏掉一条更糟。
    15. 只有日期没有钟点时，交东西（截止、提交、报名、缴费）用当天 23:59，
        去场合（开会、典礼、见面、上课、体检）用当天 09:00；原文写了"上午/早上/
        中午/下午/傍晚/晚上"就按它对应的钟点。这些都通过 resolve_time 表达，
        把带时段词的原文整句传进去。

    判断完就停下，不要再输出解释性文字。什么待办都没有时，不调用任何工具，
    直接回一句"无"。
    """

    /// few-shot 例子。
    ///
    /// 覆盖并列任务拆分、同批新建与修改、改期指代、取消、完成、第三方转述，
    /// 以及只有界面时间戳的噪声。重点是教模型输出独立动作，而不是堆场景词。
    public static let examples = """
    ── 示例 ──
    清单：
    1. 组会（截止 2026-09-02T15:00:00+08:00）
    2. 提交开题报告（截止 2026-09-05T23:59:00+08:00）

    归一化文字：「[绝对时间：2026-09-03（未给具体钟点）]要看完项目并写完论文」
    原始文字：「今天要看完项目并写完论文」
    {"decisions":[
      {"action":"create","todo":null,"title":"看完项目","dueAt":"2026-09-03T23:59:00+08:00","kind":"deadline","service":null,"code":null,"evidence":"看完项目","needsConfirmation":false,"reason":"明确的个人任务"},
      {"action":"create","todo":null,"title":"写完论文","dueAt":"2026-09-03T23:59:00+08:00","kind":"deadline","service":null,"code":null,"evidence":"写完论文","needsConfirmation":false,"reason":"明确的个人任务"}
    ]}

    归一化文字：「[绝对时间：2026-09-03T20:00:00+08:00]我要赶回合肥」
    原始文字：「明天晚上八点我要赶回合肥」
    {"decisions":[{"action":"create","todo":null,"title":"赶回合肥","dueAt":"2026-09-03T20:00:00+08:00","kind":"travel","service":null,"code":null,"evidence":"明天晚上八点我要赶回合肥","needsConfirmation":false,"reason":"明确的个人出行计划"}]}

    文字：「配餐中… 订单号 35341 麦当劳承德奥体中心餐厅」
    {"decisions":[{"action":"create","todo":null,"title":"麦当劳取餐 35341","dueAt":null,"kind":"foodPickup","service":"麦当劳","code":"35341","evidence":"配餐中… 订单号 35341","needsConfirmation":false,"reason":"已下单且正在配餐"}]}

    文字：「组会改到四点，另外今天写完论文」
    {"decisions":[
      {"action":"reschedule","todo":1,"title":null,"dueAt":"2026-09-02T16:00:00+08:00","kind":"appointment","service":null,"code":null,"evidence":"组会改到四点","needsConfirmation":false,"reason":"明确改期"},
      {"action":"create","todo":null,"title":"写完论文","dueAt":"2026-09-02T23:59:00+08:00","kind":"deadline","service":null,"code":null,"evidence":"今天写完论文","needsConfirmation":false,"reason":"同时提出另一件任务"}
    ]}

    文字：「你还差多少？ [绝对时间：2026-09-03（未给具体钟点）]应该就搞好了，改两个图」
    （清单里第 2 条是同一件事的粗略版本）
    {"decisions":[{"action":"rename","todo":2,"title":"改两个图","dueAt":"2026-09-03T23:59:00+08:00","kind":"deadline","service":null,"code":null,"evidence":"应该就搞好了，改两个图","needsConfirmation":true,"reason":"同一件事有了更具体的范围和时间"}]}

    文字：「那个报告的事往后挪挪，下周三吧」
    {"decisions":[{"action":"reschedule","todo":2,"title":null,"dueAt":"2026-09-09T23:59:00+08:00","kind":"deadline","service":null,"code":null,"evidence":"那个报告的事往后挪挪，下周三吧","needsConfirmation":true,"reason":"有指代，需要确认"}]}

    文字：「这周组会不开了」
    {"decisions":[{"action":"cancel","todo":1,"title":null,"dueAt":null,"kind":"appointment","service":null,"code":null,"evidence":"这周组会不开了","needsConfirmation":true,"reason":"明确取消本次组会"}]}

    文字：「开题报告我已经交上去了」
    {"decisions":[{"action":"complete","todo":2,"title":null,"dueAt":null,"kind":"deadline","service":null,"code":null,"evidence":"开题报告我已经交上去了","needsConfirmation":true,"reason":"本人说明已经提交"}]}

    文字：「组会改期吧」
    {"decisions":[]}

    文字：「听说隔壁组的开题报告交了」
    {"decisions":[]}

    文字：「星期五 23:35」
    {"decisions":[]}
    """
    /// 工具版的用户消息。
    ///
    /// 只给**原文**和现有清单，不再附本地算好的绝对时间——时间由模型自己
    /// 调 current_time / resolve_time 取。
    public static func toolUserMessage(
        text: String,
        candidates: [TodoRevisionCandidate],
        formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    ) -> String {
        var lines: [String] = ["现有待办清单："]
        if candidates.isEmpty {
            lines.append("（空）")
        } else {
            for candidate in candidates {
                var line = "\(candidate.index). \(candidate.title)"
                if let dueAt = candidate.dueAt {
                    line += "（截止 \(formatter.string(from: dueAt))）"
                }
                if let context = candidate.sourceContext, !context.isEmpty {
                    line += "\n   来源摘录：\(context)"
                }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("原始文字：")
        lines.append(text)
        return lines.joined(separator: "\n")
    }

    /// 把模型的一次工具调用翻译成本地的决策。
    ///
    /// 只做翻译和形状校验；"这条能不能落库"仍由调用方按原文逐字验证
    /// evidence、按编号对回候选之后决定——模型能提议，不能直接写库。
    public static func decision(
        fromToolCall call: AIToolCall,
        formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    ) -> TodoRevisionDecision? {
        let arguments = call.arguments()
        func string(_ key: String) -> String? {
            guard let value = (arguments[key] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !value.isEmpty else { return nil }
            return value
        }
        func date(_ key: String) -> Date? {
            guard let raw = string(key) else { return nil }
            if let value = formatter.date(from: raw) { return value }
            // 有的模型会带上小数秒。多试一次，别为一个格式差异丢掉整条待办。
            let lenient = ISO8601DateFormatter()
            lenient.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return lenient.date(from: raw)
        }
        let index = (arguments["todo"] as? NSNumber)?.intValue
            ?? (arguments["todo"] as? Int)
        let kind = string("kind").flatMap(TodoRevisionDecision.Kind.init(rawValue:)) ?? .general
        let needsConfirmation = (arguments["needsConfirmation"] as? Bool) ?? true
        let evidence = string("evidence")
        let reason = string("reason") ?? ""

        switch call.name {
        case TodoTools.createTodo.name:
            guard let title = string("title"), evidence != nil else { return nil }
            return TodoRevisionDecision(
                action: .create, index: nil, title: title, dueAt: date("dueAt"),
                reason: reason, kind: kind, service: string("service"),
                code: string("code"), evidence: evidence,
                needsConfirmation: needsConfirmation
            )
        case TodoTools.rescheduleTodo.name:
            guard let index, let dueAt = date("dueAt"), evidence != nil else { return nil }
            return TodoRevisionDecision(
                action: .reschedule, index: index, title: nil, dueAt: dueAt,
                reason: reason, kind: kind, evidence: evidence,
                needsConfirmation: needsConfirmation
            )
        case TodoTools.renameTodo.name:
            guard let index, let title = string("title"), evidence != nil else { return nil }
            return TodoRevisionDecision(
                action: .rename, index: index, title: title, dueAt: date("dueAt"),
                reason: reason, kind: kind, evidence: evidence,
                needsConfirmation: needsConfirmation
            )
        case TodoTools.completeTodo.name:
            guard let index, evidence != nil else { return nil }
            return TodoRevisionDecision(
                action: .complete, index: index, reason: reason, kind: kind,
                evidence: evidence, needsConfirmation: true
            )
        case TodoTools.cancelTodo.name:
            guard let index, evidence != nil else { return nil }
            return TodoRevisionDecision(
                action: .cancel, index: index, reason: reason, kind: kind,
                evidence: evidence, needsConfirmation: true
            )
        default:
            return nil
        }
    }

    /// 拼出这一次的用户消息。
    ///
    /// 现有待办**每次都带上**：模型判断"这是不是同一件事"必须看得到清单，
    /// 否则它只能一律 create，聊天里改一次时间就多一条重复待办。
    public static func userMessage(
        text: String,
        originalText: String? = nil,
        candidates: [TodoRevisionCandidate],
        now: Date,
        formatter: ISO8601DateFormatter = ISO8601DateFormatter()
    ) -> String {
        var lines: [String] = []
        lines.append("当前时间：\(formatter.string(from: now))")
        lines.append("")
        lines.append("现有待办清单：")
        if candidates.isEmpty {
            lines.append("（空）")
        } else {
            for candidate in candidates {
                var line = "\(candidate.index). \(candidate.title)"
                if let dueAt = candidate.dueAt {
                    line += "（截止 \(formatter.string(from: dueAt))）"
                }
                // 源摘录只在那条 Pin 还在时才有。它帮模型确认"清单里这条说的
                // 是不是同一件事"，比只看一个被截断过的标题可靠得多——
                // 标题是当初做减法抠出来的，信息本来就有损。
                if let context = candidate.sourceContext, !context.isEmpty {
                    line += "\n   来源摘录：\(context.prefix(200))"
                }
                lines.append(line)
            }
        }
        lines.append("")
        lines.append("本地已归一化的时间上下文（绝对时间是唯一时间依据，不要自行重算相对时间）：")
        lines.append(String(text.prefix(1_800)))
        if let originalText, originalText != text {
            lines.append("")
            lines.append("原始文字（evidence 与 code 只能逐字复制自这里）：")
            lines.append(String(originalText.prefix(1_800)))
        }
        return lines.joined(separator: "\n")
    }

    /// 解析模型输出，并把每一项独立钉死在给过的编号范围里。
    ///
    /// 新协议是 `{"decisions":[...]}`；同时接受旧版单对象，避免模型缓存或
    /// 兼容供应商偶尔沿用上一版格式。无效的一项只丢掉自己，不会拖累同批里
    /// 其余合法任务。最终再做本地去重和数量上限。
    public static func decisions(
        from text: String,
        candidateCount: Int
    ) throws -> [TodoRevisionDecision] {
        struct Envelope: Decodable { var decisions: [DecisionPayload] }

        let data = try AIStructuredOutput.objectData(from: text)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let decoder = JSONDecoder()
        let payloads: [DecisionPayload]
        if object?["decisions"] != nil {
            payloads = try decoder.decode(Envelope.self, from: data).decisions
        } else {
            // 旧版只返回一个 decision。action 缺失说明它不是任何已知协议，
            // 让上层走一次 JSON 修复，而不是把格式故障误记成“没有待办”。
            let payload = try decoder.decode(DecisionPayload.self, from: data)
            guard payload.action != nil else { throw AIExecutionError.malformedStructuredOutput }
            payloads = [payload]
        }

        var result: [TodoRevisionDecision] = []
        var seen: Set<String> = []
        var touchedCandidateIndices: Set<Int> = []
        for payload in payloads {
            let value = validatedDecision(from: payload, candidateCount: candidateCount)
            guard value.action != .none else { continue }
            // 同一条旧待办在一批里最多接受一个动作，按模型原始顺序第一条优先。
            // rename 已能携带 dueAt，因此“改名 + 改期”也无需拆成两次写入。
            if let index = value.index,
               !touchedCandidateIndices.insert(index).inserted { continue }
            let key = deduplicationKey(for: value)
            guard seen.insert(key).inserted else { continue }
            result.append(value)
            if result.count == maximumDecisionCount { break }
        }
        return result
    }

    /// 旧的单项 API 保留给已有调用方和回归测试。空数组等价于 `.none`。
    public static func decision(
        from text: String,
        candidateCount: Int
    ) throws -> TodoRevisionDecision {
        try decisions(from: text, candidateCount: candidateCount).first
            ?? TodoRevisionDecision(action: .none)
    }

    private struct DecisionPayload: Codable {
        var action: String?
        var todo: Int?
        var title: String?
        var dueAt: String?
        var reason: String?
        var kind: String?
        var service: String?
        var code: String?
        var evidence: String?
        var needsConfirmation: Bool?
    }

    private static func validatedDecision(
        from payload: DecisionPayload,
        candidateCount: Int
    ) -> TodoRevisionDecision {
        guard let rawAction = payload.action,
              let action = TodoRevisionDecision.Action(
                rawValue: rawAction.trimmingCharacters(in: .whitespaces).lowercased()
              ) else {
            return TodoRevisionDecision(action: .none)
        }

        let reason = String((payload.reason ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        let title = payload.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dueAt = payload.dueAt.flatMap(parseDate(_:))
        let kind = payload.kind.flatMap(TodoRevisionDecision.Kind.init(rawValue:)) ?? .general
        let service = payload.service?.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = payload.code?.trimmingCharacters(in: .whitespacesAndNewlines)
        let evidence = payload.evidence?.trimmingCharacters(in: .whitespacesAndNewlines)
        let needsConfirmation = payload.needsConfirmation ?? true

        func make(
            action: TodoRevisionDecision.Action,
            index: Int? = nil,
            title: String? = nil
        ) -> TodoRevisionDecision {
            TodoRevisionDecision(
                action: action,
                index: index,
                title: title,
                dueAt: dueAt,
                reason: reason,
                kind: kind,
                service: service.map { String($0.prefix(24)) },
                code: code.map { String($0.prefix(32)) },
                evidence: evidence.map { String($0.prefix(160)) },
                needsConfirmation: needsConfirmation
            )
        }

        switch action {
        case .none:
            return make(action: .none)
        case .create:
            guard let title, !title.isEmpty else { return TodoRevisionDecision(action: .none) }
            return make(action: .create, title: String(title.prefix(30)))
        case .reschedule, .rename, .complete, .cancel:
            guard let index = payload.todo, index >= 1, index <= candidateCount else {
                return TodoRevisionDecision(action: .none)
            }
            if action == .reschedule, dueAt == nil { return TodoRevisionDecision(action: .none) }
            if action == .rename, title?.isEmpty != false { return TodoRevisionDecision(action: .none) }
            return make(
                action: action,
                index: index,
                title: title.map { String($0.prefix(30)) }
            )
        }
    }

    private static func deduplicationKey(for decision: TodoRevisionDecision) -> String {
        let title = (decision.title ?? "")
            .lowercased()
            .replacingOccurrences(of: #"[\s\p{P}\p{S}]+"#, with: "", options: .regularExpression)
        let code = (decision.code ?? "").lowercased()
        let due = decision.dueAt.map { String(Int($0.timeIntervalSince1970 / 300)) } ?? "-"
        return [decision.action.rawValue, String(decision.index ?? 0), title, due, code]
            .joined(separator: "|")
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "null" else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let value = withFraction.date(from: trimmed) { return value }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
