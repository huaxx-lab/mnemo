import Foundation
import MnemoCore
import SwiftData

@Model
public final class StoredFocusSession {
    #Unique<StoredFocusSession>([\.id])

    public var id: UUID = UUID()
    public var startedAt: Date = Date.now
    public var completedAt: Date = Date.now
    public var plannedDuration: TimeInterval = 25 * 60

    public init(_ session: FocusSession) {
        id = session.id
        startedAt = session.startedAt
        completedAt = session.completedAt
        plannedDuration = session.plannedDuration
    }

    var asSession: FocusSession {
        FocusSession(
            id: id,
            startedAt: startedAt,
            completedAt: completedAt,
            plannedDuration: plannedDuration
        )
    }
}
