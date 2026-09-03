import Foundation
import Testing
@testable import MnemoCore

private let candidates: [TodoRevisionCandidate] = [
    .init(index: 1, todoID: UUID(), title: "组会"),
    .init(index: 2, todoID: UUID(), title: "提交开题报告"),
]

private func decision(_ json: String) -> TodoRevisionDecision? {
    try? TodoRevisionPrompt.decision(from: json, candidateCount: candidates.count)
}

// MARK: - 白名单

@Test("模型只能引用给过的编号，越界一律降级成什么都不做")
func rejectsOutOfRangeIndex() {
    #expect(decision(#"{"action":"cancel","todo":9}"#)?.action == TodoRevisionDecision.Action.none)
    #expect(decision(#"{"action":"cancel","todo":0}"#)?.action == TodoRevisionDecision.Action.none)
    #expect(decision(#"{"action":"complete"}"#)?.action == TodoRevisionDecision.Action.none)
}

@Test("指向已有待办的动作必须带编号，否则不作数")
func revisionRequiresIndex() {
    for action in ["reschedule", "complete", "cancel", "rename"] {
        #expect(
            decision("{\"action\":\"\(action)\"}")?.action == TodoRevisionDecision.Action.none,
            "\(action) 没给编号却被接受了"
        )
    }
}

@Test("说要改期却给不出新时间，等于什么都没说")
func rescheduleNeedsDate() {
    #expect(decision(#"{"action":"reschedule","todo":1}"#)?.action == TodoRevisionDecision.Action.none)
    #expect(decision(#"{"action":"reschedule","todo":1,"dueAt":null}"#)?.action == TodoRevisionDecision.Action.none)
}

@Test("新建必须给标题")
func createNeedsTitle() {
    #expect(decision(#"{"action":"create"}"#)?.action == TodoRevisionDecision.Action.none)
    #expect(decision(#"{"action":"create","title":"   "}"#)?.action == TodoRevisionDecision.Action.none)
}

@Test("认不出的动作名降级成什么都不做，不抛错")
func unknownActionIsInert() {
    #expect(decision(#"{"action":"delete_everything","todo":1}"#)?.action == TodoRevisionDecision.Action.none)
}

// MARK: - 解析

@Test("合法的改期能解析出编号与时间")
func parsesReschedule() {
    let value = decision(#"{"action":"reschedule","todo":1,"dueAt":"2026-09-02T16:00:00+08:00","reason":"说了改到四点"}"#)
    #expect(value?.action == .reschedule)
    #expect(value?.index == 1)
    #expect(value?.reason == "说了改到四点")
    #expect(value?.dueAt != nil)
}

@Test("容忍 Markdown 代码块包裹与带小数秒的时间")
func toleratesCommonModelFormatting() {
    let fenced = """
    ```json
    {"action":"complete","todo":2,"reason":"本人说已提交"}
    ```
    """
    #expect(decision(fenced)?.action == .complete)

    let fractional = #"{"action":"reschedule","todo":1,"dueAt":"2026-09-02T16:00:00.000+08:00"}"#
    #expect(decision(fractional)?.dueAt != nil)
}

@Test("标题与理由都有长度上限，模型写多长都不会撑爆卡片")
func clampsLongFields() {
    let long = String(repeating: "很长", count: 200)
    let value = decision("{\"action\":\"create\",\"title\":\"\(long)\",\"reason\":\"\(long)\"}")
    #expect((value?.title?.count ?? 0) <= 30)
    #expect((value?.reason.count ?? 0) <= 60)
}

@Test("不是 JSON 时抛错，由调用方按「这一轮没有模型意见」处理")
func throwsOnNonJSON() {
    #expect(throws: (any Error).self) {
        try TodoRevisionPrompt.decision(from: "我觉得应该改到四点", candidateCount: 2)
    }
}

// MARK: - 提示词

@Test("现有待办每次都带上，且只给编号不给真实 ID")
func userMessageCarriesCandidatesByIndex() {
    let message = TodoRevisionPrompt.userMessage(
        text: "组会改到四点",
        candidates: candidates,
        now: Date(timeIntervalSince1970: 1_788_000_000)
    )
    #expect(message.contains("1. 组会"))
    #expect(message.contains("2. 提交开题报告"))
    #expect(message.contains("组会改到四点"))
    // 真实 ID 绝不出域：模型看不到它，也就编不出一个能落回库里的 ID。
    for candidate in candidates {
        #expect(!message.contains(candidate.todoID.uuidString))
    }
}

