import Foundation
import Testing
@testable import MnemoCore

private let temporalCalendar: Calendar = {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    value.locale = Locale(identifier: "zh_CN")
    return value
}()

private let temporalNow: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 9
    components.day = 2
    components.hour = 20
    components.minute = 30
    return temporalCalendar.date(from: components)!
}()

@Test("普通文字里的相对时间先转换成带时区绝对时间")
func normalizesLiveRelativeTime() {
    let context = TodoTemporalNormalizer.normalize(
        "明天晚上八点我要赶回合肥",
        now: temporalNow,
        calendar: temporalCalendar
    )
    #expect(context.originalText.contains("明天晚上八点"))
    #expect(context.normalizedText.contains("2026-09-03T20:00:00+08:00"))
    #expect(context.normalizedText.contains("我要赶回合肥"))
    #expect(context.resolutions.count == 1)
    #expect(context.resolutions.first?.isContextAnchor == false)
}

@Test("聊天时间戳建立上下文，消息里的明天按消息日期而不是识别日期计算")
func chatTimestampAnchorsRelativeMessageTime() {
    let input = """
    昨天 18:45
    你还差多少？
    明天应该就搞好了，改两个图
    昨天 18:56
    ok
    """
    let context = TodoTemporalNormalizer.normalize(
        input,
        now: temporalNow,
        calendar: temporalCalendar
    )
    #expect(context.normalizedText.contains("[界面时间锚点：2026-09-01T18:45:00+08:00；不是任务]"))
    #expect(context.normalizedText.contains("[绝对时间：2026-09-02（未给具体钟点）]应该就搞好了，改两个图"))
    #expect(context.resolutions.filter(\.isContextAnchor).count == 2)
}

@Test("纯聊天时间和手机状态栏时间只标记为上下文，不生成任务时间")
func timestampOnlyLinesStayAnchors() {
    let context = TodoTemporalNormalizer.normalize(
        "20:25\n星期五 23:35",
        now: temporalNow,
        calendar: temporalCalendar
    )
    #expect(context.resolutions.allSatisfy { $0.isContextAnchor })
    #expect(context.normalizedText.components(separatedBy: "不是任务").count == 3)
}

@Test("原始文字完整保留，供 evidence 与 code 逐字验证")
func preservesOriginalEvidenceText() {
    let input = "配餐中\n订单号\n35341\n待取餐"
    let context = TodoTemporalNormalizer.normalize(
        input,
        now: temporalNow,
        calendar: temporalCalendar
    )
    #expect(context.originalText == input)
    #expect(context.normalizedText == input)
}

@Test("同一行多个时间都会转换")
func normalizesMultipleDatesInOneLine() {
    let context = TodoTemporalNormalizer.normalize(
        "周五交初稿，周六交终稿",
        now: temporalNow,
        calendar: temporalCalendar
    )
    #expect(context.resolutions.count == 2)
    #expect(!context.normalizedText.contains("周五"))
    #expect(!context.normalizedText.contains("周六"))
}
