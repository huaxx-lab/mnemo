import Foundation
import SwiftData
import MnemoCore

/// `ItemStore` 的 SwiftData 实现。行为以 `InMemoryItemStore` 为基准。
@ModelActor
public actor SwiftDataItemStore: ItemStore {

    public static func makeContainer(at url: URL? = nil, inMemory: Bool = false) throws -> ModelContainer {
        let config = if let url {
            ModelConfiguration(url: url)
        } else {
            ModelConfiguration(isStoredInMemoryOnly: inMemory)
        }
        return try ModelContainer(
            for: StoredItem.self,
            StoredContentChunk.self,
            StoredTodo.self,
            StoredFocusSession.self,
            configurations: config
        )
    }

    public func all(includingTrashed: Bool) throws -> [Item] {
        let trashed = ItemState.trashed.rawValue
        // 主排序是手动排序值（新行默认=创建时间戳，等价于最新在前），
        // createdAt 做平手兜底——老库行的 sortOrder 全是 0，靠它保持原顺序。
        var d = FetchDescriptor<StoredItem>(sortBy: [
            SortDescriptor(\.sortOrder, order: .reverse),
            SortDescriptor(\.createdAt, order: .reverse),
        ])
        if !includingTrashed {
            d.predicate = #Predicate { $0.stateRaw != trashed }
        }
        return try modelContext.fetch(d).map(\.asItem)
    }

    /// 手动排序：把 id 挪到 targetID 前面；targetID 为 nil 表示挪到末尾。
    /// 分数索引：新值取插入点两侧邻居的中点，只写一行；间隙过小时整体重排。
    public func move(_ id: UUID, before targetID: UUID?) throws {
        let trashed = ItemState.trashed.rawValue
        var d = FetchDescriptor<StoredItem>(
            predicate: #Predicate { $0.stateRaw != trashed },
            sortBy: [
                SortDescriptor(\.sortOrder, order: .reverse),
                SortDescriptor(\.createdAt, order: .reverse),
            ]
        )
        let rows = try modelContext.fetch(d)
        guard let dragged = rows.first(where: { $0.id == id }) else { return }
        // 拖到目标自己前面等于没动。
        if targetID == id { return }
        var others = rows.filter { $0.id != id }
        let insertionIndex: Int
        if let targetID {
            guard let idx = others.firstIndex(where: { $0.id == targetID }) else { return }
            insertionIndex = idx
        } else {
            insertionIndex = others.count
        }

        let above = insertionIndex > 0 ? others[insertionIndex - 1] : nil
        let below = insertionIndex < others.count ? others[insertionIndex] : nil

        var newValue: Double
        switch (above, below) {
        case let (a?, b?):
            let gap = a.sortOrder - b.sortOrder
            if gap < 0.0001 {
                // 间隙太小，中点会丢精度：按当前顺序整体重排，间距留足。
                for (i, row) in others.enumerated() {
                    row.sortOrder = Double(others.count - i) * 10_000
                }
                newValue = (others[insertionIndex - 1].sortOrder + others[insertionIndex].sortOrder) / 2
            } else {
                newValue = b.sortOrder + gap / 2
            }
        case let (a?, nil):
            newValue = a.sortOrder - 10_000
        case let (nil, b?):
            newValue = b.sortOrder + 10_000
        case (nil, nil):
            newValue = dragged.sortOrder
        }
        dragged.sortOrder = newValue
        try modelContext.save()
    }

    public func item(id: UUID) throws -> Item? { try stored(id)?.asItem }

    public func insert(_ item: Item) throws {
        modelContext.insert(StoredItem(item))
        try modelContext.save()
    }

    public func upsert(_ item: Item) throws {
        if let existing = try stored(item.id) { existing.apply(item) }
        else { modelContext.insert(StoredItem(item)) }
        try modelContext.save()
    }

    public func update(_ item: Item) throws {
        guard let s = try stored(item.id) else { return }
        s.apply(item)
        try modelContext.save()
    }

    public func allChunks() throws -> [ContentChunk] {
        let descriptor = FetchDescriptor<StoredContentChunk>(
            sortBy: [SortDescriptor(\.itemID), SortDescriptor(\.ordinal)]
        )
        return try modelContext.fetch(descriptor).map(\.asChunk)
    }

    public func chunks(itemID: UUID) throws -> [ContentChunk] {
        let descriptor = FetchDescriptor<StoredContentChunk>(
            predicate: #Predicate { $0.itemID == itemID },
            sortBy: [SortDescriptor(\.ordinal)]
        )
        return try modelContext.fetch(descriptor).map(\.asChunk)
    }

    public func chunks(itemIDs: Set<UUID>) throws -> [ContentChunk] {
        guard !itemIDs.isEmpty else { return [] }
        let wanted = Array(itemIDs)
        let descriptor = FetchDescriptor<StoredContentChunk>(
            predicate: #Predicate { wanted.contains($0.itemID) },
            sortBy: [SortDescriptor(\.itemID), SortDescriptor(\.ordinal)]
        )
        return try modelContext.fetch(descriptor).map(\.asChunk)
    }

    public func replaceChunks(itemID: UUID, with chunks: [ContentChunk]) throws {
        let descriptor = FetchDescriptor<StoredContentChunk>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        for old in try modelContext.fetch(descriptor) { modelContext.delete(old) }
        for chunk in chunks where chunk.itemID == itemID {
            modelContext.insert(StoredContentChunk(chunk))
        }
        try modelContext.save()
    }

    public func replaceChunks(
        itemID: UUID, with chunks: [ContentChunk], updating item: Item
    ) throws {
        guard item.id == itemID, let storedItem = try stored(itemID) else { return }
        let descriptor = FetchDescriptor<StoredContentChunk>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        do {
            for old in try modelContext.fetch(descriptor) { modelContext.delete(old) }
            for chunk in chunks where chunk.itemID == itemID {
                modelContext.insert(StoredContentChunk(chunk))
            }
            storedItem.apply(item)
            // 分块、聚合向量、索引时间和抓到的真实标题在一个事务里提交。
            try modelContext.save()
        } catch {
            // SwiftData save 失败后 context 仍带着未提交的 delete/insert；不回滚，
            // 下一次无关保存可能把这批半成品一起提交，破坏“失败保留旧 RAG”。
            modelContext.rollback()
            throw error
        }
    }

    public func chunkItemIDs() throws -> Set<UUID> {
        var seen: Set<UUID> = []
        for chunk in try modelContext.fetch(FetchDescriptor<StoredContentChunk>()) {
            seen.insert(chunk.itemID)
        }
        return seen
    }

    public func deleteChunks(itemID: UUID) throws {
        let descriptor = FetchDescriptor<StoredContentChunk>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        for chunk in try modelContext.fetch(descriptor) { modelContext.delete(chunk) }
        try modelContext.save()
    }

    public func allTodos() throws -> [Todo] {
        let descriptor = FetchDescriptor<StoredTodo>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try modelContext.fetch(descriptor).map(\.asTodo)
    }

    public func todo(id: UUID) throws -> Todo? { try storedTodo(id)?.asTodo }

    public func upsertTodo(_ todo: Todo) throws {
        if let stored = try storedTodo(todo.id) { stored.apply(todo) }
        else { modelContext.insert(StoredTodo(todo)) }
        try modelContext.save()
    }

    public func deleteTodo(id: UUID) throws {
        if let stored = try storedTodo(id) { modelContext.delete(stored) }
        try modelContext.save()
    }

    public func detachTodos(linkedItemID: UUID) throws {
        let descriptor = FetchDescriptor<StoredTodo>(
            predicate: #Predicate { $0.linkedItemID == linkedItemID }
        )
        for todo in try modelContext.fetch(descriptor) { todo.linkedItemID = nil }
        try modelContext.save()
    }

    public func focusSessions(since date: Date?) throws -> [FocusSession] {
        var descriptor = FetchDescriptor<StoredFocusSession>(
            sortBy: [SortDescriptor(\.completedAt, order: .reverse)]
        )
        if let date {
            descriptor.predicate = #Predicate { $0.completedAt >= date }
        }
        return try modelContext.fetch(descriptor).map(\.asSession)
    }

    public func insertFocusSession(_ session: FocusSession) throws {
        modelContext.insert(StoredFocusSession(session))
        try modelContext.save()
    }

    @discardableResult
    public func trash(id: UUID, at date: Date) throws -> Holding? {
        guard let s = try stored(id), s.stateRaw != ItemState.trashed.rawValue else { return nil }
        s.stateRaw = ItemState.trashed.rawValue
        s.trashedAt = date
        try modelContext.save()
        return s.asItem.holding
    }

    @discardableResult
    public func restore(id: UUID) throws -> Holding? {
        guard let s = try stored(id), s.stateRaw == ItemState.trashed.rawValue else { return nil }
        s.stateRaw = ItemState.active.rawValue
        s.trashedAt = nil
        try modelContext.save()      // 向量与 indexedAt 未动，恢复不触发重算
        return s.asItem.holding
    }

    public func purge(id: UUID) throws -> Item? {
        guard let stored = try stored(id) else { return nil }
        let item = stored.asItem
        try deleteChunksWithoutSaving(itemID: id)
        modelContext.delete(stored)
        try modelContext.save()
        return item
    }

    public func purgeExpired(now: Date, retention: TimeInterval) throws -> [Item] {
        // #Predicate 不支持 `??`，改为先取回收站全量再在 Swift 侧筛。
        // 回收站是几十到几百条的量级，这点开销远低于为它写一个可谓词化的冗余字段。
        let trashed = ItemState.trashed.rawValue
        let d = FetchDescriptor<StoredItem>(
            predicate: #Predicate { $0.stateRaw == trashed },
            sortBy: [SortDescriptor(\.createdAt)]
        )
        let doomed = try modelContext.fetch(d).filter {
            guard let t = $0.trashedAt else { return false }
            return now.timeIntervalSince(t) >= retention
        }
        let items = doomed.map(\.asItem)
        for s in doomed {
            try deleteChunksWithoutSaving(itemID: s.id)
            modelContext.delete(s)
        }
        try modelContext.save()
        return items
    }

    private func stored(_ id: UUID) throws -> StoredItem? {
        var d = FetchDescriptor<StoredItem>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try modelContext.fetch(d).first
    }

    private func storedTodo(_ id: UUID) throws -> StoredTodo? {
        var descriptor = FetchDescriptor<StoredTodo>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func deleteChunksWithoutSaving(itemID: UUID) throws {
        let descriptor = FetchDescriptor<StoredContentChunk>(
            predicate: #Predicate { $0.itemID == itemID }
        )
        for chunk in try modelContext.fetch(descriptor) { modelContext.delete(chunk) }
    }
}
