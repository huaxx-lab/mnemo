import Foundation

/// 库的变更事件。只描述"哪个实体被写了或删了"，不携带内容——观察者自己去读。
public enum LibraryChange: Codable, Hashable, Sendable {
    case upsertItem(UUID)
    case deleteItem(UUID)
    case upsertTodo(UUID)
    case deleteTodo(UUID)
}

public extension Item {
    /// 用户可见内容是否相同。
    ///
    /// 索引回填（向量、内容哈希、embedding 模型、indexedAt）不是内容变化——
    /// 否则每跑一次后台索引都会把条目标脏、刷新 `modifiedAt`、发一次变更事件。
    func hasSameSyncedContent(as other: Item) -> Bool {
        Self.normalized(self) == Self.normalized(other)
    }

    private static func normalized(_ item: Item) -> Item {
        var value = item
        value.modifiedAt = .distantPast
        value.vector = nil
        value.contentHash = nil
        value.embeddingModelID = nil
        value.indexedAt = nil
        value.titleOrigin = nil
        value.linkExtractionVersion = nil
        value.cloudSystemFields = nil
        return value
    }
}

public extension Todo {
    func hasSameSyncedContent(as other: Todo) -> Bool {
        Self.normalized(self) == Self.normalized(other)
    }

    private static func normalized(_ todo: Todo) -> Todo {
        var value = todo
        value.modifiedAt = .distantPast
        value.cloudSystemFields = nil
        return value
    }
}
