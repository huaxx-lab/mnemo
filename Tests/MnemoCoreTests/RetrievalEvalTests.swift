import Foundation
import Testing
@testable import MnemoCore

/// 检索证据的整体评测。
///
///     MNEMO_RAG_EVAL_REPORT=docs/retrieval-eval-result.md swift test
///
/// 不设环境变量时只跑断言，不写文件。
struct RetrievalEval {

    /// 两版实现并排跑同一份语料、同一套判定，差值就是这次优化的净收益。
    enum Variant: String, CaseIterable {
        /// 改动前：命中片段 180 字（无字面命中取块首）+ 全文前 400 字，
        /// 最后再按 `14000 / 候选数 - 220` 截一次。三刀全从头部下。
        case legacy = "改动前（类型硬过滤 + 三重头部截断）"
        /// 改动后：候选带完整正文，预算靠整条取舍满足。
        case current = "改动后（类型只加权，证据不截断）"
    }

    struct Result {
        var caseID: String
        var category: String
        var variant: Variant
        /// 答案所在的条目有没有进候选。这是"召回"那一层。
        var retrieved: Bool
        /// 答案原文有没有出现在发给模型的负载里。这是"证据完整"那一层。
        var recalled: Bool
        /// 负载里这条候选实际给出了多少字符。
        var deliveredCharacters: Int
        var note: String
    }

    // MARK: - 构库

    private struct Fixture {
        var items: [Item]
        var chunks: [ContentChunk]
        var itemByTitle: [String: Item]
    }

    private static func makeFixture() -> Fixture {
        var items: [Item] = []
        var chunks: [ContentChunk] = []
        var byTitle: [String: Item] = [:]
        for document in RetrievalEvalCorpus.documents {
            let item = Item(
                title: document.title,
                kind: document.kind,
                holding: .inline(document.body),
                createdAt: RetrievalEvalCorpus.now,
                modifiedAt: RetrievalEvalCorpus.now
            )
            items.append(item)
            byTitle[document.title] = item
            chunks += ContentChunking.chunks(
                itemID: item.id,
                text: document.body,
                source: .inlineText,
                pageNumber: nil,
                ordinalBase: 0
            )
        }
        return Fixture(items: items, chunks: chunks, itemByTitle: byTitle)
    }

    // MARK: - 两版负载

    /// 忠实复刻改动前的三道截断，用来做对照。
    private static func legacyPayload(
        hits: [SemanticSearchHit],
        items: [Item],
        chunks: [ContentChunk],
        query: StructuredQuery
    ) -> [[String: Any]] {
        let textByItem = Dictionary(grouping: chunks, by: \.itemID).mapValues { group in
            group.sorted { $0.ordinal < $1.ordinal }.map(\.text).joined(separator: " ")
        }
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let normalized = query.semanticText.lowercased()

        let candidates: [(UUID, String)] = hits.prefix(12).compactMap { hit in
            guard let item = itemByID[hit.itemID] else { return nil }
            // 旧 snippet：有整句字面命中才围绕它开窗，否则取块首，都截到 180 字。
            let flattened = (chunks.first { $0.id == hit.chunkID }?.text ?? "")
                .replacingOccurrences(of: "\n", with: " ")
            let legacySnippet: String
            if !normalized.isEmpty,
               let range = flattened.range(of: normalized, options: .caseInsensitive) {
                let offset = flattened.distance(from: flattened.startIndex, to: range.lowerBound)
                let start = flattened.index(flattened.startIndex, offsetBy: max(0, offset - 60))
                legacySnippet = String(flattened[start...].prefix(180))
            } else {
                legacySnippet = String(flattened.prefix(180))
            }
            let joined = [legacySnippet, textByItem[item.id].map { String($0.prefix(400)) }]
                .compactMap { $0 }
                .joined(separator: " · ")
            return (item.id, joined)
        }
        let budget = max(120, 14_000 / max(1, candidates.count) - 220)
        return candidates.map { id, text in
            ["itemID": id.uuidString, "excerpt": String(text.prefix(budget))]
        }
    }

    // MARK: - 跑一条

