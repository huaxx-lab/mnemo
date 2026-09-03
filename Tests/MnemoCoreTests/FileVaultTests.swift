import Foundation
import Testing
@testable import MnemoCore

/// 每个测试独立的临时 vault 根目录。
private func makeTempRoot() throws -> URL {
    let u = URL.temporaryDirectory.appending(path: "mnemo-test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

private func writeFile(_ root: URL, name: String, bytes: Int, fill: UInt8 = 0x41) throws -> URL {
    let u = root.appending(path: name)
    try Data(repeating: fill, count: bytes).write(to: u)
    return u
}

// MARK: - 正常路径

@Test("N-08 普通文件默认走引用，源文件删除可被确认")
func n08_ordinaryFileUsesReferenceFirst() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let src = try writeFile(root, name: "paper.pdf", bytes: 1024)

    let holding = try await vault.ingest(src)
    guard case .reference(_, let size) = holding else {
        Issue.record("普通文件应默认建立引用，实际 \(holding)"); return
    }
    #expect(size == 1024)

    try FileManager.default.removeItem(at: src)
    #expect(await vault.referenceHealth(holding, originalSourcePath: src.path) == .sourceDeleted)
}

@Test("N-09 外置卷离线时引用冻结，不误判删除")
func n09_offlineVolumeFreezesReference() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let holding = Holding.reference(bookmark: Data("invalid".utf8), size: 2048)
    let sourcePath = "/Volumes/Mnemo-Offline-\(UUID().uuidString)/paper.pdf"
    #expect(await vault.referenceHealth(holding, originalSourcePath: sourcePath) == .temporarilyUnavailable)
}

@Test("N-10 同内容 Pin 三次只落一份盘，引用计数为 3")
func n10_dedupByContentHash() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let a = try writeFile(root, name: "a.txt", bytes: 900, fill: 0x5A)
    let b = try writeFile(root, name: "b.txt", bytes: 900, fill: 0x5A)  // 同内容不同名
    let c = try writeFile(root, name: "c.txt", bytes: 900, fill: 0x5A)

    let h1 = try await vault.ingest(a, preference: .copyRequired)
    let h2 = try await vault.ingest(b, preference: .copyRequired)
    let h3 = try await vault.ingest(c, preference: .copyRequired)
    #expect(h1 == h2 && h2 == h3, "同内容必须得到同一个 holding")

    guard case .copy(let hash, _) = h1 else { Issue.record("期望副本"); return }
    #expect(await vault.refCount(hash) == 3)

    let files = try FileManager.default
        .contentsOfDirectory(atPath: root.appending(path: "copies").path)
        .filter { !$0.hasPrefix(".") }
    #expect(files.count == 1, "三次 Pin 只应落一份盘，实际 \(files.count) 份")

    // 删掉两个条目，副本仍在
    await vault.release(h1)
    await vault.release(h2)
    #expect(await vault.refCount(hash) == 1)
    #expect(FileManager.default.fileExists(
        atPath: root.appending(path: "copies").appending(path: hash).path))
}

@Test("N-12 用量统计区分活跃与回收站")
func n12_usageAccounting() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let a = try writeFile(root, name: "a.bin", bytes: 1000, fill: 1)
    let b = try writeFile(root, name: "b.bin", bytes: 2000, fill: 2)

    let ha = try await vault.ingest(a, preference: .copyRequired)
    _ = try await vault.ingest(b, preference: .copyRequired)
    #expect(await vault.activeUsage() == 3000)
    #expect(await vault.trashedUsage() == 0)

    await vault.release(ha)   // 计数归零，进回收站但不删盘
    #expect(await vault.activeUsage() == 2000)
    #expect(await vault.trashedUsage() == 1000)
}

// MARK: - 边界值

@Test("B-03 体积正好等于阈值归引用侧")
func b03_thresholdExactlyEqual() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root, config: VaultConfig(copyThreshold: 1024))
    let src = try writeFile(root, name: "exact.bin", bytes: 1024)
    guard case .reference = try await vault.ingest(src, preference: .automaticBySize) else {
        Issue.record("等于阈值应走引用"); return
    }
}

@Test("B-04 体积为阈值减一字节归副本侧")
func b04_thresholdMinusOne() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root, config: VaultConfig(copyThreshold: 1024))
    let src = try writeFile(root, name: "under.bin", bytes: 1023)
    guard case .copy = try await vault.ingest(src, preference: .automaticBySize) else {
        Issue.record("小于阈值应走副本"); return
    }
}

