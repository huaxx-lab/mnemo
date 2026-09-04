import Foundation

public enum SensitiveContentKind: String, Codable, Sendable, Hashable {
    case chineseIdentityNumber
    case bankCardNumber
    case phoneNumber
    case apiCredential
    case passwordLikeText
}

public struct PrivacyScreeningResult: Sendable, Equatable {
    public var matches: Set<SensitiveContentKind>

    /// 遮住就能安全外发的那几类。
    ///
    /// 手机号在正常内容里到处都是——招聘启事、快递通知、群公告，几乎每条都有。
    /// 为它整条拦下来的代价是"AI 检索完全不可用"，而它本来也不是用户想藏的
    /// 秘密（是他自己存下来的联系方式）。遮掉数字再发，模型照样读得懂上下文
    /// （"联系微信：[已隐去]"），检索能用，号码也没出去。
    ///
    /// 密钥、密码、身份证、银行卡不在此列：那几类**存在本身**就是风险，
    /// 而且遮掉之后剩下的上下文仍可能足够拼回去。它们继续硬拦。
    public static let redactableKinds: Set<SensitiveContentKind> = [.phoneNumber]

    public var blockingMatches: Set<SensitiveContentKind> {
        matches.subtracting(Self.redactableKinds)
    }

    public var canSendExternally: Bool { blockingMatches.isEmpty }

    public init(matches: Set<SensitiveContentKind>) { self.matches = matches }
}

public enum PrivacyFilter {
    /// 把能遮的那几类遮掉，其余原样。外发前统一过这一道。
    public static func redacted(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?<!\d)1[3-9]\d{9}(?!\d)"#,
            with: "[电话已隐去]",
            options: .regularExpression
        )
    }

    public static func screen(_ text: String) -> PrivacyScreeningResult {
        var matches: Set<SensitiveContentKind> = []
        if containsValidChineseID(text) { matches.insert(.chineseIdentityNumber) }
        if containsLuhnCard(text) { matches.insert(.bankCardNumber) }
        if firstMatch(#"(?<!\d)1[3-9]\d{9}(?!\d)"#, in: text) != nil {
            matches.insert(.phoneNumber)
        }
        if firstMatch(#"(?i)(?:sk|api|key|token)[-_][A-Za-z0-9_-]{16,}"#, in: text) != nil {
            matches.insert(.apiCredential)
        }
        if firstMatch(#"(?i)(?:password|passwd|密码)\s*[:=：]\s*\S{4,}"#, in: text) != nil {
            matches.insert(.passwordLikeText)
        }
        return PrivacyScreeningResult(matches: matches)
    }

    private static func containsValidChineseID(_ text: String) -> Bool {
        let pattern = #"(?<!\d)\d{17}[0-9Xx](?!\d)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = text as NSString
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let candidate = ns.substring(with: match.range).uppercased()
            let weights = [7, 9, 10, 5, 8, 4, 2, 1, 6, 3, 7, 9, 10, 5, 8, 4, 2]
            let checks = Array("10X98765432")
            let digits = candidate.prefix(17).compactMap { $0.wholeNumberValue }
            guard digits.count == 17 else { continue }
            let sum = zip(digits, weights).reduce(0) { $0 + $1.0 * $1.1 }
            if checks[sum % 11] == candidate.last { return true }
        }
        return false
    }

    private static func containsLuhnCard(_ text: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\d)\d{13,19}(?!\d)"#) else {
            return false
        }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).contains { match in
            let digits = ns.substring(with: match.range).compactMap { $0.wholeNumberValue }
            var total = 0
            for (offset, value) in digits.reversed().enumerated() {
                var digit = value
                if offset % 2 == 1 {
                    digit *= 2
                    if digit > 9 { digit -= 9 }
                }
                total += digit
            }
            return total % 10 == 0
        }
    }

    private static func firstMatch(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        return regex.firstMatch(
            in: text,
            range: NSRange(location: 0, length: (text as NSString).length)
        )
    }
}

public enum SceneActionID: String, Codable, Sendable, CaseIterable, Hashable {
    case copy
    case open
    case preview
    case extractTaxNumber
    case plainText
    case translate
    case summarize
    case askPDF
    case createTodo
}

