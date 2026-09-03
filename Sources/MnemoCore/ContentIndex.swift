import CryptoKit
import Foundation

public enum ContentChunkSource: String, Codable, Sendable {
    case inlineText
    case fileText
    case pdfPage
    case imageOCR
    case imageCaption
    /// 链接指向的正文。抓回来的网页 / PDF / 图片文字都归这一类——
    /// 对检索来说它们是同一件事："这条链接里讲了什么"。
    case linkPage
    /// 用户自己写下的那一句：改过的标题、加上的标签。
    ///
    /// 它必须和正文一样进向量库，否则"我给这个文件备注过是阿里云的密钥"
    /// 这句话只存在于界面上——模型看不到，语义检索也召不回。备注往往正是
    /// 用户唯一记得住的那个说法，而文件内容里根本没有那几个字。
    case userAnnotation
}

/// 用户写下的东西怎么变成一段可检索的文字。
///
/// 拼成自然句而不是 `title|tags` 这种字段串：向量模型对句子的表征远比对
/// 分隔符拼起来的字段串稳定，而这段文字唯一的用途就是被句子检索命中。
public enum UserAnnotationText {
    public static func build(title: String?, tags: [String], group: String?) -> String? {
        var parts: [String] = []
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("这份内容叫「\(title)」。")
        }
        let cleanTags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !cleanTags.isEmpty {
            parts.append("标签：\(cleanTags.joined(separator: "、"))。")
        }
        if let group, !group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append("分组：\(group)。")
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }
}

public struct RuntimeEmbedding: Sendable, Equatable {
    public var vector: [Float]
    public var providerID: String
    public var modelID: String
    public var dimensionChanged: Bool

    public init(vector: [Float], providerID: String, modelID: String, dimensionChanged: Bool) {
        self.vector = vector
        self.providerID = providerID
        self.modelID = modelID
        self.dimensionChanged = dimensionChanged
    }
}

public enum EmbeddingAttempt: Sendable, Equatable {
    case success(RuntimeEmbedding)
    case notConfigured
    case privacyBlocked
    case configurationFailure
    case retryableFailure(retryAfter: TimeInterval?)
}

/// 语义索引的最小检索单元。PDF 页码使用用户可见的 1-based 编号。
public struct ContentChunk: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var itemID: UUID
    public var ordinal: Int
    public var pageNumber: Int?
    public var source: ContentChunkSource
    public var text: String
    public var vector: [Float]?
    public var contentHash: String
    public var embeddingModelID: String?
    public var indexedAt: Date?

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        ordinal: Int,
        pageNumber: Int? = nil,
        source: ContentChunkSource,
        text: String,
        vector: [Float]? = nil,
        contentHash: String? = nil,
        embeddingModelID: String? = nil,
        indexedAt: Date? = nil
    ) {
        self.id = id
        self.itemID = itemID
        self.ordinal = ordinal
        self.pageNumber = pageNumber
        self.source = source
        self.text = text
        self.vector = vector
        self.contentHash = contentHash ?? Self.hash(text)
        self.embeddingModelID = embeddingModelID
        self.indexedAt = indexedAt
    }

    public var isFullyIndexed: Bool {
        vector?.isEmpty == false && embeddingModelID != nil && indexedAt != nil
    }

    private static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SemanticSearchHit: Identifiable, Sendable, Equatable {
    public var id: UUID { itemID }
    public var itemID: UUID
    public var chunkID: UUID?
    public var pageNumber: Int?
    public var snippet: String
    public var score: Float
    public var isUsingStaleVector: Bool
    public var source: ContentChunkSource?

    public init(
        itemID: UUID,
        chunkID: UUID? = nil,
        pageNumber: Int? = nil,
        snippet: String,
        score: Float,
        isUsingStaleVector: Bool = false,
        source: ContentChunkSource? = nil
    ) {
        self.itemID = itemID
        self.chunkID = chunkID
        self.pageNumber = pageNumber
        self.snippet = snippet
        self.score = score
        self.isUsingStaleVector = isUsingStaleVector
        self.source = source
    }
}