@Test("B-09 引用计数归零不立即删盘")
func b09_zeroRefKeepsFile() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let src = try writeFile(root, name: "only.bin", bytes: 512)
    let h = try await vault.ingest(src, preference: .copyRequired)
    guard case .copy(let hash, _) = h else { Issue.record("期望副本"); return }

    await vault.release(h)
    #expect(await vault.refCount(hash) == 0)
    #expect(FileManager.default.fileExists(
        atPath: root.appending(path: "copies").appending(path: hash).path),
        "归零后仍须留盘——源文件可能已不在，这是唯一一份")

    try await vault.purge(hash)   // 回收站到期才真删
    #expect(!FileManager.default.fileExists(
        atPath: root.appending(path: "copies").appending(path: hash).path))
}

// MARK: - 失败路径

@Test("F-01 零字节文件拒绝入库")
func f01_emptyFileRejected() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let src = try writeFile(root, name: "empty.bin", bytes: 0)
    await #expect(throws: VaultError.emptyFile(src)) { try await vault.ingest(src) }

    let files = try FileManager.default
        .contentsOfDirectory(atPath: root.appending(path: "copies").path)
        .filter { !$0.hasPrefix(".") }
    #expect(files.isEmpty, "拒绝入库不应产生任何副本")
}

@Test("F-02 不可读文件拒绝入库并给出原因")
func f02_unreadableRejected() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let src = try writeFile(root, name: "locked.bin", bytes: 100)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: src.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: src.path) }

    await #expect(throws: VaultError.self) { try await vault.ingest(src) }
}

@Test("F-04 必须持有副本而空间不足时显式失败且不留残片")
func f04_copyRequiredInsufficientSpaceFails() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root, availableSpace: { _ in 10 })  // 只剩 10 字节
    let src = try writeFile(root, name: "s.bin", bytes: 800)
    await #expect(throws: VaultError.self) {
        try await vault.ingest(src, preference: .copyRequired)
    }
    let residue = try FileManager.default.contentsOfDirectory(atPath: root.appending(path: "copies").path)
    #expect(residue.isEmpty)
}

@Test("F-05 拷贝中途失败回滚，不留半份副本")
func f05_copyFailureRollsBack() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let src = try writeFile(root, name: "s.bin", bytes: 800)
    let copies = root.appending(path: "copies")

    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: copies.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copies.path) }

    await #expect(throws: VaultError.self) {
        try await vault.ingest(src, preference: .copyRequired)
    }

    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copies.path)
    let residue = try FileManager.default.contentsOfDirectory(atPath: copies.path)
    #expect(residue.filter { $0.hasPrefix(".incoming-") }.isEmpty, "临时文件必须被回滚")
}

// MARK: - 对账

@Test("F-08 磁盘有、清单无的孤儿被清除")
func f08_orphanRemoved() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let copies = root.appending(path: "copies")
    let orphan = copies.appending(path: String(repeating: "a", count: 64))
    let interrupted = copies.appending(path: ".incoming-\(UUID().uuidString)")
    try Data("孤儿".utf8).write(to: orphan)
    try Data("中断的暂存副本".utf8).write(to: interrupted)

    let report = try await vault.reconcile()
    #expect(report.orphansRemoved.count == 2)
    #expect(!FileManager.default.fileExists(atPath: orphan.path))
    #expect(!FileManager.default.fileExists(atPath: interrupted.path))
}

@Test("F-07 清单有、磁盘无的记录报告为损坏，不自动删记录")
func f07_missingCopyReported() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let src = try writeFile(root, name: "s.bin", bytes: 300)
    let h = try await vault.ingest(src, preference: .copyRequired)
    guard case .copy(let hash, _) = h else { Issue.record("期望副本"); return }

    try FileManager.default.removeItem(at: root.appending(path: "copies").appending(path: hash))
    let report = try await vault.reconcile()
    #expect(report.missingCopies == [hash])
    #expect(await vault.refCount(hash) == 1, "记录不得被自动删除")
}

@Test("F-10 清理时目标已被外部删除，视为已清理不报错")
func f10_purgeTargetAlreadyGone() async throws {
    let root = try makeTempRoot()
    let vault = try FileVault(root: root)
    let src = try writeFile(root, name: "s.bin", bytes: 300)
    let h = try await vault.ingest(src, preference: .copyRequired)
    guard case .copy(let hash, _) = h else { Issue.record("期望副本"); return }

    await vault.release(h)
    try FileManager.default.removeItem(at: root.appending(path: "copies").appending(path: hash))
    try await vault.purge(hash)   // 不应抛错
    #expect(await vault.refCount(hash) == 0)
}

// MARK: - 索引字段

