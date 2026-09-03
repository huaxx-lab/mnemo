import Foundation

/// 语义化版本号。
///
/// 只吃数字段："3.0"、"3.0.1"、"v3.0.1" 都是同一个东西。构建号、提交哈希
/// 不参与比较——那是给开发者看的，不是给升级判断看的。
public struct AppVersion: Sendable, Comparable, Equatable, CustomStringConvertible {
    public let segments: [Int]

    public init(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .drop { $0 == "v" || $0 == "V" }
        var parts = cleaned.split(separator: ".").compactMap { Int($0) }
        // 尾部的零段不影响版本语义（3.0 与 3.0.0 是同一个版本），收掉它们，
        // Comparable 和 Equatable 才有同一个答案。
        while parts.last == 0 { parts.removeLast() }
        segments = parts
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.segments.count, rhs.segments.count)
        for index in 0..<count {
            let lhsSegment = index < lhs.segments.count ? lhs.segments[index] : 0
            let rhsSegment = index < rhs.segments.count ? rhs.segments[index] : 0
            if lhsSegment != rhsSegment { return lhsSegment < rhsSegment }
        }
        return false
    }

    public var description: String { segments.map(String.init).joined(separator: ".") }
}

/// GitHub release 里我们关心的最小信息集。
public struct ReleaseInfo: Sendable, Equatable {
    public var version: AppVersion
    public var title: String
    /// 发布说明（Markdown 原文）。
    public var notes: String
    /// 安装包下载地址。
    public var assetURL: URL
    public var assetName: String
    public var publishedAt: Date?

    public init(version: AppVersion, title: String, notes: String, assetURL: URL, assetName: String, publishedAt: Date?) {
        self.version = version
        self.title = title
        self.notes = notes
        self.assetURL = assetURL
        self.assetName = assetName
        self.publishedAt = publishedAt
    }
}

/// 从 GitHub releases API 的响应里挑出"比当前新、且带安装包"的那一个。
///
/// 解析规则只认两件事：tag 能解出版本号，附件里有 .dmg。latest 接口已经
/// 滤掉了 draft 和 prerelease，不需要再判。
public enum ReleaseParsing {
    public struct Error: Swift.Error, Equatable {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
    }

    public static func latestRelease(from data: Data) throws -> ReleaseInfo {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw Error("响应不是 JSON 对象") }
        guard let tag = root["tag_name"] as? String else { throw Error("没有 tag_name") }
        let version = AppVersion(tag)
        guard !version.segments.isEmpty else { throw Error("tag 不是版本号：\(tag)") }

        let assets = root["assets"] as? [[String: Any]] ?? []
        guard let asset = assets.first(where: {
            (($0["name"] as? String) ?? "").lowercased().hasSuffix(".dmg")
        }),
              let download = asset["browser_download_url"] as? String,
              let assetURL = URL(string: download)
        else { throw Error("这个 release 没有 .dmg 附件") }

        let publishedAt = (root["published_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        return ReleaseInfo(
            version: version,
            title: (root["name"] as? String) ?? tag,
            notes: (root["body"] as? String) ?? "",
            assetURL: assetURL,
            assetName: (asset["name"] as? String) ?? "Mnemo.dmg",
            publishedAt: publishedAt
        )
    }
}
