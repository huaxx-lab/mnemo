import Foundation
import MnemoCore

/// 用户手动拖出来的分组。
///
/// 和「版本合集」是两回事，虽然界面上都是一摞卡片：版本合集是**程序认出来的**
/// （同一份文档的几个版本），用户没做过任何事；手动分组是**用户自己归的**
/// （"招聘信息""房子"），程序永远猜不出来。两者判据不同、生命周期不同，
/// 所以各存各的，只在显示时共用同一套折叠动效。
struct CardGroup: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var name: String
    /// 成员顺序 = 用户放进去的顺序，不重排。
    var itemIDs: [UUID]

    init(id: UUID = UUID(), name: String, itemIDs: [UUID]) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
    }
}

/// 分组的存放。
///
/// 不进库表：它是一层纯粹的组织信息，为它给整个库做结构迁移不划算，而且
/// 归档导出时也不该带上——换台机器，别人的"招聘信息"对你没有意义。
/// 存法沿用 `NearbyDeviceOrigin` / `TodoProvenanceStore` 那一套。
@MainActor
enum CardGroupStore {
    private static let key = "Pinland.cardGroups.v1"

    private static var groups: [CardGroup] = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([CardGroup].self, from: data) else {
            return []
        }
        return decoded
    }()

    static func all() -> [CardGroup] { groups }

    static func group(containing itemID: UUID) -> CardGroup? {
        groups.first { $0.itemIDs.contains(itemID) }
    }

    /// 把 `dragged` 放进 `target` 所在的组；`target` 还没有组就新建一个。
    ///
    /// 返回落进了哪个组，调用方拿它决定要不要立刻弹出改名框。
    @discardableResult
    static func merge(_ dragged: UUID, into target: UUID, defaultName: String) -> UUID? {
        guard dragged != target else { return nil }
        // 先从原来的组里摘出去：一张卡只能属于一个组，否则"它到底在哪儿"
        // 这个问题没有答案，删组时也会留下悬空引用。
        detach(dragged)
        if let index = groups.firstIndex(where: { $0.itemIDs.contains(target) }) {
            groups[index].itemIDs.append(dragged)
            persist()
            return groups[index].id
        }
        let group = CardGroup(name: defaultName, itemIDs: [target, dragged])
        groups.append(group)
        persist()
        return group.id
    }

    /// 从所在的组里拿出来。组里只剩一张时整组解散——一张卡的"组"不是组。
    static func detach(_ itemID: UUID) {
        guard let index = groups.firstIndex(where: { $0.itemIDs.contains(itemID) }) else { return }
        groups[index].itemIDs.removeAll { $0 == itemID }
        if groups[index].itemIDs.count < 2 { groups.remove(at: index) }
        persist()
    }

    static func rename(_ groupID: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].name = String(trimmed.prefix(24))
        persist()
    }

    /// 解散：卡片都还在，只是不再归成一堆。
    static func dissolve(_ groupID: UUID) {
        groups.removeAll { $0.id == groupID }
        persist()
    }

    /// 条目消失（删除、清空回收站）之后把悬空的成员清掉。
    static func prune(keeping ids: Set<UUID>) {
        var changed = false
        for index in groups.indices.reversed() {
            let kept = groups[index].itemIDs.filter { ids.contains($0) }
            guard kept.count != groups[index].itemIDs.count else { continue }
            changed = true
            if kept.count < 2 {
                groups.remove(at: index)
            } else {
                groups[index].itemIDs = kept
            }
        }
        if changed { persist() }
    }

    private static func persist() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
