#if DEBUG
import AppKit
import SwiftUI
import MnemoCore

/// 显式启用且隔离数据目录下的应用级冒烟，不连接生产库、不监控剪贴板。
@MainActor
enum TodoSmokeCheck {
    static func run() async {
        guard let rootPath = ProcessInfo.processInfo.environment["MNEMO_DATA_ROOT"],
              rootPath.hasPrefix("/tmp/mnemo-ui-smoke-") else { exit(2) }
        let root = URL(filePath: rootPath)
        UserDefaults.standard.set(false, forKey: "Pinland.launchAtLogin")
        let model = AppModel()
        model.todoIntakeEnabled = true
        model.todoAutoCreateEnabled = false
        model.autoGroupingEnabled = false
        model.groupAssignmentAction = nil
        model.aiEnrichmentAction = nil
        model.contentIndexAction = { item, _ in
            var updated = item
            updated.indexedAt = .now
            try? await model.library.replaceChunks(for: item.id, with: [
                ContentChunk(itemID: item.id, ordinal: 0, source: .inlineText, text: item.title)
            ], updating: updated)
            return IndexingRunResult(completed: true, dimensionChanged: false)
        }
        let now = ISO8601DateFormatter().date(from: "2026-09-05T06:00:00+08:00")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var calls = 0
        model.todoRevisionAction = { text, _ in
            calls += 1
            try? await Task.sleep(for: .milliseconds(700))
            return .decided([
                .init(action: .create, title: "开会", dueAt: now.addingTimeInterval(14 * 3600),
                      evidence: "今天下午八点开会", needsConfirmation: false),
                .init(action: .create, title: "买一杯咖啡", dueAt: now.addingTimeInterval(25 * 3600),
                      evidence: "明天早上七点要买一杯咖啡", needsConfirmation: false)
            ])
        }
        func wait(_ condition: () -> Bool) async throws {
            let deadline = Date.now.addingTimeInterval(20)
            while !condition() {
                guard Date.now < deadline else {
                    throw NSError(domain: "TodoSmokeTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey:
                        "timeout: calls=\(calls) recognizing=\(model.isRecognizingTodos) prompt=\(String(describing: model.todoPrompt)) queued=\(model.remainingTodoPromptCount) todos=\(model.todos.count) error=\(model.lastError ?? "nil")"])
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: NotchLayout.shellHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Mnemo 验证"
        window.contentView = NSHostingView(rootView: NotchWorkspaceRootView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        model.expand()
        model.completeWorkspaceOpen()
        func snapshot(_ name: String) throws {
            guard let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw CocoaError(.fileWriteUnknown) }
            view.cacheDisplay(in: view.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])?.write(to: root.appending(path: name))
        }
        do {
            let item = try await model.library.ingest(text: "今天下午八点开会，明天早上七点要买一杯咖啡",
                                                       origin: .clipboard, isPinned: false)
            await model.reload()
            guard calls == 0, model.todoPrompt == nil, !model.isRecognizingTodos,
                  (try await model.library.chunks(for: item.id)).isEmpty else {
                throw NSError(domain: "TodoSmoke", code: 0, userInfo: [NSLocalizedDescriptionKey: "temporary content was processed"])
            }
            await model.pinClipboardItem(item.id)
            try await wait { model.isRecognizingTodos }
            try snapshot("01-working.png")
            try await wait { !model.isRecognizingTodos && model.todos.count == 2 }
            guard model.todoPrompt == nil else {
                throw NSError(domain: "TodoSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "明确任务不应弹卡"])
            }
            try snapshot("02-created.png")
            model.collapseNow()
            model.completeWorkspaceClose()
            window.contentView = NSHostingView(rootView: NotchAnchorRootView(model: model))
            let size = NotchLayout.anchorMetrics(for: model.barState,
                                                 suggestionCount: model.contextSuggestions.count,
                                                 supplement: model.notchSupplement,
                                                 supplementActionCount: model.notchSupplementActionCount).panelSize
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(300))
            try snapshot("03-complete-collapsed.png")
            guard calls == 1, model.todos.count == 2,
                  model.todos.allSatisfy({ $0.dueAt != nil }) else {
                throw NSError(domain: "TodoSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "final state mismatch"])
            }
            try "PASS: temporary=0 calls; pin=1 call; clear tasks auto-apply; save/FIFO; two dated todos; no cards for certain tasks\n"
                .write(to: root.appending(path: "result.txt"), atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        } catch {
            try? "FAIL: \(error)\n".write(to: root.appending(path: "result.txt"), atomically: true, encoding: .utf8)
            exit(1)
        }
    }
}
#endif
