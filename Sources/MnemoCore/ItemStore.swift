import Foundation

/// 条目存储。领域层只依赖这个协议，不感知 SwiftData 或任何具体实现。
///
/// 删除语义是软删除：`trash` 把条目移入回收站并记录时刻，`purgeExpired` 才真正抹掉。
/// 这不是为了优雅——源文件可能早已不在，副本很可能是世上唯一一份。
public protocol ItemStore: Actor {
    func all(includingTrashed: Bool) throws -> [Item]
    func item(id: UUID) throws -> Item?
    func insert(_ item: Item) throws
    func upsert(_ item: Item) throws
    func update(_ item: Item) throws
    func allChunks() throws -> [ContentChunk]
    func chunks(itemID: UUID) throws -> [ContentChunk]
    /// 只取这些条目的分块。检索先用类型/时间把候选收窄，再按候选取块——
    /// 全量加载在几百块时无所谓，库大了就是每敲一次回车读一遍整张表。
    func chunks(itemIDs: Set<UUID>) throws -> [ContentChunk]
    func replaceChunks(itemID: UUID, with chunks: [ContentChunk]) throws
    /// 原子替换 RAG 分块并更新承载聚合向量/标题的 Item。
    /// 重新解析链接不能先提交新分块、再单独提交 Item：第二次保存失败会留下
    /// 新正文配旧向量（反过来也可能），检索状态自相矛盾。
    func replaceChunks(itemID: UUID, with chunks: [ContentChunk], updating item: Item) throws
    func deleteChunks(itemID: UUID) throws
    func allTodos() throws -> [Todo]
    func todo(id: UUID) throws -> Todo?
    func upsertTodo(_ todo: Todo) throws
    func deleteTodo(id: UUID) throws
    func detachTodos(linkedItemID: UUID) throws
    /// 手动排序：把 id 挪到 targetID 前面；targetID 为 nil 表示挪到末尾。
    func move(_ id: UUID, before targetID: UUID?) throws
    func focusSessions(since: Date?) throws -> [FocusSession]
    func insertFocusSession(_ session: FocusSession) throws

    /// 移入回收站，不删盘。返回该条目的持有方式，供上层递减引用计数。
    @discardableResult func trash(id: UUID, at: Date) throws -> Holding?
    /// 从回收站恢复。向量随条目保留，不触发重算。
    @discardableResult func restore(id: UUID) throws -> Holding?
    /// 清理超出保留期的条目，返回被真正删除的条目，供上层删盘。
    func purgeExpired(now: Date, retention: TimeInterval) throws -> [Item]
    /// 彻底删掉一条：连同它的检索分块。已经不在库里返回 nil，不是错误。
    func purge(id: UUID) throws -> Item?
}

public extension ItemStore {
    func all() throws -> [Item] { try all(includingTrashed: false) }
}

