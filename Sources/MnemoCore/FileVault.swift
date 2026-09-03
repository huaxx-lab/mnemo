import Foundation
import CryptoKit

public enum FileIngestPreference: Sendable {
    /// 普通文件默认路径：先建立安全书签，只有书签确实不可用时才落副本。
    case referenceFirst
    /// 剪贴板、临时图片等源文件马上会消失，必须持有副本。
    case copyRequired
    /// 保留给迁移与底层边界测试的旧阈值策略。
    case automaticBySize
}

/// 引用型文件的可用性。自动清理只允许响应 `sourceDeleted`，其余状态都不能
/// 破坏用户数据。
public enum ReferenceHealth: Sendable, Equatable {
    case available(URL)
    case sourceDeleted
    case temporarilyUnavailable
}

/// 存储策略配置。阈值只服务旧版本迁移与 `.automaticBySize` 边界测试；
/// 新入库默认使用 `.referenceFirst`。
public struct VaultConfig: Sendable {
    /// 旧策略中小于该值拷副本，大于等于该值存引用。默认 50MB。
    public var copyThreshold: Int64
    /// 回收站保留期，默认 30 天（F2.3）。
    public var retention: TimeInterval

    public init(copyThreshold: Int64 = 50 * 1024 * 1024,
                retention: TimeInterval = 30 * 24 * 3600) {
        self.copyThreshold = copyThreshold
        self.retention = retention
    }
}

/// 副本与引用的双路径存储。
///
/// 副本以内容 SHA-256 命名，天然去重；引用计数归零不立即删盘，
/// 拖进来的路径靠不靠得住。
///
/// 从微信聊天里往外拖一个文件，落在我们手上的是
/// `~/Library/Containers/com.tencent.xinWeChat/Data/.../temp/drag/xxx.pdf`：
/// 目录归微信所有，随时被清；而且别的应用的容器受 TCC 保护，Mnemo 根本
/// 读不到里面的字节。给这种路径存书签，等于存了一条明天就失效、今天也读不出
/// 内容的引用——条目看着好好的，却永远索引不了、复制出去也粘不出来。
public enum DroppedSourceTrust {
    /// 这些位置的文件由别的进程掌控，必须当场复制而不是引用。
    public static func requiresManagedCopy(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        // 别的应用的容器：归它管、随时清，而且受 TCC 保护读不到。
        if path.contains("/Library/Containers/") { return true }
        if path.contains("/Library/Group Containers/") { return true }
        if path.contains("/Library/Caches/") { return true }
        // 应用自己的拖拽 / 下载暂存区，名字不统一但都带这几段。
        return ["/temp/drag/", "/DropTemp/", "/.dragged/"].contains { path.contains($0) }
    }

    /// 这份文件是从哪个应用里拖出来的。
    ///
    /// 容器路径里就写着对方的 bundle id：
    /// `~/Library/Containers/com.tencent.xinWeChat/Data/...`。卡片据此打上来源
    /// 应用的图标——一眼看出"这是微信里那份"，而不是一堆同样的文档图标。
    public static func sourceApplicationBundleID(forPath path: String?) -> String? {
        guard let path else { return nil }
        for marker in ["/Library/Containers/", "/Library/Group Containers/"] {
            guard let range = path.range(of: marker) else { continue }
            let remainder = path[range.upperBound...]
            guard let id = remainder.split(separator: "/").first.map(String.init),
                  id.contains(".") else { continue }
            // 组容器常带 team id 前缀（`ABCD1234.com.tencent.xinWeChat`），去掉它。
            let parts = id.split(separator: ".")
            if parts.count > 3, parts[0].allSatisfy({ $0.isUppercase || $0.isNumber }) {
                return parts.dropFirst().joined(separator: ".")
            }
            return id
        }
        return nil
    }

    /// 读不出来的时候，到底是哪一种读不出来。
    ///
    /// 这三种的处置完全不同，混成一句"读不到"只会把用户推向错误的操作：
    /// 权限问题要去系统设置授权，文件没了只能重新拖一次，容器路径则要先另存。
    public enum ReadFailure: Sendable, Equatable {
        /// 系统不允许读：TCC 未授权，或 POSIX 权限不足。
        case permissionDenied
        /// 文件已经不在了——别的应用清掉了自己的暂存目录。
        case missing
        /// 能打开但读不出字节，或者别的说不清的失败。
        case unreadable(String)
    }

