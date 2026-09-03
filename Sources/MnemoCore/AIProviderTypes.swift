import Foundation

public enum ProviderDialect: String, Codable, Sendable, CaseIterable {
    case openAICompatible
    case anthropicMessages
}

public enum ProviderAuthentication: String, Codable, Sendable, CaseIterable {
    case bearer
    case xAPIKey
    case none
}

public enum ModelModality: String, Codable, Sendable, Hashable, CaseIterable {
    case text, image, audio, video, pdf
}

public enum AIReasoningEffort: String, Codable, Sendable, CaseIterable, Comparable {
    case off, low, medium, high

    public static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.off, .low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

public enum AIFeature: String, Codable, Sendable, CaseIterable, Identifiable {
    case automaticNaming
    case automaticClassification
    case sceneRecognition
    case queryParsing
    case retrievalRecommendation
    case pasteTransformation
    case pdfQuestionAnswering
    case imageUnderstanding
    /// 待办协调：这段新看到的文字，对现有待办做了什么。
    ///
    /// 本地确定性层已经能处理"明说改到几点"这类，模型补的是它结构上够不着的
    /// 部分——指代（"那个报告的事"）、口语（"搞定了"）、以及不在词表里的说法。
    /// 没配路由时整条链退化成纯本地，不会偷偷调用。
    case todoRevision

    public var id: String { rawValue }

    public var usesStrongDefault: Bool {
        self == .pasteTransformation || self == .pdfQuestionAnswering || self == .imageUnderstanding
    }

    public var requiredInputModality: ModelModality { self == .imageUnderstanding ? .image : .text }
}

public struct ProviderConfiguration: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var displayName: String
    public var dialect: ProviderDialect
    public var baseURL: URL
    public var modelsURL: URL?
    public var authentication: ProviderAuthentication
    public var iconID: String
    public var isLocal: Bool

    public init(
        id: String,
        displayName: String,
        dialect: ProviderDialect,
        baseURL: URL,
        modelsURL: URL? = nil,
        authentication: ProviderAuthentication = .bearer,
        iconID: String,
        isLocal: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.dialect = dialect
        self.baseURL = baseURL
        self.modelsURL = modelsURL
        self.authentication = authentication
        self.iconID = iconID
        self.isLocal = isLocal
    }
}

public extension AIModelDescriptor {
    /// 是不是取向量的模型。
    ///
    /// 供应商的 /models 端点把对话模型和 embedding 模型混在同一条列表里返回，
    /// 元数据里没有类型字段，只能按名字判定。对话模型和 embedding 模型走的是
    /// 完全不同的端点，配错了要一路发到线上才失败，所以这里宁可漏判也不误判。
    var looksLikeEmbeddingModel: Bool {
        let name = "\(id) \(displayName)".lowercased()
        // rerank 常和 embedding 同族命名，但它返回的是分数不是向量。
        guard !name.contains("rerank") else { return false }
        return ["embedding", "embed", "bge-", "gte-", "m3e", "voyage", "jina-clip"]
            .contains { name.contains($0) }
    }
}

public struct AIModelDescriptor: Identifiable, Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var displayName: String
    public var inputModalities: Set<ModelModality>
    public var supportsTools: Bool
    public var supportsStructuredOutput: Bool
    public var supportsReasoning: Bool
    public var contextLimit: Int?
    public var outputLimit: Int?
    public var inputPricePerMillion: Decimal?
    public var outputPricePerMillion: Decimal?

    public init(
        id: String,
        displayName: String? = nil,
        inputModalities: Set<ModelModality> = [.text],
        supportsTools: Bool = false,
        supportsStructuredOutput: Bool = false,
        supportsReasoning: Bool = false,
        contextLimit: Int? = nil,
        outputLimit: Int? = nil,
        inputPricePerMillion: Decimal? = nil,
        outputPricePerMillion: Decimal? = nil
    ) {
        self.id = id
        self.displayName = displayName ?? id
        self.inputModalities = inputModalities
        self.supportsTools = supportsTools
        self.supportsStructuredOutput = supportsStructuredOutput
        self.supportsReasoning = supportsReasoning
        self.contextLimit = contextLimit
        self.outputLimit = outputLimit
        self.inputPricePerMillion = inputPricePerMillion
        self.outputPricePerMillion = outputPricePerMillion
    }
}

public struct FeatureRoute: Codable, Sendable, Equatable {
    public var providerID: String
    public var modelID: String
    public var reasoningEffort: AIReasoningEffort

