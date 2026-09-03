import Foundation

/// 待办提醒的用户设置。
///
/// 全部是"什么时候响"的规则，不含任何调度实现——App 层的通知中心和刘海
/// 动画都读同一份规则，两条通路不会在时间上打架。
public struct TodoReminderSettings: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    /// 提前量（分钟）。0 表示到点才提醒。
    public var leadMinutes: Int
    /// 过期未完成时是否继续提醒。
    public var repeatsWhenOverdue: Bool
    /// 逾期重复的间隔（分钟）。
    public var overdueIntervalMinutes: Int
    /// 走系统通知中心（应用没在前台也能收到）。
    public var usesSystemNotification: Bool
    /// 在刘海上弹一张卡片。
    public var usesNotchAlert: Bool
    /// 免打扰起止小时（含起、含止）。nil 表示全天可提醒。
    public var quietHoursStart: Int?
    public var quietHoursEnd: Int?

    public init(
        isEnabled: Bool = true,
        leadMinutes: Int = 10,
        repeatsWhenOverdue: Bool = true,
        overdueIntervalMinutes: Int = 60,
        usesSystemNotification: Bool = true,
        usesNotchAlert: Bool = true,
        quietHoursStart: Int? = 23,
        quietHoursEnd: Int? = 7
    ) {
        self.isEnabled = isEnabled
        self.leadMinutes = max(0, leadMinutes)
        self.repeatsWhenOverdue = repeatsWhenOverdue
        self.overdueIntervalMinutes = max(5, overdueIntervalMinutes)
        self.usesSystemNotification = usesSystemNotification
        self.usesNotchAlert = usesNotchAlert
        self.quietHoursStart = quietHoursStart
        self.quietHoursEnd = quietHoursEnd
    }

    public var hasQuietHours: Bool { quietHoursStart != nil && quietHoursEnd != nil }
}

/// 一次要送达的提醒。
public struct TodoReminder: Sendable, Equatable, Identifiable {
    public enum Trigger: String, Sendable, Equatable {
        /// 距到期还有提前量。
        case upcoming
        /// 已经过了到期时间。
        case overdue
    }

    public var id: UUID { todoID }
    public var todoID: UUID
    public var title: String
    public var dueAt: Date
    public var trigger: Trigger
    /// 这一轮的时间槽。逾期重复靠它去重：同一个小时内只提一次。
    public var slot: Int

    public init(todoID: UUID, title: String, dueAt: Date, trigger: Trigger, slot: Int) {
        self.todoID = todoID
        self.title = title
        self.dueAt = dueAt
        self.trigger = trigger
        self.slot = slot
    }

    /// 去重键。同一条待办在同一个时间槽里只提醒一次，无论轮询跑了多少拍。
    public var deduplicationKey: String { "\(todoID.uuidString):\(trigger.rawValue):\(slot)" }
}

/// 什么时候提醒、提醒谁。纯函数，方便直接测。
public enum TodoReminderPolicy {

    /// 这条待办的第一次提醒时刻。没有截止时间就没有提醒——
    /// "有一天要做"不构成一个可以响铃的时刻。
    public static func firstFireDate(
        for todo: Todo,
        settings: TodoReminderSettings
    ) -> Date? {
        guard settings.isEnabled, !todo.isCompleted, let dueAt = todo.dueAt else { return nil }
        return dueAt.addingTimeInterval(-Double(settings.leadMinutes) * 60)
    }

    /// 现在这一拍该响哪些提醒。
    ///
    /// `delivered` 是已经送达过的去重键集合，由调用方持有并持久化：进程重启后
    /// 不该把上午提过的事再全部重提一遍。
    public static func due(
        todos: [Todo],
        settings: TodoReminderSettings,
        now: Date = .now,
        delivered: Set<String>,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [TodoReminder] {
        guard settings.isEnabled else { return [] }
        guard !isQuiet(now, settings: settings, calendar: calendar) else { return [] }

        var results: [TodoReminder] = []
        for todo in todos {
            guard !todo.isCompleted, let dueAt = todo.dueAt else { continue }
            guard let fireDate = firstFireDate(for: todo, settings: settings) else { continue }
            guard fireDate <= now else { continue }

            let overdue = now >= dueAt
            // 逾期重复按固定间隔切槽：轮询多久跑一次都不影响"一个间隔只提一次"。
            let trigger: TodoReminder.Trigger = overdue ? .overdue : .upcoming
            let slot: Int
            if overdue {
                guard settings.repeatsWhenOverdue else {
                    slot = 0
                    let reminder = TodoReminder(
                        todoID: todo.id, title: todo.title, dueAt: dueAt,
                        trigger: .overdue, slot: slot
                    )
                    if !delivered.contains(reminder.deduplicationKey) { results.append(reminder) }
                    continue
                }
                let elapsed = now.timeIntervalSince(dueAt)
                slot = Int(elapsed / (Double(settings.overdueIntervalMinutes) * 60))
            } else {
                slot = 0
            }

            let reminder = TodoReminder(
                todoID: todo.id, title: todo.title, dueAt: dueAt,
                trigger: trigger, slot: slot
            )
            guard !delivered.contains(reminder.deduplicationKey) else { continue }
            results.append(reminder)
        }
        // 最紧迫的排前面：已经逾期的优先，其次按到期时间。
        return results.sorted { lhs, rhs in
            if lhs.trigger != rhs.trigger { return lhs.trigger == .overdue }
            return lhs.dueAt < rhs.dueAt
        }
    }

    /// 免打扰时段判定。跨零点（23:00–07:00）是常态，所以不能只写 start...end。
    public static func isQuiet(
        _ date: Date,
        settings: TodoReminderSettings,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Bool {
        guard let start = settings.quietHoursStart, let end = settings.quietHoursEnd,
              start != end else { return false }
        let hour = calendar.component(.hour, from: date)
        return start < end ? (hour >= start && hour < end) : (hour >= start || hour < end)
    }

    /// "稍后提醒"推迟到什么时候。
    public static func snoozeDate(from now: Date = .now, minutes: Int = 10) -> Date {
        now.addingTimeInterval(Double(max(1, minutes)) * 60)
    }

    /// 到期时间的人话描述。刘海卡片和系统通知共用，两处措辞不会不一致。
    public static func relativeDescription(
        of dueAt: Date,
        now: Date = .now,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let seconds = dueAt.timeIntervalSince(now)
        if seconds < -86_400 {
            return "已逾期 \(Int(-seconds / 86_400)) 天"
        }
        if seconds < -60 {
            return "已逾期 \(Int(-seconds / 60)) 分钟"
        }
        if seconds < 60 { return "现在到期" }
        if seconds < 3_600 { return "\(Int(seconds / 60)) 分钟后到期" }
        if calendar.isDateInToday(dueAt) {
            return "今天 " + dueAt.formatted(date: .omitted, time: .shortened) + " 到期"
        }
        if calendar.isDateInTomorrow(dueAt) {
            return "明天 " + dueAt.formatted(date: .omitted, time: .shortened) + " 到期"
        }
        return dueAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()) + " 到期"
    }
}
