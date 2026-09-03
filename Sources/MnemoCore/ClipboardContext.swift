import Foundation

/// 一次剪贴板事件的上下文。场景识别由它触发，而不是由"打开某个 Pin"触发。
public struct ClipboardContextEvent: Sendable, Equatable {
    public var fingerprint: String
    public var kind: ItemKind
    /// 文本内容；图片则是 OCR 结果。拿不到就是空串。
    public var text: String
    public var sourceApplication: String?
    public var capturedAt: Date

    public init(
        fingerprint: String,
        kind: ItemKind,
        text: String,
        sourceApplication: String? = nil,
        capturedAt: Date = .now
    ) {
        self.fingerprint = fingerprint
        self.kind = kind
        self.text = text
        self.sourceApplication = sourceApplication
        self.capturedAt = capturedAt
    }
}

/// 从剪贴板内容解出的检索意图。
public struct ContextIntent: Sendable, Equatable, Codable {
    public enum Field: String, Sendable, Codable, CaseIterable {
        case paper, resume, contract, image, handbook
        case invoice, address
        case taxNumber, email, phone, wechatID, trackingNumber
        case bankAccount, idNumber
        case meetingLink, repositoryLink

        /// 敏感字段一律只推荐，不自动写回。
        ///
        /// 银行账号和证件号即便本地唯一确定，也不该在用户没看清的情况下被
        /// 塞进剪贴板——粘错地方的代价太大。
        public var isSensitive: Bool { self == .bankAccount || self == .idNumber }
    }

    public var fields: Set<Field>
    public var preferredKinds: Set<ItemKind>
    public var semanticQuery: String
    /// 能唯一定位目标的确定性证据：精确文件名、编号、DOI、字段值。
    /// 空数组表示"只有语义相似"，此时**绝不允许**自动写回剪贴板。
    public var deterministicEvidence: [String]

    public init(
        fields: Set<Field> = [],
        preferredKinds: Set<ItemKind> = [],
        semanticQuery: String = "",
        deterministicEvidence: [String] = []
    ) {
        self.fields = fields
        self.preferredKinds = preferredKinds
        self.semanticQuery = semanticQuery
        self.deterministicEvidence = deterministicEvidence
    }

