import Foundation

public enum AIExecutionError: Error, Sendable, Equatable, LocalizedError {
    case routeNotConfigured(AIFeature)
    case providerNotFound(String)
    case modelNotConfigured(AIFeature)
    case privacyBlocked(Set<SensitiveContentKind>)
    case malformedStructuredOutput
    case unsupportedInputModality(ModelModality)

    public var errorDescription: String? {
        switch self {
        case .routeNotConfigured:
            "该 AI 功能尚未配置模型路线"
        case .providerNotFound(let id):
            "找不到供应商：\(id)"
        case .modelNotConfigured:
            "该 AI 功能尚未填写模型名"
        case .privacyBlocked:
            "内容命中本地敏感信息规则，已阻止外发"
        case .malformedStructuredOutput:
            "模型没有返回可识别的结构化结果"
        case .unsupportedInputModality(let modality):
            "当前模型不支持所需输入类型：\(modality.rawValue)"
        }
    }
}

public struct AIExecutionResult: Sendable, Equatable {
    public var output: ChatCompletionOutput
    public var providerID: String
    public var modelID: String
    public var routeNotice: String?

    public init(
        output: ChatCompletionOutput,
        providerID: String,
        modelID: String,
        routeNotice: String?
    ) {
        self.output = output
        self.providerID = providerID
        self.modelID = modelID
        self.routeNotice = routeNotice
    }
}

/// 唯一的 AI 请求入口：负责功能路由、供应商选择、思考强度门控与本地隐私筛查。
/// App 层只提供从钥匙串读取凭据的闭包，不得绕过该入口直接拼请求。
public actor AIExecutionEngine {
    public typealias CredentialLoader = @Sendable (String) async throws -> String?

    private let client: AIProviderClient

    public init(client: AIProviderClient = AIProviderClient()) {
        self.client = client
    }

    public func complete(
        feature: AIFeature,
        profile: AIRoutingProfile,
        providers: [ProviderConfiguration],
        catalog: ModelCatalogSnapshot,
        credentialLoader: @escaping CredentialLoader,
        system: String? = nil,
        prompt: String,
        privacyText: String? = nil,
        maxTokens: Int = 512,
        image: ChatImageInput? = nil,
        allowSensitiveContent: Bool = false
    ) async throws -> AIExecutionResult {
        let plan = try await plan(
            feature: feature,
            profile: profile,
            providers: providers,
            catalog: catalog,
            credentialLoader: credentialLoader,
            system: system,
            prompt: prompt,
            privacyText: privacyText,
            maxTokens: maxTokens,
            image: image,
            allowSensitiveContent: allowSensitiveContent
        )
        let output = try await client.complete(
            provider: plan.provider,
            apiKey: plan.apiKey,
            input: plan.input
        )
        return AIExecutionResult(
            output: output,
            providerID: plan.provider.id,
            modelID: plan.input.model,
            routeNotice: plan.routeNotice
        )
    }

    /// 与 complete 共用路由、隐私筛查与模态校验，只是把一次性结果换成增量流。
    /// 流式不参与用量统计——增量事件里没有 usage。
    public func streamComplete(
        feature: AIFeature,
        profile: AIRoutingProfile,
        providers: [ProviderConfiguration],
        catalog: ModelCatalogSnapshot,
        credentialLoader: @escaping CredentialLoader,
        system: String? = nil,
        prompt: String,
        privacyText: String? = nil,
        maxTokens: Int = 512,
        allowSensitiveContent: Bool = false
    ) async throws -> AsyncThrowingStream<AIStreamChunk, any Error> {
        let plan = try await plan(
            feature: feature,
            profile: profile,
            providers: providers,
            catalog: catalog,
            credentialLoader: credentialLoader,
            system: system,
            prompt: prompt,
            privacyText: privacyText,
            maxTokens: maxTokens,
            image: nil,
            allowSensitiveContent: allowSensitiveContent
        )
        return try await client.streamComplete(
            provider: plan.provider,
            apiKey: plan.apiKey,
            input: plan.input
        )
    }

    private struct ExecutionPlan {
        var provider: ProviderConfiguration
        var apiKey: String?
        var input: ChatCompletionInput
        var routeNotice: String?
    }

    /// 路由解析、隐私闸门、模态校验与取密钥。一次性与流式必须走同一条，
    /// 否则流式会绕开隐私筛查。
    private func plan(
        feature: AIFeature,
        profile: AIRoutingProfile,
        providers: [ProviderConfiguration],
        catalog: ModelCatalogSnapshot,
        credentialLoader: @escaping CredentialLoader,
        system: String?,
        prompt: String,
        privacyText: String?,
        maxTokens: Int,
        image: ChatImageInput?,
        allowSensitiveContent: Bool
    ) async throws -> ExecutionPlan {
        guard let configured = profile.route(for: feature) else {
            throw AIExecutionError.routeNotConfigured(feature)
        }
        guard !configured.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIExecutionError.modelNotConfigured(feature)
        }
        guard let provider = providers.first(where: { $0.id == configured.providerID }) else {
            throw AIExecutionError.providerNotFound(configured.providerID)
        }

        var system = system
        var prompt = prompt
        if !provider.isLocal, !allowSensitiveContent, let privacyText {
            let screening = PrivacyFilter.screen(privacyText)
            guard screening.canSendExternally else {
                throw AIExecutionError.privacyBlocked(screening.blockingMatches)
            }
            // 拦不住的那几类已经在上面挡掉了；剩下能遮的（手机号）遮掉再发。
            // 之前是整条拒发——一张带联系方式的招聘启事就能让整个检索不可用，
            // 而那个号码本来也不是用户想藏的秘密，是他自己存下来的联系方式。
            if !screening.matches.isEmpty {
                prompt = PrivacyFilter.redacted(prompt)
                system = system.map(PrivacyFilter.redacted)
            }
        }

        let descriptor = catalog.models(providerID: configured.providerID)
            .first { $0.id == configured.modelID }
        if let descriptor,
           !descriptor.inputModalities.contains(feature.requiredInputModality) {
            throw AIExecutionError.unsupportedInputModality(feature.requiredInputModality)
        }
        let resolution = profile.resolvedRoute(for: feature, model: descriptor)
            ?? RouteResolution(route: configured, notice: nil)
        let apiKey = try await credentialLoader(provider.id)
        return ExecutionPlan(
            provider: provider,
            apiKey: apiKey,
            input: .init(
                model: resolution.route.modelID,
                system: system,
                prompt: prompt,
                maxTokens: maxTokens,
                reasoningEffort: resolution.route.reasoningEffort,
                modelSupportsReasoning: descriptor?.supportsReasoning == true,
                image: image
            ),
            routeNotice: resolution.notice
        )
    }
}

