import Foundation

/// 交给模型的一条检索候选。
///
/// 从 App 层搬到领域层，理由和 SiteContentExtraction 一样：候选怎么组装、
/// 正文给多少，是"检索能不能答对"的核心规则，必须能被评测语料直接覆盖。
/// 它原来待在 executable target 里，测试连 import 都做不到。
public struct RetrievalRankingCandidate: Sendable {
    public var itemID: UUID
    public var title: String
    public var kind: ItemKind
    /// 这条候选的可读正文。**不做字数截断**——见 RetrievalEvidence 的说明。
    public var snippet: String
    public var localScore: Float
    /// 原始文件名。论文这类内容标题常常是 AI 生成的，文件名才带着真正的
    /// 标识（会议、编号、DOI）。
    public var filename: String?
    public var group: String?
    public var tags: [String]
    /// 本地是否真的命中过。localScore 为 0 的候选是"补进来给模型判断的"，
    /// 不说清楚的话模型会把它当成弱相关证据。
    public var hasLocalEvidence: Bool
    /// 这条在时间轴上的位置。没有它，"最新一版"在模型眼里和"某一版"没区别。
    public var temporal: ItemTemporalFacts
    /// 同一份东西的版本族。本地按名字主干认出来的，`versionRank` 为 1 即最新。
    /// 认不出来时留空——那说明本地没有把握，模型只按绝对时间自己比。
    public var versionGroup: String?
    public var versionRank: Int?
    public var versionCount: Int?

    public init(
        itemID: UUID,
        title: String,
        kind: ItemKind,
        snippet: String,
        localScore: Float,
        filename: String? = nil,
        group: String? = nil,
        tags: [String] = [],
        hasLocalEvidence: Bool = true,
        temporal: ItemTemporalFacts,
        versionGroup: String? = nil,
        versionRank: Int? = nil,
        versionCount: Int? = nil
    ) {
        self.itemID = itemID
        self.title = title
        self.kind = kind
        self.snippet = snippet
        self.localScore = localScore
        self.filename = filename
        self.group = group
        self.tags = tags
        self.hasLocalEvidence = hasLocalEvidence
        self.temporal = temporal
        self.versionGroup = versionGroup
        self.versionRank = versionRank
        self.versionCount = versionCount
    }
}

/// 组装"发给模型的本地证据"。
///
/// 这里只有一条设计原则：**不按字数从头部切内容**。
///
/// 旧实现在同一段文字上连切三刀——命中片段取 180 字（没有字面命中时取块首）、
/// 再拼上全文的前 400 字、最后按 `14000 / 候选数 - 220` 再截一次，每条候选
/// 实际只有约 360 个字符，而且全部来自开头。于是"这段介绍最后那个 GitHub
/// 链接在哪"这类问题必然答不出：链接在文末，三道刀都够不到它，模型手上
/// 根本没有那行字。它不是答错，是压根没看见。
///
/// 现在改成：每条候选带**完整正文**；总预算靠"后面的候选不给正文"来满足，
/// 而不是"每条都切一刀"。宁可少给几条，也要保证给出去的那几条是完整的——
/// 半截正文既可能漏掉答案，又会让模型以为自己看到了全部。
public enum RetrievalEvidence {

    public static let minimumCandidateCount = 8
    public static let maximumCandidateCount = 24

    /// 候选负载的总字符预算。
    ///
    /// 旧值是 14,000，摊到 24 条候选上每条只剩三百多字。这个数字是按"别把
    /// 请求撑爆"定的，但它保守得离谱：现在的模型上下文都在十万 token 以上，
    /// 而绝大多数条目（剪贴板文字、链接正文、截图 OCR）整条也就几百到几千字，
    /// 全给也花不完预算。只有 PDF 这类长文才会碰到上限。
    public static let payloadBudget = 120_000

