#if DEBUG
import AppKit
import MnemoCore

/// 隔离数据目录下驱动一次真实的"重新解析"，走的是生产环境完全同一条
/// wiring（`contentIndexAction` 调用真正的 `SemanticIndexCoordinator.index`，
/// 真实发网络请求），不打真实 Embedding（不带凭据，`embed` 自然回落到
/// notConfigured，只验证抓取 + 标题落库这一段）。
///
/// 用来在“用户说复现失败，我这边原样请求却总成功”的僵局里，直接跑一遍
/// 应用自己的代码路径而不是另用 curl 模拟——两者只要有一处不同，
/// 这里就能露出来。
@MainActor
enum LinkSmokeCheck {
    static func run() async {
        guard let rootPath = ProcessInfo.processInfo.environment["MNEMO_DATA_ROOT"],
              rootPath.hasPrefix("/tmp/mnemo-ui-smoke-") else { exit(2) }
        let root = URL(filePath: rootPath)
        UserDefaults.standard.set(false, forKey: "Pinland.launchAtLogin")
        let model = AppModel()
        let settings = ProviderSettingsModel()
        model.contentIndexAction = { item, forceRefreshLink in
            let t0 = Date()
            let result = await SemanticIndexCoordinator.index(
                item: item, library: model.library, settings: settings,
                forceRefreshLink: forceRefreshLink
            )
            print("SMOKE: SemanticIndexCoordinator.index took \(Date().timeIntervalSince(t0))s completed=\(result.completed)")
            return result
        }

        func wait(_ label: String, _ condition: () async -> Bool) async throws {
            let deadline = Date.now.addingTimeInterval(30)
            var lastPrint = Date.distantPast
            while await !condition() {
                guard Date.now < deadline else {
                    throw NSError(domain: "LinkSmokeTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "timeout waiting on \(label): lastError=\(model.lastError ?? "nil") feedback=\(model.feedbackMessage ?? "nil") isIndexing=\(model.isIndexing)"])
                }
                if Date.now.timeIntervalSince(lastPrint) > 2 {
                    lastPrint = .now
                    print("SMOKE: still waiting on \(label) — isIndexing=\(model.isIndexing) lastError=\(model.lastError ?? "nil") feedback=\(model.feedbackMessage ?? "nil")")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        do {
            let urlString = ProcessInfo.processInfo.environment["MNEMO_SMOKE_LINK_URL"]
                ?? "https://www.xiaohongshu.com/explore/6a94ee06000000000a009dd1?xsec_token=AB2H6jCYpFsZ5AGtH8cO1EX4rDZAh63is_ZzSlGtfgRJ4=&xsec_source="
            guard let url = URL(string: urlString) else { throw NSError(domain: "LinkSmoke", code: 10) }
            // 生产链路里链接是当文字粘贴进来的（浏览器分享 → 剪贴板 → 粘贴），
            // 不是拖文件——`ingest(urls:)` 是给本地文件拖拽用的，传一个
            // http(s) URL 进去只会被当成"文件不存在"失败。
            let report = await model.ingest(text: urlString)
            guard report.inserted == 1 || report.reused == 1,
                  let item = model.items.first(where: { $0.linkURL == url }) else {
                throw NSError(domain: "LinkSmoke", code: 0, userInfo: [NSLocalizedDescriptionKey:
                    "ingest failed: inserted=\(report.inserted) reused=\(report.reused) failed=\(report.failed)"])
            }
            let id = item.id
            print("SMOKE: ingested id=\(id) title=\(item.title) kind=\(item.kind)")
            // 生产链路：pin 之后 scheduleAIWork 会自己把它排进索引队列，
            // 不需要手动 enqueueIndex——但这里直接走 reparseLink 更贴近
            // 用户实际点的那个按钮。
            await model.pinClipboardItem(id)
            print("SMOKE: pinned, waiting for auto index to produce chunks")
            try await wait("auto index") {
                let chunkCount = (try? await model.library.chunks(for: id))?.count ?? 0
                return chunkCount > 0 || model.lastError != nil
            }
            let afterAutoIndex = try await model.library.item(id: id)
            print("SMOKE: after auto index — title=\(afterAutoIndex?.title ?? "nil") version=\(afterAutoIndex?.linkExtractionVersion.map(String.init) ?? "nil") chunks=\((try? await model.library.chunks(for: id))?.count ?? -1) lastError=\(model.lastError ?? "nil")")

            model.reparseLink(id)
            print("SMOKE: reparseLink called, waiting for feedback/error")
            try await wait("reparse") {
                model.lastError != nil || model.feedbackMessage != nil
            }
            // 给收尾几帧时间落盘。
            try await Task.sleep(for: .milliseconds(300))
            let final = try await model.library.item(id: id)
            let chunks = (try? await model.library.chunks(for: id)) ?? []
            let result = """
            PASS/INFO: \
            title=\(final?.title ?? "nil") \
            titleOrigin=\(final?.titleOrigin ?? "nil") \
            linkExtractionVersion=\(final?.linkExtractionVersion.map(String.init) ?? "nil") \
            chunkCount=\(chunks.count) \
            feedback=\(model.feedbackMessage ?? "nil") \
            lastError=\(model.lastError ?? "nil")
            """
            print("SMOKE:", result)
            try (result + "\n").write(to: root.appending(path: "result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        } catch {
            try? "FAIL: \(error)\n".write(to: root.appending(path: "result.txt"), atomically: true, encoding: .utf8)
            exit(1)
        }
    }
}
#endif
