import Foundation

public enum FocusTimerPhase: String, Codable, Sendable {
    case idle
    case running
    case paused
}

public struct FocusSession: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let completedAt: Date
    public let plannedDuration: TimeInterval

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        completedAt: Date,
        plannedDuration: TimeInterval
    ) {
        self.id = id
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.plannedDuration = max(1, plannedDuration)
    }
}

public struct FocusDaySummary: Identifiable, Sendable, Equatable {
    public var id: Date { date }
    public let date: Date
    public let completedCount: Int
    public let focusedDuration: TimeInterval

    public var intensity: Int {
        guard focusedDuration > 0 else { return 0 }
        if focusedDuration < 25 * 60 { return 1 }
        if focusedDuration < 50 * 60 { return 2 }
        if focusedDuration < 90 * 60 { return 3 }
        return 4
    }
}

public enum FocusHistory {
    /// 返回连续自然日，包含无记录日期。这样热力图的格子身份稳定，不会因新增
    /// 一次专注而整体重排。
    public static func summaries(
        sessions: [FocusSession],
        through endDate: Date = .now,
        days: Int = 91,
        calendar: Calendar = .current
    ) -> [FocusDaySummary] {
        let safeDays = max(1, days)
        let end = calendar.startOfDay(for: endDate)
        guard let start = calendar.date(byAdding: .day, value: -(safeDays - 1), to: end) else {
            return []
        }
        let grouped = Dictionary(grouping: sessions) {
            calendar.startOfDay(for: $0.completedAt)
        }
        return (0..<safeDays).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let values = grouped[day] ?? []
            return FocusDaySummary(
                date: day,
                completedCount: values.count,
                focusedDuration: values.reduce(0) { $0 + $1.plannedDuration }
            )
        }
    }

    /// 把整段日汇总压成几个"一眼能读"的数字。
    ///
    /// 底部那条统计栏原本只有一句"近 91 天 · N 次 · M 分钟"，其余全是格子。
    /// 格子擅长显示趋势，不擅长回答"我今天做了没有""连着几天了"——而后者
    /// 才是专注功能真正驱动人的地方。这一层纯计算，方便直接测。
    public static func snapshot(
        _ days: [FocusDaySummary],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> FocusSnapshot {
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })

        let todayValue = byDay[today]
        let weekDays = days.filter {
            calendar.isDate($0.date, equalTo: today, toGranularity: .weekOfYear)
        }

        // 连续天数从今天往回数。今天还没开始不该把昨天以前的连击清零——
        // 早上八点看到"连续 0 天"会让人直接放弃，所以今天为空时从昨天起算。
        var streak = 0
        var cursor = (byDay[today]?.completedCount ?? 0) > 0
            ? today
            : calendar.date(byAdding: .day, value: -1, to: today) ?? today
        while (byDay[cursor]?.completedCount ?? 0) > 0 {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }

        return FocusSnapshot(
            todayCount: todayValue?.completedCount ?? 0,
            todayDuration: todayValue?.focusedDuration ?? 0,
            weekCount: weekDays.reduce(0) { $0 + $1.completedCount },
            weekDuration: weekDays.reduce(0) { $0 + $1.focusedDuration },
            streakDays: streak,
            totalCount: days.reduce(0) { $0 + $1.completedCount },
            totalDuration: days.reduce(0) { $0 + $1.focusedDuration }
        )
    }
}

/// 统计栏要显示的全部数字。视图只负责排版，不再自己遍历数组。
public struct FocusSnapshot: Sendable, Equatable {
    public var todayCount: Int
    public var todayDuration: TimeInterval
    public var weekCount: Int
    public var weekDuration: TimeInterval
    public var streakDays: Int
    public var totalCount: Int
    public var totalDuration: TimeInterval

    public init(
        todayCount: Int = 0,
        todayDuration: TimeInterval = 0,
        weekCount: Int = 0,
        weekDuration: TimeInterval = 0,
        streakDays: Int = 0,
        totalCount: Int = 0,
        totalDuration: TimeInterval = 0
    ) {
        self.todayCount = todayCount
        self.todayDuration = todayDuration
        self.weekCount = weekCount
        self.weekDuration = weekDuration
        self.streakDays = streakDays
        self.totalCount = totalCount
        self.totalDuration = totalDuration
    }

    public var hasAnyRecord: Bool { totalCount > 0 }
}

/// 基于绝对结束时刻的专注计时器。
///
/// UI 定时器只负责触发刷新，不负责累计时间，因此休眠、卡顿或系统降频后
/// 剩余时间仍然以墙上时钟为准。
public struct FocusTimerState: Codable, Equatable, Sendable {
    public private(set) var phase: FocusTimerPhase = .idle
    public private(set) var duration: TimeInterval = 25 * 60
    public private(set) var startedAt: Date?
    private var endDate: Date?
    private var pausedRemaining: TimeInterval?

    public init() {}

    public mutating func start(duration: TimeInterval, now: Date = .now) {
        let safeDuration = max(1, duration)
        self.duration = safeDuration
        startedAt = now
        endDate = now.addingTimeInterval(safeDuration)
        pausedRemaining = nil
        phase = .running
    }

    public mutating func pause(now: Date = .now) {
        guard phase == .running else { return }
        let remaining = remaining(at: now) ?? 0
        guard remaining > 0 else {
            cancel()
            return
        }
        pausedRemaining = remaining
        endDate = nil
        phase = .paused
    }

    public mutating func resume(now: Date = .now) {
        guard phase == .paused, let remaining = pausedRemaining, remaining > 0 else { return }
        endDate = now.addingTimeInterval(remaining)
        pausedRemaining = nil
        phase = .running
    }

    public mutating func cancel() {
        phase = .idle
        startedAt = nil
        endDate = nil
        pausedRemaining = nil
    }

    public func remaining(at now: Date = .now) -> TimeInterval? {
        switch phase {
        case .idle:
            nil
        case .running:
            endDate.map { max(0, $0.timeIntervalSince(now)) }
        case .paused:
            pausedRemaining
        }
    }

    /// 用当前时间结算一次。返回 true 表示本次刷新刚刚完成计时。
    @discardableResult
    public mutating func settle(now: Date = .now) -> Bool {
        guard phase == .running, remaining(at: now) == 0 else { return false }
        cancel()
        return true
    }
}