    public var isEmpty: Bool {
        fields.isEmpty && deterministicEvidence.isEmpty
            && semanticQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 一个真实存在的候选 Pin。`itemID` 必须来自本地检索，模型不能凭空造。
public struct ContextualCandidate: Sendable, Equatable, Identifiable {
    public var id: UUID { itemID }
    public var itemID: UUID
    public var title: String
    public var kind: ItemKind
    public var localScore: Double
    /// 本地可验证命中的确定性证据。空 = 只有语义相似。
    public var evidence: [String]

    public init(
        itemID: UUID,
        title: String,
        kind: ItemKind,
        localScore: Double,
        evidence: [String] = []
    ) {
        self.itemID = itemID
        self.title = title
        self.kind = kind
        self.localScore = localScore
        self.evidence = evidence
    }
}

/// 本地粗筛：明显不值得走后续管线的内容直接丢掉，不烧 token、不播动效。
public enum ClipboardContextGate {
    /// 太短的内容不承载"我需要库里的什么"这种意图。
    public static let minimumTextLength = 6
    /// 太长的多半是整段正文被复制，不是一句诉求。
    public static let maximumTextLength = 2_000

    public static func shouldConsider(_ event: ClipboardContextEvent) -> Bool {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= minimumTextLength, text.count <= maximumTextLength else { return false }
        // 纯 URL 是"我刚拷了个链接"，不是"我在找库里的东西"。
        if let url = URL(string: text), url.scheme != nil, !text.contains(" ") { return false }
        return true
    }
}

/// 同一件事只处理一次的去重键。
///
/// 内容、来源、库内容版本、路由任何一项变了才值得重新跑；否则命中缓存，
/// 不再调用模型，也不再重复播放动画。
public struct ContextualProcessingKey: Hashable, Sendable {
    public var contentFingerprint: String
    public var sourceContext: String
    public var libraryVersion: String
    public var route: String

    public init(
        contentFingerprint: String,
        sourceContext: String,
        libraryVersion: String,
        route: String
    ) {
        self.contentFingerprint = contentFingerprint
        self.sourceContext = sourceContext
        self.libraryVersion = libraryVersion
        self.route = route
    }
}

/// 自动写回剪贴板的资格判定。
///
/// 这是整条管线唯一允许"不问用户就动他剪贴板"的地方，所以规则写死在纯函数里：
/// 只有**本地可验证的证据唯一确定一个目标**时才放行。模型的置信度不是授权——
/// 它只能排序和解释，不能把 false 变成 true。
public enum ContextualAutoCopy {
    public static func uniqueTarget(
        candidates: [ContextualCandidate],
        intent: ContextIntent
    ) -> UUID? {
        // 只有语义相似（意图里没有确定性证据）时一律只推荐，不自动执行。
        guard !intent.deterministicEvidence.isEmpty else { return nil }

        let wanted = Set(intent.deterministicEvidence.map { $0.lowercased() })
        let matched = candidates.filter { candidate in
            !Set(candidate.evidence.map { $0.lowercased() }).isDisjoint(with: wanted)
        }
        // 命中多于一个就是有歧义，交给用户选。
        guard matched.count == 1, let target = matched.first else { return nil }
        return target.itemID
    }

    /// 请求点名了一种类型，而库里这种类型**只有一个**。
    ///
    /// 这仍然是"由本地事实唯一确定"，不是"语义分数高"：用户要论文，库里
    /// 统共就一篇 PDF，那它不可能是别的。有两篇就退回去让用户选。
    public static func uniqueByKind(
        candidates: [ContextualCandidate],
        intent: ContextIntent
    ) -> UUID? {
        guard !intent.preferredKinds.isEmpty else { return nil }
        let matching = candidates.filter { intent.preferredKinds.contains($0.kind) }
        guard matching.count == 1, let target = matching.first else { return nil }
        return target.itemID
    }

    /// 字段型意图的自动写回：用户要的是某个字段的值，而库里恰好只有一个
    /// 条目能给出这个值。
    ///
    /// 和标识型的区别在于证据来自哪一边：标识型的证据在**请求里**（"csa-ud"），
    /// 字段型的证据在**库里**（只有一条 Pin 记着税号）。两边都要求唯一。
    public static func uniqueFieldValue(
        field: ContextIntent.Field,
        texts: [(itemID: UUID, text: String)]
    ) -> (itemID: UUID, value: String)? {
        let extracted = texts.compactMap { entry -> (UUID, String)? in
            ContextFieldExtractor.value(of: field, in: entry.text)
                .map { (entry.itemID, $0) }
        }
        // 同一个值出现在多条 Pin 里（重复保存）仍然算唯一——用户拿到的是同一串。
        let distinct = Set(extracted.map(\.1))
        guard distinct.count == 1, let first = extracted.first else { return nil }
        return (first.0, first.1)
    }
}

/// 从一段文本里抽出某个字段的确定性值。
///
/// 自动写回的内容必须精确到字段本身：用户要的是税号那一串，不是整段包含
/// 抬头、开户行、地址的文本。抽不出来就返回 nil——宁可只推荐，不猜。
public enum ContextFieldExtractor {
    public static func value(of field: ContextIntent.Field, in text: String) -> String? {
        switch field {
        case .taxNumber, .idNumber:
            // 统一社会信用代码 18 位；旧的纳税人识别号 15/17/18/20 位。
            firstMatch(
                #"(?:税号|纳税人识别号|统一社会信用代码|身份证号?)\s*[:：]?\s*([0-9A-Za-z]{15,20})"#,
                in: text
            )
        case .email:
            firstMatch(#"([A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})"#, in: text)
        case .phone:
            firstMatch(#"(?:电话|手机号?)\s*[:：]?\s*((?:\+?86[- ]?)?1[3-9]\d{9})"#, in: text)
                ?? firstMatch(#"\b(1[3-9]\d{9})\b"#, in: text)
        case .bankAccount:
            // "开户行：招商银行杭州分行 6225…"——线索词和号码之间常常隔着行名，
            // 所以允许中间有一段非数字文本。
            firstMatch(
                #"(?:开户行|银行账号|对公账户|收款账号)[^0-9\n]{0,40}([0-9]{10,25})"#,
                in: text
            )
        case .wechatID:
            firstMatch(#"(?:微信号?|wechat)\s*[:：]?\s*([A-Za-z][A-Za-z0-9_-]{5,19})"#, in: text)
        case .trackingNumber:
            firstMatch(#"(?:快递单号|运单号|物流单号|快递号)\s*[:：]?\s*([0-9A-Za-z]{8,25})"#, in: text)
        case .invoice, .paper, .resume, .contract, .image, .handbook, .address,
             .meetingLink, .repositoryLink:
            // 发票抬头是一整段、论文是一个文件、会议链接整条就是值本身——
            // 都不该被切成"某个字段"。
            nil
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 要不要把一次复制变成一条推荐。
///
/// 早先这件事由词表决定："含不含论文/截图/手册这些词"。词表是封闭的，
/// 于是每次换一种说法就整条链静默——"pi agent 网址给我"里既没有场景词，
/// 也没有带数字或连字符的标识，判空之后什么都不会发生。
///
/// 现在换成两级，都不依赖词表：
///
/// 1. **形态**：一句短话才看，成段正文不看（避免每复制一段文字都去检索）；
/// 2. **证据**：本地召回真的命中了库里的东西才显示。
///
/// 换句话说，决定权从"这句话像不像请求"移到了"库里到底有没有对得上的东西"。
/// 前者要穷举说法，后者天然泛化——用户怎么说都行，只要东西真的在库里。
public enum ContextRetrievalGate {
    /// 本地命中分要到这个程度才算"真的对上了"。
    ///
    /// 参照 `LexicalMatch`：整句原样出现是 0.6，标题/标签命中是 0.5 以上，
    /// 零散的二字组命中远低于此。定在 0.5 能挡掉"碰巧有个共同的词"。
    public static let evidenceThreshold: Float = 0.5

    /// 值不值得做一次本地召回。纯形态判断，不花任何模型调用。
    public static func shouldRecall(_ event: ClipboardContextEvent) -> Bool {
        ContextIntentParser.isLocalRetrievalQuery(event)
            || ContextIntentParser.looksLikeShortPhrase(event)
    }

    /// 召回之后要不要显示。明确的索取（"帮我找…"）即使弱命中也照常给；
    /// 只是碰巧复制了一句短话时，必须有像样的本地证据才打扰用户。
    public static func shouldSuggest(
        bestLocalScore: Float,
        isExplicitRequest: Bool
    ) -> Bool {
        isExplicitRequest || bestLocalScore >= evidenceThreshold
    }
}

/// 从剪贴板文本里解出意图。纯本地、确定性，不调用模型。
///
/// 模型只在这一步之后决定"值不值得检索"，以及最后在候选内排序；意图里的
/// 确定性证据必须来自这里，否则自动写回的闸门就等于交给了模型。
public enum ContextIntentParser {
    /// 场景线索表。左边是字段与它偏好的条目类型，右边是触发词。
    /// 全部确定性匹配，不调用模型——模型只在这之后决定"值不值得检索"。
    private static let cues: [(field: ContextIntent.Field, kinds: Set<ItemKind>, words: [String])] = [
        (.paper, [.pdf], ["论文", "paper", "文献", "预印本", "preprint"]),
        (.resume, [.pdf], ["简历", "resume", " cv"]),
        (.contract, [.pdf], ["合同", "协议", "contract", "agreement"]),
        // 手册、教程、课件这类"资料"过去一个都不在表里：意图判空后连模型都
        // 不会被问到，于是"研究生数学建模的手册"永远不触发。
        (.handbook, [.pdf, .file], [
            "手册", "教程", "指南", "讲义", "课件", "笔记", "说明书", "文档",
            "题库", "真题", "模板", "幻灯片", "ppt", "slides", "handbook",
            "manual", "guide", "tutorial", "cheatsheet",
        ]),
        (.image, [.image], ContentTypeVocabulary.image),
        (.invoice, [], ["发票", "开票", "抬头", "invoice"]),
        (.address, [], ["收件地址", "邮寄地址", "收货地址", "寄到"]),
        (.taxNumber, [], ["税号", "纳税人识别号", "统一社会信用代码"]),
        (.email, [], ["邮箱", "email", "e-mail"]),
        (.phone, [], ["电话", "手机号", "联系方式"]),
        (.wechatID, [], ["微信号", "wechat", "加个微信"]),
        (.trackingNumber, [], ["快递单号", "运单号", "物流单号", "快递号"]),
        (.bankAccount, [], ["开户行", "银行账号", "对公账户", "收款账号"]),
        (.idNumber, [], ["身份证", "证件号"]),
        (.meetingLink, [.link], ["会议链接", "腾讯会议", "zoom", "会议号"]),
        (.repositoryLink, [.link], ["仓库", "github", "repo", "项目地址"]),
    ]

    private static let invoiceCues = ["发票", "开票", "抬头", "invoice"]
    private static let taxCues = ["税号", "纳税人识别号", "统一社会信用代码"]
    private static let bankCues = ["开户行", "银行账号", "对公账户"]
    private static let addressCues = ["地址", "收件地址", "邮寄地址"]

    public static func parse(_ event: ClipboardContextEvent) -> ContextIntent {
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = text.lowercased()

        var fields: Set<ContextIntent.Field> = []
        var kinds: Set<ItemKind> = []
        for cue in cues where cue.words.contains(where: { lower.contains($0.lowercased()) }) {
            fields.insert(cue.field)
            kinds.formUnion(cue.kinds)
        }

        return ContextIntent(
            fields: fields,
            preferredKinds: kinds,
            semanticQuery: String(text.prefix(300)),
            deterministicEvidence: identifierTokens(in: text)
        )
    }

    /// 抽出像"标识"的词：带连字符或数字的字母数字串。
    ///
    /// `csa-ud`、`iwqos2026`、`10.1109/XXX` 这种能唯一定位一篇论文；而"论文"
    /// "提交"这类普通词不能，否则任何一句话都会被判成有确定性证据。
    public static func identifierTokens(in text: String) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: "，。、；：？！,.;:?!\"'（）()【】[]{}《》<>"))
        var seen: Set<String> = []
        var tokens: [String] = []
        for raw in text.components(separatedBy: separators) {
            let token = raw.trimmingCharacters(in: CharacterSet(charactersIn: "-_/"))
            guard token.count >= 3, token.count <= 64 else { continue }
            let hasLetter = token.contains { $0.isLetter && $0.isASCII }
            let hasDigit = token.contains { $0.isNumber }
            let hasJoiner = token.contains("-") || token.contains("_") || token.contains(".")
            // 必须同时有字母，且要么带数字要么带连接符——纯单词不算标识。
            guard hasLetter, hasDigit || hasJoiner else { continue }
            let normalized = token.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            tokens.append(token)
        }
        return tokens
    }

    /// 这段话读起来是不是在"要东西"。
    ///
    /// 场景词（论文、税号）说明**要什么**，请求词说明**这是一个诉求**而不是
    /// 摘抄。两者同时成立时不必再问模型——模型对同一句话的判断并不稳定，
    /// 同一段文字上一次判 true、下一次判 false，用户看到的就是"时灵时不灵"。
    public static func isExplicitRequest(_ text: String) -> Bool {
        let lower = text.lowercased()
        return requestCues.contains { lower.contains($0) }
    }

    private static let requestCues = [
        "发我", "发一下", "发过来", "给我", "帮我", "麻烦", "请提交", "提交一下",
        "需要", "我要", "想要", "要一份", "要一个", "要一张", "找一下", "搜索", "搜一下", "查一下",
        "找一个", "找一张", "给一张", "发一张", "发个", "是多少", "多少钱", "发份", "来一份",
        "send me", "share the", "can you send", "need the",
    ]

    /// 这次复制是不是"只是用来找库里东西的"。
    ///
    /// 场景词说明要什么，请求词说明这是一个诉求。两者同时成立时这段文字就是
    /// 一句查询，不该被当成收藏落进最近五条剪贴板轨道——收纳器和上下文管线
    /// 必须用同一个判据，否则会出现"顶部推荐了，但请求本身也被记了一条"。
    public static func isRetrievalOnlyRequest(_ event: ClipboardContextEvent) -> Bool {
        guard ClipboardContextGate.shouldConsider(event) else { return false }
        // 带日期或钟点的句子更可能是在安排将来的动作。即使同时出现“需要”
        // “找一下”这类多义词，也不能以“纯检索”为由删掉这次复制；误留一条
        // 临时内容远比吞掉任务安全。
        guard ChineseDateParser.firstDate(in: event.text) == nil else { return false }
        let intent = parse(event)
        // 场景词说明"要什么"；没有场景词但点名了一个具体标识
        // （"带有 test-time 的图给我" 里的 test-time）同样是明确的索取。
        guard !intent.fields.isEmpty || !intent.deterministicEvidence.isEmpty else { return false }
        return isExplicitRequest(event.text)
    }

    /// 本地就足以判定"值得尝试检索"：带请求动词的句子，或点名类型的短名词短语。
    ///
    /// 这里只负责检索路由，不能直接拿它决定是否丢弃一次复制。短名词短语只是
    /// “可能在找东西”，并不是删除原文的充分证据；被动捕获使用下面更保守的
    /// `shouldSuppressPassiveCapture`。
    public static func isLocalRetrievalQuery(_ event: ClipboardContextEvent) -> Bool {
        isRetrievalOnlyRequest(event) || looksLikeRetrievalPhrase(event)
    }

    /// 被动捕获时能不能确定这句话只是一条检索命令，因此无需留进临时轨道。
    ///
    /// 检索路由允许宽松召回，捕获抑制则必须保守：误留一条查询最多占用一个
    /// 临时位置，误删一句任务却会让用户以为 Ctrl-C 没生效。明确索取仍可抑制；
    /// 无请求动词的名词短语只有在排除了带绝对/相对时间的行动表达后才抑制。
    public static func shouldSuppressPassiveCapture(_ event: ClipboardContextEvent) -> Bool {
        // 只有原文自己带明确索取语气时才有资格不入库。`looksLikeRetrievalPhrase`
        // 只是一个宽松的召回信号，不能承担删除复制内容的职责。
        isRetrievalOnlyRequest(event)
    }

    /// 形态上像不像"一句短短的话"，而不是一段正文。
    ///
    /// 这是唯一还依赖形态的闸门，而且它只回答"要不要看一眼"，不回答"这是不是
    /// 请求"。后者靠词表永远追不完：手册、指南、网址、课件……每加一个词就等下
    /// 一个词。真正的判据在 `ContextRetrievalGate`：库里有没有东西真的对得上。
    public static func looksLikeShortPhrase(_ event: ClipboardContextEvent) -> Bool {
        guard ClipboardContextGate.shouldConsider(event) else { return false }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"), text.count <= 26 else { return false }
        // 句中还有句号、分号这类断句，说明是成段的话而不是一句诉求。
        // 结尾的标点不算——"帮我找一下那份手册。"仍然是诉求。
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "。！？；.!?;"))
        return !body.contains(where: { "。！？；".contains($0) })
    }

    /// 复制的是一句短短的"要什么"，虽然没写"帮我找"。
    ///
    /// "央视关于牛来报道的图片"没有任何请求动词，靠动词表判不出来，交给模型
    /// 路由又常被判成普通摘抄。但它形态很清楚：一行、很短、点名了类型、还带着
    /// 一个具体主题。这三条同时成立时按检索处理。
    ///
    /// 四条同时成立已经足够窄，因此和 `isRetrievalOnlyRequest` 一样按查询处理：
    /// 不进最近五条。误判的代价是一句短短的名词短语没被记下来，而放着不管的
    /// 代价是每次找东西都在轨道里留一条垃圾。
    public static func looksLikeRetrievalPhrase(_ event: ClipboardContextEvent) -> Bool {
        guard ClipboardContextGate.shouldConsider(event) else { return false }
        let text = event.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains("\n"), text.count <= 30 else { return false }
        // “今天要看完项目并写完论文”也很短、也包含“论文”，但时间表达已经
        // 证明它是一句行动陈述而不是在点名库里的 PDF。日期识别复用待办管线的
        // 通用解析器，不维护“写/看/交……”这类永远列不完的任务动词表。
        guard ChineseDateParser.firstDate(in: text) == nil else { return false }
        let intent = parse(event)
        // 必须点名了类型（图片 / 论文 / 截图 / 链接……）。只有字段意图（税号之类）
        // 时形态太像随手摘抄，仍旧交给模型判。
        guard !intent.preferredKinds.isEmpty else { return false }
        // 去掉类型词之后还要剩下真正的主题，否则光复制"图片"两个字也会触发。
        return QueryUnderstanding.localParse(text).semanticText.count >= 2
    }

    /// 候选是否命中了这些确定性证据。只看本地可验证的字段。
    public static func evidence(
        for intent: ContextIntent,
        title: String,
        filename: String?,
        tags: [String],
        group: String?
    ) -> [String] {
        let haystack = ([title, filename, group].compactMap { $0 } + tags)
            .joined(separator: " ")
            .lowercased()
        return intent.deterministicEvidence.filter { haystack.contains($0.lowercased()) }
    }
}


/// 自动捕获的临时剪贴板内容是否获得后台处理资格。
///
/// 开关只决定**捕获当时**是否授权，不追溯旧条目，也不因后来关闭而撤销已授权任务。
/// `wasAuthorizedAtCapture` 由 App 层按 item ID 持久化；固定与人工来源始终处理。
/// 一条内容该不该做待办识别。
///
/// 单独提出来是因为这条规则被实现错过两次：一次漏掉了拖入和主动收纳，
/// 一次让每条 Mac 复制的文字都发了模型请求。它散在捕获、固定两三个调用点上时
/// 没人能一眼看全，所以收敛成一个可以直接测的纯函数。
public enum TodoRecognitionPolicy {
    /// - Parameters:
    ///   - isPinned: 入库即固定（拖入、⌘P 收纳）或用户后来固定过。
    ///   - isFromNearbyDevice: 来自 iPhone / iPad 的通用剪贴板。
    ///
    /// 判据只有一条：**用户是不是已经表达了"留下它"**。
    ///
    /// - 拖进刘海、⌘P 主动收纳：入库时就是固定的，动作本身就是表达；
    /// - 手机 / 平板同步：内容来自另一台设备，Mac 上根本没有动作可等；
    /// - Mac 被动捕获的复制与截图：量大且多为过路内容，等固定。
    public static func shouldRecognize(
        isPinned: Bool,
        isFromNearbyDevice: Bool
    ) -> Bool {
        isPinned || isFromNearbyDevice
    }
}

public enum ClipboardContentProcessingPolicy {
    public static func authorizesNewTemporaryCapture(isEnabled: Bool) -> Bool { isEnabled }

    public static func shouldProcess(
        origin: ItemOrigin,
        isPinned: Bool,
        wasAuthorizedAtCapture: Bool
    ) -> Bool {
        origin != .clipboard || isPinned || wasAuthorizedAtCapture
    }
}
