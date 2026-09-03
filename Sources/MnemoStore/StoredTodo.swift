import Foundation
import MnemoCore
import SwiftData

@Model
public final class StoredTodo {
    #Unique<StoredTodo>([\.id])

    public var id: UUID = UUID()
    public var title: String = ""
    public var linkedItemID: UUID?
    public var isCompleted: Bool = false
    public var dueAt: Date?
    public var createdAt: Date = Date.now
    public var modifiedAt: Date = Date.now
    public var cloudSystemFields: Data?

    public init(_ todo: Todo) { apply(todo) }

    func apply(_ todo: Todo) {
        id = todo.id
        title = todo.title
        linkedItemID = todo.linkedItemID
        isCompleted = todo.isCompleted
        dueAt = todo.dueAt
        createdAt = todo.createdAt
        modifiedAt = todo.modifiedAt
        cloudSystemFields = todo.cloudSystemFields
    }

    var asTodo: Todo {
        Todo(
            id: id,
            title: title,
            linkedItemID: linkedItemID,
            isCompleted: isCompleted,
            dueAt: dueAt,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            cloudSystemFields: cloudSystemFields
        )
    }
}
