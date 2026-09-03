import Foundation
import os

enum PerformanceTrace {
    private static let log = OSLog(subsystem: "com.pinland.app", category: .pointsOfInterest)

    static func begin(_ name: StaticString) -> OSSignpostID {
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id)
        return id
    }

    static func end(_ name: StaticString, id: OSSignpostID) {
        os_signpost(.end, log: log, name: name, signpostID: id)
    }
}


/// 一次投放到底拿到了什么。
///
/// 拖拽失败是这条链上最难查的一段：发送方给了哪些类型、路径读不读得到、
/// 最后走了哪个分支，全都发生在别的应用和系统之间，事后无从还原。这里只记
/// 结论——类型标识符、文件名和分支，不记内容——写进应用支持目录，出问题时
/// 直接看这一份就够，不必再靠猜。
@MainActor
enum DropTrace {
    private static let limit = 200
    private static var lines: [String] = []

    private static var fileURL: URL {
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pinland", directoryHint: .isDirectory) // 这条路径是数据的**家**，不是品牌名。整个库、向量索引、文件仓、
            // 目录缓存都在 ~/Library/Application Support/Pinland 里。应用改名
            // 不换数据的家——换一次家等于把用户攒下的所有东西留在原地。
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appending(path: "drop-trace.log")
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: .now)
        lines.append("\(stamp) \(message)")
        if lines.count > limit { lines.removeFirst(lines.count - limit) }
        try? lines.joined(separator: "\n").appending("\n").write(
            to: fileURL, atomically: true, encoding: .utf8
        )
    }
}
