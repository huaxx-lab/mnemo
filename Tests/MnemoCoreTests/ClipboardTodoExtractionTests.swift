import Foundation
import Testing
@testable import MnemoCore

/// 全部用固定时区的日历，避免测试在跨时区机器上给出不同的"今天"。
private let calendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    value.locale = Locale(identifier: "zh_CN")
    return value
}()

/// 2026-09-02 周三 10:00 (UTC+8)
private let now: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 2
    components.hour = 10
    return calendar.date(from: components)!
}()

private func parts(_ date: Date) -> (Int, Int, Int, Int, Int) {
    let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    return (c.year!, c.month!, c.day!, c.hour!, c.minute!)
}

// MARK: - 日期解析

@Test("相对日期：明天、后天、大后天不会互相抢匹配")
func parsesRelativeDays() {
    #expect(parts(ChineseDateParser.firstDate(in: "明天交", now: now, calendar: calendar)!.date).2 == 3)
    #expect(parts(ChineseDateParser.firstDate(in: "后天交", now: now, calendar: calendar)!.date).2 == 4)
    #expect(parts(ChineseDateParser.firstDate(in: "大后天交", now: now, calendar: calendar)!.date).2 == 5)
}

@Test("星期：本周未过的取本周，下周三整整加七天")
func parsesWeekdays() {
    // 9/2 是周三。"周五"→ 9/4，"下周三"→ 9/9。
    #expect(parts(ChineseDateParser.firstDate(in: "周五之前提交", now: now, calendar: calendar)!.date).2 == 4)
    #expect(parts(ChineseDateParser.firstDate(in: "下周三答辩", now: now, calendar: calendar)!.date).2 == 9)
}

@Test("绝对日期：年月日、月日、以及只写月日时自动落到下一个该日期")
func parsesAbsoluteDates() {
    let full = ChineseDateParser.firstDate(in: "2026年12月31日截止", now: now, calendar: calendar)!
    #expect(parts(full.date).0 == 2026)
    #expect(parts(full.date).1 == 12)
    #expect(parts(full.date).2 == 31)

    // 现在是 9 月，"1月3日"指的是明年。
    let rolled = ChineseDateParser.firstDate(in: "1月3日报到", now: now, calendar: calendar)!
    #expect(parts(rolled.date).0 == 2027)
    #expect(parts(rolled.date).1 == 1)
}

@Test("时间：上午/下午与「点半」都算进去，且标记为显式时间")
func parsesTimeOfDay() {
    let afternoon = ChineseDateParser.firstDate(in: "明天下午三点半开会", now: now, calendar: calendar)!
    #expect(afternoon.hasExplicitTime)
    #expect(parts(afternoon.date).3 == 15)
    #expect(parts(afternoon.date).4 == 30)

    let morning = ChineseDateParser.firstDate(in: "9月5日上午9:00面试", now: now, calendar: calendar)!
    #expect(parts(morning.date).3 == 9)
    #expect(parts(morning.date).4 == 0)
}

@Test("只写钟点而当天已经过去时顺延到明天")
func rollsPastTimeToTomorrow() {
    let value = ChineseDateParser.firstDate(in: "8点开会", now: now, calendar: calendar)!
    #expect(parts(value.date).2 == 3)
    #expect(parts(value.date).3 == 8)
}

@Test("没有任何时间表达时返回 nil，不猜一个出来")
func returnsNilWithoutDate() {
    #expect(ChineseDateParser.firstDate(in: "帮我看看这个方案怎么样", now: now, calendar: calendar) == nil)
}

// MARK: - 待办提取

@Test("取餐码变成当天的取餐待办，码原样保留")
func extractsPickupCode() {
    let draft = ClipboardTodoExtractor.draft(
        from: "您的餐品已备好，取餐码 A12，请到 3 号窗口领取",
        now: now,
        calendar: calendar
    )
    #expect(draft?.source == .pickupCode)
    #expect(draft?.code == "A12")
    #expect(draft?.title == "取餐 A12")
    #expect(parts(draft!.dueAt!).2 == 2)
}

@Test("验证码不进待办：它几分钟就失效，留一条只是噪音")
func skipsVerificationCode() {
    let drafts = ClipboardTodoExtractor.drafts(
        from: "【某某】验证码 583921，5 分钟内有效，请勿转发",
        now: now,
        calendar: calendar
    )
    #expect(drafts.isEmpty)
}