public struct ItemAIEnrichment: Sendable, Equatable {
    public var title: String
    public var group: String?
    public var tags: [String]
    public var didGenerateTitle: Bool
    public var didGenerateClassification: Bool
    public var wasPrivacyBlocked: Bool

    public init(
        title: String,
        group: String? = nil,
        tags: [String] = [],
        didGenerateTitle: Bool = true,
        didGenerateClassification: Bool = true,
        wasPrivacyBlocked: Bool = false
    ) {
        self.title = title
        self.group = group
        self.tags = tags
        self.didGenerateTitle = didGenerateTitle
        self.didGenerateClassification = didGenerateClassification
        self.wasPrivacyBlocked = wasPrivacyBlocked
    }
}

public enum AIStructuredOutput {
    /// 容忍模型用 Markdown code fence 包裹 JSON，但只接受最外层对象。
    public static func objectData(from text: String) throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}"), start <= end {
            let candidate = String(trimmed[start...end])
            guard let data = candidate.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                throw AIExecutionError.malformedStructuredOutput
            }
            return data
        }
        throw AIExecutionError.malformedStructuredOutput
    }

    public static func enrichment(from text: String) throws -> ItemAIEnrichment {
        struct Payload: Decodable {
            var title: String
            var group: String?
            var tags: [String]?
        }
        let payload = try JSONDecoder().decode(Payload.self, from: objectData(from: text))
        let title = payload.title
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw AIExecutionError.malformedStructuredOutput }
        let tags = Array(Set((payload.tags ?? []).map {
            String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(16))
        }.filter { !$0.isEmpty })).sorted().prefix(5)
        return ItemAIEnrichment(
            title: String(title.prefix(40)),
            group: payload.group.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(20)) },
            tags: Array(tags),
            didGenerateTitle: true,
            didGenerateClassification: payload.group != nil || payload.tags != nil
        )
    }
}
