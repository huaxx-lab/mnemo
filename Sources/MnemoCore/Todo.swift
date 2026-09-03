import Foundation

/// 效率模式的一等实体。纯文字待办的 linkedItemID 为 nil；由 Pin 转来的待办
/// 保存标题快照，关联条目进入回收站时可无损降级为纯文字。
public struct Todo: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var title: String
    public var linkedItemID: UUID?
    public var isCompleted: Bool
    public var dueAt: Date?
    public var createdAt: Date
    public var modifiedAt: Date
    public var cloudSystemFields: Data?

    public init(
        id: UUID = UUID(),
        title: String,
        linkedItemID: UUID? = nil,
        isCompleted: Bool = false,
        dueAt: Date? = nil,
        createdAt: Date = .now,
        modifiedAt: Date? = nil,
        cloudSystemFields: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.linkedItemID = linkedItemID
        self.isCompleted = isCompleted
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
        self.cloudSystemFields = cloudSystemFields
    }
}