@Test("快递：只有单号不算待办，出现取件码或驿站才算")
func extractsDeliveryOnlyWhenActionable() {
    #expect(ClipboardTodoExtractor.drafts(
        from: "快递单号：SF1234567890",
        now: now,
        calendar: calendar
    ).isEmpty)

    let draft = ClipboardTodoExtractor.draft(
        from: "您的包裹已到菜鸟驿站，取件码 8-3-2201，请及时取件",
        now: now,
        calendar: calendar
    )
    #expect(draft?.source == .delivery)
    #expect(draft?.code == "8-3-2201")
}

@Test("截止类：没写钟点时按当天 23:59 算，而不是零点")
func deadlineFallsAtEndOfDay() {
    let draft = ClipboardTodoExtractor.draft(
        from: "请各位同学在周五之前提交开题报告",
        now: now,
        calendar: calendar
    )
    #expect(draft?.source == .deadline)
    let due = parts(draft!.dueAt!)
    #expect(due.2 == 4)
    #expect(due.3 == 23)
    #expect(due.4 == 59)
}

@Test("会议类保留原始钟点，不被拉到当天结束")
func appointmentKeepsExplicitTime() {
    let draft = ClipboardTodoExtractor.draft(
        from: "明天下午两点在 305 开组会",
        now: now,
        calendar: calendar
    )
    #expect(draft?.source == .appointment)
    #expect(parts(draft!.dueAt!).3 == 14)
}

@Test("有时间但没有日程线索词的句子不产生待办")
func ignoresPlainDates() {
    #expect(ClipboardTodoExtractor.drafts(
        from: "这款产品 2026年3月 在国内正式发售，销量不错",
        now: now,
        calendar: calendar
    ).isEmpty)
}

@Test("已经过去很久的日期是历史陈述，不是待办")
func ignoresPastDeadlines() {
    #expect(ClipboardTodoExtractor.drafts(
        from: "报名已于 2026年1月5日 截止",
        now: now,
        calendar: calendar
    ).isEmpty)
}

@Test("同一段文字提取多条时按可信度排序，且不重复")
func rankedAndDeduplicated() {
    let text = """
    【教务处】各位同学：开题报告请在周五之前提交
    您的包裹已到菜鸟驿站，取件码 8-3-2201
    下周三下午三点在 305 答辩
    """
    let drafts = ClipboardTodoExtractor.drafts(from: text, now: now, calendar: calendar)
    #expect(drafts.count == 3)
    #expect(drafts[0].source == .delivery)
    #expect(Set(drafts.map(\.id)).count == 3)
}

@Test("标题去掉通知套话与时间词，只留要做的事")
func stripsBoilerplateFromTitle() {
    let draft = ClipboardTodoExtractor.draft(
        from: "【教务处】通知：请于 9月10日 前提交课程论文",
        now: now,
        calendar: calendar
    )
    #expect(draft != nil)
    #expect(!draft!.title.contains("【"))
    #expect(!draft!.title.contains("9月10日"))
    #expect(draft!.title.contains("课程论文"))
}

// MARK: - 边界条件

@Test("区间写法不会被读成日期：3-5天内不是 3 月 5 日")
func rangeIsNotADate() {
    let value = ChineseDateParser.firstDate(in: "请在 3-5 天内提交", now: now, calendar: calendar)
    // 命中的应该是"5 天内"这个相对量，落在 9/7，而不是 3 月 5 日。
    #expect(value != nil)
    #expect(parts(value!.date).1 == 9)
}

@Test("过去时陈述不产生待办，哪怕只写了月日会被顺延到明年")
func pastTenseNeverBecomesTodo() {
    #expect(ClipboardTodoExtractor.drafts(
        from: "报名已于 1月5日 截止，请等待下一轮",
        now: now,
        calendar: calendar
    ).isEmpty)
    #expect(ClipboardTodoExtractor.drafts(
        from: "该活动已结束，原定 12月1日 提交",
        now: now,
        calendar: calendar
    ).isEmpty)
}