    public init(providerID: String, modelID: String, reasoningEffort: AIReasoningEffort = .off) {
        self.providerID = providerID
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
    }
}

public struct AIRoutingProfile: Codable, Sendable, Equatable {
    public var fast: FeatureRoute?
    public var strong: FeatureRoute?
    public var overrides: [AIFeature: FeatureRoute]

    public init(
        fast: FeatureRoute? = nil,
        strong: FeatureRoute? = nil,
        overrides: [AIFeature: FeatureRoute] = [:]
    ) {
        self.fast = fast
        self.strong = strong
        self.overrides = overrides
    }

    public func route(for feature: AIFeature) -> FeatureRoute? {
        overrides[feature] ?? (feature.usesStrongDefault ? strong : fast)
    }

    public func resolvedRoute(
        for feature: AIFeature,
        model: AIModelDescriptor?
    ) -> RouteResolution? {
        guard var route = route(for: feature) else { return nil }
        guard route.reasoningEffort != .off, model?.supportsReasoning != true else {
            return RouteResolution(route: route, notice: nil)
        }
        route.reasoningEffort = .off
        return RouteResolution(route: route, notice: "所选模型不支持思考强度，已按关闭发送")
    }
}

public struct RouteResolution: Sendable, Equatable {
    public let route: FeatureRoute
    public let notice: String?

    public init(route: FeatureRoute, notice: String?) {
        self.route = route
        self.notice = notice
    }
}

public enum ProviderPresets {
    public static let all: [ProviderConfiguration] = [
        .init(id: "openai", displayName: "OpenAI", dialect: .openAICompatible,
              baseURL: URL(string: "https://api.openai.com/v1")!, iconID: "openai"),
        .init(id: "anthropic", displayName: "Anthropic", dialect: .anthropicMessages,
              baseURL: URL(string: "https://api.anthropic.com/v1")!,
              authentication: .xAPIKey, iconID: "anthropic"),
        .init(id: "google", displayName: "Google Gemini", dialect: .openAICompatible,
              baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!, iconID: "google"),
        .init(id: "deepseek", displayName: "DeepSeek", dialect: .openAICompatible,
              baseURL: URL(string: "https://api.deepseek.com/v1")!, iconID: "deepseek"),
        .init(id: "moonshot", displayName: "月之暗面", dialect: .openAICompatible,
              baseURL: URL(string: "https://api.moonshot.cn/v1")!, iconID: "moonshot"),
        .init(id: "zhipu", displayName: "智谱 AI", dialect: .openAICompatible,
              baseURL: URL(string: "https://open.bigmodel.cn/api/paas/v4")!, iconID: "zhipu"),
        .init(id: "dashscope", displayName: "阿里云百炼", dialect: .openAICompatible,
              baseURL: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!,
              modelsURL: URL(string: "https://dashscope.aliyuncs.com/api/v1/models")!, iconID: "dashscope"),
        .init(id: "siliconflow", displayName: "硅基流动", dialect: .openAICompatible,
              baseURL: URL(string: "https://api.siliconflow.cn/v1")!, iconID: "siliconflow"),
        .init(id: "volcengine", displayName: "火山方舟", dialect: .openAICompatible,
              baseURL: URL(string: "https://ark.cn-beijing.volces.com/api/v3")!, iconID: "volcengine"),
        .init(id: "minimax", displayName: "MiniMax", dialect: .anthropicMessages,
              baseURL: URL(string: "https://api.minimaxi.com/anthropic/v1")!,
              authentication: .xAPIKey, iconID: "minimax"),
        .init(id: "openrouter", displayName: "OpenRouter", dialect: .openAICompatible,
              baseURL: URL(string: "https://openrouter.ai/api/v1")!, iconID: "openrouter"),
        .init(id: "ollama", displayName: "Ollama", dialect: .openAICompatible,
              baseURL: URL(string: "http://127.0.0.1:11434/v1")!, authentication: .none,
              iconID: "ollama", isLocal: true),
        .init(id: "lmstudio", displayName: "LM Studio", dialect: .openAICompatible,
              baseURL: URL(string: "http://127.0.0.1:1234/v1")!, authentication: .none,
              iconID: "lmstudio", isLocal: true),
    ]

    public static func configuration(id: String) -> ProviderConfiguration? {
        all.first { $0.id == id }
    }
}
