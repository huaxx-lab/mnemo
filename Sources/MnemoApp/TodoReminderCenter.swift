import AppKit
import MnemoCore
import UserNotifications

/// 待办提醒的送达层。
///
/// 两条通路，规则同源（都读 `TodoReminderPolicy`）：
///
/// - **系统通知**：提前排进通知中心。Mnemo 是 accessory 应用，多数时候
///   不在前台，甚至可能没在跑——只有系统通知能保证"到点真的响"。
/// - **刘海卡片**：进程在跑时才有，胜在顺手：一个对号就完成，一个时钟就推迟，
///   不必先把应用切到前台。
///
/// 两边都会去重（`TodoReminder.deduplicationKey`），所以同一件事不会响两次。
@MainActor
final class TodoReminderCenter: NSObject {
    static let completeActionID = "mnemo.todo.complete"
    static let snoozeActionID = "mnemo.todo.snooze"
    private static let categoryID = "mnemo.todo.reminder"
    private static let todoIDKey = "todoID"

    /// 一次最多排这么多条系统通知。
    ///
    /// 系统对未决通知有 64 条的硬上限，超出的会被**静默丢弃**——而且丢的是
    /// 后来的那些。只排最近要到期的，剩下的等这批响完再补，才不会出现
    /// "最近的没响、下个月的排上了"。
    private static let scheduleLimit = 32

    private weak var model: AppModel?
    private var hasRequestedAuthorization = false
    private var isAuthorized = false

    private var center: UNUserNotificationCenter? {
        // 没有 app bundle 时（直接 swift run 起来的调试进程）取 current() 会崩，
        // 不是抛错。这里明确挡住，让通知功能安静地不可用而不是拖垮整个应用。
        guard Bundle.main.bundleIdentifier != nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return nil }
        return UNUserNotificationCenter.current()
    }

    func attach(to model: AppModel) {
        self.model = model
        center?.delegate = self
        registerCategory()
        model.reminderSettingsDidChange = { [weak self, weak model] settings in
            guard let model else { return }
            self?.apply(todos: model.todos, settings: settings)
        }
        model.reminderScheduleDidChange = { [weak self] todos, settings in
            self?.apply(todos: todos, settings: settings)
        }
    }

    /// 把当前待办重新排一遍系统通知。幂等：每次都先清空再排。
    func apply(todos: [Todo], settings: TodoReminderSettings) {
        guard let center else { return }
        center.removeAllPendingNotificationRequests()
        guard settings.isEnabled, settings.usesSystemNotification else { return }
        requestAuthorizationIfNeeded()
        guard isAuthorized else { return }

        let now = Date.now
        let upcoming = todos
            .compactMap { todo -> (Todo, Date)? in
                guard let fire = TodoReminderPolicy.firstFireDate(for: todo, settings: settings),
                      fire > now,
                      !TodoReminderPolicy.isQuiet(fire, settings: settings) else { return nil }
                return (todo, fire)
            }
            .sorted { $0.1 < $1.1 }
            .prefix(Self.scheduleLimit)

        for (todo, fire) in upcoming {
            let content = UNMutableNotificationContent()
            content.title = todo.title
            content.body = todo.dueAt.map {
                TodoReminderPolicy.relativeDescription(of: $0, now: fire)
            } ?? "待办提醒"
            content.sound = .default
            content.categoryIdentifier = Self.categoryID
            content.userInfo = [Self.todoIDKey: todo.id.uuidString]

            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, fire.timeIntervalSince(now)),
                repeats: false
            )
            center.add(
                UNNotificationRequest(
                    identifier: todo.id.uuidString,
                    content: content,
                    trigger: trigger
                )
            )
        }
    }

    /// 只在用户真的打开了提醒之后才要权限。
    /// 一装上就弹系统授权框是最讨人厌的那种引导。
    func requestAuthorizationIfNeeded() {
        guard let center, !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in
                self?.isAuthorized = granted
                guard granted, let model = self?.model else { return }
                self?.apply(todos: model.todos, settings: model.reminderSettings)
            }
        }
    }

    private func registerCategory() {
        guard let center else { return }
        let complete = UNNotificationAction(
            identifier: Self.completeActionID,
            title: "标记完成",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: Self.snoozeActionID,
            title: "10 分钟后再提醒",
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Self.categoryID,
                actions: [complete, snooze],
                intentIdentifiers: []
            )
        ])
    }
}

extension TodoReminderCenter: UNUserNotificationCenterDelegate {
    /// Mnemo 常驻后台，不加这条的话应用恰好在前台时通知会被系统吞掉。
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let rawID = info["todoID"] as? String
        // 立刻回执，处理放到主线程上异步做。把 completionHandler 带进
        // @MainActor 闭包会被 Swift 6 判成跨隔离域传递；而系统只关心
        // "收到了没有"，不关心我们什么时候把待办改完。
        completionHandler()
        Task { @MainActor [weak self] in
            guard let model = self?.model,
                  let rawID, let id = UUID(uuidString: rawID) else { return }
            switch action {
            case TodoReminderCenter.completeActionID:
                await model.toggleTodoCompleted(id)
                model.rescheduleReminders()
            case TodoReminderCenter.snoozeActionID:
                await model.setTodoDueDate(id, date: TodoReminderPolicy.snoozeDate())
                model.rescheduleReminders()
            default:
                // 点通知本体：把同一条提醒也摆到刘海上，完成和推迟都在手边，
                // 不必再去应用里找那条待办在哪。
                model.presentReminder(forTodoID: id)
            }
        }
    }
}
