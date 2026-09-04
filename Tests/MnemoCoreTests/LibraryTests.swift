import Foundation
import Testing
@testable import MnemoCore

private func makeLibrary(retention: TimeInterval = 30 * 24 * 3600)
    throws -> (Library, FileVault, URL) {
    let root = URL.temporaryDirectory.appending(path: "mnemo-lib-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cfg = VaultConfig(copyThreshold: 50 * 1024 * 1024, retention: retention)
    let vault = try FileVault(root: root, config: cfg)
    return (Library(store: InMemoryItemStore(), vault: vault, config: cfg), vault, root)
}

private func writeFile(_ root: URL, _ name: String, bytes: Int, fill: UInt8 = 7) throws -> URL {
    let u = root.appending(path: name)
    try Data(repeating: fill, count: bytes).write(to: u)
    return u
}

@Test("N-11 回收站恢复后向量原样保留，不触发重算")
func n11_restoreKeepsVector() async throws {
    let (lib, _, root) = try makeLibrary()
    var item = try await lib.ingest(fileAt: writeFile(root, "a.bin", bytes: 400))

    // 模拟已完成索引
    let indexedAt = Date(timeIntervalSince1970: 1_700_000_000)
    item.vector = [0.1, 0.2, 0.3]
    item.contentHash = "hash-a"
    item.embeddingModelID = "qwen3.7-text-embedding"
    item.indexedAt = indexedAt
    try await lib.update(item)
    let chunk = ContentChunk(
        itemID: item.id,
        ordinal: 0,
        source: .inlineText,
        text: "冻结的索引分块",
        vector: [0.1, 0.2, 0.3],
        embeddingModelID: "qwen3.7-text-embedding",
        indexedAt: indexedAt
    )
    try await lib.replaceChunks(for: item.id, with: [chunk])

    try await lib.trash(id: item.id)
    #expect(try await lib.items().isEmpty, "回收站条目不出现在正常列表中")
    #expect(try await lib.chunks(for: item.id).count == 1, "回收站阶段只冻结索引，不提前清除")

    try await lib.restore(id: item.id)
    let back = try #require(try await lib.items().first)
    #expect(back.indexedAt == indexedAt, "恢复不得改动 indexedAt")
    #expect(back.vector == [0.1, 0.2, 0.3], "向量必须原样保留")
    #expect(try await lib.chunks(for: item.id).first?.vector == [0.1, 0.2, 0.3])
    #expect(back.state == .active)
}

@Test("B-05 保留期第 30 天仍可恢复，第 31 天已清除并删盘")
func b05_retentionBoundary() async throws {
    let day: TimeInterval = 24 * 3600
    let (lib, vault, root) = try makeLibrary(retention: 30 * day)
    let item = try await lib.ingest(
        fileAt: writeFile(root, "b.bin", bytes: 400, fill: 9),
        preference: .copyRequired
    )
    guard case .copy(let hash, _) = item.holding else { Issue.record("期望副本"); return }

    let trashedAt = Date()
    try await lib.trash(id: item.id, now: trashedAt)

    // 第 30 天：未到期
    let d30 = trashedAt.addingTimeInterval(30 * day - 1)
    var r = try await lib.purgeExpired(now: d30)
    #expect(r.purged == 0)
    try await lib.restore(id: item.id)
    #expect(try await lib.items().count == 1, "第 30 天仍应可恢复")

    // 再次删除，推进到第 31 天
    try await lib.trash(id: item.id, now: trashedAt)
    let d31 = trashedAt.addingTimeInterval(30 * day + 1)
    r = try await lib.purgeExpired(now: d31)
    #expect(r.purged == 1)
    #expect(r.failures.isEmpty)
    #expect(!FileManager.default.fileExists(
        atPath: root.appending(path: "copies").appending(path: hash).path),
        "到期后必须真正删盘")
    _ = vault
}