/// 内存实现。测试用，也是 SwiftData 实现的行为基准。
public actor InMemoryItemStore: ItemStore {
    private var items: [UUID: Item] = [:]
    /// 手动排序值，与 SwiftData 实现同一语义：默认=创建时间戳，拖动后取邻居中点。
    private var orders: [UUID: Double] = [:]
    private var indexedChunks: [UUID: [ContentChunk]] = [:]
    private var todos: [UUID: Todo] = [:]
    private var focusHistory: [UUID: FocusSession] = [:]
    public init(_ seed: [Item] = []) {
        for i in seed {
            items[i.id] = i
            orders[i.id] = i.createdAt.timeIntervalSince1970
        }
    }

    public func all(includingTrashed: Bool) throws -> [Item] {
        items.values
            .filter { includingTrashed || $0.state != .trashed }
            .sorted {
                let lhs = orders[$0.id] ?? 0
                let rhs = orders[$1.id] ?? 0
                if lhs != rhs { return lhs > rhs }
                return $0.createdAt > $1.createdAt
            }
    }

    public func item(id: UUID) throws -> Item? { items[id] }

    public func insert(_ item: Item) throws {
        items[item.id] = item
        if orders[item.id] == nil { orders[item.id] = item.createdAt.timeIntervalSince1970 }
    }

    public func upsert(_ item: Item) throws {
        items[item.id] = item
        if orders[item.id] == nil { orders[item.id] = item.createdAt.timeIntervalSince1970 }
    }

    public func move(_ id: UUID, before targetID: UUID?) throws {
        guard id != targetID, items[id] != nil else { return }
        var others = try all()
        others.removeAll { $0.id == id }
        let insertionIndex: Int
        if let targetID {
            guard let idx = others.firstIndex(where: { $0.id == targetID }) else { return }
            insertionIndex = idx
        } else {
            insertionIndex = others.count
        }
        let above = insertionIndex > 0 ? others[insertionIndex - 1] : nil
        let below = insertionIndex < others.count ? others[insertionIndex] : nil
        switch (above.map { orders[$0.id] ?? 0 }, below.map { orders[$0.id] ?? 0 }) {
        case let (a?, b?):
            if a - b < 0.0001 {
                for (i, row) in others.enumerated() {
                    orders[row.id] = Double(others.count - i) * 10_000
                }
                orders[id] = ((orders[others[insertionIndex - 1].id] ?? 0) + (orders[others[insertionIndex].id] ?? 0)) / 2
            } else {
                orders[id] = b + (a - b) / 2
            }
        case let (a?, nil): orders[id] = a - 10_000
        case let (nil, b?): orders[id] = b + 10_000
        case (nil, nil): break
        }
    }

    public func update(_ item: Item) throws {
        guard items[item.id] != nil else { return }
        items[item.id] = item
    }

    public func allChunks() throws -> [ContentChunk] {
        indexedChunks.values.flatMap { $0 }.sorted {
            if $0.itemID != $1.itemID { return $0.itemID.uuidString < $1.itemID.uuidString }
            return $0.ordinal < $1.ordinal
        }
    }

    public func chunks(itemID: UUID) throws -> [ContentChunk] {
        (indexedChunks[itemID] ?? []).sorted { $0.ordinal < $1.ordinal }
    }

    public func chunks(itemIDs: Set<UUID>) throws -> [ContentChunk] {
        indexedChunks
            .filter { itemIDs.contains($0.key) }
            .values
            .flatMap { $0 }
            .sorted {
                if $0.itemID != $1.itemID { return $0.itemID.uuidString < $1.itemID.uuidString }
                return $0.ordinal < $1.ordinal
            }
    }

    public func replaceChunks(itemID: UUID, with chunks: [ContentChunk]) throws {
        indexedChunks[itemID] = chunks
    }

    public func replaceChunks(
        itemID: UUID, with chunks: [ContentChunk], updating item: Item
    ) throws {
        guard item.id == itemID else { return }
        indexedChunks[itemID] = chunks.filter { $0.itemID == itemID }
        items[itemID] = item
    }

    public func deleteChunks(itemID: UUID) throws { indexedChunks[itemID] = nil }

    public func allTodos() throws -> [Todo] {
        todos.values.sorted { $0.createdAt > $1.createdAt }
    }

    public func todo(id: UUID) throws -> Todo? { todos[id] }

    public func upsertTodo(_ todo: Todo) throws { todos[todo.id] = todo }

    public func deleteTodo(id: UUID) throws { todos[id] = nil }

    public func detachTodos(linkedItemID: UUID) throws {
        let matches = todos.values.filter { $0.linkedItemID == linkedItemID }.map(\.id)
        for id in matches {
            guard var todo = todos[id] else { continue }
            todo.linkedItemID = nil
            todos[id] = todo
        }
    }

    public func focusSessions(since date: Date?) throws -> [FocusSession] {
        focusHistory.values
            .filter { session in
                guard let date else { return true }
                return session.completedAt >= date
            }
            .sorted { $0.completedAt > $1.completedAt }
    }

    public func insertFocusSession(_ session: FocusSession) throws {
        focusHistory[session.id] = session
    }

    @discardableResult
    public func trash(id: UUID, at date: Date) throws -> Holding? {
        guard var i = items[id], i.state != .trashed else { return nil }
        i.state = .trashed
        i.trashedAt = date
        items[id] = i
        return i.holding
    }

    @discardableResult
    public func restore(id: UUID) throws -> Holding? {
        guard var i = items[id], i.state == .trashed else { return nil }
        i.state = .active
        i.trashedAt = nil
        items[id] = i          // 向量与 indexedAt 原样保留，恢复不触发重算
        return i.holding
    }

    public func purge(id: UUID) throws -> Item? {
        guard let item = items[id] else { return nil }
        items[id] = nil
        indexedChunks[id] = nil
        return item
    }

    public func purgeExpired(now: Date, retention: TimeInterval) throws -> [Item] {
        let doomed = items.values.filter {
            $0.state == .trashed && $0.trashedAt.map { now.timeIntervalSince($0) >= retention } == true
        }
        for i in doomed { items[i.id] = nil }
        for i in doomed { indexedChunks[i.id] = nil }
        return doomed.sorted { $0.createdAt < $1.createdAt }
    }
}
