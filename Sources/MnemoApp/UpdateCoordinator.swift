import AppKit
import Foundation
import MnemoCore
import SwiftUI

/// 自动更新。
///
/// 链路：GitHub releases/latest 拿元信息 → 比版本号 → 下 DMG（带进度）→
/// 挂载、换包、卸载 → 重启。全部无登录，公开仓库的公开接口。
///
/// 有意不用 Sparkle：它是给"有签名证书、有 appcast 服务"的应用准备的，
/// 我们是 ad-hoc 签名 + GitHub release，一条 HTTPS 加一次 ditto 就够了，
/// 引入框架只会让打包链路多一层要维护的东西。
/// 用 Observation 而不是 Combine 的 ObservableObject。
///
/// 这两套观察机制不能混：`main.swift` 里用 `withObservationTracking` 观察
/// `isWindowPresented`，而访问 `@Published` 属性**不会**注册到
/// ObservationRegistrar，`onChange` 因此永不触发——`presentUpdateWindowIfNeeded()`
/// 一次都没被调用过，窗口永远不出现。表现就是"点检查更新完全没反应"。
/// 全应用（AppModel 等）都是 `@Observable`，这里跟上。
@MainActor
@Observable
final class UpdateCoordinator: NSObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(progress: Double, received: Int64, total: Int64)
        case installing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var isWindowPresented = false

    /// 谁负责真的开关那扇窗。
    ///
    /// 这里原来靠 `withObservationTracking` 在 AppDelegate 侧监听
    /// `isWindowPresented`，但那是**一次性**的边沿触发：每次响应完都要重新
    /// 武装，而 Observation 的 `onChange` 是 willSet 语义、且**不做相等性
    /// 判断**（设成同一个值照样触发）。窗口关闭又会回头调 dismiss()，于是
    /// 一次点击能引出好几拍重入，任何一拍武装失败，之后点"检查更新"就再也
    /// 没有反应——这个 bug 在这个机制上已经复发两次了。
    /// 改成直接回调：谁改状态谁负责通知，没有边沿、没有重新武装。
    @ObservationIgnored var presentationDidChange: (() -> Void)?

    /// 所有状态变更都从这里走，保证通知不会漏。
    private func setPresented(_ value: Bool) {
        guard isWindowPresented != value else { return }
        isWindowPresented = value
        presentationDidChange?()
    }

    @ObservationIgnored private let repo = "huaxx-lab/mnemo"
    @ObservationIgnored private var downloadTask: URLSessionDownloadTask?
    @ObservationIgnored private var downloadSession: URLSession?
    /// 已发现但还没装的新版本。取消下载后回到这一步，不用重新检查。
    @ObservationIgnored private var lastAvailableRelease: ReleaseInfo?

    static let shared = UpdateCoordinator()

    private override init() { super.init() }

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }

    /// 启动时静默检查：有更新才弹，没有就当没发生过。没有节流——用户要求
    /// 每次启动都查一次，何况这次请求只是个 GitHub API，量小到无所谓。
    func checkOnLaunch() {
        Task { await check(silent: true) }
    }

    /// 菜单里点"版本"：立即查，并且无论结果如何都给用户一个交代。
    func checkNow() {
        // 窗口可能已经开着、只是被别的应用盖住了：点菜单就该把它端到前面，
        // 所以这里不看当前值，直接要求呈现一次。
        isWindowPresented = true
        presentationDidChange?()
        Task { await check(silent: false) }
    }

    private func check(silent: Bool) async {
        // 正在查的时候重复点击直接忽略，避免同一次检查发两遍请求。
        if case .checking = phase { return }
        phase = .checking
        do {
            let release = try await fetchLatestRelease()
            if release.version > currentVersion {
                lastAvailableRelease = release
                phase = .available(release)
                setPresented(true)
            } else {
                phase = .upToDate
                setPresented(!silent)
            }
        } catch {
            // 静默检查失败不打扰：下次启动还会再来。手动检查要让人知道。
            phase = silent ? .idle : .failed("检查更新失败：\(error.localizedDescription)")
            setPresented(!silent)
        }
    }

    func downloadAndInstall(_ release: ReleaseInfo) {
        guard downloadTask == nil else { return }
        phase = .downloading(progress: 0, received: 0, total: 0)
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadSession = session
        let task = session.downloadTask(with: release.assetURL)
        downloadTask = task
        task.resume()
    }

    func dismiss() {
        // 下载中的关闭不是取消：窗口可以收起，下载继续。
        setPresented(false)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        // 回到"发现新版本"那一步，用户之后还能重新下载。
        if let lastAvailableRelease {
            phase = .available(lastAvailableRelease)
        } else {
            phase = .idle
        }
    }

    // MARK: - 网络

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
            timeoutInterval: 15
        )
        // GitHub 对没有 UA 的请求直接 403。
        request.setValue("Mnemo/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.network }
        guard http.statusCode == 200 else {
            // 404 多半是"还没有任何 release"，这和"出错"是两回事。
            if http.statusCode == 404 { throw UpdateError.noReleaseYet }
            throw UpdateError.http(http.statusCode)
        }
        return try ReleaseParsing.latestRelease(from: data)
    }

    // MARK: - 安装

    private func install(dmg: URL) {
        phase = .installing
        Task {
            do {
                try await Self.installDMG(dmg)
                // 安装完成，直接重启进新版本。
                relaunch()
            } catch {
                phase = .failed("安装失败：\(error.localizedDescription)")
            }
        }
    }

    /// 挂载 → 换掉 /Applications 里的应用 → 卸载。
    ///
    /// 中间任何一步失败都不会留下半个安装：先复制到 /Applications 旁的临时
    /// 位置再原子替换，比"先删后拷"安全——拷坏了旧的还在。
    static func installDMG(_ dmg: URL) async throws {
        // `-quiet` 的意思就是"什么都不打印"，原来却要去解析它的 stdout 找挂载点，
        // 拿到的永远是空串，于是每次安装都停在"映像里没有 .app"。改用 `-plist`：
        // 输出是结构化的，卷名里有空格也不会被切错。
        let output = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-plist", dmg.path])
        guard let volume = mountPoint(fromAttachPlist: output) else {
            throw UpdateError.install("挂载映像失败")
        }
        defer {
            Task.detached {
                _ = try? await run("/usr/bin/hdiutil", ["detach", "-quiet", volume.path])
            }
        }
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: volume, includingPropertiesForKeys: nil
        )) ?? []
        guard let source = candidates.first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.install("映像里没有 .app")
        }
        let destination = URL(filePath: "/Applications/Mnemo.app")
        let staging = destination.deletingLastPathComponent()
            .appending(path: ".mnemo-update-\(UUID().uuidString).app")
        // 隔离属性跟着 DMG 来，留着它用户每次打开都要再过一次 Gatekeeper。
        _ = try? await run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", source.path])
        try FileManager.default.copyItem(at: source, to: staging)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: staging, to: destination)
        try? FileManager.default.removeItem(at: dmg)
    }

    /// 从 `hdiutil attach -plist` 的输出里取挂载点。
    ///
    /// 一张映像会列出好几个 system-entity（分区表、各分区），只有真正挂上的
    /// 那个带 mount-point。
    static func mountPoint(fromAttachPlist output: String) -> URL? {
        guard let data = output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]]
        else { return nil }
        let path = entities
            .compactMap { $0["mount-point"] as? String }
            .first { !$0.isEmpty }
        return path.map { URL(filePath: $0) }
    }

    private func relaunch() {
        let app = URL(filePath: "/Applications/Mnemo.app")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(filePath: executable)
            process.arguments = arguments
            // 两条流必须分开收。合在一个管道里的话，hdiutil 那条
            // "'hdiutil attach -nobrowse' is deprecated" 的警告会混进 stdout，
            // 拼在 XML 前面，plist 直接解析失败。
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            process.terminationHandler = { process in
                let stdout = String(
                    data: out.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                let stderr = String(
                    data: err.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: stdout)
                } else {
                    let detail = (stderr.isEmpty ? stdout : stderr)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: UpdateError.install(detail))
                }
            }
        }
    }

    enum UpdateError: LocalizedError {
        case network
        case noReleaseYet
        case http(Int)
        case install(String)

        var errorDescription: String? {
            switch self {
            case .network: "网络不可达"
            case .noReleaseYet: "还没有发布过任何版本"
            case .http(let code): "服务返回了 \(code)"
            case .install(let detail): detail.isEmpty ? "安装过程失败" : detail
            }
        }
    }
}

