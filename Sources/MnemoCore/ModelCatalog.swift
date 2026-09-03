import Foundation

public struct ProviderModelCatalog: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var models: [AIModelDescriptor]

    public init(id: String, displayName: String, models: [AIModelDescriptor]) {
        self.id = id
        self.displayName = displayName
        self.models = models
    }
}

public struct ModelCatalogSnapshot: Codable, Sendable, Equatable {
    public var providers: [ProviderModelCatalog]
    public var fetchedAt: Date?
    public var sourceETag: String?

    public init(providers: [ProviderModelCatalog], fetchedAt: Date? = nil, sourceETag: String? = nil) {
        self.providers = providers
        self.fetchedAt = fetchedAt
        self.sourceETag = sourceETag
    }

    public func models(providerID: String) -> [AIModelDescriptor] {
        providers.first { $0.id == providerID }?.models ?? []
    }
}

public enum ModelCatalogError: Error, LocalizedError, Sendable, Equatable {
    case invalidPayload
    case emptyCatalog

    public var errorDescription: String? {
        switch self {
        case .invalidPayload: "模型目录格式无效"
        case .emptyCatalog: "供应商没有返回可用模型"
        }
    }
}

/// 只在显式刷新完成后发布一份新快照。视图始终观察完整快照，因此不会经历
/// 清空 → 逐条追加 → 重排的抖动过程。
public actor ModelCatalogStore {
    private let cacheURL: URL?
    private let bundled: ModelCatalogSnapshot
    private var snapshot: ModelCatalogSnapshot
    public private(set) var revision = 0

    public init(bundled: ModelCatalogSnapshot, cacheURL: URL? = nil) {
        self.bundled = bundled
        self.cacheURL = cacheURL
        if let cacheURL,
           let data = try? Data(contentsOf: cacheURL),
           let cached = try? JSONDecoder().decode(ModelCatalogSnapshot.self, from: data),
           !cached.providers.isEmpty {
            self.snapshot = cached
        } else {
            self.snapshot = bundled
        }
    }

    public func current() -> ModelCatalogSnapshot { snapshot }

    /// 用户点击「刷新模型」后的供应商原子更新。刷新失败时此方法不改状态。
    @discardableResult
    public func replaceLiveModels(
        providerID: String,
        displayName: String,
        models: [AIModelDescriptor],
        fetchedAt: Date = .now
    ) throws -> ModelCatalogSnapshot {
        guard !models.isEmpty else { throw ModelCatalogError.emptyCatalog }
        let previousMetadata = Dictionary(
            uniqueKeysWithValues: snapshot.models(providerID: providerID).map { ($0.id, $0) }
        )
        let merged = models.map { live -> AIModelDescriptor in
            guard var known = previousMetadata[live.id] else { return live }
            known.displayName = live.displayName
            return known
        }
        var providers = snapshot.providers.filter { $0.id != providerID }
        providers.append(.init(
            id: providerID,
            displayName: displayName,
            models: merged.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        ))
        providers.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let next = ModelCatalogSnapshot(
            providers: providers,
            fetchedAt: fetchedAt,
            sourceETag: snapshot.sourceETag
        )
        try publish(next)
        return snapshot
    }

    /// models.dev 仅补齐 chat 元数据；解析完整成功后才替换快照。
    @discardableResult
    public func replaceModelsDevPayload(
        _ data: Data,
        eTag: String? = nil,
        fetchedAt: Date = .now
    ) throws -> ModelCatalogSnapshot {
        let parsed = try Self.parseModelsDev(data)
        guard !parsed.isEmpty else { throw ModelCatalogError.emptyCatalog }
        let next = ModelCatalogSnapshot(providers: parsed, fetchedAt: fetchedAt, sourceETag: eTag)
        try publish(next)
        return snapshot
    }

    /// 将 models.dev 的能力与价格补进 Mnemo 已适配的供应商，而不是把供应商
    /// 官方 `/models` 返回的可用列表替换成一个更大的公共目录。已有列表只按相同
    /// model id 补元数据；本地尚无任何列表时，才使用公共目录作为离线初始快照。
    @discardableResult
    public func mergeModelsDevPayload(
        _ data: Data,
        providerAliases: [String: [String]],
        eTag: String? = nil,
        fetchedAt: Date = .now
    ) throws -> ModelCatalogSnapshot {
        let parsed = try Self.parseModelsDev(data)
        guard !parsed.isEmpty else { throw ModelCatalogError.emptyCatalog }
        let byID = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, $0) })
        var providers = snapshot.providers

        for (localID, aliases) in providerAliases {
            let publicModels = aliases
                .compactMap { byID[$0]?.models }
                .flatMap { $0 }
            guard !publicModels.isEmpty else { continue }
            let publicByID = Dictionary(
                publicModels.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            if let index = providers.firstIndex(where: { $0.id == localID }) {
                let existing = providers[index].models
                if existing.isEmpty {
                    providers[index].models = Self.sortedUnique(publicModels)
                } else {
                    providers[index].models = existing.map { model in
                        guard var metadata = publicByID[model.id] else { return model }
                        // 官方模型列表中的展示名比公共目录更接近当前账号实际可见名称。
                        metadata.displayName = model.displayName
                        return metadata
                    }
                }
            } else {
                providers.append(.init(
                    id: localID,
                    displayName: localID,
                    models: Self.sortedUnique(publicModels)
                ))
            }
        }

        providers.sort { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let next = ModelCatalogSnapshot(
            providers: providers,
            fetchedAt: fetchedAt,
            sourceETag: eTag ?? snapshot.sourceETag
        )
        try publish(next)
        return snapshot
    }

    public func restoreBundledSnapshot() throws {
        try publish(bundled)
    }

    private func publish(_ next: ModelCatalogSnapshot) throws {
        if let cacheURL {
            let parent = cacheURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: cacheURL, options: .atomic)
        }
        snapshot = next
        revision += 1
    }

    private static func parseModelsDev(_ data: Data) throws -> [ProviderModelCatalog] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ModelCatalogError.invalidPayload
        }
        var providers: [ProviderModelCatalog] = []
        for (providerID, value) in root {
            guard let provider = value as? [String: Any],
                  let rawModels = provider["models"] as? [String: Any] else { continue }
            let displayName = (provider["name"] as? String) ?? providerID
            let models = rawModels.compactMap { modelID, rawValue -> AIModelDescriptor? in
                guard let raw = rawValue as? [String: Any] else { return nil }
                let modalities = raw["modalities"] as? [String: Any]
                let inputs = (modalities?["input"] as? [String] ?? ["text"])
                    .compactMap(ModelModality.init(rawValue:))
                let limits = raw["limit"] as? [String: Any]
                let cost = raw["cost"] as? [String: Any]
                return AIModelDescriptor(
                    id: modelID,
                    displayName: (raw["name"] as? String) ?? modelID,
                    inputModalities: Set(inputs),
                    supportsTools: (raw["tool_call"] as? Bool) ?? false,
                    supportsStructuredOutput: (raw["structured_output"] as? Bool) ?? false,
                    supportsReasoning: (raw["reasoning"] as? Bool) ?? false,
                    contextLimit: (limits?["context"] as? NSNumber)?.intValue,
                    outputLimit: (limits?["output"] as? NSNumber)?.intValue,
                    inputPricePerMillion: decimal(cost?["input"]),
                    outputPricePerMillion: decimal(cost?["output"])
                )
            }
            guard !models.isEmpty else { continue }
            providers.append(.init(
                id: providerID,
                displayName: displayName,
                models: models.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
            ))
        }
        return providers.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        if let number = value as? NSNumber { return number.decimalValue }
        if let text = value as? String { return Decimal(string: text) }
        return nil
    }

    private static func sortedUnique(_ models: [AIModelDescriptor]) -> [AIModelDescriptor] {
        let values = Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return values.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }
}

public enum BundledModelCatalog {
    /// 只保证离线配置界面有稳定内容。真实列表由用户在供应商页主动刷新；
    /// embedding 始终允许手填，不把这份快照当完整目录。
    public static let snapshot = ModelCatalogSnapshot(providers: [
        .init(id: "minimax", displayName: "MiniMax", models: [
            .init(id: "MiniMax-M3", inputModalities: [.text, .image, .video], supportsTools: true,
                  supportsReasoning: true, contextLimit: 1_048_576,
                  inputPricePerMillion: 0.3, outputPricePerMillion: 1.2),
            .init(id: "MiniMax-M2.7", supportsTools: true, supportsReasoning: true, contextLimit: 204_800,
                  inputPricePerMillion: 0.3, outputPricePerMillion: 1.2),
            .init(id: "MiniMax-M2.5", supportsTools: true, supportsReasoning: true, contextLimit: 204_800,
                  inputPricePerMillion: 0.3, outputPricePerMillion: 1.2),
        ]),
        .init(id: "dashscope", displayName: "阿里云百炼", models: [
            .init(id: "qwen3.7-text-embedding", displayName: "qwen3.7-text-embedding"),
        ]),
    ])
}