@Test("整屏 OCR 合成的长行会按句子继续拆，不被整行丢掉")
func longOCRLineIsSplitIntoSentences() {
    let blob = String(repeating: "这是一段无关的说明文字，用来把这一行撑得很长。", count: 12)
        + "请各位同学在周五之前提交开题报告。"
        + String(repeating: "后面还有更多无关内容。", count: 12)
    let draft = ClipboardTodoExtractor.draft(from: blob, now: now, calendar: calendar)
    #expect(draft?.source == .deadline)
    #expect(draft!.title.contains("开题报告"))
}

@Test("取件码旁边出现「餐」字不会把动词说成取餐")
func pickupVerbComesFromTheMatchedCue() {
    let draft = ClipboardTodoExtractor.draft(
        from: "取件码 A12，餐厅在一楼西侧",
        now: now,
        calendar: calendar
    )
    #expect(draft?.title == "取件 A12")
}

@Test("码类待办不会被文本里无关的远期日期带跑")
func pickupDueStaysToday() {
    let draft = ClipboardTodoExtractor.draft(
        from: "取餐码 B72，本券有效期至 2027年3月1日",
        now: now,
        calendar: calendar
    )
    #expect(draft != nil)
    #expect(parts(draft!.dueAt!).1 == 9)
    #expect(parts(draft!.dueAt!).2 == 2)
}

@Test("完全无关的内容一次正则都不跑就返回空")
func unrelatedTextExitsEarly() {
    #expect(ClipboardTodoExtractor.drafts(
        from: "let value = items.map(\\.id).sorted()",
        now: now,
        calendar: calendar
    ).isEmpty)
    #expect(ClipboardTodoExtractor.drafts(
        from: "https://developer.apple.com/design/human-interface-guidelines/",
        now: now,
        calendar: calendar
    ).isEmpty)
}

@Test("空白、超短、超长输入都不会崩也不会误报")
func degenerateInputs() {
    #expect(ClipboardTodoExtractor.drafts(from: "", now: now, calendar: calendar).isEmpty)
    #expect(ClipboardTodoExtractor.drafts(from: "   \n\n ", now: now, calendar: calendar).isEmpty)
    #expect(ClipboardTodoExtractor.drafts(from: "取餐", now: now, calendar: calendar).isEmpty)
    let huge = String(repeating: "无关内容。", count: 20_000)
    #expect(ClipboardTodoExtractor.drafts(from: huge, now: now, calendar: calendar).isEmpty)
}

@Test("大段文本上的提取要足够快，能放在剪贴板路径上跑")
func extractionIsFastEnough() {
    let blob = String(repeating: "【教务处】请各位同学在周五之前提交开题报告。其他说明若干。\n", count: 200)
    // 先跑一趟热身。正则是懒加载的静态常量，第一次调用要把它们全部编译出来——
    // 那是一次性成本，和"每来一条剪贴板要花多久"不是一回事，而这条断言问的
    // 是后者。不热身的话这个测试会随机红，取决于同一进程里谁先跑。
    _ = ClipboardTodoExtractor.drafts(from: blob, now: now, calendar: calendar)

    // 量 CPU 时间而不是墙钟：并行跑用例时墙钟主要反映被抢占了多久，
    // 而这里要断言的是这段提取本身贵不贵。
    var best = Double.infinity
    for _ in 0..<5 {
        best = min(best, cpuSeconds {
            _ = ClipboardTodoExtractor.drafts(from: blob, now: now, calendar: calendar)
        })
    }
    // 只截断到 4,000 字符，加上正则缓存，这一趟应当远低于一次界面刷新的预算。
    #expect(best < 0.05, "最快一趟 \(String(format: "%.1f", best * 1_000)) ms CPU")
}

@Test("本地多任务和模型使用同一个五条安全上限")
func localDraftsUseSharedDecisionLimit() {
    let text = """
    周四提交项目一报告
    周四提交项目一报告
    周五提交项目二报告
    周六提交项目三报告
    周日提交项目四报告
    下周一提交项目五报告
    下周二下午三点参加项目六答辩
    """
    let drafts = ClipboardTodoExtractor.drafts(from: text, now: now, calendar: calendar)
    #expect(drafts.count == TodoRevisionPrompt.maximumDecisionCount)
    #expect(Set(drafts.map(\.id)).count == TodoRevisionPrompt.maximumDecisionCount)
    #expect(drafts.first?.source == .appointment)
    #expect(drafts.first?.title.contains("项目六答辩") == true)
    #expect(!drafts.contains(where: { $0.title.contains("项目五报告") }))
}