@Test("源还在时把来源摘录一并给出，源没了就不给")
func includesSourceContextWhenAvailable() {
    let withSource = TodoRevisionCandidate(
        index: 1,
        todoID: UUID(),
        title: "提交开题报告",
        sourceContext: "导师群消息：开题报告周五之前交到教务处"
    )
    let message = TodoRevisionPrompt.userMessage(
        text: "那个报告延期了",
        candidates: [withSource],
        now: .now
    )
    #expect(message.contains("来源摘录"))
    #expect(message.contains("教务处"))

    let withoutSource = TodoRevisionCandidate(index: 1, todoID: UUID(), title: "提交开题报告")
    #expect(!TodoRevisionPrompt.userMessage(
        text: "那个报告延期了",
        candidates: [withoutSource],
        now: .now
    ).contains("来源摘录"))
}

@Test("清单为空时也要说清楚是空的，不能让模型以为没给")
func emptyCandidateListIsExplicit() {
    let message = TodoRevisionPrompt.userMessage(text: "周五交报告", candidates: [], now: .now)
    #expect(message.contains("（空）"))
}

@Test("few-shot 例子覆盖所有可执行动作与空结果")
func examplesCoverEveryOutcome() {
    let examples = TodoRevisionPrompt.examples
    for action in ["reschedule", "cancel", "complete", "create", "rename"] {
        #expect(examples.contains("\"action\":\"\(action)\""), "缺少 \(action) 的示例")
    }
    #expect(examples.contains("\"decisions\":[]"))
    // 第三方主语和"说了改期却没给时间"是最容易出错的两类，必须各有一条。
    #expect(examples.contains("听说隔壁组"))
    #expect(examples.contains("组会改期吧"))
}

// MARK: - 证据校验

@Test("码逐字对上就够：OCR 带错字也不该把候选降级")
func verifiedCodeSurvivesOCRErrors() {
    // 这是库里那张麦当劳截图的真实 OCR：Vision 把"餐"认成了"䬸"、"餐"认成"督"。
    // 模型引用时会顺手纠正回来，所以"引用必须逐字出现"这条判据在截图上
    // 几乎永远失败——而订单号本身是一位不差的。
    let ocr = """
    17:58（
    配餐中.
    • 餐厅配䬸中，冰淇淋在取督时现场
    制作.
    订单号
    35341
    确认中  配餐中  待取餐
    麦当劳承德奥体中心餐厅
    """
    let decision = TodoRevisionDecision(
        action: .create,
        title: "麦当劳取餐 35341",
        kind: .foodPickup,
        service: "麦当劳",
        code: "35341",
        evidence: "餐厅配餐中，冰淇淋在取餐时现场制作. 订单号 35341 待取餐",
        needsConfirmation: false
    )
    #expect(decision.hasVerifiableEvidence(in: ocr))
}

@Test("码对不上一律否决，哪怕引用抄得很像")
func wrongCodeIsRejectedEvenWithGoodEvidence() {
    let ocr = "订单号 35341 配餐中 待取餐"
    let decision = TodoRevisionDecision(
        action: .create,
        title: "取餐",
        code: "35431",
        evidence: "订单号 35341 配餐中 待取餐",
        needsConfirmation: false
    )
    #expect(!decision.hasVerifiableEvidence(in: ocr))
}

@Test("没有码时靠引用重合度：容忍错字，拦得住整句编造")
func evidenceOverlapGatesFabrication() {
    let source = "请各位同学在周五之前提交开题报告，交到教务处"

    // 只有个别字不同（模型纠正 / 换用词），应当通过。
    let paraphrased = TodoRevisionDecision(
        action: .create,
        title: "提交开题报告",
        evidence: "各位同学在周五之前提交开题报告",
        needsConfirmation: false
    )
    #expect(paraphrased.hasVerifiableEvidence(in: source))

    // 整句编造：原文里找不到任何像样的连续片段。
    let invented = TodoRevisionDecision(
        action: .create,
        title: "缴纳学费",
        evidence: "请在下周一之前完成学费缴纳并上传凭证",
        needsConfirmation: false
    )
    #expect(!invented.hasVerifiableEvidence(in: source))
}

