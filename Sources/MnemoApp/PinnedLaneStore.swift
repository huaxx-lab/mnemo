import Foundation
import MnemoCore

/// 轨道最前面那一段"钉住区"。
///
/// 和「锁定保留」（`isPinned`）是两件事，虽然中文里都叫钉：那个决定条目会不会
/// 被新内容挤出临时轨道，是**存不存**的问题；这个决定它排在哪儿，是**摆在哪**
/// 的问题。一条内容可以只钉位置不锁存，也可以反过来。
///
/// 顺序自己存一份，不复用 `sortOrder`：钉住区的意义就是"后面来多少新东西都
/// 不动我"，而 `sortOrder` 默认取创建时间戳，新条目天然排在最前——两者的默认
/// 行为正好相反，共用一个字段就要靠不断改写别人的值来维持，改漏一次顺序就乱。
@MainActor
enum PinnedLaneStore {
    private static let key = "Pinland.pinnedLane.v1"

    private static var ordered: [UUID] = {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }()

    static func ids() -> [UUID] { ordered }

    static func contains(_ id: UUID) -> Bool { ordered.contains(id) }

    /// 钉住。`target` 为 nil 时排到这一段的末尾。
    ///
    /// `after` 不能省：落在某张钉住卡片的**右缘**时，插入点是它后面那一格，
    /// 而不是整段的末尾。之前把这种情况当成"没有锚点"，卡片会越过后面所有
    /// 钉住的卡直接甩到队尾——和用户眼前那根插入竖线差着好几格。
    static func pin(_ id: UUID, anchor target: UUID?, after: Bool = false) {
        ordered.removeAll { $0 == id }
        guard let target, let index = ordered.firstIndex(of: target) else {
            ordered.append(id)
            persist()
            return
        }
        ordered.insert(id, at: after ? index + 1 : index)
        persist()
    }

    static func unpin(_ id: UUID) {
        guard ordered.contains(id) else { return }
        ordered.removeAll { $0 == id }
        persist()
    }

    /// 钉住区内部换位。两张都在区里时才走这条，否则就是进出区的事。
    static func move(_ id: UUID, before target: UUID?, after: Bool) {
        guard ordered.contains(id) else { return }
        ordered.removeAll { $0 == id }
        guard let target, let index = ordered.firstIndex(of: target) else {
            ordered.append(id)
            persist()
            return
        }
        ordered.insert(id, at: after ? index + 1 : index)
        persist()
    }

    static func prune(keeping ids: Set<UUID>) {
        let kept = ordered.filter { ids.contains($0) }
        guard kept.count != ordered.count else { return }
        ordered = kept
        persist()
    }

    private static func persist() {
        UserDefaults.standard.set(ordered.map(\.uuidString), forKey: key)
    }
}
