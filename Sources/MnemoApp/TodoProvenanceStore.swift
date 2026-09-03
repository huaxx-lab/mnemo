import Foundation

/// 每条待办是从哪条 Pin 提取出来的。
///
/// 为什么不写进 `Todo.linkedItemID`：那个字段已经有确定的含义——"由 Pin 转来
/// 的待办"，右键 Pin 里的「标为待办」按它来增删。把提取来源塞进去，会让用户
/// 在那条 Pin 上取消勾选时，连带删掉一条他自己确认过的待办。
///
/// 为什么不进 SwiftData：这是一条辅助记录，为它给整个库做一次结构迁移不划算。
/// 存法沿用 `NearbyDeviceOrigin` 那一套。
///
/// **回收站不算删除。** 源被扔进回收站之后随时可能被还原，所以这条记录跟着
/// "活动 + 回收站"两拨条目一起收敛；只有彻底清空之后才断开——那时我们手上
/// 确实没有任何内容可给模型，也不该为此留一份副本。
@MainActor
enum TodoProvenanceStore {
    private static let key = "Pinland.todoProvenance.v1"

    private static var map: [UUID: UUID] = {
        guard let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] else {
            return [:]
        }
        var result: [UUID: UUID] = [:]
        for (todo, item) in raw {
            guard let todoID = UUID(uuidString: todo), let itemID = UUID(uuidString: item) else {
                continue
            }
            result[todoID] = itemID
        }
        return result
    }()

    static func record(todoID: UUID, sourceItemID: UUID) {
        guard map[todoID] != sourceItemID else { return }
        map[todoID] = sourceItemID
        persist()
    }

    static func sourceItemID(for todoID: UUID) -> UUID? { map[todoID] }

    /// 删除某条待办后，来源是否仍被其他待办引用。反向查询放在存储自己这里，
    /// 避免 App 层拿 todo ID 和 item ID 做跨命名空间比较。
    static func hasReference(to sourceItemID: UUID) -> Bool {
        map.values.contains(sourceItemID)
    }

    static func forget(todoID: UUID) {
        guard map.removeValue(forKey: todoID) != nil else { return }
        persist()
    }

    /// - Parameters:
    ///   - todoIDs: 现存的待办。
    ///   - itemIDs: 现存的条目，**包含回收站里的**——那些随时可能被还原。
    static func prune(todoIDs: Set<UUID>, itemIDs: Set<UUID>) {
        let kept = map.filter { todoIDs.contains($0.key) && itemIDs.contains($0.value) }
        guard kept.count != map.count else { return }
        map = kept
        persist()
    }

    private static func persist() {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value.uuidString) })
        UserDefaults.standard.set(raw, forKey: key)
    }
}
