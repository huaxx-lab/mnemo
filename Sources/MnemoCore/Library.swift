import Foundation
import UniformTypeIdentifiers

public struct ReferenceAuditResult: Sendable, Equatable {
    public var removed: [Item]
    public var contentChanged: [Item]

    public init(removed: [Item] = [], contentChanged: [Item] = []) {
        self.removed = removed
        self.contentChanged = contentChanged
    }
}

/// 把存储与文件持有绑在一起的门面：条目的增删改必须同时维护引用计数，
/// 分开调用迟早会漏，漏了就是磁盘泄漏或误删。
public actor Library {
    private let store: any ItemStore
    private let vault: FileVault
    private let config: VaultConfig
    private var changeObserver: (@Sendable (LibraryChange) async -> Void)?

    public init(store: any ItemStore, vault: FileVault, config: VaultConfig = VaultConfig()) {
        self.store = store
        self.vault = vault
        self.config = config
    }

    public func items(includingTrashed: Bool = false) async throws -> [Item] {
        try await store.all(includingTrashed: includingTrashed)
    }

    public func item(id: UUID) async throws -> Item? { try await store.item(id: id) }

    public func todo(id: UUID) async throws -> Todo? { try await store.todo(id: id) }

    public func setChangeObserver(
        _ observer: (@Sendable (LibraryChange) async -> Void)?
    ) {
        changeObserver = observer
    }

    /// 写回条目。索引器回填向量、AI 回填标题都走这里。
    public func update(_ item: Item) async throws {
        let previous = try await store.item(id: item.id)
        var changed = item
        let syncChanged = previous.map { !$0.hasSameSyncedContent(as: item) } ?? true
        if let previous {
            changed.modifiedAt = syncChanged ? .now : previous.modifiedAt
            changed.cloudSystemFields = previous.cloudSystemFields
        } else {
            changed.modifiedAt = .now
        }
        try await store.update(changed)
        if syncChanged { await notify(.upsertItem(changed.id)) }
    }

    /// 用户手动写下的标题 / 标签。
    ///
    /// `titledLocally` 在这里要置 false：它的含义是"这个名字还只是本地凑出来的，
    /// AI 有机会把它换掉"。用户亲手改过的名字不该被任何自动流程覆盖——那是
    /// 这个应用里最强的一种意图表达。
    ///
    /// 改完标记内容版本失效（`contentHash` 清空），让索引队列把它捡回去重建：
    /// 用户写的这句话要变成一段可检索的文字才算数。重建很便宜——分块的向量
    /// 按内容对账沿用，真正要重新 embed 的只有新增的那一句。
    public func setUserAnnotation(
        id: UUID,
        title: String?,
        tags: [String]
    ) async throws {
        guard var item = try await store.item(id: id) else { return }
        var changed = false
        if let title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != item.title {
                item.title = trimmed
                item.titledLocally = false
                changed = true
            }
        }
        let cleanTags = Self.normalizedTags(tags)
        if cleanTags != item.tags {
            item.tags = cleanTags
            changed = true
        }
        guard changed else { return }
        item.contentHash = nil
        try await store.update(item)
        await notify(.upsertItem(id))
    }

    /// 去空白、去重、保序、限量。标签是给人看也给检索用的，一条重复的标签
    /// 除了让提示词更长没有任何作用。
    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in tags {
            let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tag.isEmpty, tag.count <= 24,
                  seen.insert(tag.lowercased()).inserted else { continue }
            result.append(tag)
            if result.count == 8 { break }
        }
        return result
    }

    public func allChunks() async throws -> [ContentChunk] { try await store.allChunks() }

    /// 手动排序：把条目挪到目标前面。顺序不是内容，不触发 notify——
    /// 上层已经在本地乐观更新过了，也不该因此重建索引。
    public func moveItem(_ id: UUID, before targetID: UUID?) async throws {
        try await store.move(id, before: targetID)
    }

    /// 移进 / 移出隐私空间。
    ///
    /// 检索分块是**冻结，不是删除**。
    ///
    /// 一开始写成了删除，想的是"清干净才安全"。但这个方案本来就只隐藏、
    /// 不加密——库文件里条目正文一直是明文，删掉分块并不多带来一分保护，
    /// 却要让移出来的人重跑一遍 OCR 和 Embedding。代价真实，收益是零。
    ///
    /// 冻结靠的是**条目级过滤**：隐私条目不进 `aiEligibleItems`，而检索链路
    /// 的分块一律按条目 ID 取（`chunks(for: scopeIDs)`），条目被摘掉，它的
    /// 分块根本不会被加载。所以真正的闸门在条目那一层，不在分块。
    public func setPrivate(id: UUID, isPrivate: Bool) async throws {
        guard var item = try await store.item(id: id), item.isPrivate != isPrivate else { return }
        item.isPrivate = isPrivate
        if isPrivate {
            // 进了隐私空间就不再是"临时"的。
            //
            // 一是额度：临时轨道只有 5 条，淘汰只数 `origin == .clipboard &&
            // !isPinned`——置上 isPinned 之后它自动退出那个集合，占的名额当场
            // 还回去，不会因为"我把它藏起来了"而挤掉别的东西。
            // 二是语义：肯把一条内容收进隐私空间，本身就是"我要留着它"的表态，
            // 比 pin 还强。移出来之后也就不该再变回随时会被冲掉的临时项。
            item.isPinned = true
        }
        // 索引原样保留：移出来立刻就能被检索到，不用重跑一遍 OCR 和 Embedding。
        try await store.update(item)
        await notify(.upsertItem(id))
    }

    public func todos() async throws -> [Todo] { try await store.allTodos() }

    public func setTodo(for itemID: UUID, enabled: Bool) async throws {
        let existing = try await store.allTodos().first { $0.linkedItemID == itemID }
        if enabled {
            guard existing == nil, let item = try await store.item(id: itemID) else { return }
            let todo = Todo(title: item.title, linkedItemID: itemID)
            try await store.upsertTodo(todo)
            await notify(.upsertTodo(todo.id))
        } else if let existing {
            try await store.deleteTodo(id: existing.id)
            await notify(.deleteTodo(existing.id))
        }
    }

    @discardableResult
    public func addTodo(title: String) async throws -> Todo {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let todo = Todo(title: value)
        try await store.upsertTodo(todo)
        await notify(.upsertTodo(todo.id))
        return todo
    }

    public func updateTodo(_ todo: Todo) async throws {
        let previous = try await store.todo(id: todo.id)
        guard previous.map({ !$0.hasSameSyncedContent(as: todo) }) ?? true else { return }
        var changed = todo
        changed.modifiedAt = .now
        changed.cloudSystemFields = previous?.cloudSystemFields
        try await store.upsertTodo(changed)
        await notify(.upsertTodo(changed.id))
    }

    public func deleteTodo(id: UUID) async throws {
        try await store.deleteTodo(id: id)
        await notify(.deleteTodo(id))
    }

    public func installSyncedAsset(from url: URL) async throws -> Holding {
        try await vault.ingest(url, preference: .copyRequired)
    }

    public func restoreArchivedReference(
        path: String?,
        size: Int64
    ) async throws -> (holding: Holding, isAvailable: Bool, holdingWasRetained: Bool) {
        guard let path, FileManager.default.fileExists(atPath: path) else {
            return (.reference(bookmark: Data(), size: size), false, false)
        }
        let holding = try await vault.ingest(
            URL(fileURLWithPath: path),
            preference: .referenceFirst
        )
        return (holding, true, true)
    }

    /// 外部导入专用：写库但不发出本地变更事件。
    public func applySyncedItem(
        _ item: Item,
        incomingHoldingIsRetained: Bool = false
    ) async throws {
        let old = try await store.item(id: item.id)
        try await store.upsert(item)
        let oldOwnsCopy = old.map(Self.ownsManagedCopy) ?? false
        let newOwnsCopy = Self.ownsManagedCopy(item)
        if let old, old.holding == item.holding {
            if oldOwnsCopy && !newOwnsCopy { await vault.release(old.holding) }
            if !oldOwnsCopy && newOwnsCopy { await vault.retain(item.holding) }
            return
        }
        if let old, oldOwnsCopy { await vault.release(old.holding) }
        if incomingHoldingIsRetained {
            if !newOwnsCopy { await vault.release(item.holding) }
        } else if newOwnsCopy {
            await vault.retain(item.holding)
        }
    }

    public func applySyncedTodo(_ todo: Todo) async throws {
        try await store.upsertTodo(todo)
    }

    /// 归档导入是本地写入，必须发出变更事件；上面的 applySyncedItem /
    /// applySyncedTodo 则是静默写入。
    public func applyImportedItem(
        _ item: Item,
        incomingHoldingIsRetained: Bool = false
    ) async throws {
        try await applySyncedItem(item, incomingHoldingIsRetained: incomingHoldingIsRetained)
        await notify(.upsertItem(item.id))
    }

    public func applyImportedTodo(_ todo: Todo) async throws {
        try await applySyncedTodo(todo)
        await notify(.upsertTodo(todo.id))
    }

    public func removeSyncedTodo(id: UUID) async throws {
        try await store.deleteTodo(id: id)
    }

    public func trashSyncedItem(id: UUID, now: Date = .now) async throws {
        let old = try await store.item(id: id)
        guard let holding = try await store.trash(id: id, at: now) else { return }
        try await store.detachTodos(linkedItemID: id)
        if old.map(Self.ownsManagedCopy) == true { await vault.release(holding) }
    }

    public func focusSessions(since date: Date? = nil) async throws -> [FocusSession] {
        try await store.focusSessions(since: date)
    }

    public func recordFocusSession(_ session: FocusSession) async throws {
        try await store.insertFocusSession(session)
    }

    public func chunks(for itemIDs: Set<UUID>) async throws -> [ContentChunk] {
        try await store.chunks(itemIDs: itemIDs)
    }

    public func chunks(for itemID: UUID) async throws -> [ContentChunk] {
        try await store.chunks(itemID: itemID)
    }

    public func replaceChunks(for itemID: UUID, with chunks: [ContentChunk]) async throws {
        try await store.replaceChunks(itemID: itemID, with: chunks)
    }

    public func reconcileVault() async throws -> ReconcileReport {
        try await vault.reconcile()
    }

    public func storageUsage() async -> (active: Int64, trashed: Int64) {
        (await vault.activeUsage(), await vault.trashedUsage())
    }

    public func resolvedFileURL(for item: Item) async throws -> URL? {
        try await vault.resolve(item.holding, originalSourcePath: item.originalSourcePath)
    }

    /// 拖入一个文件。存储决策先于任何 AI 处理——AI 失败不影响条目已落库。
    /// 相同内容已存在时复用原条目；若原条目在回收站则恢复它。这样 Finder
    /// 重复投放与 Mnemo 内部拖回都不会制造肉眼相同的卡片。
    @discardableResult
    public func ingest(
        fileAt url: URL,
        kind: ItemKind? = nil,
        preference: FileIngestPreference = .referenceFirst,
        origin: ItemOrigin = .manual,
        isPinned: Bool = true,
        /// 真正的来处。承诺投放和"把拖拽板字节落盘"这两条路拿到的是我们自己
        /// 临时目录里的文件，来处要由调用方补上，否则卡片认不出它来自哪个应用。
        sourcePath: String? = nil
    ) async throws -> Item {
        // 别的应用的容器 / 临时目录里的文件必须当场留副本：那条路径明天就没了，
        // 而且现在就可能读不出内容。
        let effective: FileIngestPreference = preference == .referenceFirst
            && DroppedSourceTrust.requiresManagedCopy(url) ? .copyRequired : preference
        let holding = try await vault.ingest(url, preference: effective)
        if let duplicate = try await duplicate(for: holding) {
            // vault.ingest 已为候选副本加过一次引用；既然不插入新条目就回滚。
            await vault.release(holding)
            return try await reconcileDuplicate(duplicate, origin: origin, isPinned: isPinned)
        }
        // 原文件的时间对**所有**持有方式都要记：它是"内容自己的时间"，
        // 检索层靠它回答"最新一版是哪个"。副本型以前不记，于是一篇三月定稿、
        // 今天拖进来的论文在库里只剩今天这个时间，两版新旧完全分不出来。
        // 健康检查不受影响：`auditReferences` 自己 guard 了 `.reference`。
        let sourceMetadata = Self.sourceMetadata(for: url)
        let referenceSize = if case .reference = holding { sourceMetadata.size } else { Optional<Int64>.none }
        let item = Item(
            title: url.deletingPathExtension().lastPathComponent,
            kind: kind ?? Self.inferKind(from: url),
            holding: holding,
            titledLocally: true,         // 先给本地名字，AI 命名是后续的异步升级
            origin: origin,
            isPinned: isPinned,
            originalFilename: url.lastPathComponent,
            // 引用型靠它做健康检查；副本型只作来处记录，`auditReferences`
            // 只处理 `.reference`，不会把副本误判成"原文件被删了"。
            originalSourcePath: sourcePath ?? url.standardizedFileURL.path,
            sourceModificationDate: sourceMetadata.modifiedAt,
            sourceFileSize: referenceSize,
            contentTypeIdentifier: Self.contentType(for: url)?.identifier
        )
        try await store.insert(item)
        await notify(.upsertItem(item.id))
        return item
    }

    /// Pin 一段文字。
    @discardableResult
    public func ingest(
        text: String,
        origin: ItemOrigin = .manual,
        isPinned: Bool = true
    ) async throws -> Item {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let duplicate = try await duplicate(inlineText: trimmed) {
            return try await reconcileDuplicate(duplicate, origin: origin, isPinned: isPinned)
        }
        // 分享文案（"标题 + 链接 + 一句套话"）也算链接。旧判定要求整段不含
        // 任何空白，于是小红书、抖音、B 站分享过来的内容全被存成纯文字：
        // 没有封面、没有平台图标、点了也打不开。
        let share = ShareLinkExtractor.first(in: trimmed)
        let link = share?.isSharePayload == true ? share?.url : nil
        let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
        // 分享文案里【】中那段是原标题，逐字可靠；比拿域名当标题好得多。
        let title = share?.title
            ?? link?.host(percentEncoded: false)
            ?? String(firstLine.prefix(24))
        let item = Item(
            title: title,
            kind: link == nil ? .text : .link,
            holding: .inline(text),
            titledLocally: true,
            origin: origin,
            isPinned: isPinned,
            contentTypeIdentifier: link == nil ? UTType.plainText.identifier : UTType.url.identifier
        )
        try await store.insert(item)
        await notify(.upsertItem(item.id))
        return item
    }

    private func duplicate(inlineText text: String) async throws -> Item? {
        let candidates = try await store.all(includingTrashed: true).filter {
            guard $0.state == .active || $0.state == .trashed,
                  case .inline(let existing) = $0.holding else { return false }
            return existing.trimmingCharacters(in: .whitespacesAndNewlines) == text
        }
        return Self.preferredDuplicate(in: candidates)
    }

    private func duplicate(for holding: Holding) async throws -> Item? {
        let candidates = try await store.all(includingTrashed: true).filter {
            $0.state == .active || $0.state == .trashed
        }

        if case .copy(let incomingHash, _) = holding {
            return Self.preferredDuplicate(in: candidates.filter {
                guard case .copy(let existingHash, _) = $0.holding else { return false }
                return existingHash == incomingHash
            })
        }

        guard case .reference = holding,
              let incomingURL = try await vault.resolve(holding)?.standardizedFileURL else {
            return nil
        }
        var matches: [Item] = []
        for item in candidates {
            guard case .reference = item.holding,
                  let existingURL = try? await vault.resolve(
                    item.holding,
                    originalSourcePath: item.originalSourcePath
                  )?.standardizedFileURL,
                  existingURL == incomingURL else { continue }
            matches.append(item)
        }
        return Self.preferredDuplicate(in: matches)
    }

    private static func preferredDuplicate(in candidates: [Item]) -> Item? {
        candidates.first(where: { $0.state == .active })
            ?? candidates.first(where: { $0.state == .trashed })
    }

    private func restoreIfNeeded(_ item: Item) async throws -> Item {
        guard item.state == .trashed else { return item }
        if let holding = try await store.restore(id: item.id) {
            await vault.retain(holding)
        }
        if let restored = try await store.item(id: item.id) { return restored }
        var restored = item
        restored.state = .active
        restored.trashedAt = nil
        return restored
    }

    private func reconcileDuplicate(
        _ duplicate: Item,
        origin: ItemOrigin,
        isPinned: Bool
    ) async throws -> Item {
        var item = try await restoreIfNeeded(duplicate)
        var changed = false
        if isPinned, !item.isPinned {
            item.isPinned = true
            changed = true
        } else if origin == .clipboard, !item.isPinned {
            // 相同内容再次复制：移动到剪贴板轨道最前，而不是新增一条。
            item.createdAt = .now
            changed = true
        }
        if changed {
            item.modifiedAt = .now
            try await store.update(item)
            await notify(.upsertItem(item.id))
        }
        return item
    }

    /// 剪贴板历史只淘汰未固定的临时项；永久 Pin 不参与容量计算。
    ///
    /// `independentIDs` 是一条需要**独立容量**的轨道。App 层把通用剪贴板来的
    /// iPhone / iPad 条目 ID 传进来，于是两组分别保留 `limit` 条：Mac 最近 5 条
    /// 不会挤掉手机最近 5 条，反过来也一样。Core 不知道“手机”这个概念，只负责
    /// 按明确给出的分区执行容量规则，因此不会把 AppKit 来源判断渗进领域层。
    @discardableResult
    public func trimClipboardHistory(
        limit: Int,
        independentIDs: Set<UUID> = []
    ) async throws -> [Item] {
        let safeLimit = max(1, limit)
        let history = try await store.all(includingTrashed: false)
            .filter { $0.origin == .clipboard && !$0.isPinned }

        let independent = history
            .filter { independentIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        let primary = history
            .filter { !independentIDs.contains($0.id) }
            .sorted { $0.createdAt > $1.createdAt }
        let overflow = Array(primary.dropFirst(safeLimit))
            + Array(independent.dropFirst(safeLimit))

        for item in overflow {
            if let holding = try await store.trash(id: item.id, at: .now) {
                try await store.detachTodos(linkedItemID: item.id)
                if Self.ownsManagedCopy(item) { await vault.release(holding) }
                await notify(.upsertItem(item.id))
            }
        }
        return overflow
    }


    public func pinClipboardItem(id: UUID) async throws {
        try await setClipboardPin(id: id, isPinned: true)
    }

    /// 固定与取消固定是同一件事的两面。只做单向的话，锁定之后图钉就消失了，
    /// 用户再没有入口把它放回那五条滚动轨道——只能删掉重来。
    public func setClipboardPin(id: UUID, isPinned: Bool) async throws {
        guard var item = try await store.item(id: id),
              item.origin == .clipboard,
              item.isPinned != isPinned else { return }
        item.isPinned = isPinned
        item.modifiedAt = .now
        try await store.update(item)
        await notify(.upsertItem(item.id))
    }

    /// 编辑文本条目。按内容比对判脏——打开编辑器又原样关闭不该产生 token 花费。
    /// - Returns: 内容是否真的变了
    @discardableResult
    public func edit(id: UUID, newText: String) async throws -> Bool {
        guard var item = try await store.item(id: id),
              case .inline(let old) = item.holding else { return false }
        guard old != newText else { return false }

        item.holding = .inline(newText)
        item.titledLocally = true       // 新内容版本需要重新命名与分类
        item.group = nil
        item.tags = []
        item.aiPrivacyBlocked = false
        // 只清内容版本标记。旧向量与旧分块在新索引完整落盘前继续提供
        // 降级召回，搜索层会把它明确标成 stale。
        item.contentHash = nil
        item.modifiedAt = .now
        try await store.update(item)
        await notify(.upsertItem(item.id))
        return true
    }

    /// 删除 = 移入回收站 + 递减引用计数。计数归零也不删盘。
    public func trash(id: UUID, now: Date = .now) async throws {
        let existing = try await store.item(id: id)
        guard let holding = try await store.trash(id: id, at: now) else { return }
        try await store.detachTodos(linkedItemID: id)
        if existing.map(Self.ownsManagedCopy) == true { await vault.release(holding) }
        await notify(.upsertItem(id))
    }

    public func restore(id: UUID) async throws {
        guard let holding = try await store.restore(id: id) else { return }
        await vault.retain(holding)
        if var item = try await store.item(id: id) {
            item.modifiedAt = .now
            try await store.update(item)
        }
        await notify(.upsertItem(id))
    }

    /// 彻底清除一条，走和清空回收站同一条路：检索分块（RAG）、受管副本、
    /// 条目记录一起消失，之后没有任何东西还指着它。
    ///
    /// 条目已经不在库里时返回 false 而不是抛错——"之前已经清空过了"是一种
    /// 正常状态，不该让调用方为它写一段 catch。
    @discardableResult
    public func purge(id: UUID) async throws -> Bool {
        guard let item = try await store.purge(id: id) else { return false }
        if case .copy(let hash, _) = item.holding {
            // 受管副本按引用计数清；同一份内容被别处引用时 vault 自己会保留。
            try? await vault.purge(hash)
        }
        await notify(.deleteItem(id))
        return true
    }

    /// 用户显式清空回收站。复用到期清理的物理删除路径，引用型条目只删
    /// 数据库记录，绝不操作书签指向的原文件。
    @discardableResult
    public func emptyTrash() async throws -> (purged: Int, failures: [VaultError]) {
        let doomed = try await store.purgeExpired(now: .distantFuture, retention: 0)
        var failures: [VaultError] = []
        for item in doomed {
            guard case .copy(let hash, _) = item.holding else { continue }
            do { try await vault.purge(hash) }
            catch let error as VaultError { failures.append(error) }
        }
        for item in doomed { await notify(.deleteItem(item.id)) }
        return (doomed.count, failures)
    }

    /// 低频健康检查：只有已确认源文件被删除才从主库移除。外置卷离线、
    /// 权限暂时失效或老数据缺少原始路径时一律保留，避免把「暂时不可用」误判成删除。
    @discardableResult
    public func trashMissingReferences(now: Date = .now) async throws -> [Item] {
        try await auditReferences(now: now).removed
    }

    /// 引用文件状态机：删除时软删除；离线时冻结；内容版本变化时只标脏并
    /// 返回给上层重新排队。迁移来的旧记录第一次只补版本基线，不盲目重算。
    public func auditReferences(now: Date = .now) async throws -> ReferenceAuditResult {
        let active = try await store.all(includingTrashed: false)
        var result = ReferenceAuditResult()
        for original in active {
            var item = original
            guard case .reference = item.holding else { continue }
            switch await vault.referenceHealth(
                item.holding,
                originalSourcePath: item.originalSourcePath
            ) {
            case .sourceDeleted:
                guard try await store.trash(id: item.id, at: now) != nil else { continue }
                try await store.detachTodos(linkedItemID: item.id)
                result.removed.append(item)
                await notify(.upsertItem(item.id))
            case .temporarilyUnavailable:
                continue
            case .available(let url):
                let metadata = Self.sourceMetadata(for: url)
                let hadBaseline = item.sourceModificationDate != nil || item.sourceFileSize != nil
                let changed = hadBaseline && (
                    item.sourceModificationDate != metadata.modifiedAt
                    || item.sourceFileSize != metadata.size
                )
                item.originalSourcePath = url.standardizedFileURL.path
                item.sourceModificationDate = metadata.modifiedAt
                item.sourceFileSize = metadata.size
                if case .reference(let bookmark, _) = item.holding, let size = metadata.size {
                    item.holding = .reference(bookmark: bookmark, size: size)
                }
                if changed {
                    item.titledLocally = true
                    item.group = nil
                    item.tags = []
                    item.aiPrivacyBlocked = false
                    // 保留旧索引直到新版本原子替换，避免外部编辑后出现搜索空窗。
                    item.contentHash = nil
                    result.contentChanged.append(item)
                }
                if changed || !hadBaseline || item.originalSourcePath != original.originalSourcePath {
                    if changed { item.modifiedAt = .now }
                    try await store.update(item)
                    if changed { await notify(.upsertItem(item.id)) }
                }
            }
        }
        return result
    }

    /// 清理到期条目并删盘。删除失败不吞异常，返回给调用方。
    @discardableResult
    public func purgeExpired(now: Date = .now) async throws -> (purged: Int, failures: [VaultError]) {
        let doomed = try await store.purgeExpired(now: now, retention: config.retention)
        var failures: [VaultError] = []
        for item in doomed {
            guard case .copy(let hash, _) = item.holding else { continue }
            do { try await vault.purge(hash) }
            catch let e as VaultError { failures.append(e) }
        }
        for item in doomed { await notify(.deleteItem(item.id)) }
        return (doomed.count, failures)
    }

    private func notify(_ change: LibraryChange) async {
        await changeObserver?(change)
    }

    private static func ownsManagedCopy(_ item: Item) -> Bool {
        guard case .copy = item.holding else { return false }
        return item.state != .trashed && item.state != .unavailableOnThisDevice
    }

    static func inferKind(from url: URL) -> ItemKind {
        guard let type = contentType(for: url) else { return .binary }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .plainText) || type.conforms(to: .rtf) { return .text }
        return .file
    }

    private static func contentType(for url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        guard !url.pathExtension.isEmpty else { return nil }
        return UTType(filenameExtension: url.pathExtension)
    }

    private static func sourceMetadata(for url: URL) -> (modifiedAt: Date?, size: Int64?) {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (values?.contentModificationDate, values?.fileSize.map(Int64.init))
    }

    /// 裸链接判定。分享文案走 `ShareLinkExtractor`，两者的汇合点是
    /// `Item.linkURL`——调用方一律读那个，不要在别处再判一次。
    static func webURL(from text: String) -> URL? {
        guard !text.contains(where: \.isWhitespace),
              let url = URL(string: text),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host() != nil else { return nil }
        return url
    }
}
