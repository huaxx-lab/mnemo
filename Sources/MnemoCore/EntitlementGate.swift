import Foundation

public enum EntitledFeature: String, Codable, Sendable, CaseIterable {
    case ai
    case efficiency
}

public protocol EntitlementChecking: Sendable {
    func isUnlocked(_ feature: EntitledFeature) -> Bool
}

/// 当前版本全部开放。业务入口仍然统一询问这个 gate，未来接入 StoreKit 时
/// 只替换实现，不需要回头寻找散落的按钮与网络调用。
public struct OpenEntitlementGate: EntitlementChecking {
    public init() {}
    public func isUnlocked(_ feature: EntitledFeature) -> Bool { true }
}

public enum EarlyAccessMarker {
    public static let defaultsKey = "Pinland.firstInstalledVersion"

    @discardableResult
    public static func recordIfNeeded(
        currentVersion: String,
        defaults: UserDefaults = .standard
    ) -> String {
        if let existing = defaults.string(forKey: defaultsKey), !existing.isEmpty {
            return existing
        }
        let safeVersion = currentVersion.isEmpty ? "unknown" : currentVersion
        defaults.set(safeVersion, forKey: defaultsKey)
        return safeVersion
    }
}
