import Foundation

public struct LibraryArchiveManifest: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var exportedAt: Date
    public var appVersion: String
    public var items: [ArchivedItem]
    public var todos: [ArchivedTodo]
    public var focusSessions: [FocusSession]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        exportedAt: Date = .now,
        appVersion: String,
        items: [ArchivedItem],
        todos: [ArchivedTodo],
        focusSessions: [FocusSession]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.items = items
        self.todos = todos
        self.focusSessions = focusSessions
    }
}

public enum ArchivedContent: Codable, Sendable, Equatable {
    case inline(String)
    case managedCopy(hash: String, size: Int64, relativePath: String)
    case externalReference(path: String?, size: Int64)
}

public struct ArchivedItem: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var kind: ItemKind
    public var state: ItemState
    public var createdAt: Date
    public var modifiedAt: Date
    public var trashedAt: Date?
    public var titledLocally: Bool
    public var titleOrigin: String?
    public var linkExtractionVersion: Int?
    public var origin: ItemOrigin
    public var isPinned: Bool
    public var originalFilename: String?
    public var contentTypeIdentifier: String?
    public var group: String?
    public var tags: [String]
    public var aiPrivacyBlocked: Bool
    public var allowsSensitiveAI: Bool
    public var content: ArchivedContent

    public init(item: Item) {
        id = item.id
        title = item.title
        kind = item.kind
        state = item.state
        createdAt = item.createdAt
        modifiedAt = item.modifiedAt
        trashedAt = item.trashedAt
        titledLocally = item.titledLocally
        titleOrigin = item.titleOrigin
        linkExtractionVersion = item.linkExtractionVersion
        origin = item.origin
        isPinned = item.isPinned
        originalFilename = item.originalFilename
        contentTypeIdentifier = item.contentTypeIdentifier
        group = item.group
        tags = item.tags
        aiPrivacyBlocked = item.aiPrivacyBlocked
        allowsSensitiveAI = item.allowsSensitiveAI
        switch item.holding {
        case .inline(let text):
            content = .inline(text)
        case .copy(let hash, let size):
            content = .managedCopy(hash: hash, size: size, relativePath: "assets/\(hash)")
        case .reference(_, let size):
            content = .externalReference(path: item.originalSourcePath, size: size)
        }
    }

    public func materialize(holding: Holding, state overrideState: ItemState? = nil) -> Item {
        Item(
            id: id,
            title: title,
            kind: kind,
            holding: holding,
            state: overrideState ?? state,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            trashedAt: trashedAt,
            titledLocally: titledLocally,
            titleOrigin: titleOrigin,
            linkExtractionVersion: linkExtractionVersion,
            origin: origin,
            isPinned: isPinned,
            originalFilename: originalFilename,
            originalSourcePath: {
                if case .externalReference(let path, _) = content { return path }
                return nil
            }(),
            contentTypeIdentifier: contentTypeIdentifier,
            group: group,
            tags: tags,
            aiPrivacyBlocked: aiPrivacyBlocked,
            allowsSensitiveAI: allowsSensitiveAI
        )
    }
}

public struct ArchivedTodo: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var title: String
    public var linkedItemID: UUID?
    public var isCompleted: Bool
    public var dueAt: Date?
    public var createdAt: Date
    public var modifiedAt: Date

    public init(todo: Todo) {
        id = todo.id
        title = todo.title
        linkedItemID = todo.linkedItemID
        isCompleted = todo.isCompleted
        dueAt = todo.dueAt
        createdAt = todo.createdAt
        modifiedAt = todo.modifiedAt
    }

    public var materialized: Todo {
        Todo(
            id: id,
            title: title,
            linkedItemID: linkedItemID,
            isCompleted: isCompleted,
            dueAt: dueAt,
            createdAt: createdAt,
            modifiedAt: modifiedAt
        )
    }
}

public struct LibraryArchiveImportResult: Sendable, Equatable {
    public var importedItemIDs: [UUID]
    public var skippedItems: Int
    public var importedTodos: Int
    public var importedFocusSessions: Int
}

public enum LibraryArchiveError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidPackage(String)
    case missingAsset(String)
    case assetHashMismatch(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "不支持的归档版本：\(version)"
        case .invalidPackage(let reason): "归档无效：\(reason)"
        case .missingAsset(let hash): "归档缺少副本文件：\(hash)"
        case .assetHashMismatch(let hash): "副本完整性校验失败：\(hash)"
        }
    }
}

