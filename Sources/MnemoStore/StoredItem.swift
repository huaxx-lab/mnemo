import Foundation
import SwiftData
import MnemoCore

/// SwiftData 的持久化实体。
///
/// 刻意与领域层的 `Item` 分开：`Item` 是值类型、可自由跨 actor 传递、可脱离数据库测试；
/// `StoredItem` 是引用类型且绑定 ModelContext。两者在边界上互转，
/// 这样换存储实现时领域层与测试一行都不用改。
@Model
public final class StoredItem {
    #Unique<StoredItem>([\.id])

    public var id: UUID = UUID()
    public var title: String = ""
    public var kindRaw: String = ItemKind.file.rawValue
    /// `Holding` 是带关联值的枚举，SwiftData 存不了，编码成 Data
    public var holdingData: Data = Data()
    public var stateRaw: String = ItemState.active.rawValue
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now
    public var trashedAt: Date?
    public var titledLocally: Bool = false
    public var originRaw: String = ItemOrigin.manual.rawValue
    public var isPinned: Bool = true
    public var originalFilename: String?
    public var originalSourcePath: String?
    public var sourceModificationDate: Date?
    public var sourceFileSize: Int64?
    public var contentTypeIdentifier: String?
    public var group: String?
    public var tags: [String] = []
    public var aiPrivacyBlocked: Bool = false
    public var isPrivate: Bool = false
    public var allowsSensitiveAI: Bool = false
    public var isTodo: Bool = false
    public var todoCompleted: Bool = false
    public var todoDueAt: Date?
    /// 手动排序值（分数索引）。新行默认取 createdAt 时间戳，等价于
    /// 现有的「最新在前」；拖动重排后由 store 写入邻居中点。
    /// 只存在存储层，不进入领域类型 Item——顺序不是内容，不该参与导出归档。
    public var sortOrder: Double = 0

    public var vector: [Float]?
    public var contentHash: String?
    public var embeddingModelID: String?
    public var indexedAt: Date?
    public var cloudSystemFields: Data?

    public init(_ item: Item) {
        apply(item)
        // 只有新行才落默认值；apply 不碰 sortOrder，后续 update 不覆盖用户排好的位置。
        sortOrder = item.createdAt.timeIntervalSince1970
    }

    func apply(_ item: Item) {
        id = item.id
        title = item.title
        kindRaw = item.kind.rawValue
        holdingData = (try? JSONEncoder().encode(item.holding)) ?? Data()
        stateRaw = item.state.rawValue
        createdAt = item.createdAt
        modifiedAt = item.modifiedAt
        trashedAt = item.trashedAt
        titledLocally = item.titledLocally
        originRaw = item.origin.rawValue
        isPinned = item.isPinned
        originalFilename = item.originalFilename
        originalSourcePath = item.originalSourcePath
        sourceModificationDate = item.sourceModificationDate
        sourceFileSize = item.sourceFileSize
        contentTypeIdentifier = item.contentTypeIdentifier
        group = item.group
        tags = item.tags
        aiPrivacyBlocked = item.aiPrivacyBlocked
        isPrivate = item.isPrivate
        allowsSensitiveAI = item.allowsSensitiveAI
        isTodo = item.isTodo
        todoCompleted = item.todoCompleted
        todoDueAt = item.todoDueAt
        vector = item.vector
        contentHash = item.contentHash
        embeddingModelID = item.embeddingModelID
        indexedAt = item.indexedAt
        cloudSystemFields = item.cloudSystemFields
    }

    /// 转回领域模型。编码损坏时退化为空文本条目并标记损坏，不静默丢弃整条记录。
    var asItem: Item {
        let holding = (try? JSONDecoder().decode(Holding.self, from: holdingData)) ?? .inline("")
        let decoded = (try? JSONDecoder().decode(Holding.self, from: holdingData)) != nil
        return Item(
            id: id,
            title: title,
            kind: ItemKind(rawValue: kindRaw) ?? .binary,
            holding: holding,
            state: decoded ? (ItemState(rawValue: stateRaw) ?? .active) : .damaged,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            trashedAt: trashedAt,
            titledLocally: titledLocally,
            origin: ItemOrigin(rawValue: originRaw) ?? .manual,
            isPinned: isPinned,
            originalFilename: originalFilename,
            originalSourcePath: originalSourcePath,
            sourceModificationDate: sourceModificationDate,
            sourceFileSize: sourceFileSize,
            contentTypeIdentifier: contentTypeIdentifier,
            group: group,
            tags: tags,
            aiPrivacyBlocked: aiPrivacyBlocked,
            allowsSensitiveAI: allowsSensitiveAI,
            isPrivate: isPrivate,
            isTodo: isTodo,
            todoCompleted: todoCompleted,
            todoDueAt: todoDueAt,
            vector: vector,
            contentHash: contentHash,
            embeddingModelID: embeddingModelID,
            indexedAt: indexedAt,
            cloudSystemFields: cloudSystemFields
        )
    }
}
