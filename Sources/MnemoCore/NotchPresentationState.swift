import Foundation

public struct NotchPresentationState: Equatable, Sendable {
    public enum WorkspacePhase: Equatable, Sendable {
        case hidden
        case opening
        case open
        case closing
    }

    public enum DragPhase: Equatable, Sendable {
        case idle
        case targeted
        case receiving
        case absorbed
        case failed
    }

    public private(set) var workspacePhase: WorkspacePhase
    public private(set) var dragPhase: DragPhase

    public init(
        workspacePhase: WorkspacePhase = .hidden,
        dragPhase: DragPhase = .idle
    ) {
        self.workspacePhase = workspacePhase
        self.dragPhase = dragPhase
    }

    public var isWorkspacePresented: Bool { workspacePhase != .hidden }
    public var acceptsWorkspaceInput: Bool { workspacePhase == .open }
    public var showsDropFeedback: Bool {
        dragPhase == .targeted || dragPhase == .receiving
    }

    @discardableResult
    public mutating func requestOpen() -> Bool {
        switch workspacePhase {
        case .hidden, .closing:
            workspacePhase = .opening
            return true
        case .opening, .open:
            return false
        }
    }

    public mutating func completeOpen() {
        guard workspacePhase == .opening else { return }
        workspacePhase = .open
    }

    @discardableResult
    public mutating func requestClose() -> Bool {
        switch workspacePhase {
        case .opening, .open:
            workspacePhase = .closing
            return true
        case .hidden, .closing:
            return false
        }
    }

    public mutating func completeClose() {
        guard workspacePhase == .closing else { return }
        workspacePhase = .hidden
    }

    public mutating func dragEntered() {
        // .absorbed / .failed 只是上一次投放的余韵，不是"正在接收"。
        // 旧实现只接受 .idle 和 .failed，于是上一次投放后的 420ms 结算窗口内
        // 再拖第二个进来，dragEntered 被拒 → beginDrop 返回 false →
        // 内容既不入库也不报错，直接消失。连拖两张截图就会丢件。
        guard dragPhase != .receiving else { return }
        dragPhase = .targeted
    }

    public mutating func dragExited() {
        guard dragPhase == .targeted else { return }
        dragPhase = .idle
    }

    @discardableResult
    public mutating func beginDrop() -> Bool {
        guard dragPhase == .targeted else { return false }
        dragPhase = .receiving
        return true
    }

    public mutating func completeDrop(succeeded: Bool) {
        guard dragPhase == .receiving || dragPhase == .targeted else { return }
        dragPhase = succeeded ? .absorbed : .failed
    }

    public mutating func settleDrag() {
        dragPhase = .idle
    }
}
