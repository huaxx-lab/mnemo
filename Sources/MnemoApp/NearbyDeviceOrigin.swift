import AppKit
import Foundation

/// 内容来自哪一类苹果设备。
///
/// 系统只在剪贴板上打一个 `com.apple.is-remote-clipboard` 标记，表示"来自另一台
/// 苹果设备"，**不公开设备型号**（Apple 也明说没有直接操作通用剪贴板的 API）。
/// 所以这里只做一件事：在能看出形态时把图标画准，看不出就诚实地画通用图标，
/// 绝不编一个型号出来。
enum NearbyDeviceKind: String, Codable, Sendable {
    case phone
    case pad
    /// 拿不到任何形态线索（纯文字、链接、异常尺寸）。
    case unknown

    /// 从截图尺寸推断。**只用来选图标**，判断错了也不影响任何行为。
    ///
    /// iPhone 全面屏截图约 2.16:1，iPad 约 1.33:1，两者相距很远，中间留一段
    /// 空白判为 unknown——宁可显示通用图标，也不要在 16:9 这种模糊地带硬猜。
    static func inferred(fromPixelSize size: CGSize) -> NearbyDeviceKind {
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        guard short > 0 else { return .unknown }
        let ratio = long / short
        if ratio >= 1.9 { return .phone }
        if ratio <= 1.45 { return .pad }
        return .unknown
    }

    var symbol: String {
        switch self {
        case .phone: "iphone"
        case .pad: "ipad"
        case .unknown: "ipad.and.iphone"
        }
    }

    var displayName: String {
        switch self {
        case .phone: "iPhone"
        case .pad: "iPad"
        case .unknown: "其他苹果设备"
        }
    }
}

/// 哪些条目是从其他苹果设备的通用剪贴板同步过来的，以及是哪一类设备。
///
/// 不进 SwiftData：这是一条纯展示与路由用的来源标记，为它给整个库做一次
/// 结构迁移不划算。存法沿用 `processableTemporaryIDs` 那一套——UserDefaults
/// 里的一小张表，条目淘汰时一起清掉。
@MainActor
enum NearbyDeviceOrigin {
    private static let key = "Pinland.nearbyDeviceItems.v2"
    /// v1 只存了一组 ID，没有设备类型。升级时原样接过来，标成 unknown——
    /// 已有条目的角标从"手机"变成"其他苹果设备"是诚实的降级，不是丢数据。
    private static let legacyKey = "Pinland.nearbyDeviceItemIDs"

    private static var kinds: [UUID: NearbyDeviceKind] = {
        let defaults = UserDefaults.standard
        if let raw = defaults.dictionary(forKey: key) as? [String: String] {
            var result: [UUID: NearbyDeviceKind] = [:]
            for (id, kind) in raw {
                guard let uuid = UUID(uuidString: id) else { continue }
                result[uuid] = NearbyDeviceKind(rawValue: kind) ?? .unknown
            }
            return result
        }
        let legacy = (defaults.stringArray(forKey: legacyKey) ?? [])
            .compactMap(UUID.init(uuidString:))
        return Dictionary(uniqueKeysWithValues: legacy.map { ($0, .unknown) })
    }()

    /// 把一次捕获明确归到"其他设备"或"本机"。
    ///
    /// 不能只有 mark 没有反向操作：同一段文字可能先从 iPhone 同步过来，随后
    /// 用户又在 Mac 上复制。Library 会复用同一个条目并把它移到最前，如果来源
    /// 标记不随**最新一次捕获**更新，它会永远占着手机轨道的名额。
    static func setNearby(_ isNearby: Bool, kind: NearbyDeviceKind = .unknown, for id: UUID) {
        let updated: NearbyDeviceKind? = isNearby ? kind : nil
        guard kinds[id] != updated else { return }
        kinds[id] = updated
        persist()
    }

    static func mark(_ id: UUID, kind: NearbyDeviceKind = .unknown) {
        setNearby(true, kind: kind, for: id)
    }

    static func contains(_ id: UUID) -> Bool { kinds[id] != nil }

    static func kind(of id: UUID) -> NearbyDeviceKind? { kinds[id] }

    /// 给容量结算用的稳定快照。调用方只读，不能直接改内部集合。
    static var itemIDs: Set<UUID> { Set(kinds.keys) }

    /// 条目被淘汰、删除之后这条标记就没有意义了。跟着活动条目一起收敛，
    /// 免得这份表随使用时间单调增长。
    static func prune(keeping live: Set<UUID>) {
        let kept = kinds.filter { live.contains($0.key) }
        guard kept.count != kinds.count else { return }
        kinds = kept
        persist()
    }

    private static func persist() {
        let raw = Dictionary(
            uniqueKeysWithValues: kinds.map { ($0.key.uuidString, $0.value.rawValue) }
        )
        UserDefaults.standard.set(raw, forKey: key)
    }
}
