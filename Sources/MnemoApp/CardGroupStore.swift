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
    private static let backup1Key = "Pinland.cardGroups.backup1.v1"
    private static let backup2Key = "Pinland.cardGroups.backup2.v1"

    private static var groups: [CardGroup] = {
        let defaults = UserDefaults.standard
        // 主表损坏时自动退到最近一代备份；正常的空数组是合法值，不回滚。
        for key in [key, backup1Key, backup2Key] {
            guard let data = defaults.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([CardGroup].self, from: data) else {
                continue
            }
            return decoded
        }
        return []
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

    /// 展开态下调整组内成员顺序。折叠态整组是一个实体，不会走到这里。
    static func moveMember(_ itemID: UUID, before targetID: UUID, after: Bool) {
        guard itemID != targetID,
              let groupIndex = groups.firstIndex(where: {
                  $0.itemIDs.contains(itemID) && $0.itemIDs.contains(targetID)
              }) else { return }
        var ids = groups[groupIndex].itemIDs
        ids.removeAll { $0 == itemID }
        guard var targetIndex = ids.firstIndex(of: targetID) else { return }
        if after { targetIndex += 1 }
        ids.insert(itemID, at: min(targetIndex, ids.count))
        guard ids != groups[groupIndex].itemIDs else { return }
        groups[groupIndex].itemIDs = ids
        persist()
    }

    /// 从所在的组里拿出来。组里只剩一张时整组解散——一张卡的"组"不是组。
    static func detach(_ itemID: UUID) {
        guard let index = groups.firstIndex(where: { $0.itemIDs.contains(itemID) }) else { return }
        groups[index].itemIDs.removeAll { $0 == itemID }
        if groups[index].itemIDs.count < 2 { groups.remove(at: index) }
        persist()
    }

    /// 撤销删除时恢复成员关系。`snapshot` 是删除前那一组的完整顺序；只恢复
    /// 当前仍活着的成员，避免把期间真正删除的条目重新写成幽灵引用。
    static func restoreMembership(
        _ itemID: UUID, from snapshot: CardGroup, keeping alive: Set<UUID>
    ) {
        // 一张卡只能属于一个组；只改内存一次，最后统一 persist，避免备份被
        // 一个操作的中间态连续覆盖。
        for index in groups.indices.reversed() {
            groups[index].itemIDs.removeAll { $0 == itemID }
            if groups[index].itemIDs.count < 2 { groups.remove(at: index) }
        }

        let wanted = snapshot.itemIDs.filter { alive.contains($0) }
        guard wanted.contains(itemID), wanted.count >= 2 else {
            persist()
            return
        }
        if let index = groups.firstIndex(where: { $0.id == snapshot.id }) {
            let current = groups[index].itemIDs.filter { alive.contains($0) }
            let currentSet = Set(current)
            var order = wanted.filter { currentSet.contains($0) || $0 == itemID }
            order.append(contentsOf: current.filter { !order.contains($0) })
            groups[index].itemIDs = order
        } else {
            groups.append(CardGroup(id: snapshot.id, name: snapshot.name, itemIDs: wanted))
        }
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
    @discardableResult
    static func prune(keeping ids: Set<UUID>) -> Bool {
        // 永不清空到零——这是最后的安全闸。
        //
        // 一次调用把整个分组表清空只可能意味着一件事：传入的 `ids` 是错的
        // （比如调用点拿到的条目列表是空的，而调用点自己不知道）。这种时候
        // 绝不能顺着错的输入把用户归好的类全删掉——宁可这次不修，等拿到
        // 真的存活列表再修。一整组全是幽灵成员可以由解散/手动清理来处理，
        // 而不是这里替用户决定全部消失。
        guard !groups.isEmpty else { return false }
        let wouldClearAll = groups.allSatisfy { group in
            group.itemIDs.contains { ids.contains($0) } == false
        }
        if wouldClearAll { return false }

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
        return changed
    }

    private static func persist() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        let defaults = UserDefaults.standard
        guard defaults.data(forKey: key) != data else { return }
        // 每次覆盖前保留两代。merge 内部可能有两个写入步骤，两代正好能留住
        // 操作开始前的完整状态；即使将来再出现错误修剪，也不再不可恢复。
        if let previousBackup = defaults.data(forKey: backup1Key) {
            defaults.set(previousBackup, forKey: backup2Key)
        }
        if let current = defaults.data(forKey: key) {
            defaults.set(current, forKey: backup1Key)
        }
        defaults.set(data, forKey: key)
    }
}