    /// 命中优先，不足则用确定性过滤后的其余条目补齐。补进来的分数是 0，
    /// 模型看得出它们没有本地证据，但至少有机会按标题/类型判断。
    public static func candidates(
        hits: [SemanticSearchHit],
        items: [Item],
        chunks: [ContentChunk],
        query: StructuredQuery
    ) -> [RetrievalRankingCandidate] {
        // 可读内容全在分块里：图片的 OCR 与视觉标签、PDF 的页文本、文档的正文。
        // 补进候选池的条目没有本地命中，摘要如果只写文件名，模型看到的就是
        // "mnemo-clipboard-xxx.png"——一张央视报道的截图和一张猫图长得一样。
        let textByItem = Dictionary(grouping: chunks, by: \.itemID).mapValues { group in
            group.sorted { $0.ordinal < $1.ordinal }
                .map(\.text)
                .joined(separator: "\n")
        }
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var candidates = hits.prefix(12).compactMap { hit -> RetrievalRankingCandidate? in
            guard let item = itemByID[hit.itemID] else { return nil }
            // 命中片段现在就是命中块的全文，条目正文里已经含着它，再拼一次
            // 只会让同一段话在负载里出现两遍、白占预算。正文取不到时才退回
            // 用命中片段本身。
            let body = textByItem[item.id] ?? hit.snippet
            return RetrievalRankingCandidate(
                itemID: item.id,
                title: item.title,
                kind: item.kind,
                snippet: body,
                localScore: hit.score,
                filename: item.originalFilename,
                group: item.group,
                tags: item.tags,
                hasLocalEvidence: true,
                temporal: ItemTemporalFacts(item: item)
            )
        }
        guard candidates.count < minimumCandidateCount else {
            return annotatedWithVersions(candidates, recency: query.recency)
        }

        var seen = Set(candidates.map(\.itemID))
        // 类型/时间这类确定性条件仍然生效，只是不再要求词法或向量命中。
        //
        // 但它们只该收窄，不该清零：查询理解一旦把类型猜错（"csa-ud 是什么"
        // 被判成只找 PDF 之类），过滤后就是空集，模型连判断的机会都没有。
        // 滤空时退回全部活动条目：先补类型对得上的，再补其余的。
        let preferred = VectorSearch.filter(items, by: query)
        let preferredIDs = Set(preferred.map(\.id))
        let pool = preferred.sorted { $0.modifiedAt > $1.modifiedAt }
            + items.filter { !preferredIDs.contains($0.id) }
                .sorted { $0.modifiedAt > $1.modifiedAt }
        for item in pool where seen.insert(item.id).inserted {
            candidates.append(RetrievalRankingCandidate(
                itemID: item.id,
                title: item.title,
                kind: item.kind,
                snippet: describe(item, indexedText: textByItem[item.id]),
                localScore: 0,
                filename: item.originalFilename,
                group: item.group,
                tags: item.tags,
                hasLocalEvidence: false,
                temporal: ItemTemporalFacts(item: item)
            ))
            if candidates.count >= maximumCandidateCount { break }
        }
        return annotatedWithVersions(candidates, recency: query.recency)
    }

    /// 候选序列化成给模型看的对象。两条检索路径（流式回答、控制器）共用同一份
    /// 字段，否则给一处补了时间、另一处没补，同一句"最新那版"在两条路上会给出
    /// 不同答案。
    ///
    /// 预算的用法是**整条取舍**，不是逐条切字：按排名依次放入完整正文，放不下
    /// 的候选只留元数据并标记 `excerptOmitted`，让模型知道"这条我没给你正文"，
    /// 而不是把半截正文当成全部。
    public static func payload(
        _ candidates: [RetrievalRankingCandidate],
        snippetKey: String,
        now: Date,
        budget: Int = payloadBudget
    ) -> [[String: Any]] {
        var remaining = max(0, budget)
        return candidates.map { candidate in
            var object: [String: Any] = [
                "itemID": candidate.itemID.uuidString,
                "title": candidate.title,
                "kind": candidate.kind.rawValue,
                "localScore": Double(candidate.localScore),
                "hasLocalEvidence": candidate.hasLocalEvidence,
                // 内容自己的时间。文件用它自身的修改时间，剪贴板内容只有入库时间。
                "contentDate": RetrievalTemporalFormat.absolute(candidate.temporal.contentDate),
                "contentDateIsFromFile": candidate.temporal.contentDateIsFromSource,
                "capturedAt": RetrievalTemporalFormat.absolute(candidate.temporal.capturedAt),
                "age": RetrievalTemporalFormat.relative(candidate.temporal.contentDate, now: now),
            ]
            let body = candidate.snippet
            if !body.isEmpty {
                if body.count <= remaining {
                    object[snippetKey] = body
                    remaining -= body.count
                } else {
                    object["excerptOmitted"] = true
                }
            }
            if let filename = candidate.filename { object["filename"] = filename }
            if let group = candidate.group { object["group"] = group }
            if !candidate.tags.isEmpty { object["tags"] = candidate.tags }
            if let versionGroup = candidate.versionGroup,
               let rank = candidate.versionRank,
               let total = candidate.versionCount {
                object["versionGroup"] = versionGroup
                object["versionRank"] = rank
                object["versionCount"] = total
            }
            return object
        }
    }

