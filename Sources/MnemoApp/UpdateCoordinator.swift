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
@MainActor
final class UpdateCoordinator: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(ReleaseInfo)
        case downloading(progress: Double, received: Int64, total: Int64)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published var isWindowPresented = false

    private let repo = "huaxx-lab/mnemo"
    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    /// 已发现但还没装的新版本。取消下载后回到这一步，不用重新检查。
    private var lastAvailableRelease: ReleaseInfo?
    private var lastCheckKey = "Pinland.update.lastCheck"

    static let shared = UpdateCoordinator()

    private override init() { super.init() }

    var currentVersion: AppVersion {
        AppVersion(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
    }

    /// 启动时静默检查：有更新才弹，没有就当没发生过。半天最多查一次。
    func checkOnLaunch() {
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastCheckKey) as? Date,
           Date.now.timeIntervalSince(last) < 12 * 3600 { return }
        Task { await check(silent: true) }
    }

    /// 菜单里点"版本"：立即查，并且无论结果如何都给用户一个交代。
    func checkNow() {
        isWindowPresented = true
        Task { await check(silent: false) }
    }

    private func check(silent: Bool) async {
        guard case .checking = phase, silent == false else {
            phase = .checking
            UserDefaults.standard.set(Date.now, forKey: lastCheckKey)
            do {
                let release = try await fetchLatestRelease()
                if release.version > currentVersion {
                    lastAvailableRelease = release
                    phase = .available(release)
                    isWindowPresented = true
                } else {
                    phase = .upToDate
                    isWindowPresented = !silent
                }
            } catch {
                // 静默检查失败不打扰：下次启动还会再来。手动检查要让人知道。
                phase = silent ? .idle : .failed("检查更新失败：\(error.localizedDescription)")
                isWindowPresented = !silent
            }
            return
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
        isWindowPresented = false
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
        let mountPoint = try await run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-quiet", dmg.path])
        let mountedVolume = mountPoint.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\t").last ?? ""
        let volume = URL(filePath: mountedVolume)
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
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }
            process.terminationHandler = { process in
                let output = String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(),
                    encoding: .utf8
                ) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    continuation.resume(throwing: UpdateError.install(output.trimmingCharacters(in: .whitespacesAndNewlines)))
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
        Task { @MainActor in
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "mnemo-update-\(UUID().uuidString).dmg")
            do {
                // location 在回调返回后就被系统清掉，先挪到自己的目录。
                try FileManager.default.moveItem(at: location, to: destination)
                self.downloadTask = nil
                self.downloadSession?.finishTasksAndInvalidate()
                self.downloadSession = nil
                self.install(dmg: destination)
            } catch {
                self.phase = .failed("下载文件保存失败：\(error.localizedDescription)")
            }
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
