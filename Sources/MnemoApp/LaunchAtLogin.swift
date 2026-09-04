import Foundation
import ServiceManagement

/// 开机自启。
///
/// 用 `SMAppService.mainApp`：系统自己维护登录项，用户在「系统设置 → 通用 →
/// 登录项」里也能看到并关掉。老办法是往 `~/Library/LaunchAgents` 写 plist，
/// 那种方式绕过了系统的登录项面板——用户在设置里看不到它，只能靠翻文件系统
/// 才知道有个东西每次开机在跑。
///
/// 状态以**系统为准**而不是自己存一份：用户可能在系统设置里关掉，我们那份
/// 记录就成了谎话。每次读都问系统。
@MainActor
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// 用户在系统设置里手动禁用过。这种情况下我们再调 register 也不会生效，
    /// 得让界面说清楚，而不是显示一个打开却没用的开关。
    static var isBlockedBySystem: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    @discardableResult
    static func set(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                guard SMAppService.mainApp.status != .enabled else { return true }
                try SMAppService.mainApp.register()
            } else {
                guard SMAppService.mainApp.status == .enabled else { return true }
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            return false
        }
    }

    /// 首次启动时按默认值登记一次。
    ///
    /// 只在**从来没有表过态**时才动手：用户自己关掉之后，不能因为"默认是开"
    /// 就在下次启动时又给他打开——那是最讨人厌的一类行为。
    static func applyDefaultIfNeeded(defaultsKey: String) {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) == nil else { return }
        defaults.set(true, forKey: defaultsKey)
        set(true)
    }
}
