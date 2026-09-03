import Foundation
import Testing
@testable import MnemoCore

/// 待办识别的整体评测。
///
/// 逐条行为测试回答"这一条为什么该这样"；这里回答"整体上对多少、要多久"。
/// 结果可导出成 Markdown 报告：
///
///     MNEMO_EVAL_REPORT=docs/todo-recognition-eval-result.md swift test
///
/// 不设环境变量时只跑断言，不写文件——评测不该在每次普通测试里改动工作区。
struct TodoRecognitionEval {

    enum Outcome: String {
        /// 判对了。
        case correct
        /// 该有结论却什么都没给。
        case missed
        /// 不该动却动了。误报比漏报伤，因为用户根本没触发任何东西。
        case falsePositive
        /// 给了结论，但动作或对象不对。
        case wrong
    }

    struct Result {
        var caseID: String
        var category: String
        var needsModel: Bool
        var outcome: Outcome
        var detail: String
        var seconds: Double
    }

    /// 只跑本地确定性层。模型那一版（few-shot）跑同一份语料、同一套判定，
    /// 两列并排就是这次引入 few-shot 的净收益。
    static func runLocal() -> [Result] {
        TodoRecognitionCorpus.cases.map { evaluate($0) }
    }

    private static func evaluate(_ testCase: TodoRecognitionCorpus.Case) -> Result {
        let todos = TodoRecognitionCorpus.todos(testCase.todos)
        let started = Date()
        let drafts = ClipboardTodoExtractor.drafts(
            from: testCase.text,
            now: TodoRecognitionCorpus.now,
            calendar: TodoRecognitionCorpus.calendar
        )
        let plans = TodoReconciler.plans(
            text: testCase.text,
            drafts: drafts,
            todos: todos,
            now: TodoRecognitionCorpus.now,
            calendar: TodoRecognitionCorpus.calendar,
            limit: TodoRevisionPrompt.maximumDecisionCount
        )
        let seconds = Date().timeIntervalSince(started)
        let (outcome, detail) = judge(plans: plans, expected: testCase.expectation, todos: todos)
        return Result(
            caseID: testCase.id,
            category: testCase.category,
            needsModel: testCase.needsModel,
            outcome: outcome,
            detail: detail,
            seconds: seconds
        )
    }

    private static func judge(
        plans: [TodoRevisionPlan],
        expected: TodoRecognitionCorpus.Expectation,
        todos: [Todo]
    ) -> (Outcome, String) {
        if case .none = expected {
            guard !plans.isEmpty else { return (.correct, "") }
            return (
                .falsePositive,
                "多给了 " + plans.map { label($0.revision, todos: todos) }.joined(separator: "、")
            )
        }

        if case .creates(let needles) = expected {
            let created = plans.compactMap { plan -> String? in
                guard case .create(let draft) = plan.revision else { return nil }
                return draft.title
            }
            guard plans.count == needles.count, created.count == needles.count else {
                return (
                    plans.isEmpty ? .missed : .wrong,
                    "得到 \(created.count) 条新建，期望 \(needles.count) 条；实际："
                        + (created.isEmpty ? "无" : created.joined(separator: "、"))
                )
            }
            let unmatched = needles.filter { needle in
                !created.contains(where: { $0.contains(needle) })
            }
            return unmatched.isEmpty
                ? (.correct, "")
                : (.wrong, "缺少：" + unmatched.joined(separator: "、"))
        }

        guard let plan = plans.first else { return (.missed, "什么都没给") }
        guard plans.count == 1 else {
            return (
                .wrong,
                "期望一条，却给了：" + plans.map { label($0.revision, todos: todos) }
                    .joined(separator: "、")
            )
        }
        return judgeSingle(plan: plan, expected: expected, todos: todos)
    }

    private static func judgeSingle(
        plan: TodoRevisionPlan,
        expected: TodoRecognitionCorpus.Expectation,
        todos: [Todo]
    ) -> (Outcome, String) {
        func title(of id: UUID) -> String { todos.first { $0.id == id }?.title ?? "?" }

        switch (expected, plan.revision) {
        case (.create(let needle), .create(let draft)):
            return draft.title.contains(needle)
                ? (.correct, "")
                : (.wrong, "标题「\(draft.title)」不含「\(needle)」")

        case (.reschedule(let wanted, let hour, let day), .reschedule(let id, _, _, let to)):
            guard title(of: id) == wanted else {
                return (.wrong, "改到了「\(title(of: id))」而不是「\(wanted)」")
            }
            let components = TodoRecognitionCorpus.calendar
                .dateComponents([.day, .hour], from: to)
            if let hour, components.hour != hour {
                return (.wrong, "时间是 \(components.hour ?? -1) 点，期望 \(hour) 点")
            }
            if let day, components.day != day {
                return (.wrong, "日期是 \(components.day ?? -1) 号，期望 \(day) 号")
            }
            return (.correct, "")

        case (.complete(let wanted), .complete(let id, _)):
            return title(of: id) == wanted ? (.correct, "") : (.wrong, "对象不对")
        case (.cancel(let wanted), .cancel(let id, _)):
            return title(of: id) == wanted ? (.correct, "") : (.wrong, "对象不对")

        case (_, let actual):
            return (.wrong, "给出的是 \(label(actual, todos: todos))")
        }
    }

    private static func label(_ revision: TodoRevision, todos: [Todo]) -> String {
        switch revision {
        case .create(let draft): "新建「\(draft.title)」"
        case .reschedule(_, let title, _, _): "改期「\(title)」"
        case .rename(_, let from, let to, _, _): "改名「\(from)」→「\(to)」"
        case .complete(_, let title): "完成「\(title)」"
        case .cancel(_, let title): "取消「\(title)」"
        }
    }

