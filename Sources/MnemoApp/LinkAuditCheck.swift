#if DEBUG
import AppKit
import CryptoKit
import Foundation
import MnemoCore

/// 把库里现有的链接整批过一遍**真实抓取路径**，逐条报告标题、正文、首图
/// 三样各自拿到了什么。
///
/// 用意和 `LinkSmokeCheck` 不同：那个是单条链接跑完整入库流程，用来复现
/// 某一条的具体问题；这个是横向体检——"库里这些链接现在到底有多少条是
/// 真抓到了正文、有多少条只剩标题、有多少条首图其实是平台占位图"，只有
/// 铺开看才分得清"这条笔记本来就没正文"和"我们没抓到"。
///
/// 首图是不是平台占位图，用的是**成品字节比对**：`LinkCoverStore.store`
/// 缩放编码是确定的，同一张源图落盘后字节一致——生产库里三条毫不相关的
/// 笔记封面 MD5 完全相同，就是这么发现的。
@MainActor
enum LinkAuditCheck {
    /// 已知的平台占位图（小红书通用红底 logo）落盘后的指纹。
    private static let knownPlaceholderHashes: Set<String> = [
        "5f75bd4d18e5a3b4795feebda371b130"
    ]

    struct Row: Codable {
        var pk: Int
        var url: String
        var storedTitle: String
        var storedBodyChars: Int
        var fetchedTitle: String?
        var fetchedBodyChars: Int
        var fetchedBodyHead: String
        var coverKind: String
        var verdict: String
    }

    static func run() async {
        guard let inputPath = ProcessInfo.processInfo.environment["MNEMO_AUDIT_INPUT"],
              let outputPath = ProcessInfo.processInfo.environment["MNEMO_AUDIT_OUTPUT"],
              let data = try? Data(contentsOf: URL(filePath: inputPath)),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { exit(2) }

        await XiaohongshuSession.restoreAtLaunch()
        print("AUDIT: signedIn=\(XiaohongshuSession.isSignedIn) cookies=\(XiaohongshuSession.cookieCount)")

        var rows: [Row] = []
        for (index, item) in items.enumerated() {
            guard let urlString = item["url"] as? String, let url = URL(string: urlString) else { continue }
            let pk = item["pk"] as? Int ?? -1
            let storedTitle = item["title"] as? String ?? ""
            let storedBody = ((item["page"] as? [Any])?.last as? Int) ?? 0

            let fetched = await LinkContentFetcher.fetch(url)
            let preview = await LinkCoverStore.fetch(for: url)

            var coverKind = "none"
            if let cover = preview.cover {
                let probeID = UUID()
                if LinkCoverStore.store(cover, for: probeID),
                   let bytes = try? Data(contentsOf: LinkCoverStore.url(for: probeID)) {
                    let digest = Insecure.MD5.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
                    coverKind = knownPlaceholderHashes.contains(digest)
                        ? "PLACEHOLDER"
                        : "real(\(Int(cover.size.width))x\(Int(cover.size.height)))"
                    LinkCoverStore.remove(probeID)
                } else {
                    coverKind = "unstorable"
                }
            }

            let body = fetched?.text ?? ""
            let head = body.replacingOccurrences(of: "\n", with: " ").prefix(50)
            let verdict: String
            if fetched == nil {
                verdict = "FETCH_FAILED"
            } else if body.isEmpty {
                verdict = "NO_BODY"
            } else if coverKind == "PLACEHOLDER" {
                verdict = "BODY_OK_COVER_PLACEHOLDER"
            } else if coverKind == "none" {
                verdict = "BODY_OK_NO_COVER"
            } else {
                verdict = "OK"
            }

            let row = Row(
                pk: pk, url: urlString, storedTitle: storedTitle, storedBodyChars: storedBody,
                fetchedTitle: fetched?.title, fetchedBodyChars: body.count,
                fetchedBodyHead: String(head), coverKind: coverKind, verdict: verdict
            )
            rows.append(row)
            print("AUDIT[\(index + 1)/\(items.count)] pk=\(pk) \(verdict) body=\(body.count) cover=\(coverKind) title=\(fetched?.title ?? "nil")")

            // 别把同一个站点打太急：这是体检，不是压测。
            try? await Task.sleep(for: .milliseconds(700))
        }

        if let out = try? JSONEncoder().encode(rows) {
            try? out.write(to: URL(filePath: outputPath))
        }
        print("AUDIT: done, \(rows.count) rows -> \(outputPath)")
        NSApp.terminate(nil)
    }
}
#endif