@Test("AC-42 索引完整性判定")
func ac42_indexCompleteness() {
    var item = Item(title: "开票信息", kind: .text, holding: .inline("抬头…"))
    #expect(!item.isFullyIndexed)

    item.vector = [0.1, 0.2]
    item.contentHash = "abc"
    item.embeddingModelID = "qwen3.7-text-embedding"
    item.indexedAt = .now
    #expect(item.isFullyIndexed)

    item.vector = []
    #expect(!item.isFullyIndexed, "空向量不算已索引")
}


@Test("别的应用容器与临时目录里的文件必须留副本，不能存书签")
func droppedSourcesFromOtherAppsRequireACopy() {
    func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // 从微信聊天里往外拖文件，落到我们手上的就是这条路径：目录归微信所有、
    // 随时被清，而且容器受 TCC 保护，我们连字节都读不到。
    #expect(DroppedSourceTrust.requiresManagedCopy(url(
        "/Users/me/Library/Containers/com.tencent.xinWeChat/Data/Documents/temp/drag/paper.pdf"
    )))
    #expect(DroppedSourceTrust.requiresManagedCopy(url("/Users/me/Library/Caches/x/report.pdf")))
    #expect(DroppedSourceTrust.requiresManagedCopy(url("/Users/me/Library/Group Containers/g/x.pdf")))

    // 用户自己整理好的位置照旧走引用，不白占一份磁盘；临时目录也不一刀切，
    // 需要副本的调用点（剪贴板位图等）本来就显式要求 .copyRequired。
    #expect(!DroppedSourceTrust.requiresManagedCopy(url("/Users/me/Documents/论文/paper.pdf")))
    #expect(!DroppedSourceTrust.requiresManagedCopy(url("/Users/me/Downloads/paper.pdf")))
    #expect(!DroppedSourceTrust.requiresManagedCopy(url("/Volumes/Backup/paper.pdf")))
    #expect(!DroppedSourceTrust.requiresManagedCopy(url("/private/var/folders/ab/T/scratch.pdf")))
}

@Test("读得出字节才算可用：只看权限位会漏掉 TCC 拦截")
func readabilityIsCheckedByActuallyReading() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appending(path: "mnemo-readable-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let present = root.appending(path: "ok.txt")
    try Data("hi".utf8).write(to: present)
    #expect(DroppedSourceTrust.isReadable(present))
    #expect(!DroppedSourceTrust.isReadable(root.appending(path: "missing.txt")))
}


@Test("容器路径能认出文件来自哪个应用")
func sourceApplicationIsDerivedFromContainerPath() {
    #expect(DroppedSourceTrust.sourceApplicationBundleID(
        forPath: "/Users/me/Library/Containers/com.tencent.xinWeChat/Data/Documents/temp/drag/a.pdf"
    ) == "com.tencent.xinWeChat")
    // 组容器常带 team id 前缀，要去掉才是真正的 bundle id
    #expect(DroppedSourceTrust.sourceApplicationBundleID(
        forPath: "/Users/me/Library/Group Containers/ABCD1234.com.tencent.xinWeChat/x.pdf"
    ) == "com.tencent.xinWeChat")
    // 用户自己的目录没有来源应用可言
    #expect(DroppedSourceTrust.sourceApplicationBundleID(
        forPath: "/Users/me/Documents/paper.pdf"
    ) == nil)
    #expect(DroppedSourceTrust.sourceApplicationBundleID(forPath: nil) == nil)
}

@Test("读不到文件时能区分权限不足、文件消失和其他原因")
func classifiesReadFailureCause() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "mnemo-readfail-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 正常文件：读得到，没有失败原因。
    let readable = root.appending(path: "readable.txt")
    try Data("hello".utf8).write(to: readable)
    #expect(DroppedSourceTrust.readFailure(readable) == nil)
    #expect(DroppedSourceTrust.isReadable(readable))

    // 不存在：必须报"文件消失"，而不是笼统的读不到——这两种的出路不同，
    // 一个是重新拖一次，一个是去系统设置授权。
    let missing = root.appending(path: "gone.txt")
    #expect(DroppedSourceTrust.readFailure(missing) == .missing)

    // 权限不足：POSIX 权限置零，模拟 TCC/权限拦截。
    let denied = root.appending(path: "denied.txt")
    try Data("secret".utf8).write(to: denied)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: denied.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: denied.path) }
    // root 身份下权限位不拦人；只在真的被拦时断言分类正确。
    if !FileManager.default.isReadableFile(atPath: denied.path) {
        #expect(DroppedSourceTrust.readFailure(denied) == .permissionDenied)
        #expect(!DroppedSourceTrust.isReadable(denied))
    }
}