public struct RetrievalRecommendation: Sendable, Equatable, Identifiable {
    public var id: UUID { itemID }
    public var itemID: UUID
    public var confidence: Double
    public var reason: String
    /// 用户要的其实是这条 Pin 里的**一小段**——网址、单号、某个名字。
    ///
    /// 模型只能**指认**，不能改写：这段文字必须逐字出现在候选的本地内容里，
    /// 由 `CopyPayloadResolver` 校验。校验不过就当没有，退回整条。
    /// 这条路取代了原来那张写死的字段正则表：想要什么由用户的话决定，
    /// 而不是由我们提前枚举了哪几个字段。
    public var copyText: String?

    public init(itemID: UUID, confidence: Double, reason: String, copyText: String? = nil) {
        self.itemID = itemID
        self.confidence = confidence
        self.reason = reason
        self.copyText = copyText
    }
}

/// 决定"到底把什么放进剪贴板"。
public enum CopyPayloadResolver {
    /// 模型指认的那一段必须真的在本地内容里。
    ///
    /// 逐字比对之外还容忍空白差异——模型常常把换行吃掉或多加一个空格，
    /// 但绝不容忍"看起来差不多"：一个被改写过的网址粘出去就是错的。
    public static func verified(_ copyText: String?, in haystack: String) -> String? {
        guard let raw = copyText?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw.count <= 400 else { return nil }
        if haystack.contains(raw) { return raw }
        // 退一步：按空白归一化之后再找，找到就返回原文那一段。
        let flatNeedle = collapsed(raw)
        guard !flatNeedle.isEmpty, collapsed(haystack).contains(flatNeedle) else { return nil }
        return raw
    }

    private static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}

public enum RetrievalSelection: Sendable, Equatable {
    /// 机器可读 JSON 有效；数组可以为空，表示模型明确认为没有相关候选。
    case selected([RetrievalRecommendation])
    /// 没有可解码的推荐信封。调用方应明确显示本地降级，而不是把它当“空结果”。
    case malformed
}

/// 快捷推荐最终要做的是交付库里的内容，还是基于库内证据回答问题。
///
/// 这不是靠一张“怎么 / 为什么 / 核心观点”词表猜出来的；控制器结合完整请求与
/// 本地候选做语义判断。`retrieve` 仍受本地 ID 与片段校验约束，`answer` 则进入
/// 独立的证据读取与中文回答步骤，不能再借用 `copyText` 截一段原文冒充答案。
public enum RecommendationResponseIntent: String, Sendable, Codable, Equatable {
    case retrieve
    case answer
}

/// 控制器的 Few-shot 只教“用户最终想得到什么”，不参与候选召回，也不提供任何
/// 真实 itemID。正反例成对出现：同一主题仅因动词不同就走不同输出通道，避免模型
/// 看到 PDF 候选后条件反射地同时给文件卡与摘要。
public struct RecommendationIntentExample: Sendable, Equatable {
    public var request: String
    public var intent: RecommendationResponseIntent
    public var boundary: String

    public init(
        request: String,
        intent: RecommendationResponseIntent,
        boundary: String
    ) {
        self.request = request
        self.intent = intent
        self.boundary = boundary
    }
}

/// "最终产物是解释"的确定性下界。
///
/// 这不是回到"靠词表猜类型"的老路：它不判断要找什么、也不参与召回，只在模型
/// 把**明确在追问内容**的请求判成 retrieve 时纠正回 answer。实测失败样本是
/// "qkv 截图里讲了什么"——请求同时点名了对象（截图）又追问内容，模型被前半句
/// 带偏，于是把一段原文塞进剪贴板，而用户要的是解释。
///
/// 只收录追问内容时才成立的说法。"把总结发我"这类**要原对象**的请求里也会出现
/// "总结"二字，所以单独的"总结""分析"不在表内。
public enum RecommendationIntentFloor {
    static let explanationMarkers = [
        "讲了什么", "讲的是什么", "讲的什么", "讲了啥", "讲了些什么",
        "说了什么", "说的是什么", "说了啥",
        "写了什么", "写的是什么",
        "是什么意思", "什么意思",
        "核心观点", "核心结论", "主要内容", "主要讲",
        "总结一下", "分析一下", "解释一下", "概括一下",
        "为什么", "怎么实现", "如何实现", "怎么运行", "如何工作",
        "what does it say", "what is it about", "what does this say",
        "summarize", "explain", "what does the",
    ]