@Test("结构化码不会再被有效期规则重复解释成第二条任务")
func verifiedCodeSuppressesDuplicateScheduleDraft() {
    let drafts = ClipboardTodoExtractor.drafts(
        from: "取餐码 B72，本券有效期至 2027年3月1日",
        now: now,
        calendar: calendar
    )
    #expect(drafts.count == 1)
    #expect(drafts.first?.code == "B72")
}

// MARK: - 截图 OCR 的视觉换行

/// 真实语料：微信群通知的截图 OCR 结果。
///
/// 这段文字里有四件事，但 OCR 是按聊天气泡的宽度断行的——日期在一行、
/// 事情在下一行。修复前一条都提不出来。
private let wechatNoticeOCR = """
11:00
知乎
〈2026级研究生招生群（100）
束时间就不能填报了
10:56
管理员
王辅导员
各位新生好：
现将近期重要日程安排通知如下，
请大家留意并提前做好规划：
9月4日（明天）全天入学教育
（8:50前在明理礼堂就坐完毕，下午
14:20在明理礼堂就坐完毕。）请携
带《学生手册》及笔，按时参加。
9月5日-6日各班、党支部、实
验室分别组织交流活动
9月7日（周一）上午 开学典礼
9月9日（周三）下午14:00 学院
新生见面会（13:45在明理礼堂就坐
完毕。
以上活动请大家合理安排时间，准
时出席。如有变动，另行通知。
"""

private func september(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = day
    components.hour = hour
    components.minute = minute
    return Calendar(identifier: .gregorian).date(from: components)!
}

@Test("群通知截图：四条日程一条都不能漏")
func extractsEveryEventFromWrappedNoticeScreenshot() {
    let now = september(3, 16, 41)
    let drafts = ClipboardTodoExtractor.drafts(from: wechatNoticeOCR, now: now)

    #expect(drafts.count == 4, "识别到 \(drafts.count) 条：\(drafts.map(\.title))")

    let days = drafts.compactMap { $0.dueAt }.map {
        Calendar(identifier: .gregorian).component(.day, from: $0)
    }
    #expect(Set(days) == [4, 5, 7, 9], "日期落点不对：\(days)")

    // 标题要是"那件事"，不是半句括注、也不是日期残渣。
    let titles = drafts.map(\.title).joined(separator: " | ")
    #expect(titles.contains("入学教育"), "\(titles)")
    #expect(titles.contains("交流活动"), "\(titles)")
    #expect(titles.contains("开学典礼"), "\(titles)")
    #expect(titles.contains("见面会"), "\(titles)")
    for draft in drafts {
        #expect(!draft.title.hasPrefix("（"), "标题以括注开头：\(draft.title)")
        #expect(!draft.title.hasPrefix("-"), "标题带日期残渣：\(draft.title)")
    }
}

@Test("被宽度切断的半句会接回去，自己收尾的短行不会被粘走")
func rejoinsOnlyVisuallyWrappedLines() {
    // 上面那段里的聊天界面噪声（时间戳、群名、发言人）都是短行，
    // 不能被接进正文——"填报"是截止线索词，粘上时间戳就会造出假待办。
    let now = september(3, 16, 41)
    let drafts = ClipboardTodoExtractor.drafts(from: wechatNoticeOCR, now: now)
    for draft in drafts {
        #expect(!draft.title.contains("填报"), "界面噪声被当成了待办：\(draft.title)")
        #expect(!draft.title.contains("管理员"), "界面噪声被当成了待办：\(draft.title)")
        #expect(!draft.title.contains("11:00"), "界面噪声被当成了待办：\(draft.title)")
    }
}

@Test("只有一条日期行时不算清单，不放行无线索词的行")
func singleDatedLineIsNotASchedule() {
    // 正文里偶然出现一个未来日期非常常见，不能因此建待办。
    let now = september(3, 16, 41)
    let drafts = ClipboardTodoExtractor.drafts(
        from: "会议纪要\n9月20日 服务器会迁到新机房\n其余不变",
        now: now
    )
    // "会议"是线索词，会命中它自己那一行；但"9月20日 服务器…"这行
    // 没有线索词，也不该因为清单规则被放行。
    #expect(!drafts.contains { $0.title.contains("服务器") }, "\(drafts.map(\.title))")
}