// MARK: - 下载进度

extension UpdateCoordinator: URLSessionDownloadDelegate {
    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        Task { @MainActor in
            let total = max(totalBytesExpectedToWrite, 1)
            phase = .downloading(
                progress: Double(totalBytesWritten) / Double(total),
                received: totalBytesWritten,
                total: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // 必须在这个方法**返回之前**同步搬走文件。
        //
        // URLSession 的契约：didFinishDownloadingTo 一返回，location 那个临时
        // 文件立刻被系统删掉。旧代码把 moveItem 包进 Task 里，方法当场返回、
        // 文件先被删，Task 再去搬就只剩
        // "couldn't be moved … the former doesn't exist"。
        let outcome = Self.persistDownloadedDMG(from: location)
        let received = downloadTask.countOfBytesReceived
        Task { @MainActor in
            self.downloadTask = nil
            self.downloadSession?.finishTasksAndInvalidate()
            self.downloadSession = nil
            switch outcome {
            case .success(let url):
                // 先把进度条补满。几 MB 的包眨眼就下完，最后一次
                // didWriteData 常常还没来得及渲染就被"正在安装"顶掉，
                // 看着就像"没跑完就开始装了"。
                self.phase = .downloading(progress: 1, received: received, total: received)
                self.install(dmg: url)
            case .failure(let error):
                self.phase = .failed("下载文件保存失败：\(error.localizedDescription)")
            }
        }
    }

    /// 存进「下载」目录，和用户在浏览器里下东西的位置一致：安装失败时他能
    /// 自己找到那个 DMG 手动装，而不是在一个随机临时目录里凭空消失。
    /// 目录不可用（极少见）才退回临时目录。
    nonisolated private static func persistDownloadedDMG(from location: URL) -> Result<URL, any Error> {
        let fileManager = FileManager.default
        let downloads = (try? fileManager.url(
            for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? fileManager.temporaryDirectory
        var destination = downloads.appending(path: "Mnemo-Update.dmg")
        // 不覆盖用户已有的同名文件。
        var index = 2
        while fileManager.fileExists(atPath: destination.path) {
            destination = downloads.appending(path: "Mnemo-Update-\(index).dmg")
            index += 1
        }
        do {
            try fileManager.moveItem(at: location, to: destination)
            return .success(destination)
        } catch {
            return .failure(error)
        }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        Task { @MainActor in
            // 用户自己取消不算失败。
            if (error as NSError).code == NSURLErrorCancelled { return }
            self.downloadTask = nil
            self.phase = .failed("下载失败：\(error.localizedDescription)")
        }
    }
}
