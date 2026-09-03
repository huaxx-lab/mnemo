import Foundation
import Testing
@testable import MnemoCore

/// 固定时区，否则"上周"在跨时区机器上落在不同的格子里。
private let calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    value.locale = Locale(identifier: "zh_CN")
    value.firstWeekday = 2
    return value
}()

/// 2026-09-03 周四 10:00 (UTC+8)
private let now: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 3
    components.hour = 10
    return calendar.date(from: components)!
}()

private func at(_ year: Int, _ month: Int, _ day: Int) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
}

private func document(
    _ filename: String,
    kind: ItemKind = .pdf,
    date: Date,
    title: String = "论文"
) -> VersionedDocument {
    VersionedDocument(
        id: UUID(),
        title: title,
        filename: filename,
        kind: kind,
        contentDate: date
    )
}

// MARK: - 排序意图

@Test("说了「最新 / 最早」才有排序偏好，没说就是 nil")
func parsesRecencyPreference() {
    #expect(RecencyVocabulary.preference(in: "tii 那篇论文最新一版") == .newest)
    #expect(RecencyVocabulary.preference(in: "give me the latest tii paper") == .newest)
    #expect(RecencyVocabulary.preference(in: "找一下最早那版评审意见") == .oldest)
    #expect(RecencyVocabulary.preference(in: "第一版的实验数据") == .oldest)
    #expect(RecencyVocabulary.preference(in: "tii 那篇论文") == nil)
}

@Test("两个方向都出现时按先出现的那个算")
func recencyTakesTheLeadingCue() {
    #expect(RecencyVocabulary.preference(in: "要最新那版，不是最早那版") == .newest)
    #expect(RecencyVocabulary.preference(in: "先看最早那版，别拿最新的") == .oldest)
}

@Test("排序词与时间词都不留在语义查询里，否则会污染向量")
func recencyWordsDoNotPolluteSemanticText() {
    let parsed = QueryUnderstanding.localParse(
        "帮我找一下 tii 那篇论文最新版",
        now: now,
        calendar: calendar
    )
    #expect(parsed.recency == .newest)
    #expect(parsed.semanticText.contains("tii"))
    #expect(!parsed.semanticText.contains("最新"))
    // "最新版"必须整词剥掉，不能剥完"最新"剩下一个孤零零的"版"。
    #expect(!parsed.semanticText.contains("版"))
}

// MARK: - 时间范围

@Test("日历格子：今天、昨天、前天各自落在自己那一天")
func parsesCalendarDays() {
    func day(_ query: String) -> Int? {
        guard let window = QueryUnderstanding.timeWindow(in: query, now: now, calendar: calendar)
        else { return nil }
        return calendar.component(.day, from: window.start)
    }
    #expect(day("今天存的截图") == 3)
    #expect(day("昨天那份") == 2)
    #expect(day("前天发的链接") == 1)
}

@Test("上周 / 上个月是日历格子，不是从现在往回数")
func parsesCalendarUnits() {
    let lastWeek = QueryUnderstanding.timeWindow(in: "上周的会议记录", now: now, calendar: calendar)
    #expect(lastWeek != nil)
    // 9/3 是周四，firstWeekday=2（周一）时上周是 8/24–8/31。
    #expect(calendar.component(.day, from: lastWeek!.start) == 24)
    #expect(lastWeek!.end <= now)

    let lastMonth = QueryUnderstanding.timeWindow(in: "上个月那份报表", now: now, calendar: calendar)
    #expect(lastMonth != nil)
    #expect(calendar.component(.month, from: lastMonth!.start) == 8)

    let thisMonth = QueryUnderstanding.timeWindow(in: "这个月存的", now: now, calendar: calendar)
    #expect(calendar.component(.month, from: thisMonth!.start) == 9)
}