    public static func requiresAnswer(_ request: String) -> Bool {
        let normalized = request.lowercased()
        return explanationMarkers.contains { normalized.contains($0) }
    }
}

public enum RecommendationIntentFewShot {
    public static let version = "intent-exclusive-v5"

    /// 示例覆盖的是“最终产物”的边界，而不是某几个文件类型的关键词表。
    /// 同一个本地对象分别给出交付 / 理解两种请求，让模型学会看用户要的结果。
    public static let examples: [RecommendationIntentExample] = [
        // 文档 / PDF
        .init(request: "把 CSA-UD 的 PDF 给我", intent: .retrieve,
              boundary: "最终产物是 PDF 本身"),
        .init(request: "CSA-UD 讲了什么", intent: .answer,
              boundary: "最终产物是对内容的解释，PDF 只是证据"),
        // 图片
        .init(request: "把那张网络拓扑图给我", intent: .retrieve,
              boundary: "最终产物是图片本身"),
        .init(request: "这张网络拓扑图说明了什么", intent: .answer,
              boundary: "最终产物是对图片含义的解释"),
        // 点名了对象、但追问的是内容：仍然是 answer
        .init(request: "把 qkv 截图发我", intent: .retrieve,
              boundary: "最终产物是那张截图"),
        .init(request: "qkv 截图里讲了什么", intent: .answer,
              boundary: "点名了截图，但最终产物是对截图内容的解释，截图只是证据"),
        // 链接 / 网页
        .init(request: "给我 pi agent 的网址", intent: .retrieve,
              boundary: "最终产物是本地原文中的网址"),
        .init(request: "pi agent 那个页面主要介绍什么", intent: .answer,
              boundary: "最终产物是页面内容摘要，链接只是证据"),
        // 表格 / 数据
        .init(request: "把上季度的数据表发我", intent: .retrieve,
              boundary: "最终产物是表格文件"),
        .init(request: "上季度的数据反映了什么趋势", intent: .answer,
              boundary: "最终产物是基于数据的分析"),
        // 日志
        .init(request: "复制昨晚那段错误日志", intent: .retrieve,
              boundary: "最终产物是日志原文"),
        .init(request: "昨晚的错误日志说明为什么失败", intent: .answer,
              boundary: "最终产物是故障原因解释"),
        // 代码 / 脚本
        .init(request: "把部署脚本发我", intent: .retrieve,
              boundary: "最终产物是脚本本身"),
        .init(request: "这个部署脚本做了什么，有什么风险", intent: .answer,
              boundary: "最终产物是代码说明与风险分析"),
        // 文字 / 会议记录
        .init(request: "把会议记录原文给我", intent: .retrieve,
              boundary: "最终产物是记录原文"),
        .init(request: "总结会议结论和待办", intent: .answer,
              boundary: "最终产物是综合总结"),
        // 英文请求也按最终产物判断
        .init(request: "Send me the terminal guide PDF", intent: .retrieve,
              boundary: "the final product is the PDF itself"),
        .init(request: "What does the terminal guide explain?", intent: .answer,
              boundary: "the final product is an explanation"),
    ]

    /// 示例故意只输出 intent：它们负责分类边界；完整候选 JSON 的格式由紧随其后的
    /// schema 约束。把假 UUID 放进示例反而会诱导模型复制一个不在本轮白名单里的 ID。
    public static var promptBlock: String {
        examples.enumerated().map { index, example in
            "示例 \(index + 1)\n用户请求：\(example.request)\n"
                + "判断：{\"intent\":\"\(example.intent.rawValue)\"}\n"
                + "边界：\(example.boundary)"
        }.joined(separator: "\n\n")
    }
}

