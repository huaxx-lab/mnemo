import Foundation
import Testing
@testable import MnemoCore

private let calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    value.locale = Locale(identifier: "zh_CN")
    return value
}()

/// 2026-09-02 周三 10:00 (UTC+8)
private let now: Date = {
    var c = DateComponents()
    c.year = 2026; c.month = 9; c.day = 2; c.hour = 10
    return calendar.date(from: c)!
}()

private func at(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    var c = DateComponents()
    c.year = 2026; c.month = month; c.day = day; c.hour = hour; c.minute = minute
    return calendar.date(from: c)!
}

private func hourOf(_ date: Date) -> Int { calendar.component(.hour, from: date) }
private func dayOf(_ date: Date) -> Int { calendar.component(.day, from: date) }

private let meeting = Todo(title: "在305开组会", dueAt: at(9, 2, 15))
private let report = Todo(title: "提交开题报告", dueAt: at(9, 5, 23, 59))
private let library = [meeting, report]

private func plan(_ text: String, todos: [Todo] = library) -> TodoRevisionPlan? {
    TodoReconciler.plan(
        text: text,
        draft: ClipboardTodoExtractor.draft(from: text, now: now, calendar: calendar),
        todos: todos,
        now: now,
        calendar: calendar
    )
}

// MARK: - 匹配

@Test("标题只有一部分原样出现也算同一件事")
func similarityHandlesPartialTitles() {
    #expect(TodoReconciler.similarity(title: "在305开组会", text: "组会改到四点") >= TodoReconciler.matchThreshold)
    #expect(TodoReconciler.similarity(title: "组会", text: "组会改到四点") == 1)
    // 单字重合是巧合。
    #expect(TodoReconciler.similarity(title: "开会", text: "今天天气不错开心") == 0)
    // 只共用一个通用词不算同一件事。
    #expect(TodoReconciler.similarity(title: "提交开题报告", text: "记得提交材料") == 0)
}

@Test("两条待办同样像时判为有歧义，不挑一个")
func ambiguousMatchIsRejected() {
    let a = Todo(title: "组会", dueAt: at(9, 2, 15))
    let b = Todo(title: "组会", dueAt: at(9, 3, 15))
    #expect(TodoReconciler.match(text: "组会改到四点", in: [a, b]) == nil)
}

@Test("已完成的待办不参与匹配")
func completedTodosAreIgnored() {
    var done = meeting
    done.isCompleted = true
    #expect(TodoReconciler.match(text: "组会改到四点", in: [done]) == nil)
}

// MARK: - 改期

@Test("明说改到几点：改期，且强匹配时不必再问")
func explicitReschedule() {
    let value = plan("组会改到四点", todos: [Todo(title: "组会", dueAt: at(9, 2, 15))])
    guard case .reschedule(_, _, _, let to)? = value?.revision else {
        Issue.record("期望 reschedule，实得 \(String(describing: value?.revision))")
        return
    }
    #expect(hourOf(to) == 16)
    #expect(value?.isCertain == true)
}

@Test("标题只有一部分命中时改期要问一句")
func weakMatchRescheduleAsks() {
    let value = plan("组会改到四点")
    guard case .reschedule(let id, _, _, let to)? = value?.revision else {
        Issue.record("期望 reschedule")
        return
    }
    #expect(id == meeting.id)
    #expect(hourOf(to) == 16)
    #expect(value?.isCertain == false)
}

@Test("延期到某一天：没写钟点时落在当天结束")
func rescheduleToDayFallsAtEndOfDay() {
    let value = plan("开题报告延期到下周一")
    guard case .reschedule(let id, _, _, let to)? = value?.revision else {
        Issue.record("期望 reschedule")
        return
    }
    #expect(id == report.id)
    #expect(dayOf(to) == 7)
    #expect(hourOf(to) == 23)
}

@Test("说了改期却没给新时间：不产生任何提案")
func rescheduleWithoutNewTimeIsIgnored() {
    #expect(plan("组会改期吧") == nil)
}

@Test("改到的时间和现在一样：不算改期")
func noOpRescheduleIsIgnored() {
    #expect(plan("组会改到下午三点", todos: [Todo(title: "组会", dueAt: at(9, 2, 15))]) == nil)
}

// MARK: - 取消与完成