@Test("「最近三天」「两周内」是从现在往回数的滑动窗口")
func parsesTrailingWindows() {
    #expect(TimeWindowVocabulary.trailingDays(in: "最近三天存的图") == 3)
    #expect(TimeWindowVocabulary.trailingDays(in: "过去 7 天的链接") == 7)
    #expect(TimeWindowVocabulary.trailingDays(in: "两周内那份稿子") == 14)
    #expect(TimeWindowVocabulary.trailingDays(in: "tii 的论文") == nil)

    let window = QueryUnderstanding.timeWindow(in: "最近三天的截图", now: now, calendar: calendar)
    #expect(window != nil)
    #expect(calendar.component(.day, from: window!.start) == 31)
    #expect(window!.end == now)
}

@Test("没有任何时间说法时不划范围，别凭空造一个")
func noWindowWithoutCue() {
    #expect(QueryUnderstanding.timeWindow(in: "tii 那篇论文", now: now, calendar: calendar) == nil)
}

// MARK: - 条目时间

@Test("文件自己的修改时间优先于入库时间，并如实标注来源")
func temporalFactsPreferSourceDate() {
    let dragged = Item(
        title: "tii 论文",
        kind: .pdf,
        holding: .copy(hash: "a", size: 10),
        createdAt: at(2026, 9, 3),
        sourceModificationDate: at(2026, 3, 14)
    )
    let facts = ItemTemporalFacts(item: dragged)
    #expect(facts.contentDate == at(2026, 3, 14))
    #expect(facts.capturedAt == at(2026, 9, 3))
    #expect(facts.contentDateIsFromSource)

    // 剪贴板文字没有文件时间，只能拿入库时间顶替——但必须说明是顶替的，
    // 否则模型会把"我今天存的"读成"这是今天写的"。
    let copied = Item(
        title: "一段文字",
        kind: .text,
        holding: .inline("内容"),
        createdAt: at(2026, 9, 1)
    )
    let copiedFacts = ItemTemporalFacts(item: copied)
    #expect(copiedFacts.contentDate == at(2026, 9, 1))
    #expect(!copiedFacts.contentDateIsFromSource)
}

@Test("给模型的时间是绝对时间，相对说法只作人类可读补充")
func formatsAbsoluteTime() {
    let text = RetrievalTemporalFormat.absolute(at(2026, 3, 14), calendar: calendar)
    #expect(text.hasPrefix("2026-03-14T"))
    #expect(text.contains("+08:00"))
    #expect(RetrievalTemporalFormat.dayKey(at(2026, 3, 14), calendar: calendar) == "2026-03-14")

    #expect(RetrievalTemporalFormat.relative(now, now: now, calendar: calendar) == "0 分钟前")
    #expect(RetrievalTemporalFormat.relative(at(2026, 9, 1), now: now, calendar: calendar) == "2 天前")
    #expect(RetrievalTemporalFormat.relative(at(2026, 3, 14), now: now, calendar: calendar) == "5 个月前")
    // 文件系统时钟错乱时如实说，不要硬掰成 0 天前。
    #expect(RetrievalTemporalFormat.relative(at(2027, 1, 1), now: now, calendar: calendar) == "晚于当前时间")
}

@Test("时间范围过滤时两个时间命中其一就算数")
func filterAcceptsEitherDate() {
    let paper = Item(
        title: "tii 论文",
        kind: .pdf,
        holding: .copy(hash: "a", size: 10),
        createdAt: at(2026, 9, 1),
        sourceModificationDate: at(2026, 3, 14)
    )
    // 「上周存的」说的是入库时间。
    let byCapture = StructuredQuery(
        startDate: at(2026, 8, 31),
        endDate: at(2026, 9, 2),
        semanticText: "论文"
    )
    #expect(VectorSearch.filter([paper], by: byCapture).count == 1)

    // 「三月那版」说的是文件自己的时间。同一条都该留下。
    let byContent = StructuredQuery(
        startDate: at(2026, 3, 1),
        endDate: at(2026, 4, 1),
        semanticText: "论文"
    )
    #expect(VectorSearch.filter([paper], by: byContent).count == 1)

    let unrelated = StructuredQuery(
        startDate: at(2026, 1, 1),
        endDate: at(2026, 2, 1),
        semanticText: "论文"
    )
    #expect(VectorSearch.filter([paper], by: unrelated).isEmpty)
}

// MARK: - 版本族