public actor LibraryArchiveManager {
    public static let shared = LibraryArchiveManager()
    private let fileManager = FileManager.default

    public init() {}

    public func export(
        library: Library,
        to destination: URL,
        appVersion: String
    ) async throws {
        let didAccess = destination.startAccessingSecurityScopedResource()
        defer { if didAccess { destination.stopAccessingSecurityScopedResource() } }

        let parent = destination.deletingLastPathComponent()
        let staging = parent.appending(
            path: ".mnemo-export-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        defer { try? fileManager.removeItem(at: staging) }
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        let assets = staging.appending(path: "assets", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: assets, withIntermediateDirectories: true)

        let items = try await library.items(includingTrashed: true)
        var copiedHashes = Set<String>()
        for item in items {
            guard case .copy(let hash, _) = item.holding,
                  copiedHashes.insert(hash).inserted else { continue }
            guard let source = try await library.resolvedFileURL(for: item) else {
                throw LibraryArchiveError.missingAsset(hash)
            }
            try fileManager.copyItem(at: source, to: assets.appending(path: hash))
        }

        let manifest = LibraryArchiveManifest(
            appVersion: appVersion,
            items: items.map(ArchivedItem.init),
            todos: try await library.todos().map(ArchivedTodo.init),
            focusSessions: try await library.focusSessions()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(
            to: staging.appending(path: "manifest.json"),
            options: .atomic
        )

        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fileManager.moveItem(at: staging, to: destination)
        }
    }

    public func `import`(library: Library, from source: URL) async throws -> LibraryArchiveImportResult {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer { if didAccess { source.stopAccessingSecurityScopedResource() } }
        let manifestURL = source.appending(path: "manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw LibraryArchiveError.invalidPackage("缺少 manifest.json")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            LibraryArchiveManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion == LibraryArchiveManifest.currentSchemaVersion else {
            throw LibraryArchiveError.unsupportedSchema(manifest.schemaVersion)
        }
        guard Set(manifest.items.map(\.id)).count == manifest.items.count,
              Set(manifest.todos.map(\.id)).count == manifest.todos.count else {
            throw LibraryArchiveError.invalidPackage("存在重复标识")
        }

        // 全部校验完成后才触碰现有库。relativePath 不能逃逸归档目录。
        var validatedAssets: [String: URL] = [:]
        for item in manifest.items {
            guard case .managedCopy(let hash, _, let relativePath) = item.content else { continue }
            guard relativePath == "assets/\(hash)" else {
                throw LibraryArchiveError.invalidPackage("副本路径不安全")
            }
            let asset = source.appending(path: relativePath)
            guard fileManager.fileExists(atPath: asset.path) else {
                throw LibraryArchiveError.missingAsset(hash)
            }
            guard try FileVault.sha256(of: asset) == hash else {
                throw LibraryArchiveError.assetHashMismatch(hash)
            }
            validatedAssets[hash] = asset
        }

        var importedIDs: [UUID] = []
        var skipped = 0
        for archived in manifest.items.sorted(by: { $0.createdAt < $1.createdAt }) {
            let existing = try await library.item(id: archived.id)
            if let existing, existing.modifiedAt >= archived.modifiedAt {
                skipped += 1
                continue
            }
            let holding: Holding
            let overrideState: ItemState?
            let retained: Bool
            switch archived.content {
            case .inline(let text):
                holding = .inline(text)
                overrideState = nil
                retained = false
            case .managedCopy(let hash, _, _):
                guard let asset = validatedAssets[hash] else {
                    throw LibraryArchiveError.missingAsset(hash)
                }
                holding = try await library.installSyncedAsset(from: asset)
                overrideState = nil
                retained = true
            case .externalReference(let path, let size):
                let resolved = try await library.restoreArchivedReference(path: path, size: size)
                holding = resolved.holding
                overrideState = resolved.isAvailable ? nil : .unavailableOnThisDevice
                retained = resolved.holdingWasRetained
            }
            let item = archived.materialize(holding: holding, state: overrideState)
            try await library.applyImportedItem(item, incomingHoldingIsRetained: retained)
            importedIDs.append(item.id)
        }

        var importedTodos = 0
        for archived in manifest.todos {
            if let existing = try await library.todo(id: archived.id),
               existing.modifiedAt >= archived.modifiedAt { continue }
            try await library.applyImportedTodo(archived.materialized)
            importedTodos += 1
        }
        for session in manifest.focusSessions {
            try await library.recordFocusSession(session)
        }
        return LibraryArchiveImportResult(
            importedItemIDs: importedIDs,
            skippedItems: skipped,
            importedTodos: importedTodos,
            importedFocusSessions: manifest.focusSessions.count
        )
    }
}