@Test("两条日期行时要有通知框架词才算清单")
func twoDatedLinesNeedNoticeFraming() {
    let now = september(3, 16, 41)
    let bare = ClipboardTodoExtractor.drafts(
        from: "9月10日 阿里云账单出账\n9月20日 域名到期",
        now: now
    )
    // "到期"是截止线索词，那一条本来就该有；"出账"没有线索词，
    // 缺框架词时不放行。
    #expect(!bare.contains { $0.title.contains("出账") }, "\(bare.map(\.title))")

    let framed = ClipboardTodoExtractor.drafts(
        from: "本月安排如下：\n9月10日 阿里云账单出账\n9月20日 域名到期",
        now: now
    )
    #expect(framed.contains { $0.title.contains("出账") }, "\(framed.map(\.title))")
}

@Test("没写钟点时按原文的时段词定点，没有时段词才落在早上")
func allDayAppointmentsFollowTheWrittenPeriod() {
    let now = september(3, 16, 41)
    let calendar = Calendar(identifier: .gregorian)
    let drafts = ClipboardTodoExtractor.drafts(from: wechatNoticeOCR, now: now)

    // "9月7日（周一）上午 开学典礼"——上午写在原文里，就该是上午。
    let ceremony = try! #require(drafts.first { $0.title.contains("开学典礼") }?.dueAt)
    #expect(calendar.component(.hour, from: ceremony) == 9, "\(ceremony)")

    // "9月5日—6日各班…交流活动"没有任何时段词，落在保守的早上。
    let exchange = try! #require(drafts.first { $0.title.contains("交流活动") }?.dueAt)
    #expect(calendar.component(.hour, from: exchange) == 9, "\(exchange)")
}

@Test("下午、晚上的日程不会被一律塞进早上")
func afternoonAndEveningKeepTheirPeriod() {
    let now = september(3, 16, 41)
    let calendar = Calendar(identifier: .gregorian)
    let text = "本周安排如下：\n9月10日 下午 项目评审\n9月11日 晚上 组会\n9月12日 中午 体检"
    let drafts = ClipboardTodoExtractor.drafts(from: text, now: now)
    func hour(_ keyword: String) -> Int? {
        drafts.first { $0.title.contains(keyword) }?.dueAt
            .map { calendar.component(.hour, from: $0) }
    }
    #expect(hour("评审") == 14, "\(drafts.map { ($0.title, $0.dueAt) })")
    #expect(hour("组会") == 19, "\(drafts.map { ($0.title, $0.dueAt) })")
    #expect(hour("体检") == 12, "\(drafts.map { ($0.title, $0.dueAt) })")
}

// MARK: - 刘海展开方式

@Test("默认只认点击，悬停要显式打开")
func expandTriggerDefaultsToClickOnly() {
    #expect(NotchExpandTrigger.click.allowsClick)
    #expect(!NotchExpandTrigger.click.allowsHover)
    #expect(NotchExpandTrigger.hover.allowsHover)
    #expect(!NotchExpandTrigger.hover.allowsClick)
    // 存的是 rawValue，改名等于换掉所有人的设置。
    #expect(NotchExpandTrigger.click.rawValue == "click")
    #expect(NotchExpandTrigger(rawValue: "hover") == .hover)
}

@Test("句号后面跟着右括号也算收尾，下一段不会被粘进标题")
func closingBracketAfterPeriodStillEndsTheSentence() {
    let now = september(3, 16, 41)
    // 真实 OCR：末尾是「就坐完毕。）」——句号后面还有一个右括号。
    let text = """
现将近期重要日程安排通知如下：
9月7日（周一）上午 开学典礼
9月9日（周三）下午14:00 学院
新生见面会（13:45在明理礼堂就坐
完毕。）
以上活动请大家合理安排时间，准
时出席。如有变动，另行通知。
"""
    let drafts = ClipboardTodoExtractor.drafts(from: text, now: now)
    let meeting = try! #require(drafts.first { $0.title.contains("见面会") })
    #expect(!meeting.title.contains("以上活动"), "\(meeting.title)")
    #expect(meeting.title == "学院新生见面会", "\(meeting.title)")
}