    static func run(_ variant: Variant) -> [Result] {
        let fixture = makeFixture()
        return RetrievalEvalCorpus.cases.map { testCase in
            let structured = QueryUnderstanding.localParse(testCase.query)
            // 旧行为是在排序前按类型硬过滤（那时 rank 内部就这么做）。这里把
            // 过滤前置，效果完全等价，对照才是真的。
            let searchable = variant == .legacy
                ? VectorSearch.filter(fixture.items, by: structured)
                : fixture.items
            let hits = SemanticSearch.rank(
                items: searchable,
                chunks: fixture.chunks,
                query: structured,
                queryVector: nil,           // 评测不依赖网络：只跑本地词法这一路
                currentEmbeddingModelID: nil
            )
            let objects: [[String: Any]]
            switch variant {
            case .legacy:
                objects = legacyPayload(
                    hits: hits, items: searchable,
                    chunks: fixture.chunks, query: structured
                )
            case .current:
                let candidates = RetrievalEvidence.candidates(
                    hits: hits, items: searchable,
                    chunks: fixture.chunks, query: structured
                )
                objects = RetrievalEvidence.payload(
                    candidates, snippetKey: "excerpt", now: RetrievalEvalCorpus.now
                )
            }
            let delivered = objects
                .compactMap { $0["excerpt"] as? String }
                .joined(separator: "\n")
            let goldID = fixture.itemByTitle[testCase.goldDocument]?.id
            return Result(
                caseID: testCase.id,
                category: testCase.category,
                variant: variant,
                retrieved: goldID.map { id in hits.contains { $0.itemID == id } } ?? false,
                recalled: delivered.contains(testCase.goldSpan),
                deliveredCharacters: delivered.count,
                note: testCase.note
            )
        }
    }
}

// MARK: - 断言

@Test("改动后：每一条的答案原文都真的进了负载")
func retrievalEvidenceCoversGoldSpans() {
    let results = RetrievalEval.run(.current)
    let missed = results.filter { !$0.recalled }
    #expect(
        missed.isEmpty,
        "答案没进负载：\(missed.map(\.caseID).joined(separator: "、"))"
    )
}

@Test("改动前确实答不出用户实报的那两类问题——对照组不能悄悄变绿")
func legacyLosesReportedCases() {
    let legacy = Dictionary(
        uniqueKeysWithValues: RetrievalEval.run(.legacy).map { ($0.caseID, $0) }
    )
    // rag-01 是用户原话那条：「链接」被当成类型过滤，条目连候选都进不去。
    #expect(legacy["rag-01"]?.retrieved == false)
    #expect(legacy["rag-01"]?.recalled == false)
    // rag-07 是同一个病因的另一种说法。
    #expect(legacy["rag-07"]?.retrieved == false)
}

@Test("改动后：答案所在的条目都被召回")
func retrievalReachesGoldDocuments() {
    let missed = RetrievalEval.run(.current).filter { !$0.retrieved }
    #expect(missed.isEmpty, "没召回：\(missed.map(\.caseID).joined(separator: "、"))")
}

@Test("说了类型的查询，同类条目要排在前面——加权不能等于没有")
func kindStillOrdersResults() {
    let link = Item(
        title: "一条链接", kind: .link,
        holding: .inline("https://example.com/release 发布日期 10 月 17 日"),
        createdAt: RetrievalEvalCorpus.now, modifiedAt: RetrievalEvalCorpus.now
    )
    let note = Item(
        title: "一条笔记", kind: .text,
        holding: .inline("发布日期 10 月 17 日"),
        createdAt: RetrievalEvalCorpus.now, modifiedAt: RetrievalEvalCorpus.now
    )
    let chunks = [link, note].flatMap { item -> [ContentChunk] in
        guard case .inline(let text) = item.holding else { return [] }
        return ContentChunking.chunks(
            itemID: item.id, text: text, source: .inlineText,
            pageNumber: nil, ordinalBase: 0
        )
    }
    let query = QueryUnderstanding.localParse("那个链接里的发布日期")
    let hits = SemanticSearch.rank(
        items: [note, link], chunks: chunks, query: query,
        queryVector: nil, currentEmbeddingModelID: nil
    )
    #expect(hits.count == 2, "两条都该留在结果里，类型不该排除任何一条")
    #expect(hits.first?.itemID == link.id, "说了「链接」，链接类要排前面")
}

@Test("改动后送出的证据比改动前多，但没有无上限膨胀")
func evidenceVolumeIsBoundedButLarger() {
    let before = RetrievalEval.run(.legacy).reduce(0) { $0 + $1.deliveredCharacters }
    let after = RetrievalEval.run(.current).reduce(0) { $0 + $1.deliveredCharacters }
    #expect(after > before)
    #expect(after <= RetrievalEvidence.payloadBudget * RetrievalEvalCorpus.cases.count)
}