@Test("同一份文件的多版按名字主干分族，从新到旧排")
func groupsVersionsByStem() {
    let v1 = document("tii-paper-v1.pdf", date: at(2026, 3, 14))
    let v2 = document("tii_paper_v2.pdf", date: at(2026, 6, 1))
    let v3 = document("tii paper 20260901.pdf", date: at(2026, 9, 1))
    let other = document("rdma-survey.pdf", date: at(2026, 5, 1))

    let families = DocumentVersioning.families([v1, v3, other, v2])
    #expect(families.count == 1)
    #expect(families.first?.stem == "tiipaper")
    #expect(families.first?.orderedIDs == [v3.id, v2.id, v1.id])

    let ranks = DocumentVersioning.ranks([v1, v2, v3, other])
    #expect(ranks[v3.id]?.rank == 1)
    #expect(ranks[v1.id]?.rank == 3)
    #expect(ranks[v3.id]?.total == 3)
    // 落单的条目不进任何族：一条的族不携带信息，只会占提示词预算。
    #expect(ranks[other.id] == nil)
}

@Test("中英文版本记号都能剥掉，主干相同才算一族")
func stripsVersionMarkers() {
    #expect(DocumentVersioning.stem(title: "x", filename: "季度汇报初稿.docx")
        == DocumentVersioning.stem(title: "x", filename: "季度汇报最终版.docx"))
    #expect(DocumentVersioning.stem(title: "x", filename: "budget_final.xlsx")
        == DocumentVersioning.stem(title: "x", filename: "budget draft.xlsx"))
    #expect(DocumentVersioning.stem(title: "x", filename: "报表 (1).pdf")
        == DocumentVersioning.stem(title: "x", filename: "报表.pdf"))
    // 整词才剥：finalcut 不是 cut 的最终版。
    #expect(DocumentVersioning.stem(title: "x", filename: "finalcut.mov") == "finalcut")
}

@Test("主干太短或太通用时一律不分族，宁可不判也不要判错")
func refusesGenericStems() {
    #expect(DocumentVersioning.stem(title: "论文", filename: nil) == nil)
    #expect(DocumentVersioning.stem(title: "screenshot", filename: "screenshot.png") == nil)
    #expect(DocumentVersioning.stem(title: "报告", filename: "报告.pdf") == nil)
    #expect(DocumentVersioning.stem(title: "ab", filename: nil) == nil)

    // 名字相同但都是通用词的两条不该被说成"同一份的新旧两版"。
    let families = DocumentVersioning.families([
        document("论文.pdf", date: at(2026, 3, 1), title: "论文"),
        document("论文.pdf", date: at(2026, 9, 1), title: "论文"),
    ])
    #expect(families.isEmpty)
}

@Test("类型不同不算同一份东西的两版")
func doesNotGroupAcrossKinds() {
    let paper = document("tii-paper.pdf", kind: .pdf, date: at(2026, 3, 1))
    let shot = document("tii-paper.png", kind: .image, date: at(2026, 9, 1))
    #expect(DocumentVersioning.families([paper, shot]).isEmpty)
}

@Test("同一时刻的两条也要有稳定顺序，同一次查询不能给出两个「最新版」")
func versionOrderIsStable() {
    let sameMoment = at(2026, 5, 5)
    let a = document("thesis-v1.pdf", date: sameMoment)
    let b = document("thesis-v2.pdf", date: sameMoment)
    let first = DocumentVersioning.families([a, b]).first?.orderedIDs
    let second = DocumentVersioning.families([b, a]).first?.orderedIDs
    #expect(first != nil)
    #expect(first == second)
}

@Test("标题被 AI 改写过时仍靠文件名认出是同一份")
func prefersFilenameOverGeneratedTitle() {
    let v1 = VersionedDocument(
        id: UUID(),
        title: "面向低时延推理的稀疏注意力方法",
        filename: "tii-paper-v1.pdf",
        kind: .pdf,
        contentDate: at(2026, 3, 1)
    )
    let v2 = VersionedDocument(
        id: UUID(),
        title: "稀疏注意力在边缘设备上的部署",
        filename: "tii-paper-v2.pdf",
        kind: .pdf,
        contentDate: at(2026, 9, 1)
    )
    let families = DocumentVersioning.families([v1, v2])
    #expect(families.first?.orderedIDs.first == v2.id)
}

