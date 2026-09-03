import Foundation
import Testing
@testable import MnemoCore

@Test("专注计时按绝对结束时间结算，休眠后不会逐秒漂移")
func focusTimerUsesWallClock() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var timer = FocusTimerState()
    timer.start(duration: 25 * 60, now: start)

    #expect(timer.phase == .running)
    let remaining = timer.remaining(at: start.addingTimeInterval(9 * 60)) ?? -1
    #expect(abs(remaining - 16 * 60) < 0.001)
    let didFinish = timer.settle(now: start.addingTimeInterval(25 * 60 + 1))
    #expect(didFinish)
    #expect(timer.phase == .idle)
    #expect(timer.remaining(at: start.addingTimeInterval(25 * 60 + 1)) == nil)
}

@Test("暂停期间剩余时间冻结，恢复后从冻结点继续")
func focusTimerPauseAndResume() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    var timer = FocusTimerState()
    timer.start(duration: 100, now: start)
    timer.pause(now: start.addingTimeInterval(30))

    #expect(timer.phase == .paused)
    #expect(timer.remaining(at: start.addingTimeInterval(500)) == 70)

    timer.resume(now: start.addingTimeInterval(600))
    #expect(timer.phase == .running)
    #expect(timer.remaining(at: start.addingTimeInterval(630)) == 40)
}

@Test("专注热力图补齐空白日并按完成日聚合")
func focusHistoryAggregatesCompletedSessions() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let end = Date(timeIntervalSince1970: 1_700_006_400)
    let previous = calendar.date(byAdding: .day, value: -1, to: end)!
    let sessions = [
        FocusSession(startedAt: previous, completedAt: previous, plannedDuration: 15 * 60),
        FocusSession(startedAt: end, completedAt: end, plannedDuration: 25 * 60),
        FocusSession(startedAt: end, completedAt: end, plannedDuration: 45 * 60),
    ]

    let days = FocusHistory.summaries(
        sessions: sessions,
        through: end,
        days: 3,
        calendar: calendar
    )

    #expect(days.count == 3)
    #expect(days[0].completedCount == 0)
    #expect(days[1].completedCount == 1)
    #expect(days[1].intensity == 1)
    #expect(days[2].completedCount == 2)
    #expect(days[2].focusedDuration == 70 * 60)
    #expect(days[2].intensity == 3)
}