public struct RecommendationAgentDecision: Sendable, Equatable {
    public var intent: RecommendationResponseIntent
    public var recommendations: [RetrievalRecommendation]

    public init(
        intent: RecommendationResponseIntent,
        recommendations: [RetrievalRecommendation]
    ) {
        self.intent = intent
        self.recommendations = recommendations
    }
}

public enum RecommendationAgentDecisionSelection: Sendable, Equatable {
    case selected(RecommendationAgentDecision)
    case malformed
}

/// 一轮快捷推荐只能选择一个面向用户的输出通道。回答所用的 Pin ID 只是内部证据，
/// 不能同时冒充“给你这份文件”的推荐卡；交付模式才允许出现文件 / 片段结果。
public enum RecommendationAgentOutput: Sendable, Equatable {
    case deliver(itemIDs: [UUID])
    case answer(evidenceItemIDs: [UUID])
}

public extension RecommendationAgentDecision {
    /// 模型把"追问内容"判成 retrieve 时纠正回 answer，并丢掉复制载荷：
    /// answer 的候选只是内部证据，不能顺手把一段原文写进剪贴板冒充回答。
    func correctedByIntentFloor(request: String) -> RecommendationAgentDecision {
        guard intent == .retrieve, RecommendationIntentFloor.requiresAnswer(request) else {
            return self
        }
        return RecommendationAgentDecision(
            intent: .answer,
            recommendations: recommendations.map {
                RetrievalRecommendation(
                    itemID: $0.itemID,
                    confidence: $0.confidence,
                    reason: $0.reason,
                    copyText: nil
                )
            }
        )
    }

    func output(selectedItemIDs: [UUID]) -> RecommendationAgentOutput {
        switch intent {
        case .retrieve: .deliver(itemIDs: selectedItemIDs)
        case .answer: .answer(evidenceItemIDs: selectedItemIDs)
        }
    }
}

/// “模型收敛到唯一结果就自动写剪贴板”的授权边界。它没有被删除，但只属于
/// retrieve：answer 即使只用一个文件、图片、网页、笔记或其他 Pin 作证据，也不能
/// 顺手把原对象或摘录覆盖进剪贴板。
public enum RecommendationAutoCopyPolicy {
    public struct AnswerDelivery: Sendable, Equatable {
        public var answer: String
        public var didWrite: Bool
        public var errorMessage: String?

        public init(answer: String, didWrite: Bool, errorMessage: String?) {
            self.answer = answer
            self.didWrite = didWrite
            self.errorMessage = errorMessage
        }
    }

    /// 把“回答完整”与“系统剪贴板真写成功”分开建模，避免 UI 在写入前先画对号。
    public static func answerDelivery(
        answer: String?,
        write: (String) -> Bool
    ) -> AnswerDelivery? {
        guard let answer = completedAnswer(answer) else { return nil }
        let wrote = write(answer)
        return AnswerDelivery(
            answer: answer,
            didWrite: wrote,
            errorMessage: wrote ? nil : "回答已生成，但写入系统剪贴板失败；可点复制重试"
        )
    }

    /// 回答自动复制只接受回答器已经确认的最终非空文本。模型明确 token 截断时回答器
    /// 不会产出这里的输入；调用方还要在真正写系统剪贴板前检查 generation。
    public static func completedAnswer(_ answer: String?) -> String? {
        guard let answer = answer?.trimmingCharacters(in: .whitespacesAndNewlines),
              !answer.isEmpty else { return nil }
        return answer
    }

    public static func convergedTarget(
        decision: RecommendationAgentDecision?,
        selectedItemIDs: [UUID],
        locallyEvidencedItemIDs: Set<UUID>,
        modelWasAvailable: Bool,
        hasSensitiveIntent: Bool
    ) -> UUID? {
        guard modelWasAvailable,
              decision?.intent == .retrieve,
              !hasSensitiveIntent,
              selectedItemIDs.count == 1,
              let only = selectedItemIDs.first,
              locallyEvidencedItemIDs.contains(only) else { return nil }
        return only
    }
}