@Test("单条候选正文超预算时整条不给，不切半截")
func oversizedCandidateIsOmittedNotTruncated() {
    let long = String(repeating: "长", count: 500)
    let candidate = RetrievalRankingCandidate(
        itemID: UUID(),
        title: "超长文档",
        kind: .file,
        snippet: long,
        localScore: 1,
        temporal: ItemTemporalFacts(
            contentDate: RetrievalEvalCorpus.now,
            capturedAt: RetrievalEvalCorpus.now,
            contentDateIsFromSource: false
        )
    )
    let objects = RetrievalEvidence.payload(
        [candidate], snippetKey: "excerpt", now: RetrievalEvalCorpus.now, budget: 100
    )
    #expect(objects[0]["excerpt"] == nil)
    #expect(objects[0]["excerptOmitted"] as? Bool == true)
}

@Test("检索评测报告可导出")
func retrievalEvalReportExports() throws {
    guard let path = ProcessInfo.processInfo.environment["MNEMO_RAG_EVAL_REPORT"] else { return }
    let legacy = RetrievalEval.run(.legacy)
    let current = RetrievalEval.run(.current)
    let byID = Dictionary(uniqueKeysWithValues: legacy.map { ($0.caseID, $0) })

    var lines: [String] = [
        "# 检索证据评测结果",
        "",
        "由 `RetrievalEvalTests` 自动生成，语料见 `RetrievalEvalCorpus.swift`。",
        "",
        "衡量两层：**召回**（答案所在条目有没有进候选）和**证据**（答案原文有没有进负载）。",
        "排序再准，证据里没有那行字，模型也只能编或者说不知道。",
        "",
        "本轮一共改了三处：",
        "",
        "1. **类型词从硬过滤改成排序加权**——「链接在哪里」里的「链接」原来会被解析成",
        "   `kinds=[.link]`，把答案所在的文本条目连同全库文本一起剔除，检索直接零命中。",
        "2. **证据不再按字数从头部截断**——原来同一段文字被切三刀（命中片段 180 字、",
        "   全文前 400 字、总预算 ÷ 候选数），每条候选实际只有约 360 字且全部来自开头。",
        "3. **「上周五」不再被读成「上周」**——`contains(\"上周\")` 在「上周五」上命中，",
        "   把范围放大成整整一周；日期范围滤空时另外退回全库。",
        "",
        "第 3 处在共用的查询解析里，两列都受益，所以它的收益不体现在下表的差值中。",
        "下表的差值 = 第 1 处 + 第 2 处。",
        "",
        "## 总体",
        "",
        "| 指标 | 改动前 | 改动后 |",
        "| --- | --- | --- |",
    ]
    let beforeHit = legacy.filter(\.recalled).count
    let afterHit = current.filter(\.recalled).count
    let total = current.count
    lines.append("| 语料条数 | \(total) | \(total) |")
    lines.append("| 答案条目被召回 | \(legacy.filter(\.retrieved).count) | \(current.filter(\.retrieved).count) |")
    lines.append("| 答案原文进入负载 | \(beforeHit) | \(afterHit) |")
    lines.append(String(
        format: "| 证据召回率 | %.1f%% | %.1f%% |",
        Double(beforeHit) / Double(total) * 100,
        Double(afterHit) / Double(total) * 100
    ))
    lines.append("| 送出证据总字符 | \(legacy.reduce(0) { $0 + $1.deliveredCharacters }) | \(current.reduce(0) { $0 + $1.deliveredCharacters }) |")
    lines += [
        "",
        "## 逐条",
        "",
        "两列各含两个判定：**召回**（答案所在条目有没有进候选）/ **证据**（答案原文有没有进负载）。",
        "",
        "| 用例 | 类别 | 查询 | 改动前 | 改动后 | 守住的东西 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    for (index, result) in current.enumerated() {
        let testCase = RetrievalEvalCorpus.cases[index]
        func mark(_ value: RetrievalEval.Result?) -> String {
            guard let value else { return "—" }
            return "\(value.retrieved ? "✅" : "❌") / \(value.recalled ? "✅" : "❌")"
        }
        let before = mark(byID[result.caseID])
        let after = mark(result)
        lines.append(
            "| \(result.caseID) | \(result.category) | \(testCase.query) | \(before) | \(after) | \(result.note) |"
        )
    }
    lines.append("")
    try lines.joined(separator: "\n").write(
        toFile: path, atomically: true, encoding: .utf8
    )
}