    /// 真的能读出字节吗。`isReadableFile` 只看 POSIX 权限，TCC 拦截要到
    /// 实际打开时才暴露——"复制成功却粘不出来"就是这个差别造成的。
    public static func isReadable(_ url: URL) -> Bool {
        readFailure(url) == nil
    }

    /// 探测失败原因，而不是假设。
    ///
    /// 以前这条路径只回答"能不能读"，界面上却把所有失败都说成"它在其他应用
    /// 的私有目录里，请先存到访达"。当真实原因是没给完全磁盘访问权限时，
    /// 这条建议是错的：用户照做也修不好，而真正要点的那个开关一个字没提。
    ///
    /// - Returns: 能读就是 nil。
    public static func readFailure(_ url: URL) -> ReadFailure? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // 打开成功不等于读得到：TCC 有时到实际读取才拦。
            guard (try? handle.read(upToCount: 1)) != nil else {
                return .unreadable("打开成功但读不出内容")
            }
            return nil
        } catch let error as NSError {
            return classify(error) ?? .unreadable(error.localizedDescription)
        }
    }

    /// 沿错误链找出真正的原因。
    ///
    /// Foundation 交上来的往往是一层包装：读一个 chmod 000 的文件抛的是
    /// `NSCocoaErrorDomain 513`（字面意思是"写权限不足"，对读操作是误导），
    /// 真正的 `EACCES` 埋在 `NSUnderlyingError` 里。只看最外层就会把权限问题
    /// 判成"其他原因"，然后给出一条修不好问题的建议。
    private static func classify(_ error: NSError) -> ReadFailure? {
        var current: NSError? = error
        var depth = 0
        while let error = current, depth < 4 {
            if error.domain == NSPOSIXErrorDomain {
                switch Int32(error.code) {
                case EACCES, EPERM: return .permissionDenied
                case ENOENT, ENOTDIR: return .missing
                default: break
                }
            }
            if error.domain == NSCocoaErrorDomain {
                switch error.code {
                case NSFileReadNoPermissionError, NSFileWriteNoPermissionError:
                    return .permissionDenied
                case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                    return .missing
                default: break
                }
            }
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return nil
    }
}