@Test("空证据或过短证据不获得自动执行资格")
func emptyEvidenceIsNotVerifiable() {
    let source = "订单号 35341 配餐中"
    #expect(!TodoRevisionDecision(action: .create, title: "x").hasVerifiableEvidence(in: source))
    #expect(!TodoRevisionDecision(action: .create, title: "x", evidence: "订单")
        .hasVerifiableEvidence(in: source))
}

// MARK: - 多任务

@Test("同一句里的两件事解析成两个独立待办并共享日期")
func parsesMultipleIndependentCreates() throws {
    let json = #"{"decisions":[{"action":"create","todo":null,"title":"看完项目","dueAt":"2026-09-03T23:59:00+08:00","evidence":"看完项目","needsConfirmation":false},{"action":"create","todo":null,"title":"写完论文","dueAt":"2026-09-03T23:59:00+08:00","evidence":"写完论文","needsConfirmation":false}]}"#
    let values = try TodoRevisionPrompt.decisions(from: json, candidateCount: candidates.count)

    #expect(values.map(\.title) == ["看完项目", "写完论文"])
    #expect(values.count == 2)
    #expect(values[0].dueAt == values[1].dueAt)
}

@Test("批量结果逐项校验，坏项不会拖掉同批的好项")
func validatesEveryDecisionIndependently() throws {
    let json = #"{"decisions":[{"action":"cancel","todo":99},{"action":"create","title":"写完论文","evidence":"写完论文","needsConfirmation":false},{"action":"reschedule","todo":1,"dueAt":null}]}"#
    let values = try TodoRevisionPrompt.decisions(from: json, candidateCount: candidates.count)

    #expect(values.count == 1)
    #expect(values.first?.action == .create)
    #expect(values.first?.title == "写完论文")
}

@Test("批量结果会去重并严格限制最多五项")
func deduplicatesAndCapsDecisionBatch() throws {
    let entries = [
        #"{"action":"create","title":"任务 A","dueAt":"2026-09-03T23:59:00+08:00"}"#,
        #"{"action":"create","title":"任务A","dueAt":"2026-09-03T23:59:00+08:00"}"#,
        #"{"action":"create","title":"任务 B"}"#,
        #"{"action":"create","title":"任务 C"}"#,
        #"{"action":"create","title":"任务 D"}"#,
        #"{"action":"create","title":"任务 E"}"#,
        #"{"action":"create","title":"任务 F"}"#,
    ]
    let values = try TodoRevisionPrompt.decisions(
        from: "{\"decisions\":[\(entries.joined(separator: ","))]}",
        candidateCount: candidates.count
    )

    #expect(values.count == TodoRevisionPrompt.maximumDecisionCount)
    #expect(values.compactMap(\.title) == ["任务 A", "任务 B", "任务 C", "任务 D", "任务 E"])
}

@Test("空 decisions 是模型明确判断没有任务，旧单对象仍兼容")
func handlesEmptyAndLegacyResponses() throws {
    #expect(try TodoRevisionPrompt.decisions(
        from: #"{"decisions":[]}"#,
        candidateCount: candidates.count
    ).isEmpty)
    #expect(try TodoRevisionPrompt.decisions(
        from: #"{"action":"create","title":"旧格式任务"}"#,
        candidateCount: candidates.count
    ).first?.title == "旧格式任务")
}

@Test("多任务 few-shot 明确要求并列动作拆开")
func examplesTeachMultiTaskSplitting() {
    #expect(TodoRevisionPrompt.system.contains("并列动作必须拆开"))
    #expect(TodoRevisionPrompt.examples.contains("今天要看完项目并写完论文"))
    #expect(TodoRevisionPrompt.examples.contains("\"title\":\"看完项目\""))
    #expect(TodoRevisionPrompt.examples.contains("\"title\":\"写完论文\""))
}

@Test("同一条现有待办一批里最多接受一次修改")
func oneMutationPerExistingTodoPerBatch() throws {
    let json = #"{"decisions":[{"action":"reschedule","todo":1,"dueAt":"2026-09-03T16:00:00+08:00"},{"action":"cancel","todo":1},{"action":"complete","todo":2}]}"#
    let values = try TodoRevisionPrompt.decisions(from: json, candidateCount: candidates.count)

    #expect(values.count == 2)
    #expect(values[0].action == .reschedule)
    #expect(values[0].index == 1)
    #expect(values[1].action == .complete)
    #expect(values[1].index == 2)
}
