#if DEBUG
import AppKit
import Foundation
import MnemoCore

/// 把一条链接的原始 HTML 按**和生产完全相同的请求方式**（同一份请求头画像、
/// 同一个带登录态的 cookie 罐）抓下来存盘，供离线看结构。
///
/// 存在的理由：抓取出问题时，最常见的死路是"我这边照着猜的请求复现不了"。
/// 页面结构是平台随时会改的东西，与其照文档猜 `imageList` 里应该有什么，
/// 不如把那一刻真实返回的东西原样落到磁盘上翻。
@MainActor
enum LinkHTMLDump {
    static func run() async {
        // 离线模式：直接拿一份已经存下来的 HTML 过一遍解析器，看它到底认出了
        // 什么。抓取和解析分开验证，才分得清"没抓到"和"抓到了但没解析对"。
        if let parsePath = ProcessInfo.processInfo.environment["MNEMO_DUMP_PARSE"],
           let html = try? String(contentsOf: URL(filePath: parsePath), encoding: .utf8) {
            let pageURL = ProcessInfo.processInfo.environment["MNEMO_DUMP_URL"].flatMap(URL.init(string:))
            let note = SiteContentExtraction.Xiaohongshu.note(fromHTML: html, url: pageURL)
            print("PARSE: note=\(note == nil ? "nil" : "ok")")
            print("PARSE: title=\(note?.title ?? "nil")")
            print("PARSE: textChars=\(note?.text.count ?? -1)")
            print("PARSE: imageURLs(\(note?.imageURLs.count ?? -1))=\(note?.imageURLs.map(\.absoluteString) ?? [])")
            exit(EXIT_SUCCESS)
        }

        guard let urlString = ProcessInfo.processInfo.environment["MNEMO_DUMP_URL"],
              let url = URL(string: urlString),
              let outPath = ProcessInfo.processInfo.environment["MNEMO_DUMP_OUTPUT"]
        else { exit(2) }

        await XiaohongshuSession.restoreAtLaunch()
        print("DUMP: signedIn=\(XiaohongshuSession.isSignedIn) cookies=\(XiaohongshuSession.cookieCount)")

        var request = URLRequest(url: url, timeoutInterval: 15)
        BrowserRequestHeaders.apply(.document, to: &request)
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            print("DUMP: request failed")
            exit(1)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        try? data.write(to: URL(filePath: outPath))
        print("DUMP: status=\(status) bytes=\(data.count) -> \(outPath)")
        NSApp.terminate(nil)
    }
}
#endif
