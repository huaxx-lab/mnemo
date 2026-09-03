import Foundation

/// 条目的内容类别。UTI 判定不出来时归入 `.binary`，仍然入库（design 边界：类型无法识别）。
public enum ItemKind: String, Codable, Sendable, CaseIterable {
    case text, image, pdf, link, file, binary
}

/// 条目持有内容的方式。普通文件优先存安全书签；只有临时来源或无法建立
/// 可靠引用时才持有副本（F2.1）。
public enum Holding: Sendable, Equatable, Codable {
    /// 文本直接内联，不落文件
    case inline(String)
    /// 副本：以内容 SHA-256 命名存于沙盒
    case copy(hash: String, size: Int64)
    /// 引用：安全书签，绑定本机文件系统
    case reference(bookmark: Data, size: Int64)

    public var size: Int64 {
        switch self {
        case .inline(let s): Int64(s.utf8.count)
        case .copy(_, let n), .reference(_, let n): n
        }
    }

    public var isReference: Bool {
        if case .reference = self { return true }
        return false
    }
}

/// 条目状态。`broken` 只兼容旧库；新引用健康检查会把确认删除移入回收站，
/// 把暂时不可达保留为 active/冻结，不再要求用户手动重新定位（design 8.3）。
public enum ItemState: String, Codable, Sendable {
    /// 正常
    case active
    /// 旧库中的断链记录，保留用于迁移与兼容显示
    case broken
    /// 数据库有记录但副本文件缺失
    case damaged
    /// 引用型条目在非原设备上
    case unavailableOnThisDevice
    /// 在回收站中
    case trashed
}

public enum ItemOrigin: String, Codable, Sendable {
    case manual
    case clipboard
}

public struct Item: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public var title: String
    public var kind: ItemKind
    public var holding: Holding
    public var state: ItemState
    public var createdAt: Date
    public var modifiedAt: Date
    public var trashedAt: Date?
    /// 命名是否由本地规则产生（敏感内容命中筛查时为 true，卡片显示「本地处理」徽标）
    public var titledLocally: Bool
    /// 自动剪贴板历史与用户主动收藏必须分开；只有未固定的 clipboard 项
    /// 会参与容量淘汰。
    public var origin: ItemOrigin
    public var isPinned: Bool
    /// 原始文件名（含扩展名）。Vault 副本以哈希命名，取用、缩略图和拖出时
    /// 必须依赖这份元数据恢复用户看到的文件名。
    public var originalFilename: String?
    /// 引用建立时的原始绝对路径。它不是取用入口（取用始终解析书签），只用于
    /// 在书签解析失败时区分「原文件已删除」与「外置卷暂时离线」。
    public var originalSourcePath: String?
    /// 引用型原文件的轻量内容版本。健康巡检只比较元数据；仅在变化后才重新
    /// 读取正文或计算 Embedding，避免周期性扫描整篇文档。
    public var sourceModificationDate: Date?
    public var sourceFileSize: Int64?
    /// 入库时解析出的统一类型标识。扩展名缺失或副本改名后仍可用于能力门控。
    public var contentTypeIdentifier: String?
    /// AI 或本地规则产生的轻量组织信息。标签上限由写入端控制，搜索与导出均保留。
    public var group: String?
    public var tags: [String]
    public var aiPrivacyBlocked: Bool
    public var allowsSensitiveAI: Bool
    /// 在隐私空间里。
    ///
    /// 它**只是隐藏**，不是加密：库文件里仍是明文，拿到这台机器的人读得到。
    /// 界面上因此只说"已隐藏"，绝不说"已加密"——让用户以为数据被保护了，
    /// 比不提供这个功能更糟。
    ///
    /// 状态存在条目本身而不是旁路记录：旁路记录一旦损坏或被删就是 fail-open，
    /// 所有隐私条目瞬间全部露出来。
    public var isPrivate: Bool
    public var isTodo: Bool
    public var todoCompleted: Bool
    public var todoDueAt: Date?

    // MARK: 索引字段（F5.1 / AC-42）
    public var vector: [Float]?
    public var contentHash: String?
    public var embeddingModelID: String?
    public var indexedAt: Date?
    /// 遗留字段。iCloud 同步已移除，这里恒为 nil；保留列以避免对用户现有
    /// SwiftData 库做一次没有收益的迁移。
    public var cloudSystemFields: Data?

    public init(
        id: UUID = UUID(),
        title: String,
        kind: ItemKind,
        holding: Holding,
        state: ItemState = .active,
        createdAt: Date = .now,
        modifiedAt: Date? = nil,
        trashedAt: Date? = nil,
        titledLocally: Bool = false,
        origin: ItemOrigin = .manual,
        isPinned: Bool = true,
        originalFilename: String? = nil,
        originalSourcePath: String? = nil,
        sourceModificationDate: Date? = nil,
        sourceFileSize: Int64? = nil,
        contentTypeIdentifier: String? = nil,
        group: String? = nil,
        tags: [String] = [],
        aiPrivacyBlocked: Bool = false,
        allowsSensitiveAI: Bool = false,
        isPrivate: Bool = false,
        isTodo: Bool = false,
        todoCompleted: Bool = false,
        todoDueAt: Date? = nil,
        vector: [Float]? = nil,
        contentHash: String? = nil,
        embeddingModelID: String? = nil,
        indexedAt: Date? = nil,
        cloudSystemFields: Data? = nil
    ) {
        self.id = id; self.title = title; self.kind = kind
        self.holding = holding; self.state = state
        self.createdAt = createdAt; self.modifiedAt = modifiedAt ?? createdAt
        self.trashedAt = trashedAt
        self.titledLocally = titledLocally
        self.origin = origin
        self.isPinned = isPinned
        self.originalFilename = originalFilename
        self.originalSourcePath = originalSourcePath
        self.sourceModificationDate = sourceModificationDate
        self.sourceFileSize = sourceFileSize
        self.contentTypeIdentifier = contentTypeIdentifier
        self.group = group
        self.tags = tags
        self.aiPrivacyBlocked = aiPrivacyBlocked
        self.allowsSensitiveAI = allowsSensitiveAI
        self.isPrivate = isPrivate
        self.isTodo = isTodo
        self.todoCompleted = todoCompleted
        self.todoDueAt = todoDueAt
        self.vector = vector; self.contentHash = contentHash
        self.embeddingModelID = embeddingModelID; self.indexedAt = indexedAt
        self.cloudSystemFields = cloudSystemFields
    }

    /// 索引是否完整。AC-42 的断言依据。
    public var isFullyIndexed: Bool {
        vector?.isEmpty == false && contentHash != nil
            && embeddingModelID != nil && indexedAt != nil
    }
}