    // MARK: - 报告

    static func report(_ results: [Result]) -> String {
        let local = results.filter { !$0.needsModel }
        let modelOnly = results.filter(\.needsModel)
        let correct = local.filter { $0.outcome == .correct }.count
        let times = results.map(\.seconds).sorted()

        var lines: [String] = []
        lines.append("# 待办识别评测结果")
        lines.append("")
        lines.append("由 `TodoRecognitionEvalTests` 自动生成，语料见 `TodoRecognitionCorpus.swift`。")
        lines.append("")
        lines.append("生成时间：\(ISO8601DateFormatter().string(from: .now))")
        lines.append("")
        lines.append("## 总体")
        lines.append("")
        lines.append("| 指标 | 本地确定性层 | 本地 + few-shot |")
        lines.append("| --- | --- | --- |")
        lines.append("| 语料条数 | \(results.count) | \(results.count) |")
        lines.append("| 其中本地层可覆盖 | \(local.count) | \(results.count) |")
        lines.append("| 判对 | \(correct) | 待测 |")
        lines.append(String(
            format: "| 准确率（可覆盖子集） | %.1f%% | 待测 |",
            local.isEmpty ? 0 : Double(correct) / Double(local.count) * 100
        ))
        lines.append("| 误报 | \(local.filter { $0.outcome == .falsePositive }.count) | 待测 |")
        lines.append("| 漏报 | \(local.filter { $0.outcome == .missed }.count) | 待测 |")
        lines.append("| 错判 | \(local.filter { $0.outcome == .wrong }.count) | 待测 |")
        lines.append("| 本地层结构性覆盖不到 | \(modelOnly.count) | 待测 |")
        lines.append("")
        if let median = times[safe: times.count / 2], let p95 = times[safe: Int(Double(times.count) * 0.95)] {
            lines.append(String(
                format: "单条耗时：中位数 %.3f ms，P95 %.3f ms（提取 + 协调，不含 OCR）。",
                median * 1_000, p95 * 1_000
            ))
            lines.append("")
        }

        lines.append("## 分类")
        lines.append("")
        lines.append("| 类别 | 条数 | 判对 | 误报 | 漏报 | 错判 |")
        lines.append("| --- | --- | --- | --- | --- | --- |")
        for category in Array(Set(results.map(\.category))).sorted() {
            let bucket = results.filter { $0.category == category && !$0.needsModel }
            guard !bucket.isEmpty else { continue }
            lines.append(
                "| \(category) | \(bucket.count) "
                + "| \(bucket.filter { $0.outcome == .correct }.count) "
                + "| \(bucket.filter { $0.outcome == .falsePositive }.count) "
                + "| \(bucket.filter { $0.outcome == .missed }.count) "
                + "| \(bucket.filter { $0.outcome == .wrong }.count) |"
            )
        }
        lines.append("")

        let failures = local.filter { $0.outcome != .correct }
        if !failures.isEmpty {
            lines.append("## 本地层未通过")
            lines.append("")
            lines.append("| 用例 | 类别 | 结果 | 说明 |")
            lines.append("| --- | --- | --- | --- |")
            for item in failures {
                lines.append("| \(item.caseID) | \(item.category) | \(item.outcome.rawValue) | \(item.detail) |")
            }
            lines.append("")
        }

        lines.append("## 留给 few-shot 的用例")
        lines.append("")
        lines.append("本地确定性层**结构性**做不到的几条。它们不是 bug，是这一层的边界；")
        lines.append("引入 few-shot 之后这几条的表现就是这次改动的净收益。")
        lines.append("")
        lines.append("| 用例 | 类别 | 本地层结果 | 说明 |")
        lines.append("| --- | --- | --- | --- |")
        for item in modelOnly {
            let note = TodoRecognitionCorpus.cases.first { $0.id == item.caseID }?.note ?? ""
            lines.append("| \(item.caseID) | \(item.category) | \(item.outcome.rawValue) | \(note) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

@Test("本地确定性层在评测语料上不出现误报")
func localLayerHasNoFalsePositives() {
    let results = TodoRecognitionEval.runLocal()
    let falsePositives = results.filter { !$0.needsModel && $0.outcome == .falsePositive }
    #expect(
        falsePositives.isEmpty,
        "误报：\(falsePositives.map { "\($0.caseID) \($0.detail)" }.joined(separator: "；"))"
    )
}

@Test("本地确定性层在可覆盖子集上全部判对")
func localLayerCoversItsSubset() {
    let results = TodoRecognitionEval.runLocal()
    let failures = results.filter { !$0.needsModel && $0.outcome != .correct }
    #expect(
        failures.isEmpty,
        "未通过：\(failures.map { "\($0.caseID)（\($0.outcome.rawValue)）\($0.detail)" }.joined(separator: "；"))"
    )
}

@Test("单条识别耗时留在交互预算内")
func recognitionStaysFast() {
    let results = TodoRecognitionEval.runLocal()
    let worst = results.map(\.seconds).max() ?? 0
    #expect(worst < 0.02, "最慢一条 \(String(format: "%.2f", worst * 1_000)) ms")
}

/// 导出报告。设了 `MNEMO_EVAL_REPORT` 才写文件。
@Test("评测报告可导出")
func exportsReport() throws {
    let results = TodoRecognitionEval.runLocal()
    let text = TodoRecognitionEval.report(results)
    #expect(text.contains("待办识别评测结果"))
    guard let path = ProcessInfo.processInfo.environment["MNEMO_EVAL_REPORT"] else { return }
    try text.write(to: URL(filePath: path), atomically: true, encoding: .utf8)
}
