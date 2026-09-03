import Foundation

/// FileVault 的失败原因。每一条对应 design 第 10 节的一行边界，
/// 均为显式抛出，不做 silent fallback。
public enum VaultError: Error, Equatable, CustomStringConvertible {
    /// F-01：零字节文件
    case emptyFile(URL)
    /// F-02：文件不存在或不可读
    case unreadable(URL, reason: String)
    /// F-05：副本拷贝中途失败，已回滚
    case copyFailed(URL, reason: String)
    /// 引用源已确认删除；上层应把 Pin 移入回收站
    case staleBookmark
    /// 外置卷离线、权限暂失等不可确认删除的状态
    case referenceUnavailable
    /// F-09：引用计数归零后删除副本失败，记录保留待重试
    case purgeFailed(hash: String, reason: String)

    public var description: String {
        switch self {
        case .emptyFile(let u):
            "文件为空，未入库：\(u.lastPathComponent)"
        case .unreadable(let u, let r):
            "无法读取 \(u.lastPathComponent)：\(r)"
        case .copyFailed(let u, let r):
            "拷贝 \(u.lastPathComponent) 失败并已回滚：\(r)"
        case .staleBookmark:
            "原文件已删除，Pin 将移入回收站"
        case .referenceUnavailable:
            "原文件暂时不可用；Pin 已保留，请检查磁盘或访问权限"
        case .purgeFailed(let h, let r):
            "删除副本 \(h.prefix(8)) 失败，将在下次启动重试：\(r)"
        }
    }
}

/// 启动对账扫描的结果（F2.5）。
public struct ReconcileReport: Sendable, Equatable {
    /// 磁盘上存在但清单无记录，已清除（F-08）
    public var orphansRemoved: [String] = []
    /// 清单有记录但文件缺失，对应条目应转损坏态（F-07）
    public var missingCopies: [String] = []
    /// 上次归零删除失败、本次重试成功的
    public var retriedPurges: [String] = []

    public var isClean: Bool {
        orphansRemoved.isEmpty && missingCopies.isEmpty && retriedPurges.isEmpty
    }
}