/// 一轮快捷回答里的工具状态。它只存在于当前 Task：不编码、不落盘，也不会成为
/// 下一轮的消息历史。控制器先产生真实 itemID，读取器再按这些 ID 取证据，最后
/// 回答器只看这份 evidence。
public struct RecommendationAnswerEvidence: Sendable, Equatable {
    public var itemID: UUID
    public var title: String
    public var filename: String?
    public var excerpts: [String]

    public init(
        itemID: UUID,
        title: String,
        filename: String? = nil,
        excerpts: [String]
    ) {
        self.itemID = itemID
        self.title = title
        self.filename = filename
        self.excerpts = excerpts
    }
}

public enum RecommendationAnswerEvidenceSelector {
    public static let maximumExcerptsPerItem = 6
    public static let maximumExcerptCharacters = 2_400

    /// 从一条真实 Pin 的所有分块里选当前问题最相关的证据。优先沿用查询向量；
    /// 向量不可用时仍有中文二字组 / 英文词的本地字面分，最终才按文档顺序补齐。
    public static func select(
        chunks: [ContentChunk],
        query: String,
        queryVector: [Float]?,
        limit: Int = maximumExcerptsPerItem
    ) -> [String] {
        guard !chunks.isEmpty else { return [] }
        let maximum = max(1, min(limit, maximumExcerptsPerItem))
        let ranked = chunks.map { chunk -> (chunk: ContentChunk, score: Float) in
            let lexical = LexicalMatch.score(text: chunk.text, query: query)
            let semantic = queryVector.flatMap { queryVector in
                chunk.vector.map { VectorSearch.cosine(queryVector, $0) }
            } ?? 0
            return (chunk, max(lexical, semantic))
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.chunk.ordinal < rhs.chunk.ordinal
        }
        return ranked.prefix(maximum).compactMap { entry in
            let text = entry.chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let excerpt = window(
                in: text,
                around: query,
                maximumCharacters: maximumExcerptCharacters
            )
            let page = entry.chunk.pageNumber.map { "第 \($0) 页" }
            let source = page ?? entry.chunk.source.rawValue
            return "[\(source)]\n\(excerpt)"
        }
    }

    /// 长页不能一律取开头。相关术语在第 3,000 字时，旧实现即使把这一页排第一，
    /// 发给回答模型的仍是前 2,400 字，真正证据再次被截掉。优先围绕完整查询；
    /// 找不到整句时围绕任一最长词项，实在没有才取页首。
    private static func window(
        in text: String,
        around query: String,
        maximumCharacters: Int
    ) -> String {
        guard text.count > maximumCharacters else { return text }
        let needles = ([query] + LexicalMatch.terms(in: query).sorted { $0.count > $1.count })
            .filter { !$0.isEmpty }
        guard let range = needles.lazy.compactMap({ text.range(of: $0, options: .caseInsensitive) }).first
        else { return String(text.prefix(maximumCharacters)) }
        let center = text.distance(from: text.startIndex, to: range.lowerBound)
        let startOffset = max(0, min(text.count - maximumCharacters, center - maximumCharacters / 3))
        let start = text.index(text.startIndex, offsetBy: startOffset)
        return String(text[start...].prefix(maximumCharacters))
    }
}