/// 由回收站到期后调用 `purge` 真正删除——因为源文件可能早已不在，
/// 副本很可能是世上唯一一份（design 3.3）。
public actor FileVault {
    public typealias SpaceProbe = @Sendable (URL) -> Int64?

    private let root: URL
    private let copies: URL
    private let manifestURL: URL
    private let fm = FileManager.default
    private let availableSpace: SpaceProbe

    public private(set) var config: VaultConfig
    /// hash → 引用计数
    private var refCounts: [String: Int] = [:]
    /// 归零删除失败、待下次启动重试的
    private var pendingPurges: Set<String> = []

    public init(root: URL,
                config: VaultConfig = VaultConfig(),
                availableSpace: @escaping SpaceProbe = FileVault.systemFreeSpace) throws {
        self.root = root
        self.config = config
        self.availableSpace = availableSpace
        self.copies = root.appending(path: "copies", directoryHint: .isDirectory)
        self.manifestURL = root.appending(path: "manifest.json")
        try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true)
        let m = Self.readManifest(at: manifestURL)
        self.refCounts = m.refCounts
        self.pendingPurges = Set(m.pendingPurges)
    }

    public static let systemFreeSpace: SpaceProbe = { url in
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))
            .flatMap(\.volumeAvailableCapacity).map(Int64.init)
    }

    // MARK: - 入库

    /// 把一个文件收进 vault。
    ///
    /// - 零字节直接拒绝，不建条目（F-01）
    /// - 不可读直接拒绝并给出原因（F-02）
    /// - 必须持有副本而空间不足时显式失败，不偷换为可能消失的引用（F-04）
    /// - 拷贝中途失败回滚临时文件，不留半份副本（F-05）
    public func ingest(
        _ url: URL,
        preference: FileIngestPreference = .referenceFirst
    ) throws -> Holding {
        // 拖进来的 URL 常带着系统给的沙盒扩展（从别的应用容器里拖出来的尤其
        // 如此）。不激活它，读属性和拷贝都会被拒——旧实现只建书签、从不读
        // 内容，所以这个缺口一直没暴露；一旦改成必须留副本就整条拖入都失败了。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileSizeKey, .isReadableKey])
        } catch {
            throw VaultError.unreadable(url, reason: error.localizedDescription)
        }
        guard values.isReadable == true else {
            throw VaultError.unreadable(url, reason: "无读取权限")
        }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else { throw VaultError.emptyFile(url) }

        switch preference {
        case .referenceFirst:
            do { return try makeReference(url, size: size) }
            catch {
                guard availableSpace(copies).map({ $0 >= size }) != false else {
                    throw VaultError.copyFailed(url, reason: "无法建立文件引用且副本空间不足")
                }
                return try makeCopy(url, size: size)
            }
        case .copyRequired:
            guard availableSpace(copies).map({ $0 >= size }) != false else {
                throw VaultError.copyFailed(url, reason: "副本空间不足")
            }
            return try makeCopy(url, size: size)
        case .automaticBySize:
            // 迁移兼容：等于阈值归引用侧。
            guard size < config.copyThreshold else { return try makeReference(url, size: size) }
            if let free = availableSpace(copies), free < size {
                return try makeReference(url, size: size)
            }
            return try makeCopy(url, size: size)
        }
    }

    private func makeReference(_ url: URL, size: Int64) throws -> Holding {
        do {
            // App 内应使用 .withSecurityScope；CLT 环境下无沙盒，用普通书签等价验证解析逻辑
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            return .reference(bookmark: data, size: size)
        } catch {
            throw VaultError.unreadable(url, reason: error.localizedDescription)
        }
    }

    private func makeCopy(_ url: URL, size: Int64) throws -> Holding {
        let hash: String
        do { hash = try Self.sha256(of: url) }
        catch { throw VaultError.unreadable(url, reason: error.localizedDescription) }

        let dest = copies.appending(path: hash)
        if fm.fileExists(atPath: dest.path) {
            // 已有同内容副本，只加引用计数，不重复落盘（F2.2 / N-10）
            bump(hash, by: 1)
            return .copy(hash: hash, size: size)
        }

        // 先写临时文件再原子移动；任一步失败都清掉临时文件，绝不留半份
        let tmp = copies.appending(path: ".incoming-\(UUID().uuidString)")
        do {
            try fm.copyItem(at: url, to: tmp)
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            throw VaultError.copyFailed(url, reason: error.localizedDescription)
        }
        bump(hash, by: 1)
        return .copy(hash: hash, size: size)
    }

    // MARK: - 引用计数

    /// 条目被删除时调用。计数归零也不删盘——等回收站到期。
    public func release(_ holding: Holding) {
        guard case .copy(let hash, _) = holding else { return }
        bump(hash, by: -1)
    }

    /// 条目从回收站恢复时调用。
    public func retain(_ holding: Holding) {
        guard case .copy(let hash, _) = holding else { return }
        bump(hash, by: 1)
    }

    public func refCount(_ hash: String) -> Int { refCounts[hash] ?? 0 }

    /// 解析条目实际可取用的文件位置。副本缺失与引用暂不可用都显式报错，
    /// 调用方据此显示损坏或冻结态，而不是把一张空卡片交给用户。
    public func resolve(_ holding: Holding, originalSourcePath: String? = nil) throws -> URL? {
        switch holding {
        case .inline:
            return nil
        case .copy(let hash, _):
            let url = copies.appending(path: hash)
            guard fm.fileExists(atPath: url.path) else {
                throw VaultError.unreadable(url, reason: "沙盒副本不存在")
            }
            return url
        case .reference:
            switch referenceHealth(holding, originalSourcePath: originalSourcePath) {
            case .available(let url): return url
            case .sourceDeleted: throw VaultError.staleBookmark
            case .temporarilyUnavailable: throw VaultError.referenceUnavailable
            }
        }
    }

    /// 解析引用并把「删除」与「暂时不可达」分开。书签是实际取用入口；原路径
    /// 只在书签本身无法解析时辅助判断卷是否仍然挂载。
    public func referenceHealth(
        _ holding: Holding,
        originalSourcePath: String? = nil
    ) -> ReferenceHealth {
        guard case .reference(let bookmark, _) = holding else { return .temporarilyUnavailable }
        var stale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return probeReferenceURL(url)
        } catch {
            guard let originalSourcePath else { return .temporarilyUnavailable }
            return probeReferenceURL(URL(fileURLWithPath: originalSourcePath))
        }
    }

    private func probeReferenceURL(_ url: URL) -> ReferenceHealth {
        do {
            if try url.checkResourceIsReachable() { return .available(url) }
        } catch {
            let nsError = error as NSError
            let isMissing = (nsError.domain == NSCocoaErrorDomain && [4, 260].contains(nsError.code))
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 2)
            if !isMissing { return .temporarilyUnavailable }
        }
        return Self.volumeIsUnavailable(for: url)
            ? .temporarilyUnavailable
            : .sourceDeleted
    }

    /// `/Volumes/<卷名>/…` 的卷根不存在，说明是外置卷未挂载，不能据此删 Pin。
    /// 系统卷与用户目录中的明确 ENOENT 才属于源文件删除。
    static func volumeIsUnavailable(for url: URL, fileManager: FileManager = .default) -> Bool {
        let components = url.standardizedFileURL.pathComponents
        guard components.count >= 3,
              components[0] == "/",
              components[1] == "Volumes" else { return false }
        let volumeRoot = URL(fileURLWithPath: "/Volumes", isDirectory: true)
            .appending(path: components[2], directoryHint: .isDirectory)
        return !fileManager.fileExists(atPath: volumeRoot.path)
    }

    /// 回收站到期后真正删盘。删除失败不吞异常，记入待重试集合（F-09）。
    public func purge(_ hash: String) throws {
        guard refCount(hash) <= 0 else { return }
        let f = copies.appending(path: hash)
        guard fm.fileExists(atPath: f.path) else {
            // F-10：目标已被外部删除，视为已清理，仅清记录，不中断本轮
            refCounts[hash] = nil
            pendingPurges.remove(hash)
            saveManifest()
            return
        }
        do { try fm.removeItem(at: f) }
        catch {
            pendingPurges.insert(hash)
            saveManifest()
            throw VaultError.purgeFailed(hash: hash, reason: error.localizedDescription)
        }
        refCounts[hash] = nil
        pendingPurges.remove(hash)
        saveManifest()
    }

    // MARK: - 对账

    /// 启动时的双向一致性扫描（F2.5）。
    ///
    /// 磁盘有、清单无 → 孤儿，清除；清单有、磁盘无 → 报告给上层转损坏态，
    /// 不自动删记录（元数据比文件值钱）。
    @discardableResult
    public func reconcile() throws -> ReconcileReport {
        var report = ReconcileReport()

        for hash in pendingPurges.sorted() where refCount(hash) <= 0 {
            if (try? purge(hash)) != nil { report.retriedPurges.append(hash) }
        }

        let entries = (try? fm.contentsOfDirectory(atPath: copies.path)) ?? []
        for staging in entries.filter({ $0.hasPrefix(".incoming-") }).sorted() {
            try? fm.removeItem(at: copies.appending(path: staging))
            report.orphansRemoved.append(staging)
        }
        let onDisk = Set(entries.filter { !$0.hasPrefix(".") })
        let known = Set(refCounts.keys)

        for orphan in onDisk.subtracting(known).sorted() {
            try? fm.removeItem(at: copies.appending(path: orphan))
            report.orphansRemoved.append(orphan)
        }
        report.missingCopies = known.subtracting(onDisk).sorted()
        return report
    }

    // MARK: - 用量

    /// 活跃副本占用（F2.6）。以清单为准而非扫盘，避免大库卡顿。
    public func activeUsage() -> Int64 {
        refCounts.reduce(into: Int64(0)) { total, entry in
            guard entry.value > 0 else { return }
            let f = copies.appending(path: entry.key)
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        }
    }

    /// 计数已归零、仍占盘的部分（回收站占用）。
    public func trashedUsage() -> Int64 {
        refCounts.reduce(into: Int64(0)) { total, entry in
            guard entry.value <= 0 else { return }
            let f = copies.appending(path: entry.key)
            total += (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { Int64($0) } ?? 0
        }
    }

    // MARK: - 内部

    private func bump(_ hash: String, by delta: Int) {
        refCounts[hash, default: 0] += delta
        saveManifest()
    }

    private struct Manifest: Codable {
        var refCounts: [String: Int]
        var pendingPurges: [String]
    }

    /// 静态读取：actor 的 init 不能同步调用隔离方法。
    private static func readManifest(at url: URL) -> Manifest {
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return Manifest(refCounts: [:], pendingPurges: []) }
        return m
    }

    private func saveManifest() {
        let m = Manifest(refCounts: refCounts, pendingPurges: pendingPurges.sorted())
        try? JSONEncoder().encode(m).write(to: manifestURL, options: .atomic)
    }

    /// 分块读取，避免大文件一次性载入内存。
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