@Test("真实库里的下载序号也算版本记号：Overleaf 的 __9_-6 与 __10_-7 是同一篇")
func groupsRealWorldDownloadCounters() {
    let base = "Communication_Semantic_Aware_RDMA_Loss_Recovery_for_QP_scalable_Hyperscale_AI_Training"
    let older = document("\(base)__9_-6.pdf", date: at(2026, 7, 1))
    let newer = document("\(base)__10_-7.pdf", date: at(2026, 9, 1))
    #expect(DocumentVersioning.families([older, newer]).first?.orderedIDs == [newer.id, older.id])

    let iwqos2 = document("iwqos2026-paper333-2.pdf", date: at(2026, 6, 1))
    let iwqos3 = document("iwqos2026-paper333-3.pdf", date: at(2026, 8, 1))
    let families = DocumentVersioning.families([iwqos2, iwqos3])
    #expect(families.first?.orderedIDs == [iwqos3.id, iwqos2.id])
    // 名字自带的编号（paper333）不是序号，不能一起剥掉。
    #expect(families.first?.stem == "iwqos2026paper333")
}

@Test("结尾数字属于名字本身时不剥：gpt-4 不是 gpt 的第 4 版")
func keepsTrailingDigitsThatBelongToTheName() {
    #expect(DocumentVersioning.stem(title: "x", filename: "gpt-4.pdf") == "gpt4")
    #expect(DocumentVersioning.stem(title: "x", filename: "llama-3.pdf") == "llama3")
    // chapter-1 / chapter-2 是两章，不是两版：剥完只剩 chapter，短于下限，不剥。
    #expect(DocumentVersioning.families([
        document("chapter-1.pdf", date: at(2026, 3, 1)),
        document("chapter-2.pdf", date: at(2026, 4, 1)),
    ]).isEmpty)
}

// MARK: - 靠首页标题认出同一份文档

/// 真实语料：同一篇论文的 IWQoS 投稿版和 IEEE TII 版。
/// 文件名、AI 标题两两都对不上，只有首页上那行标题几乎一样。
private let tiiFirstPage = """
IEEE TRANSACTIONS ON INDUSTRIAL INFORMATICS, VOL. XX, NO. XX, XXXX 1
Communication-Semantic-Aware RDMA Loss
Recovery for QP-scalable MoE Training
10 pages total
Abstract— Current AI clusters primarily rely on Remote
Direct Memory Access (RDMA) for large-scale AI training.
"""

private let iwqosFirstPage = """
Communication-Semantic-Aware RDMA Loss
Recovery for QP-scalable Hyperscale AI Training
Paper #333, 10 pages total
Abstract—Current artificial intelligence (AI) infrastructures
widely adopt Remote Direct Memory Access (RDMA).
"""

private let handbookFirstPage = """
用 户 手 册
中国研究生创新实践系列大赛
中国研究生数学建模竞赛
（学生）
"""

@Test("首页标题剥掉期刊页眉和页数行")
func extractsDocumentTitleFromFirstPage() {
    let tii = DocumentTitleExtraction.title(fromFirstPage: tiiFirstPage)
    #expect(tii == "Communication-Semantic-Aware RDMA Loss Recovery for QP-scalable MoE Training",
            "\(tii ?? "nil")")

    let iwqos = DocumentTitleExtraction.title(fromFirstPage: iwqosFirstPage)
    #expect(iwqos == "Communication-Semantic-Aware RDMA Loss Recovery for QP-scalable Hyperscale AI Training",
            "\(iwqos ?? "nil")")

    let handbook = DocumentTitleExtraction.title(fromFirstPage: handbookFirstPage)
    #expect(handbook?.contains("中国研究生数学建模竞赛") == true, "\(handbook ?? "nil")")
}

