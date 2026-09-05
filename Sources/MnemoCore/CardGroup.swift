import Foundation

public struct CardGroup: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    /// 成员顺序 = 用户放进去的顺序，不重排。
    public var itemIDs: [UUID]

    public init(id: UUID = UUID(), name: String, itemIDs: [UUID]) {
        self.id = id
        self.name = name
        self.itemIDs = itemIDs
    }
}

public extension CardGroup {
    /// 界面与模型共用的有效成员投影，不改持久化备份或回收站关系。
    func visible(in items: [Item]) -> CardGroup? {
        let alive = Set(items.lazy.filter { $0.state == .active && !$0.isPrivate }.map(\.id))
        return visible(keeping: alive)
    }

    func visible(keeping alive: Set<UUID>) -> CardGroup? {
        var seen: Set<UUID> = []
        let members = itemIDs.filter { alive.contains($0) && seen.insert($0).inserted }
        guard members.count >= 2 else { return nil }
        return CardGroup(id: id, name: name, itemIDs: members)
    }
}

/// Hand-made groups are a projection only in All. Kind tabs still show every matching item.
public enum CardGroupProjection {
    public static func shouldFold(tabKind: ItemKind?) -> Bool { tabKind == nil }
    public static func shouldShowManualFilters(tabKind: ItemKind?) -> Bool { tabKind == nil }
}
