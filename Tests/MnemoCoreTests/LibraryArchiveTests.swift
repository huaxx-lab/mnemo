import Foundation
import Testing
@testable import MnemoCore

@Test("整库归档在新环境恢复副本、元数据、待办与专注记录")
func libraryArchiveRoundTrip() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "mnemo-archive-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let sourceURL = root.appending(path: "paper.txt")
    try Data("paper body".utf8).write(to: sourceURL)
    let source = Library(
        store: InMemoryItemStore(),
        vault: try FileVault(root: root.appending(path: "source-vault"))
    )
    var copied = try await source.ingest(fileAt: sourceURL, preference: .copyRequired)
    copied.tags = ["论文", "检索"]
    copied.group = "研究"
    copied.vector = [0.1, 0.2]
    try await source.update(copied)
    _ = try await source.ingest(text: "https://example.com")
    _ = try await source.addTodo(title: "阅读论文")
    try await source.recordFocusSession(FocusSession(
        startedAt: Date(timeIntervalSince1970: 100),
        completedAt: Date(timeIntervalSince1970: 1_600),
        plannedDuration: 1_500
    ))

    let archiveURL = root.appending(path: "backup.pinlandarchive", directoryHint: .isDirectory)
    let manager = LibraryArchiveManager()
    try await manager.export(library: source, to: archiveURL, appVersion: "test")

    let destination = Library(
        store: InMemoryItemStore(),
        vault: try FileVault(root: root.appending(path: "destination-vault"))
    )
    let importedChanges = ChangeRecorderForArchive()
    await destination.setChangeObserver { change in await importedChanges.append(change) }
    let result = try await manager.import(library: destination, from: archiveURL)
    let restored = try await destination.items()

    #expect(result.importedItemIDs.count == 2)
    #expect(restored.count == 2)
    let restoredPaper = restored.first { $0.title == copied.title }
    #expect(restoredPaper?.tags == ["论文", "检索"])
    #expect(restoredPaper?.group == "研究")
    #expect(restoredPaper?.vector == nil)
    let restoredURL: URL?
    if let restoredPaper {
        restoredURL = try await destination.resolvedFileURL(for: restoredPaper)
    } else {
        restoredURL = nil
    }
    #expect(restoredURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } == "paper body")
    #expect(try await destination.todos().count == 1)
    #expect(try await destination.focusSessions().count == 1)
    #expect(await importedChanges.snapshot().count == 3, "两个 Pin 与一个待办都应进入同步队列")
}

private actor ChangeRecorderForArchive {
    private var values: [LibraryChange] = []
    func append(_ value: LibraryChange) { values.append(value) }
    func snapshot() -> [LibraryChange] { values }
}

@Test("归档副本校验失败时不写入目标库")
func libraryArchiveRejectsCorruptAssetBeforeImport() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "mnemo-archive-corrupt-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "asset.txt")
    try Data("original".utf8).write(to: file)
    let source = Library(
        store: InMemoryItemStore(),
        vault: try FileVault(root: root.appending(path: "source-vault"))
    )
    let item = try await source.ingest(fileAt: file, preference: .copyRequired)
    let archive = root.appending(path: "backup.pinlandarchive", directoryHint: .isDirectory)
    let manager = LibraryArchiveManager()
    try await manager.export(library: source, to: archive, appVersion: "test")
    guard case .copy(let hash, _) = item.holding else {
        Issue.record("期望受管副本")
        return
    }
    try Data("tampered".utf8).write(to: archive.appending(path: "assets/\(hash)"))

    let destination = Library(
        store: InMemoryItemStore(),
        vault: try FileVault(root: root.appending(path: "destination-vault"))
    )
    await #expect(throws: LibraryArchiveError.self) {
        try await manager.import(library: destination, from: archive)
    }
    #expect(try await destination.items().isEmpty)
}