@Test("B-06 编辑器原样关闭不判脏；内容真变了才标脏")
func b06_editDirtiesOnlyOnRealChange() async throws {
    let (lib, _, _) = try makeLibrary()
    var item = try await lib.ingest(text: "公司抬头：某某科技")
    item.contentHash = "hash-original"
    item.vector = [0.2, 0.8]
    item.embeddingModelID = "embedding-v1"
    item.indexedAt = Date(timeIntervalSince1970: 1_700_000_000)
    item.titledLocally = false
    item.group = "工作"
    item.tags = ["公司"]
    try await lib.update(item)

    let unchanged = try await lib.edit(id: item.id, newText: "公司抬头：某某科技")
    #expect(unchanged == false, "内容未变不应判脏")
    #expect(try await lib.items().first?.contentHash == "hash-original")

    let changed = try await lib.edit(id: item.id, newText: "公司抬头：某某科技有限公司")
    #expect(changed == true)
    let edited = try #require(try await lib.items().first)
    #expect(edited.contentHash == nil, "内容变了必须标脏")
    #expect(edited.vector == [0.2, 0.8], "新索引完成前保留旧向量供降级召回")
    #expect(edited.embeddingModelID == "embedding-v1")
    #expect(edited.indexedAt != nil)
    #expect(edited.titledLocally, "编辑后的内容版本必须重新进行 AI 整理")
    #expect(edited.group == nil && edited.tags.isEmpty, "旧内容的分类不能污染新内容")
}

@Test("相同文件重复收纳复用原 Pin，副本引用计数不重复增加")
func libraryDeduplicatesSameFile() async throws {
    let (lib, vault, root) = try makeLibrary()
    let src = try writeFile(root, "shared.bin", bytes: 600, fill: 3)
    let a = try await lib.ingest(fileAt: src, preference: .copyRequired)
    let b = try await lib.ingest(fileAt: src, preference: .copyRequired)
    guard case .copy(let hash, _) = a.holding else { Issue.record("期望副本"); return }
    #expect(a.id == b.id)
    #expect(try await lib.items().count == 1)
    #expect(await vault.refCount(hash) == 1)

    try await lib.trash(id: a.id)
    #expect(await vault.refCount(hash) == 0)
    #expect(FileManager.default.fileExists(
        atPath: root.appending(path: "copies").appending(path: hash).path),
        "归零仍不删盘，等到期")
}

@Test("同一内容重新拖入时恢复回收站中的原 Pin")
func libraryRestoresDuplicateFromTrash() async throws {
    let (lib, vault, root) = try makeLibrary()
    let src = try writeFile(root, "restore-me.bin", bytes: 600, fill: 4)
    var original = try await lib.ingest(fileAt: src, preference: .copyRequired)
    guard case .copy(let hash, _) = original.holding else {
        Issue.record("期望副本"); return
    }
    let indexedAt = Date(timeIntervalSince1970: 1_710_000_000)
    original.vector = [0.4, 0.6]
    original.contentHash = "restore-hash"
    original.embeddingModelID = "embedding-v1"
    original.indexedAt = indexedAt
    original.titledLocally = false
    try await lib.update(original)
    try await lib.replaceChunks(for: original.id, with: [ContentChunk(
        itemID: original.id,
        ordinal: 0,
        source: .inlineText,
        text: "已经索引",
        vector: [0.4, 0.6],
        embeddingModelID: "embedding-v1",
        indexedAt: indexedAt
    )])
    try await lib.trash(id: original.id)

    let restored = try await lib.ingest(fileAt: src, preference: .copyRequired)
    #expect(restored.id == original.id)
    #expect(restored.state == .active)
    #expect(restored.vector == [0.4, 0.6], "重复拖入恢复时不得抹掉或重算向量")
    #expect(restored.titledLocally == false, "恢复不能再次触发 AI 命名")
    #expect(try await lib.chunks(for: original.id).count == 1)
    #expect(try await lib.items().count == 1)
    #expect(await vault.refCount(hash) == 1)
}

@Test("相同文字与链接重复收纳不会创建副本")
func libraryDeduplicatesInlineContent() async throws {
    let (lib, _, _) = try makeLibrary()
    let first = try await lib.ingest(text: "  https://example.com/docs  ")
    let second = try await lib.ingest(text: "https://example.com/docs")
    #expect(second.id == first.id)
    #expect(try await lib.items().count == 1)
}