public struct SceneActionCandidate: Identifiable, Codable, Sendable, Equatable {
    public var id: SceneActionID
    public var title: String
    public var localReason: String
    public var requiresConfirmation: Bool

    public init(id: SceneActionID, title: String, localReason: String, requiresConfirmation: Bool) {
        self.id = id
        self.title = title
        self.localReason = localReason
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct SceneRecommendation: Identifiable, Codable, Sendable, Equatable {
    public var id: SceneActionID
    public var title: String
    public var reason: String
    public var confidence: Double
    public var requiresConfirmation: Bool

    public init(
        id: SceneActionID,
        title: String,
        reason: String,
        confidence: Double,
        requiresConfirmation: Bool
    ) {
        self.id = id
        self.title = title
        self.reason = reason
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
    }
}

public struct SceneContext: Sendable, Equatable {
    public var kind: ItemKind
    public var text: String?
    public var sourceApplication: String?

    public init(kind: ItemKind, text: String? = nil, sourceApplication: String? = nil) {
        self.kind = kind
        self.text = text
        self.sourceApplication = sourceApplication
    }
}

public enum SceneRecognition {
    public static func localCandidates(for context: SceneContext) -> [SceneActionCandidate] {
        var result: [SceneActionCandidate] = []
        switch context.kind {
        case .link:
            result += [
                .init(id: .open, title: "打开链接", localReason: "这是网页链接", requiresConfirmation: false),
                .init(id: .copy, title: "复制链接", localReason: "可直接复制", requiresConfirmation: false),
                .init(id: .summarize, title: "总结网页", localReason: "链接适合提炼重点", requiresConfirmation: true),
            ]
        case .pdf:
            result += [
                .init(id: .preview, title: "预览 PDF", localReason: "这是 PDF 文件", requiresConfirmation: false),
                .init(id: .askPDF, title: "询问 PDF", localReason: "可按页检索内容", requiresConfirmation: true),
                .init(id: .createTodo, title: "设为待办", localReason: "文件可关联任务", requiresConfirmation: true),
            ]
        case .image:
            result += [
                .init(id: .preview, title: "查看原图", localReason: "这是图片", requiresConfirmation: false),
                .init(id: .plainText, title: "提取文字", localReason: "可使用本地 OCR", requiresConfirmation: true),
                .init(id: .copy, title: "复制图片", localReason: "可直接复制", requiresConfirmation: false),
            ]
        case .text:
            if looksLikeInvoice(context.text ?? "") {
                result.append(.init(
                    id: .extractTaxNumber,
                    title: "只取税号",
                    localReason: "检测到开票字段",
                    requiresConfirmation: true
                ))
            }
            result += [
                .init(id: .copy, title: "复制文字", localReason: "可直接复制", requiresConfirmation: false),
                .init(id: .translate, title: "翻译", localReason: "文字可翻译", requiresConfirmation: true),
                .init(id: .createTodo, title: "转为待办", localReason: "文字可关联任务", requiresConfirmation: true),
            ]
        case .file, .binary:
            result += [
                .init(id: .open, title: "打开文件", localReason: "使用默认应用打开", requiresConfirmation: false),
                .init(id: .preview, title: "快速预览", localReason: "先查看内容", requiresConfirmation: false),
                .init(id: .createTodo, title: "设为待办", localReason: "文件可关联任务", requiresConfirmation: true),
            ]
        }
        var seen: Set<SceneActionID> = []
        return result.filter { seen.insert($0.id).inserted }
    }

    /// 模型只能给本地白名单候选排序，不能发明新的动作。低置信度退回通用动作。
    public static func validatedRecommendations(
        modelJSON: Data?,
        candidates: [SceneActionCandidate],
        confidenceThreshold: Double = 0.58
    ) -> [SceneRecommendation] {
        let allowed = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let decoded: [ModelRecommendation]
        if let modelJSON,
           let value = try? JSONDecoder().decode(ModelRecommendationEnvelope.self, from: modelJSON) {
            decoded = value.recommendations
        } else {
            decoded = []
        }
        let highConfidence = decoded.compactMap { value -> SceneRecommendation? in
            guard let id = SceneActionID(rawValue: value.actionID),
                  let candidate = allowed[id],
                  value.confidence >= confidenceThreshold else { return nil }
            return SceneRecommendation(
                id: id,
                title: candidate.title,
                reason: value.reason.isEmpty ? candidate.localReason : value.reason,
                confidence: min(1, max(0, value.confidence)),
                requiresConfirmation: candidate.requiresConfirmation
            )
        }
        if !highConfidence.isEmpty { return Array(highConfidence.prefix(3)) }

        return candidates
            .filter { [.copy, .open, .preview].contains($0.id) }
            .prefix(3)
            .map {
                SceneRecommendation(
                    id: $0.id,
                    title: $0.title,
                    reason: $0.localReason,
                    confidence: 0,
                    requiresConfirmation: $0.requiresConfirmation
                )
            }
    }

    private static func looksLikeInvoice(_ text: String) -> Bool {
        let markers = ["税号", "纳税人识别号", "开户行", "发票抬头"]
        return markers.filter(text.contains).count >= 2
    }

    private struct ModelRecommendationEnvelope: Decodable {
        var recommendations: [ModelRecommendation]
    }

    private struct ModelRecommendation: Decodable {
        var actionID: String
        var confidence: Double
        var reason: String
    }
}

public struct StructuredQuery: Sendable, Equatable {
    public var kinds: Set<ItemKind>
    public var startDate: Date?
    public var endDate: Date?
    /// 要新的还是要旧的。和 startDate/endDate 是两回事：那两个划定范围，
    /// 这个决定范围内的排序。"上周那份"是范围，"最新一版"是排序。
    public var recency: RecencyPreference?
    public var semanticText: String

    public init(
        kinds: Set<ItemKind> = [],
        startDate: Date? = nil,
        endDate: Date? = nil,
        recency: RecencyPreference? = nil,
        semanticText: String
    ) {
        self.kinds = kinds
        self.startDate = startDate
        self.endDate = endDate
        self.recency = recency
        self.semanticText = semanticText
    }
}

/// "这句话在要哪种东西"只能有一份词表。
///
/// 之前剪贴板意图和搜索查询解析各自维护一份：给前者补了"的图"，后者不认，
/// 于是检索没有类型过滤，一条正好含 test-time 的**文字**把要找的图挤掉了。
public enum ContentTypeVocabulary {
    public static let image = [
        "截图", "图片", "照片", "图像", "配图", "封面图",
        // "图"单独一个字太泛（图书馆、图层），这些搭配才是在要图。
        "那张图", "发张图", "张图", "的图", "图给我",
        "示意图", "流程图", "架构图", "效果图", "图表",
        "screenshot", "image", "photo", "picture", "figure",
    ]
    public static let pdf = ["pdf", "论文", "文献", "预印本", "preprint", "手册", "讲义", "课件"]
    public static let link = ["链接", "网页", "网址", "url"]
    public static let text = ["文字", "文本", "笔记"]

    public static func kinds(in query: String) -> Set<ItemKind> {
        var kinds: Set<ItemKind> = []
        if matches(image, in: query) { kinds.insert(.image) }
        if matches(pdf, in: query) { kinds.insert(.pdf) }
        if matches(link, in: query) { kinds.insert(.link) }
        if matches(text, in: query) { kinds.insert(.text) }
        return kinds
    }

    /// 类型词只说明"要哪一类"，不是要找的东西本身：留在查询里会污染向量。
    public static var allWords: [String] { image + pdf + link + text }

    private static func matches(_ words: [String], in query: String) -> Bool {
        words.contains { query.localizedCaseInsensitiveContains($0) }
    }
}

public enum QueryUnderstanding {
    public static func localParse(
        _ query: String,
        now: Date = .now,
        calendar: Calendar = .current
    ) -> StructuredQuery {
        let kinds = ContentTypeVocabulary.kinds(in: query)
        let window = timeWindow(in: query, now: now, calendar: calendar)
        let start = window?.start
        let end = window?.end

        var semantic = query
        // 查询向量只表达“要找什么”，把剪贴板里的请求套话与类型词剥掉。
        // 否则快捷路径会嵌入“给我发一张……”这一整句，而索引分块只有内容，
        // 同一主题在搜索页和剪贴板路径会得到不同的召回分数。
        for token in ContentTypeVocabulary.allWords
            + RecencyVocabulary.allWords
            + TimeWindowVocabulary.allWords + [
            "那个", "的", "帮我找一下", "帮我找", "帮我",
            "给我发一下", "给我发一张", "给我发", "发给我", "发我", "发一下",
            "找一下", "找一张", "找一个", "请提交", "提交一下", "麻烦", "请",
            "send me", "can you send", "share the", "need the",
        ] {
            semantic = semantic.replacingOccurrences(of: token, with: " ")
        }
        semantic = semantic.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return StructuredQuery(
            kinds: kinds,
            startDate: start,
            endDate: end,
            recency: RecencyVocabulary.preference(in: query),
            semanticText: semantic
        )
    }

    /// 查询里那个时间范围。
    ///
    /// 从最具体的说法往下试，先命中先返回："前天"必须排在"天"之前，
    /// "上个月"必须排在"上"之前，否则短词会把长词吃掉。
    static func timeWindow(
        in query: String,
        now: Date,
        calendar: Calendar
    ) -> (start: Date, end: Date)? {
        func day(offset: Int) -> (Date, Date)? {
            guard let today = calendar.dateInterval(of: .day, for: now),
                  let start = calendar.date(byAdding: .day, value: offset, to: today.start),
                  let end = calendar.date(byAdding: .day, value: 1, to: start) else { return nil }
            return (start, end)
        }
        func unit(_ component: Calendar.Component, offset: Int) -> (Date, Date)? {
            guard let current = calendar.dateInterval(of: component, for: now),
                  let shifted = calendar.date(byAdding: component, value: offset, to: current.start),
                  let interval = calendar.dateInterval(of: component, for: shifted) else { return nil }
            return (interval.start, interval.end)
        }

        // "上周五 / 这周三"说的是具体某一天，不是整周。可 contains("上周")
        // 在"上周五"上照样命中，于是范围被放大成整整一周，再按它过滤就会
        // 把答案滤没。周/月这类日历格子在出现星期几时一律让位。
        let hasWeekday = query.range(
            of: #"(?:这|本|下|下下|上)?\s*(?:周|星期|礼拜)\s*[一二三四五六日天末1-7]"#,
            options: .regularExpression
        ) != nil

        for (words, resolve) in [
            (TimeWindowVocabulary.dayBeforeYesterday, { day(offset: -2) }),
            (TimeWindowVocabulary.yesterday, { day(offset: -1) }),
            (TimeWindowVocabulary.today, { day(offset: 0) }),
            (TimeWindowVocabulary.lastWeek, { unit(.weekOfYear, offset: -1) }),
            (TimeWindowVocabulary.thisWeek, { unit(.weekOfYear, offset: 0) }),
            (TimeWindowVocabulary.lastMonth, { unit(.month, offset: -1) }),
            (TimeWindowVocabulary.thisMonth, { unit(.month, offset: 0) }),
            (TimeWindowVocabulary.thisYear, { unit(.year, offset: 0) }),
        ] as [([String], () -> (Date, Date)?)] {
            let isWeekWord = words == TimeWindowVocabulary.thisWeek
                || words == TimeWindowVocabulary.lastWeek
            if isWeekWord, hasWeekday { continue }
            guard words.contains(where: { query.localizedCaseInsensitiveContains($0) }),
                  let window = resolve() else { continue }
            return (window.0, window.1)
        }

        // "最近三天"、"过去 7 天"、"一周内"这类滑动窗口。上面那些是日历格子，
        // 这一条是从现在往回数，两者语义不同，不能互相替代。
        if let days = TimeWindowVocabulary.trailingDays(in: query),
           let start = calendar.date(byAdding: .day, value: -days, to: now) {
            return (start, now)
        }
        return nil
    }
}

/// 说时间范围的那些词。
///
/// 单独摆出来是为了让"要剥掉哪些词才不污染向量"和"哪些词代表哪个范围"
/// 读的是同一份表——之前只认"昨天/今天"，两处各写一遍，补词时漏了一处。
public enum TimeWindowVocabulary {
    public static let today = ["今天", "今日", "today"]
    public static let yesterday = ["昨天", "昨日", "yesterday"]
    public static let dayBeforeYesterday = ["前天"]
    public static let thisWeek = ["本周", "这周", "这个星期", "this week"]
    public static let lastWeek = ["上周", "上个星期", "上星期", "last week"]
    public static let thisMonth = ["本月", "这个月", "this month"]
    public static let lastMonth = ["上个月", "上月", "last month"]
    public static let thisYear = ["今年", "this year"]

    public static var allWords: [String] {
        (today + yesterday + dayBeforeYesterday + thisWeek + lastWeek
            + thisMonth + lastMonth + thisYear + ["最近", "过去", "以内", "之内", "内"])
            .sorted { $0.count > $1.count }
    }

    /// "最近三天"、"过去 7 天"、"两周内"里的天数。认不出来返回 nil。
    ///
    /// 中文数字必须认：日常说的是"最近两周"，不是"最近 14 天"。数字部分和
    /// `ChineseDateParser` 用同一个写法（一个捕获组同时容纳两种），
    /// 免得两处对"两"这类字的处理慢慢分叉。
    public static func trailingDays(in query: String) -> Int? {
        let count = #"(\d{1,3}|[零一二三四五六七八九十两]{1,3})"#
        for (pattern, multiplier) in [
            (#"(?:最近|过去|近)\s*"# + count + #"\s*天"#, 1),
            (#"(?:最近|过去|近)\s*"# + count + #"\s*(?:周|星期)"#, 7),
            (count + #"\s*天\s*(?:以内|之内|内)"#, 1),
            (count + #"\s*(?:周|星期)\s*(?:以内|之内|内)"#, 7),
        ] {
            guard let raw = ChineseDateParser.firstMatch(pattern, in: query)?.group(1),
                  let value = ChineseDateParser.number(from: raw),
                  value > 0, value * multiplier <= 400 else { continue }
            return value * multiplier
        }
        return nil
    }
}

public enum VectorSearch {
    public static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0
        for index in lhs.indices {
            dot += lhs[index] * rhs[index]
            lhsNorm += lhs[index] * lhs[index]
            rhsNorm += rhs[index] * rhs[index]
        }
        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        guard denominator > 0, denominator.isFinite else { return 0 }
        let value = dot / denominator
        return value.isFinite ? value : 0
    }

    /// 查询里的类型词命中这条了吗。没提类型时人人都算命中。
    ///
    /// 它是**排序偏好**，不是准入条件——见 `filter` 的说明。
    public static func matchesKind(_ item: Item, _ query: StructuredQuery) -> Bool {
        query.kinds.isEmpty || query.kinds.contains(item.kind)
    }

    /// 确定性过滤。
    ///
    /// `matchingKinds: false` 时**不按类型排除**。理由是类型词在自然语言里
    /// 多半不是约束而是描述："我那个软件的 github 链接在哪里"里的"链接"说的是
    /// 要找的那行字，不是"只在链接类条目里找"。可它会被解析成 kinds=[.link]，
    /// 于是答案所在的那条文本笔记连同全库文本条目一起被剔除，检索直接返回
    /// 零命中——用户看到的是"它根本不知道"，而真正发生的是候选里压根没有它。
    /// 时间范围不一样：那是用户明确划的界，仍然照做。
    public static func filter(
        _ items: [Item],
        by query: StructuredQuery,
        matchingKinds: Bool = true
    ) -> [Item] {
        items.filter { item in
            if matchingKinds, !matchesKind(item, query) { return false }
            guard query.startDate != nil || query.endDate != nil else { return true }
            // 两个时间都算数：一篇三月定稿、上周才拖进来的论文，用户说"上周那份"
            // 指的是入库时间，说"三月那版"指的是文件自己的时间。两种说法都对，
            // 而这里没有任何依据去挑一个——所以命中其一即可。范围条件只该收窄，
            // 挑错那个等于把要找的东西直接滤没。
            let facts = ItemTemporalFacts(item: item)
            return [facts.capturedAt, facts.contentDate].contains { date in
                if let start = query.startDate, date < start { return false }
                if let end = query.endDate, date >= end { return false }
                return true
            }
        }
    }
}