public enum AgenticRetrieval {
    /// The model is a ranker over local RAG output, not a source of new results.
    /// Unknown and duplicate IDs are discarded before anything reaches the UI.
    public static func decision(
        modelJSON: Data?,
        allowedItemIDs: Set<UUID>,
        limit: Int = 5,
        requiresExplicitIntent: Bool = false
    ) -> RecommendationAgentDecisionSelection {
        struct Envelope: Decodable {
            struct Entry: Decodable {
                var itemID: String
                var confidence: Double
                var reason: String
                var copyText: String?
            }
            var intent: String?
            var recommendations: [Entry]
        }
        guard let modelJSON,
              let decoded = try? JSONDecoder().decode(Envelope.self, from: modelJSON) else {
            return .malformed
        }
        // 兼容搜索流与旧缓存没有 intent 的信封；一旦模型显式给了未知动作则拒绝，
        // 不能把拼错的 answer 静默降成“复制整条”。
        let intent: RecommendationResponseIntent
        if let rawIntent = decoded.intent {
            guard let parsed = RecommendationResponseIntent(rawValue: rawIntent) else {
                return .malformed
            }
            intent = parsed
        } else {
            // 搜索流的旧推荐信封没有 intent，默认 retrieve 保持兼容；Command-G
            // 控制器必须显式判断，缺字段就触发一次结构化修复，不能静默当成要文件。
            guard !requiresExplicitIntent else { return .malformed }
            intent = .retrieve
        }

        var seen: Set<UUID> = []
        let recommendations: [RetrievalRecommendation] = decoded.recommendations.compactMap { entry -> RetrievalRecommendation? in
            guard let id = UUID(uuidString: entry.itemID),
                  allowedItemIDs.contains(id),
                  seen.insert(id).inserted else { return nil }
            let reason = entry.reason
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return RetrievalRecommendation(
                itemID: id,
                confidence: min(1, max(0, entry.confidence)),
                reason: String(reason.prefix(96)),
                // answer 的 ID 只是证据，不允许携带复制载荷；retrieve 的片段仍需
                // 调用方按完整本地正文做第二次逐字校验。
                copyText: intent == .retrieve
                    ? entry.copyText.map { String($0.prefix(400)) }
                    : nil
            )
        }
        return .selected(RecommendationAgentDecision(
            intent: intent,
            recommendations: Array(recommendations.prefix(max(1, limit)))
        ))
    }

    public static func selection(
        modelJSON: Data?,
        allowedItemIDs: Set<UUID>,
        limit: Int = 5
    ) -> RetrievalSelection {
        guard case .selected(let decision) = decision(
            modelJSON: modelJSON,
            allowedItemIDs: allowedItemIDs,
            limit: limit
        ) else { return .malformed }
        return .selected(decision.recommendations)
    }

    public static func validatedRecommendations(
        modelJSON: Data?,
        allowedItemIDs: Set<UUID>,
        limit: Int = 5
    ) -> [RetrievalRecommendation] {
        guard case .selected(let recommendations) = selection(
            modelJSON: modelJSON,
            allowedItemIDs: allowedItemIDs,
            limit: limit
        ) else { return [] }
        return recommendations
    }

    /// 模型完成判断后，最终推荐集合以它返回的白名单 ID 为准。
    ///
    /// `reorder` 保留给“选中的排前面、其余本地命中仍保留”的场景；Agent 搜索
    /// 使用这个方法收敛结果，模型没有选中的候选不会继续冒充 AI 推荐卡片。
    public static func selectedHits(
        from hits: [SemanticSearchHit],
        using recommendations: [RetrievalRecommendation]
    ) -> [SemanticSearchHit] {
        let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.itemID, $0) })
        return recommendations.compactMap { byID[$0.itemID] }
    }

    public static func reorder(
        _ hits: [SemanticSearchHit],
        using recommendations: [RetrievalRecommendation]
    ) -> [SemanticSearchHit] {
        guard !recommendations.isEmpty else { return hits }
        let byID = Dictionary(uniqueKeysWithValues: hits.map { ($0.itemID, $0) })
        let recommendedIDs = Set(recommendations.map(\.itemID))
        return recommendations.compactMap { byID[$0.itemID] }
            + hits.filter { !recommendedIDs.contains($0.itemID) }
    }
}

/// 字面匹配打分。
///
/// 原来是"整句必须原样出现"：中文查询几乎永远匹配不上——"央视报道牛来的截图"
/// 不会一字不差地出现在 OCR 文本里，于是没配 embedding 时图片和 PDF 基本
/// 搜不到。改成按词打分：英文按空格切词，中文按二字组切，命中比例决定分数。
public enum LexicalMatch {
    public static let fullPhraseScore: Float = 0.6
    public static let maximumPartialScore: Float = 0.45

    public static func score(text: String, query: String) -> Float {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return 0 }
        let haystack = text.lowercased()
        if haystack.contains(query) { return fullPhraseScore }