    private static func describe(_ item: Item, indexedText: String?) -> String {
        var parts: [String] = []
        if let filename = item.originalFilename { parts.append(filename) }
        if let group = item.group { parts.append(group) }
        if !item.tags.isEmpty { parts.append(item.tags.joined(separator: "、")) }
        if case .inline(let text) = item.holding { parts.append(text) }
        // 图片只有 OCR 和视觉标签能说明它是什么；PDF 与文档同理靠页文本。
        if let indexedText, !indexedText.isEmpty { parts.append(indexedText) }
        return parts.joined(separator: " · ")
    }

    /// 给候选补上版本族，并在用户明确要"最新 / 最早"时按时间重排。
    ///
    /// 重排只发生在**同一族内部**，而且一条候选都不会被丢掉。理由是这层
    /// 判断依据只是名字主干，够不上"确定"：分族错了最多是顺序不理想，模型
    /// 手上仍有每条的绝对时间可以自己纠正；而按它删候选，一旦分错就是把
    /// 要找的东西直接藏起来，用户在界面上根本看不出发生过什么。
    private static func annotatedWithVersions(
        _ candidates: [RetrievalRankingCandidate],
        recency: RecencyPreference?
    ) -> [RetrievalRankingCandidate] {
        let ranks = DocumentVersioning.ranks(candidates.map {
            VersionedDocument(
                id: $0.itemID,
                title: $0.title,
                filename: $0.filename,
                kind: $0.kind,
                contentDate: $0.temporal.contentDate
            )
        })
        guard !ranks.isEmpty else { return candidates }

        var annotated = candidates.map { candidate -> RetrievalRankingCandidate in
            guard let rank = ranks[candidate.itemID] else { return candidate }
            var value = candidate
            value.versionGroup = rank.stem
            value.versionRank = rank.rank
            value.versionCount = rank.total
            return value
        }
        guard let recency else { return annotated }

        // 稳定排序：族内按用户要的方向排，族外和不属于任何族的条目保持原位。
        // 排序键取"这一族在原列表里最靠前的位置"，这样族的整体位置不变，
        // 变的只是族内谁排前面——本地相似度的判断仍然被尊重。
        let anchors = Dictionary(
            annotated.enumerated().compactMap { index, candidate in
                candidate.versionGroup.map { ($0, index) }
            },
            uniquingKeysWith: min
        )
        annotated = annotated.enumerated()
            .sorted { lhs, rhs in
                let lhsAnchor = lhs.element.versionGroup.flatMap { anchors[$0] } ?? lhs.offset
                let rhsAnchor = rhs.element.versionGroup.flatMap { anchors[$0] } ?? rhs.offset
                if lhsAnchor != rhsAnchor { return lhsAnchor < rhsAnchor }
                guard let lhsRank = lhs.element.versionRank,
                      let rhsRank = rhs.element.versionRank,
                      lhsRank != rhsRank else { return lhs.offset < rhs.offset }
                return recency == .newest ? lhsRank < rhsRank : lhsRank > rhsRank
            }
            .map(\.element)
        return annotated
    }
}