@Test("同一篇论文的两版归成一族，尽管文件名和标题全都对不上")
func groupsTheSamePaperAcrossUnrelatedFilenames() throws {
    let tiiID = UUID(uuidString: "505D8287-B39B-488A-B380-76BB3F49E316")!
    let iwqosID = UUID(uuidString: "EF296881-8711-4E6C-9B1C-F69DE4F70BDE")!
    let handbookID = UUID(uuidString: "F8393327-2FF0-407E-9E82-FF4D0DDD608E")!

    let documents = [
        VersionedDocument(
            id: tiiID,
            title: "面向MoE训练的通信语义感知RDMA丢包恢复",
            filename: "Communication_Semantic_Aware_RDMA_Loss_Recovery_for_QP_scalable_Hyperscale_AI_Training__9_-6.pdf",
            kind: .pdf,
            contentDate: Date(timeIntervalSince1970: 1_800_000_000),
            documentTitle: DocumentTitleExtraction.title(fromFirstPage: tiiFirstPage)
        ),
        VersionedDocument(
            id: iwqosID,
            title: "IWQoS2026论文摘要整理",
            filename: "iwqos2026-paper333-2.pdf",
            kind: .pdf,
            contentDate: Date(timeIntervalSince1970: 1_790_000_000),
            documentTitle: DocumentTitleExtraction.title(fromFirstPage: iwqosFirstPage)
        ),
        VersionedDocument(
            id: handbookID,
            title: "研究生数模竞赛学生手册",
            filename: "中国研究生创新实践系列大赛数模竞赛-用户手册（学生）.pdf",
            kind: .pdf,
            contentDate: Date(timeIntervalSince1970: 1_795_000_000),
            documentTitle: DocumentTitleExtraction.title(fromFirstPage: handbookFirstPage)
        ),
    ]

    let families = DocumentVersioning.families(documents)
    #expect(families.count == 1, "分出了 \(families.count) 族")
    let family = try #require(families.first)
    // 最新的一版排在最前面。
    #expect(family.orderedIDs == [tiiID, iwqosID], "\(family.orderedIDs)")
    #expect(!family.orderedIDs.contains(handbookID), "手册被错认成了论文的一版")
}

@Test("名字只沾一点边的不归族")
func doesNotGroupMerelyRelatedDocuments() {
    let documents = [
        VersionedDocument(
            id: UUID(), title: "RDMA 综述", filename: "rdma-survey.pdf", kind: .pdf,
            contentDate: .now,
            documentTitle: "A Survey of RDMA Congestion Control in Datacenters"
        ),
        VersionedDocument(
            id: UUID(), title: "MoE 训练", filename: "moe-training.pdf", kind: .pdf,
            contentDate: .now,
            documentTitle: "Communication-Semantic-Aware RDMA Loss Recovery for QP-scalable MoE Training"
        ),
    ]
    #expect(DocumentVersioning.families(documents).isEmpty)
}

@Test("中文标题按二字组认亲，不需要分词器")
func matchesChineseTitlesByBigrams() {
    let a = DocumentNameSimilarity.tokens("中国研究生数学建模竞赛用户手册")
    let b = DocumentNameSimilarity.tokens("中国研究生数学建模竞赛用户手册（学生）第二版")
    #expect(DocumentNameSimilarity.jaccard(a, b) >= DocumentNameSimilarity.threshold)

    let unrelated = DocumentNameSimilarity.tokens("阿里云访问密钥备注")
    #expect(DocumentNameSimilarity.jaccard(a, unrelated) < DocumentNameSimilarity.threshold)
}

@Test("同一族内部严格按时间从新到旧")
func familyMembersAreStrictlyNewestFirst() throws {
    func document(_ day: Int) -> VersionedDocument {
        VersionedDocument(
            id: UUID(),
            title: "季度报告",
            filename: "quarterly-report-v\(day).pdf",
            kind: .pdf,
            contentDate: Date(timeIntervalSince1970: TimeInterval(1_800_000_000 + day * 86_400)),
            documentTitle: "Quarterly Revenue Report for the Northern Region"
        )
    }
    // 故意乱序喂进去。
    let documents = [document(3), document(1), document(5), document(2)]
    let family = try #require(DocumentVersioning.families(documents).first)
    let byID = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
    let dates = family.orderedIDs.compactMap { byID[$0]?.contentDate }
    #expect(dates.count == 4)
    #expect(dates == dates.sorted(by: >), "\(dates)")
}