        let terms = self.terms(in: query)
        guard !terms.isEmpty else { return 0 }
        let matched = terms.filter { haystack.contains($0) }.count
        guard matched > 0 else { return 0 }
        return maximumPartialScore * Float(matched) / Float(terms.count)
    }

    /// 英文按空格切词（长度 ≥ 2）；中文没有空格，按连续汉字的二字组切——
    /// 二字组是中文检索里代价最低又足够有区分度的粒度。
    public static func terms(in query: String) -> [String] {
        var terms: Set<String> = []
        for token in query.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
            let word = String(token)
            if word.unicodeScalars.allSatisfy({ $0.value < 0x2E80 }) {
                if word.count >= 2 { terms.insert(word) }
                continue
            }
            let characters = Array(word)
            if characters.count == 1 {
                terms.insert(word)
            } else {
                for index in 0..<(characters.count - 1) {
                    terms.insert(String(characters[index...(index + 1)]))
                }
            }
        }
        return Array(terms)
    }
}

public enum SemanticSearch {
    /// 先执行确定性的类型/日期过滤，再按每个 Pin 的最佳块聚合。旧向量仍参与，
    /// 但结果明确标记为正在重建索引。
    public static func rank(
        items: [Item],
        chunks: [ContentChunk],
        query: StructuredQuery,
        queryVector: [Float]?,
        currentEmbeddingModelID: String?,
        limit: Int = 30
    ) -> [SemanticSearchHit] {
        let candidates = VectorSearch.filter(items, by: query)
        let candidateIDs = Set(candidates.map(\.id))
        let itemByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        let normalizedQuery = query.semanticText.lowercased()
        var best: [UUID: SemanticSearchHit] = [:]

        for chunk in chunks where candidateIDs.contains(chunk.itemID) {
            let semanticScore = queryVector.map { vector in
                chunk.vector.map { VectorSearch.cosine(vector, $0) } ?? 0
            } ?? 0
            let lexicalScore = LexicalMatch.score(text: chunk.text, query: normalizedQuery)
            let score = max(semanticScore, lexicalScore)
            guard score > 0 else { continue }
            let stale = itemByID[chunk.itemID]?.contentHash == nil
                || (currentEmbeddingModelID.map { chunk.embeddingModelID != $0 } ?? false)
            let hit = SemanticSearchHit(
                itemID: chunk.itemID,
                chunkID: chunk.id,
                pageNumber: chunk.pageNumber,
                snippet: snippet(chunk.text, around: normalizedQuery),
                score: score,
                isUsingStaleVector: stale,
                source: chunk.source
            )
            if best[chunk.itemID].map({ $0.score < score }) != false { best[chunk.itemID] = hit }
        }

        // 标题、标签与分组始终保留本地全文召回，即使 Embedding 尚未配置或正在排队。
        if !normalizedQuery.isEmpty {
            for item in candidates {
                let metadata = ([item.title, item.group].compactMap { $0 } + item.tags)
                    .joined(separator: " ")
                let metadataScore = LexicalMatch.score(text: metadata, query: normalizedQuery)
                guard metadataScore > 0 else { continue }
                let hit = SemanticSearchHit(
                    itemID: item.id,
                    snippet: metadata,
                    score: max(best[item.id]?.score ?? 0, 0.5 + metadataScore * 0.2),
                    isUsingStaleVector: item.contentHash == nil
                )
                if best[item.id].map({ $0.score < hit.score }) != false { best[item.id] = hit }
            }
        }
        return best.values.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.itemID.uuidString < $1.itemID.uuidString
        }.prefix(max(1, limit)).map { $0 }
    }

    private static func snippet(_ text: String, around query: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        guard !query.isEmpty,
              let range = flattened.range(of: query, options: .caseInsensitive) else {
            return String(flattened.prefix(180))
        }
        let offset = flattened.distance(from: flattened.startIndex, to: range.lowerBound)
        let startOffset = max(0, offset - 60)
        let start = flattened.index(flattened.startIndex, offsetBy: startOffset)
        return String(flattened[start...].prefix(180))
    }
}