@Test("取消一律要问，绝不自动删")
func cancelAlwaysAsks() {
    let value = plan("这周组会取消")
    guard case .cancel(let id, _)? = value?.revision else {
        Issue.record("期望 cancel，实得 \(String(describing: value?.revision))")
        return
    }
    #expect(id == meeting.id)
    #expect(value?.isCertain == false)
}

@Test("取消比改期强：一句话里两者都有时按取消算")
func cancelOutranksReschedule() {
    let value = plan("组会取消了，改到下周再说")
    guard case .cancel? = value?.revision else {
        Issue.record("期望 cancel")
        return
    }
}

@Test("本人说交了：标记完成，但仍然要问")
func completeAsks() {
    let value = plan("开题报告我已经交上去了")
    guard case .complete(let id, _)? = value?.revision else {
        Issue.record("期望 complete，实得 \(String(describing: value?.revision))")
        return
    }
    #expect(id == report.id)
    #expect(value?.isCertain == false)
}

@Test("说的是别人：一个字都不改")
func thirdPartyStatementsAreIgnored() {
    #expect(plan("听说隔壁组的开题报告交了") == nil)
    #expect(plan("他们的组会取消了") == nil)
    #expect(TodoReconciler.intent(in: "据说开题报告延期到下周") == nil)
}

// MARK: - 新建与去重

@Test("清单里没有的事才新建")
func createsOnlyWhatIsMissing() {
    let value = plan("请各位同学在周五之前提交课程论文")
    guard case .create(let draft)? = value?.revision else {
        Issue.record("期望 create，实得 \(String(describing: value?.revision))")
        return
    }
    #expect(draft.title.contains("课程论文"))
}

@Test("同一件事同一个时间再来一遍：什么都不做")
func duplicateIsSuppressed() {
    #expect(plan("请在 9月5日 之前提交开题报告") == nil)
}

@Test("同一件事但时间不同、又没明说改期：提出改期并要求确认")
func implicitRescheduleAsks() {
    let value = plan("请在 9月4日 之前提交开题报告")
    guard case .reschedule(let id, _, _, let to)? = value?.revision else {
        Issue.record("期望 reschedule，实得 \(String(describing: value?.revision))")
        return
    }
    #expect(id == report.id)
    #expect(dayOf(to) == 4)
    #expect(value?.isCertain == false)
}

// MARK: - 边界

@Test("清单为空时只可能是新建")
func emptyLibraryOnlyCreates() {
    let value = plan("周五之前提交开题报告", todos: [])
    guard case .create? = value?.revision else {
        Issue.record("期望 create")
        return
    }
    #expect(plan("组会改到四点", todos: []) == nil)
}

@Test("原本没有截止时间的待办也能被改期")
func rescheduleFromNilDueDate() {
    let open = Todo(title: "组会")
    let value = plan("组会改到四点", todos: [open])
    guard case .reschedule(_, _, let from, let to)? = value?.revision else {
        Issue.record("期望 reschedule")
        return
    }
    #expect(from == nil)
    #expect(hourOf(to) == 16)
}

@Test("空白与无关文字不产生提案")
func reconciliationDegenerateInputs() {
    #expect(plan("") == nil)
    #expect(plan("   \n ") == nil)
    #expect(plan("今天食堂人好多") == nil)
    #expect(plan("let x = items.map(\\.id)") == nil)
}

@Test("整段聊天记录里认出改期，不被周围的废话干扰")
func findsRevisionInsideChatLog() {
    let chat = """
    小王：今天中午吃什么
    小李：随便吧
    导师：各位，组会改到四点，教室不变
    小王：收到
    """
    let value = plan(chat, todos: [Todo(title: "组会", dueAt: at(9, 2, 15))])
    guard case .reschedule(_, _, _, let to)? = value?.revision else {
        Issue.record("期望 reschedule，实得 \(String(describing: value?.revision))")
        return
    }
    #expect(hourOf(to) == 16)
}

// MARK: - 性能

@Test("协调在真实规模下足够快，能放在剪贴板路径上跑")
func reconciliationIsFastEnough() {
    let todos = (0..<40).map { Todo(title: "待办事项编号\($0)", dueAt: at(9, 5, 12)) }
        + [meeting, report]
    let chat = String(repeating: "小王：随便聊两句，没什么要紧的事。\n", count: 40)
        + "导师：组会改到四点\n"
    let perRun = cpuSeconds {
        for _ in 0..<20 {
            _ = TodoReconciler.plan(
                text: chat, draft: nil, todos: todos, now: now, calendar: calendar
            )
        }
    } / 20
    #expect(perRun < 0.02, "单次协调 \(String(format: "%.2f", perRun * 1000)) ms CPU")
}