@Test("删除引用型 Pin 只移入回收站，绝不删除原文件")
func trashingReferenceKeepsOriginalFile() async throws {
    let root = URL.temporaryDirectory.appending(path: "mnemo-reference-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cfg = VaultConfig(copyThreshold: 1, retention: 30 * 24 * 3600)
    let vault = try FileVault(root: root.appending(path: "vault"), config: cfg)
    let library = Library(store: InMemoryItemStore(), vault: vault, config: cfg)
    let source = try writeFile(root, "source.txt", bytes: 32, fill: 5)
    let item = try await library.ingest(fileAt: source)
    guard case .reference = item.holding else { Issue.record("期望文件引用"); return }

    try await library.trash(id: item.id)
    #expect(FileManager.default.fileExists(atPath: source.path))
    #expect(try await library.items().isEmpty)
    #expect(try await library.items(includingTrashed: true).count == 1)
}

@Test("手动清空回收站删除受管副本但保留引用原文件")
func emptyTrashNeverDeletesReferencedOriginal() async throws {
    let (library, _, root) = try makeLibrary()
    let copiedSource = try writeFile(root, "copy.bin", bytes: 600, fill: 5)
    let referencedSource = try writeFile(root, "reference.bin", bytes: 600, fill: 6)
    let copy = try await library.ingest(fileAt: copiedSource, preference: .copyRequired)
    let reference = try await library.ingest(fileAt: referencedSource, preference: .referenceFirst)
    try await library.trash(id: copy.id)
    try await library.trash(id: reference.id)

    let result = try await library.emptyTrash()
    #expect(result.purged == 2)
    #expect(result.failures.isEmpty)
    #expect(FileManager.default.fileExists(atPath: referencedSource.path))
    #expect(try await library.items(includingTrashed: true).isEmpty)
}

@Test("普通文件默认建立引用，临时来源显式要求副本")
func libraryUsesReferenceFirstPolicy() async throws {
    let (lib, _, root) = try makeLibrary()
    let source = try writeFile(root, "ordinary.txt", bytes: 128, fill: 6)
    let referenced = try await lib.ingest(fileAt: source)
    guard case .reference = referenced.holding else {
        Issue.record("普通文件应优先引用"); return
    }

    let temporary = try writeFile(root, "temporary.txt", bytes: 129, fill: 7)
    let copied = try await lib.ingest(fileAt: temporary, preference: .copyRequired)
    guard case .copy = copied.holding else {
        Issue.record("临时来源必须持有副本"); return
    }
}

@Test("引用源文件删除后自动从主库移除")
func missingReferenceIsAutomaticallyTrashed() async throws {
    let (lib, _, root) = try makeLibrary()
    let source = try writeFile(root, "will-disappear.txt", bytes: 96, fill: 8)
    let item = try await lib.ingest(fileAt: source)
    guard case .reference = item.holding else { Issue.record("期望引用"); return }

    try FileManager.default.removeItem(at: source)
    let removed = try await lib.trashMissingReferences()
    #expect(removed.map(\.id) == [item.id])
    #expect(try await lib.items().isEmpty)
    #expect(try await lib.items(includingTrashed: true).first?.state == .trashed)
}

@Test("外置卷未挂载时保留引用 Pin，不误判为源文件删除")
func unavailableExternalVolumeIsNotAutomaticallyTrashed() async throws {
    let root = URL.temporaryDirectory.appending(path: "mnemo-offline-volume-\(UUID().uuidString)")
    let store = InMemoryItemStore()
    let vault = try FileVault(root: root)
    let lib = Library(store: store, vault: vault)
    let offlineVolumePath = "/Volumes/Mnemo-Definitely-Offline-\(UUID().uuidString)/paper.pdf"
    let item = Item(
        title: "离线论文",
        kind: .pdf,
        holding: .reference(bookmark: Data("invalid-bookmark".utf8), size: 1024),
        originalFilename: "paper.pdf",
        originalSourcePath: offlineVolumePath
    )
    try await store.insert(item)

    let removed = try await lib.trashMissingReferences()
    #expect(removed.isEmpty)
    #expect(try await lib.items().first?.id == item.id)
}

@Test("引用文档内容版本变化时标脏重建，离线与删除状态保持独立")
func changedReferenceInvalidatesAIStateWithoutTrashing() async throws {
    let root = URL.temporaryDirectory.appending(path: "mnemo-reference-change-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = InMemoryItemStore()
    let vault = try FileVault(root: root.appending(path: "vault"))
    let lib = Library(store: store, vault: vault)
    let source = root.appending(path: "paper.txt")
    try Data("第一版论文".utf8).write(to: source)
    var item = try await lib.ingest(fileAt: source)
    item.vector = [0.3, 0.7]
    item.contentHash = "old"
    item.embeddingModelID = "embedding-v1"
    item.indexedAt = .now
    item.titledLocally = false
    item.group = "论文"
    item.tags = ["旧版"]
    try await lib.update(item)

    try await Task.sleep(for: .milliseconds(20))
    try Data("第二版论文，内容更长".utf8).write(to: source, options: .atomic)
    let audit = try await lib.auditReferences()
    #expect(audit.removed.isEmpty)
    #expect(audit.contentChanged.map(\.id) == [item.id])
    let changed = try #require(try await lib.items().first)
    #expect(changed.state == .active)
    #expect(changed.titledLocally)
    #expect(changed.contentHash == nil)
    #expect(changed.vector == [0.3, 0.7], "外部编辑后应保留旧向量直到重建完成")
    #expect(changed.embeddingModelID == "embedding-v1" && changed.indexedAt != nil)
    #expect(changed.group == nil && changed.tags.isEmpty)
}

@Test("剪贴板历史默认滚动保留 5 条，固定项不参与淘汰")
func clipboardHistoryEvictsOnlyTransientItems() async throws {
    let (lib, _, _) = try makeLibrary()
    let promoted = try await lib.ingest(text: "keep-me", origin: .clipboard, isPinned: false)
    try await lib.pinClipboardItem(id: promoted.id)
    for index in 0..<6 {
        _ = try await lib.ingest(text: "clipboard-\(index)", origin: .clipboard, isPinned: false)
    }

    let evicted = try await lib.trimClipboardHistory(limit: 5)
    #expect(evicted.count == 1)
    let active = try await lib.items()
    #expect(active.filter { $0.origin == .clipboard && !$0.isPinned }.count == 5)
    #expect(active.contains { $0.id == promoted.id && $0.isPinned })

    // 锁定必须可逆：取消之后立刻重新参与淘汰。只做单向的话图钉会消失，
    // 用户再没有入口把它放回滚动轨道，只能删掉重来。
    try await lib.setClipboardPin(id: promoted.id, isPinned: false)
    #expect(try await lib.item(id: promoted.id)?.isPinned == false)
    let afterUnpin = try await lib.trimClipboardHistory(limit: 5)
    #expect(afterUnpin.contains { $0.id == promoted.id }, "取消锁定后最旧的一条应被淘汰")
}


@Test("待办可关联 Pin 或独立存在，关联 Pin 删除后降级为纯文字")
func todosRemainIndependentFromItemLifecycle() async throws {
    let (lib, _, root) = try makeLibrary()
    let pdf = try await lib.ingest(fileAt: writeFile(root, "paper.pdf", bytes: 512))
    try await lib.setTodo(for: pdf.id, enabled: true)
    var linked = try #require(try await lib.todos().first)
    #expect(linked.linkedItemID == pdf.id)
    linked.isCompleted = true
    try await lib.updateTodo(linked)
    #expect(try await lib.items().contains { $0.id == pdf.id }, "完成待办不得删除收纳条目")

    let standalone = try await lib.addTodo(title: "整理桌面")
    #expect(standalone.linkedItemID == nil)
    try await lib.trash(id: pdf.id)
    let todos = try await lib.todos()
    #expect(todos.count == 2)
    let detached = try #require(todos.first { $0.id == linked.id })
    #expect(detached.linkedItemID == nil)
    #expect(detached.title == pdf.title)
    #expect(detached.isCompleted)
}

@Test("分块索引按 Pin 原子替换，最终清除条目时级联删除")
func contentChunksReplaceAndPurgeWithItem() async throws {
    let day: TimeInterval = 24 * 3600
    let (lib, _, _) = try makeLibrary(retention: day)
    let item = try await lib.ingest(text: "论文正文")
    let first = ContentChunk(
        itemID: item.id,
        ordinal: 0,
        pageNumber: 1,
        source: .pdfPage,
        text: "第一页"
    )
    try await lib.replaceChunks(for: item.id, with: [first])
    #expect(try await lib.chunks(for: item.id).map(\.text) == ["第一页"])

    let replacement = ContentChunk(
        itemID: item.id,
        ordinal: 0,
        pageNumber: 2,
        source: .pdfPage,
        text: "第二页新版"
    )
    try await lib.replaceChunks(for: item.id, with: [replacement])
    #expect(try await lib.chunks(for: item.id).map(\.text) == ["第二页新版"])

    let deletedAt = Date.now
    try await lib.trash(id: item.id, now: deletedAt)
    _ = try await lib.purgeExpired(now: deletedAt.addingTimeInterval(day + 1))
    #expect(try await lib.chunks(for: item.id).isEmpty)
}

@Test("文件入库保留原文件名与内容类型，链接按 URL 入库")
func itemPresentationMetadata() async throws {
    let (lib, _, root) = try makeLibrary()
    let imageURL = try writeFile(root, "cover.png", bytes: 128)
    let image = try await lib.ingest(fileAt: imageURL)
    #expect(image.originalFilename == "cover.png")
    #expect(image.kind == .image)
    #expect(image.contentTypeIdentifier != nil)

    let link = try await lib.ingest(text: "https://example.com/docs")
    #expect(link.kind == .link)
    #expect(link.title == "example.com")
}

@Test("Mac 与手机剪贴板各自保留 5 条，互不挤占")
func clipboardTracksHaveIndependentCapacity() async throws {
    let (lib, _, _) = try makeLibrary()
    var phoneIDs: Set<UUID> = []
    for index in 0..<7 {
        let item = try await lib.ingest(
            text: "phone-clipboard-\(index)",
            origin: .clipboard,
            isPinned: false
        )
        phoneIDs.insert(item.id)
    }
    for index in 0..<6 {
        _ = try await lib.ingest(
            text: "mac-clipboard-\(index)",
            origin: .clipboard,
            isPinned: false
        )
    }

    let evicted = try await lib.trimClipboardHistory(limit: 5, independentIDs: phoneIDs)
    #expect(evicted.count == 3)
    let active = try await lib.items().filter { $0.origin == .clipboard && !$0.isPinned }
    #expect(active.filter { phoneIDs.contains($0.id) }.count == 5)
    #expect(active.filter { !phoneIDs.contains($0.id) }.count == 5)
}

@Test("独立轨道中的固定项不占容量")
func pinnedPhoneItemDoesNotConsumeTrackCapacity() async throws {
    let (lib, _, _) = try makeLibrary()
    var phoneIDs: Set<UUID> = []
    for index in 0..<6 {
        let item = try await lib.ingest(
            text: "phone-pin-\(index)",
            origin: .clipboard,
            isPinned: false
        )
        phoneIDs.insert(item.id)
        if index == 0 { try await lib.pinClipboardItem(id: item.id) }
    }

    let evicted = try await lib.trimClipboardHistory(limit: 5, independentIDs: phoneIDs)
    #expect(evicted.isEmpty)
    let active = try await lib.items()
    #expect(active.filter { phoneIDs.contains($0.id) && !$0.isPinned }.count == 5)
    #expect(active.contains { phoneIDs.contains($0.id) && $0.isPinned })
}

@Test("拖入与主动收纳的内容默认就是固定的，不需要用户再确认一次")
func manualIngestIsPinnedByDefault() async throws {
    let (lib, _, root) = try makeLibrary()
    let file = root.appending(path: "dragged.png")
    try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)

    // 拖进刘海 / ⌘P 主动收纳走的是同一条 ingest，默认 origin=.manual、isPinned=true。
    // 待办识别据此判断"用户已经表达了要留下它"，所以这两条来路必须自动识别。
    let dragged = try await lib.ingest(fileAt: file, preference: .copyRequired)
    #expect(dragged.isPinned)
    #expect(dragged.origin == .manual)

    // 剪贴板被动捕获则相反：不固定，等用户明确固定后才处理。
    let captured = try await lib.ingest(
        text: "随手复制的一段文字",
        origin: .clipboard,
        isPinned: false
    )
    #expect(!captured.isPinned)
    #expect(captured.origin == .clipboard)
}

@Test("彻底清除一条会连检索分块一起清掉")
func purgeRemovesItemAndChunks() async throws {
    let (lib, _, _) = try makeLibrary()
    let item = try await lib.ingest(text: "一段会被建索引的内容")
    try await lib.replaceChunks(for: item.id, with: [
        ContentChunk(itemID: item.id, ordinal: 0, source: .inlineText, text: "分块一"),
        ContentChunk(itemID: item.id, ordinal: 1, source: .inlineText, text: "分块二"),
    ])
    #expect(try await lib.chunks(for: item.id).count == 2)

    #expect(try await lib.purge(id: item.id))
    #expect(try await lib.item(id: item.id) == nil)
    // RAG 分块必须跟着消失，否则检索还会召回一条已经不存在的东西。
    #expect(try await lib.chunks(for: item.id).isEmpty)
}

@Test("清除一条已经不在库里的记录不算失败")
func purgingMissingItemIsNotAnError() async throws {
    let (lib, _, _) = try makeLibrary()
    // "之前已经清空过了"是一种正常状态，调用方不该为它写 catch。
    #expect(try await lib.purge(id: UUID()) == false)
}

@Test("彻底清除也适用于回收站里的条目")
func purgeWorksOnTrashedItem() async throws {
    let (lib, _, _) = try makeLibrary()
    let item = try await lib.ingest(text: "先进回收站，再被彻底清掉")
    try await lib.replaceChunks(for: item.id, with: [
        ContentChunk(itemID: item.id, ordinal: 0, source: .inlineText, text: "分块"),
    ])
    try await lib.trash(id: item.id)
    #expect(try await lib.items(includingTrashed: true).contains { $0.id == item.id })

    #expect(try await lib.purge(id: item.id))
    #expect(try await lib.items(includingTrashed: true).isEmpty)
    #expect(try await lib.chunks(for: item.id).isEmpty)
}

@Test("副本型 Pin 也记住原文件的修改时间，检索才分得出新旧两版")
func copyHoldingKeepsSourceModificationDate() async throws {
    let (lib, _, root) = try makeLibrary()
    let url = try writeFile(root, "tii-paper-v1.pdf", bytes: 400)
    // 一篇三月定稿、今天才收进来的论文。
    let authored = Date(timeIntervalSince1970: 1_773_000_000)
    try FileManager.default.setAttributes([.modificationDate: authored], ofItemAtPath: url.path)

    let copied = try await lib.ingest(fileAt: url, preference: .copyRequired)
    guard case .copy = copied.holding else {
        Issue.record("这条用例要的是副本型持有")
        return
    }
    #expect(copied.sourceModificationDate == authored)
    // 内容时间取文件自己的，而不是入库那一刻。
    #expect(ItemTemporalFacts(item: copied).contentDate == authored)
    #expect(ItemTemporalFacts(item: copied).contentDateIsFromSource)
    // sourceFileSize 仍然只属于引用型：它是健康检查的基线，不是时间信息。
    #expect(copied.sourceFileSize == nil)
}

@Test("隐私空间是冻结索引，不是删除：移出来立刻能搜到，不用重跑一遍")
func privateItemFreezesRatherThanLosesItsIndex() async throws {
    let (lib, _, root) = try makeLibrary()
    var item = try await lib.ingest(fileAt: writeFile(root, "secret.txt", bytes: 300))
    item.vector = [0.1, 0.2]
    item.contentHash = "hash"
    item.indexedAt = Date(timeIntervalSince1970: 1_700_000_000)
    try await lib.update(item)
    try await lib.replaceChunks(for: item.id, with: [
        ContentChunk(itemID: item.id, ordinal: 0, source: .fileText, text: "银行卡密码是 1234"),
    ])

    try await lib.setPrivate(id: item.id, isPrivate: true)

    // 分块和向量原样保留：这个方案只隐藏不加密，库里正文本来就是明文，
    // 删分块换不来一分保护，却要让移出来的人重跑 OCR 和 Embedding。
    // 真正的闸门在条目那一层——隐私条目不进 aiEligibleItems，检索链路按
    // 条目 ID 取分块，条目被摘掉分块就永远加载不到。
    #expect(try await lib.chunks(for: item.id).count == 1)
    let hidden = try #require(try await lib.item(id: item.id))
    #expect(hidden.isPrivate)
    #expect(hidden.vector == [0.1, 0.2], "冻结不该动向量")
    #expect(hidden.indexedAt != nil, "冻结不该把索引标脏")

    try await lib.setPrivate(id: item.id, isPrivate: false)
    let restored = try #require(try await lib.item(id: item.id))
    #expect(!restored.isPrivate)
    #expect(restored.indexedAt != nil, "移出来应当立刻可检索，不需要重建")
}

@Test("进了隐私空间就不再占临时轨道的额度，移出来也不变回临时")
func privateItemLeavesTheTemporaryLane() async throws {
    let (lib, _, root) = try makeLibrary()
    let item = try await lib.ingest(
        fileAt: writeFile(root, "temp.txt", bytes: 120),
        origin: .clipboard,
        isPinned: false
    )
    #expect(item.isPinned == false)

    try await lib.setPrivate(id: item.id, isPrivate: true)
    let hidden = try #require(try await lib.item(id: item.id))
    // 淘汰只数 origin == .clipboard && !isPinned，置上 isPinned 就自动退出，
    // 占的名额当场还回去。
    #expect(hidden.isPinned)

    try await lib.setPrivate(id: item.id, isPrivate: false)
    let restored = try #require(try await lib.item(id: item.id))
    #expect(restored.isPinned, "移出来之后也不该再变回随时会被冲掉的临时项")
    #expect(!restored.isPrivate)
}

// MARK: - 人工标题与标签

@Test("人工改的标题不再被自动命名覆盖，标签去重限量")
func userAnnotationPinsTheTitleAndCleansTags() async throws {
    let (library, _, _) = try makeLibrary()
    let item = try await library.ingest(text: "sk-alibaba-cloud-secret-key-value")

    try await library.setUserAnnotation(
        id: item.id,
        title: "  阿里云访问密钥  ",
        tags: ["密钥", " 密钥 ", "阿里云", "", "生产环境"]
    )

    let saved = try #require(try await library.item(id: item.id))
    #expect(saved.title == "阿里云访问密钥")
    // titledLocally=false 的含义就是"这个名字定下来了"，自动命名据此跳过它。
    #expect(saved.titledLocally == false)
    // 去空白、按大小写去重、丢掉空串，顺序保持用户输入的顺序。
    #expect(saved.tags == ["密钥", "阿里云", "生产环境"])
    // 内容版本作废，索引队列会把它捡回去重建——用户写的这句话要进向量库。
    #expect(saved.contentHash == nil)
}

@Test("没有实际变化时不写库，也不作废索引")
func userAnnotationIsANoOpWhenNothingChanged() async throws {
    let (library, _, _) = try makeLibrary()
    let item = try await library.ingest(text: "一段普通文字")
    try await library.setUserAnnotation(id: item.id, title: "命名过的标题", tags: ["甲"])
    var saved = try #require(try await library.item(id: item.id))
    saved.contentHash = "已经建好索引了"
    try await library.update(saved)

    try await library.setUserAnnotation(id: item.id, title: "命名过的标题", tags: ["甲"])
    let after = try #require(try await library.item(id: item.id))
    #expect(after.contentHash == "已经建好索引了", "无变化却作废了索引")
}

@Test("标题和标签会拼成一段可检索的自然语言")
func userAnnotationBecomesRetrievableText() {
    let text = UserAnnotationText.build(
        title: "阿里云访问密钥",
        tags: ["密钥", "生产环境"],
        group: "凭据"
    )
    let value = try! #require(text)
    #expect(value.contains("阿里云访问密钥"))
    #expect(value.contains("密钥、生产环境"))
    #expect(value.contains("凭据"))

    // 什么都没写就没有这一段，不要往向量库里塞空句子。
    #expect(UserAnnotationText.build(title: nil, tags: [], group: nil) == nil)
    #expect(UserAnnotationText.build(title: "  ", tags: ["  "], group: nil) == nil)
}

@Test("重新解析原子替换正文分块、聚合向量与真实标题")
func linkRefreshCommitsRAGAtomically() async throws {
    let (library, _, _) = try makeLibrary()
    var item = try await library.ingest(text: "https://linux.do/t/topic/2808529")
    item.kind = .link
    item.title = "无法访问链接内容"
    item.titledLocally = true
    item.vector = [0.1, 0.2]
    item.contentHash = "old-hash"
    item.embeddingModelID = "old-model"
    item.indexedAt = Date(timeIntervalSince1970: 10)
    try await library.update(item)
    try await library.replaceChunks(
        for: item.id,
        with: [ContentChunk(itemID: item.id, ordinal: 0, source: .linkPage, text: "旧正文")]
    )

    var refreshed = item
    refreshed.title = "解读 DeepSeek Harness 的核心论文"
    refreshed.vector = [0.8, 0.9]
    refreshed.contentHash = "new-hash"
    refreshed.embeddingModelID = "new-model"
    refreshed.indexedAt = Date(timeIntervalSince1970: 20)
    let newChunks = [
        ContentChunk(
            itemID: item.id,
            ordinal: 0,
            source: .linkPage,
            text: "《解读 DeepSeek Harness 的核心论文》\n#1 author：完整正文",
            vector: [0.8, 0.9],
            embeddingModelID: "new-model"
        )
    ]

    try await library.replaceChunks(for: item.id, with: newChunks, updating: refreshed)

    let stored = try #require(try await library.item(id: item.id))
    let chunks = try await library.chunks(for: item.id)
    #expect(stored.title == "解读 DeepSeek Harness 的核心论文")
    #expect(stored.vector == [0.8, 0.9])
    #expect(stored.contentHash == "new-hash")
    #expect(stored.embeddingModelID == "new-model")
    #expect(stored.indexedAt == Date(timeIntervalSince1970: 20))
    #expect(chunks.map(\.text) == ["《解读 DeepSeek Harness 的核心论文》\n#1 author：完整正文"])
}

@Suite("删除与 RAG 的一致性")
struct DeletionRAGConsistencyTests {

    private func makeLibrary() -> (Library, InMemoryItemStore) {
        let store = InMemoryItemStore()
        let root = FileManager.default.temporaryDirectory
            .appending(path: "mnemo-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let vault = try! FileVault(root: root)
        return (Library(store: store, vault: vault), store)
    }

    @Test("彻底删除一条时它的分块一起消失")
    func purgeRemovesChunks() async throws {
        let (library, store) = makeLibrary()
        let item = Item(title: "会议纪要", kind: .text, holding: .inline("发布窗口 10 月 17 日"))
        try await store.insert(item)
        try await library.replaceChunks(for: item.id, with: [
            ContentChunk(itemID: item.id, ordinal: 0, source: .inlineText, text: "发布窗口 10 月 17 日"),
        ])
        #expect(try await library.chunks(for: item.id).count == 1)

        try await library.trash(id: item.id)
        // 回收站里还能还原，分块必须留着。
        #expect(try await library.chunks(for: item.id).count == 1)

        try await library.purge(id: item.id)
        #expect(try await library.chunks(for: item.id).isEmpty)
    }

    @Test("孤儿分块会被清掉：删干净了就不该还能被检索到")
    func orphanChunksAreSwept() async throws {
        let (library, store) = makeLibrary()
        let item = Item(title: "已经删掉的东西", kind: .text, holding: .inline("敏感内容"))
        try await store.insert(item)
        try await library.replaceChunks(for: item.id, with: [
            ContentChunk(itemID: item.id, ordinal: 0, source: .inlineText, text: "敏感内容"),
        ])
        // 模拟"条目没了、分块还在"——历史上任何一次漏删都会留下这种状态。
        _ = try await store.purge(id: item.id)
        try await store.replaceChunks(itemID: item.id, with: [
            ContentChunk(itemID: item.id, ordinal: 0, source: .inlineText, text: "敏感内容"),
        ])
        #expect(try await library.chunks(for: item.id).count == 1)

        let swept = try await library.purgeOrphanChunks()
        #expect(swept == 1)
        #expect(try await library.chunks(for: item.id).isEmpty)
    }

    @Test("清扫不碰还活着的条目，回收站里的也不碰")
    func sweepKeepsLiveAndTrashedChunks() async throws {
        let (library, store) = makeLibrary()
        let live = Item(title: "还在用", kind: .text, holding: .inline("A"))
        let trashed = Item(title: "在回收站", kind: .text, holding: .inline("B"))
        try await store.insert(live)
        try await store.insert(trashed)
        for item in [live, trashed] {
            try await library.replaceChunks(for: item.id, with: [
                ContentChunk(itemID: item.id, ordinal: 0, source: .inlineText, text: item.title),
            ])
        }
        try await library.trash(id: trashed.id)

        #expect(try await library.purgeOrphanChunks() == 0)
        #expect(try await library.chunks(for: live.id).count == 1)
        #expect(try await library.chunks(for: trashed.id).count == 1)
    }
}