@Test("本地回退不会再把多个草稿截成第一条")
func localFallbackKeepsMultipleDrafts() {
    let first = TodoDraft(
        id: "a", title: "提交项目报告", dueAt: at(9, 4, 23, 59),
        source: .deadline, reason: "第一条"
    )
    let second = TodoDraft(
        id: "b", title: "参加课程答辩", dueAt: at(9, 5, 15),
        source: .appointment, reason: "第二条"
    )
    let values = TodoReconciler.plans(
        text: "周四提交项目报告；周五参加课程答辩",
        drafts: [first, second],
        todos: [],
        now: now,
        calendar: calendar
    )

    #expect(values.count == 2)
    #expect(values.map(\.title) == ["提交项目报告", "参加课程答辩"])
}

@Test("批量本地提案不会重复修改同一个现有待办")
func localBatchTouchesExistingTodoOnce() {
    let meeting = Todo(title: "组会", dueAt: at(9, 2, 15))
    let duplicateDrafts = [
        TodoDraft(id: "a", title: "组会", dueAt: at(9, 2, 16), source: .appointment, reason: "a"),
        TodoDraft(id: "b", title: "组会", dueAt: at(9, 2, 16), source: .appointment, reason: "b"),
    ]
    let values = TodoReconciler.plans(
        text: "组会改到四点",
        drafts: duplicateDrafts,
        todos: [meeting],
        now: now,
        calendar: calendar
    )

    #expect(values.count == 1)
    guard case .reschedule(let id, _, _, _)? = values.first?.revision else {
        Issue.record("应得到一条改期")
        return
    }
    #expect(id == meeting.id)
}

@Test("直接加入设置不能授权修改或删除已有待办")
func existingTodoMutationsRequireExplicitConfirmation() {
    let create = TodoRevision.create(TodoDraft(
        id: "new", title: "新任务", dueAt: nil, source: .appointment, reason: "new"
    ))
    #expect(!create.requiresExplicitConfirmation)
    #expect(!TodoRevision.reschedule(
        todoID: UUID(), title: "组会", from: nil, to: now
    ).requiresExplicitConfirmation)
    #expect(TodoRevision.rename(
        todoID: UUID(), from: "旧", to: "新", dueAt: nil, previousDueAt: nil
    ).requiresExplicitConfirmation)
    #expect(TodoRevision.complete(todoID: UUID(), title: "任务").requiresExplicitConfirmation)
    #expect(TodoRevision.cancel(todoID: UUID(), title: "任务").requiresExplicitConfirmation)
}

// MARK: - 提醒重排

@Test("改时间、勾完成、删除都会改变排期指纹")
func reminderFingerprintTracksEveryScheduleInput() {
    // 指纹只在 AppModel 里；这里守住它依赖的那几个字段确实构成排期输入，
    // 任何一个变了都必须重排。策略层是共用的，用它来验。
    let settings = TodoReminderSettings(isEnabled: true, leadMinutes: 10)
    let due = Date.now.addingTimeInterval(3_600)
    let todo = Todo(title: "开组会", dueAt: due)

    let onTime = TodoReminderPolicy.firstFireDate(for: todo, settings: settings)
    #expect(onTime != nil)

    var moved = todo
    moved.dueAt = due.addingTimeInterval(7_200)
    #expect(TodoReminderPolicy.firstFireDate(for: moved, settings: settings) != onTime)

    var done = todo
    done.isCompleted = true
    #expect(TodoReminderPolicy.firstFireDate(for: done, settings: settings) == nil,
            "已完成的待办不该再排提醒")
}

@Test("提前量按设置生效：到期前 N 分钟响")
func reminderHonoursLeadMinutes() {
    let due = Date(timeIntervalSince1970: 1_800_000_000)
    let todo = Todo(title: "答辩", dueAt: due)
    let fire = TodoReminderPolicy.firstFireDate(
        for: todo,
        settings: TodoReminderSettings(isEnabled: true, leadMinutes: 15)
    )
    #expect(fire == due.addingTimeInterval(-15 * 60))
}
