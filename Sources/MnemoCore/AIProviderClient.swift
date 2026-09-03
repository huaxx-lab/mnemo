import Foundation

public struct AIHTTPRequest: Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct AIHTTPResponse: Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol AIHTTPTransport: Sendable {
    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse
    /// 流式请求，逐块返回响应体。默认实现退化成一次性请求后整体产出一块，
    /// 因此不支持流的端点与测试替身无需各自实现。
    func stream(_ request: AIHTTPRequest) async throws -> AsyncThrowingStream<Data, any Error>
}

public extension AIHTTPTransport {
    func stream(_ request: AIHTTPRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        let response = try await send(request)
        if let error = AIHTTPStatus.error(for: response) { throw error }
        return AsyncThrowingStream { continuation in
            continuation.yield(response.body)
            continuation.finish()
        }
    }
}

/// HTTP 状态码到 ProviderError 的唯一映射，一次性请求与流式请求共用。
public enum AIHTTPStatus {
    public static func error(for response: AIHTTPResponse) -> ProviderError? {
        switch response.statusCode {
        case 200..<300:
            return nil
        case 401, 403:
            return .invalidCredential
        case 429:
            let value = response.headers.first {
                $0.key.caseInsensitiveCompare("Retry-After") == .orderedSame
            }?.value
            return .rateLimited(retryAfter: value.flatMap(TimeInterval.init))
        default:
            let message = (try? JSONSerialization.jsonObject(with: response.body))
                .flatMap { $0 as? [String: Any] }?["message"] as? String
            return .server(status: response.statusCode, message: message)
        }
    }
}

public final class URLSessionAITransport: AIHTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
            result[String(describing: entry.key)] = String(describing: entry.value)
        }
        return AIHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }

    public func stream(_ request: AIHTTPRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (field, value) in request.headers { urlRequest.setValue(value, forHTTPHeaderField: field) }
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let (bytes, response) = try await session.bytes(for: urlRequest)
        guard let http = response as? HTTPURLResponse else { throw ProviderError.invalidResponse }
        if !(200..<300).contains(http.statusCode) {
            // 错误体读全再抛：裸状态码对排查 BYOK 配置没有帮助。
            var body = Data()
            for try await byte in bytes { body.append(byte) }
            let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
            throw AIHTTPStatus.error(
                for: AIHTTPResponse(statusCode: http.statusCode, headers: headers, body: body)
            ) ?? ProviderError.invalidResponse
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // **绝不能用 `bytes.lines`**：它会把空行吞掉，而空行正是 SSE 的
                    // 事件边界。实测同一条 MiniMax 流，按行读得到 0 个事件，按字节
                    // 保留换行得到 10 个——上层于是判定"供应商不支持流式"，退回一次性
                    // 请求，表现就是"等半天再一次性全出来"。这里按字节切，原样保留 \n。
                    var line = Data()
                    for try await byte in bytes {
                        line.append(byte)
                        if byte == 0x0A {
                            continuation.yield(line)
                            line.removeAll(keepingCapacity: true)
                        }
                    }
                    if !line.isEmpty { continuation.yield(line) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

public enum ProviderError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case missingCredential
    case invalidCredential
    case rateLimited(retryAfter: TimeInterval?)
    case server(status: Int, message: String?)
    case invalidResponse
    case emptyOutput
    /// 流式端点在已产出部分正文后报告 token 上限。调用方必须把已落地内容
    /// 标为不完整，不能把正常断流误报成完整答案。
    case truncatedOutput
    case unsupportedEmbeddingDialect

    public var errorDescription: String? {
        switch self {
        case .invalidURL: "供应商地址无效"
        case .missingCredential: "尚未配置 API Key"
        case .invalidCredential: "密钥无效"
        case .rateLimited(let delay):
            delay.map { "请求过多，请在 \(Int($0)) 秒后重试" } ?? "请求过多，请稍后重试"
        case .server(let status, let message): "供应商返回 \(status)：\(message ?? "未知错误")"
        case .invalidResponse: "供应商响应格式无法识别"
        case .emptyOutput: "模型返回了空内容"
        case .truncatedOutput: "模型达到输出上限，回答没有生成完整"
        case .unsupportedEmbeddingDialect: "该供应商方言不支持 Embedding"
        }
    }
}

public struct ChatCompletionInput: Sendable, Equatable {
    public var model: String
    public var system: String?
    public var prompt: String
    public var maxTokens: Int
    public var reasoningEffort: AIReasoningEffort
    public var modelSupportsReasoning: Bool
    public var image: ChatImageInput?

    public init(
        model: String,
        system: String? = nil,
        prompt: String,
        maxTokens: Int = 512,
        reasoningEffort: AIReasoningEffort = .off,
        modelSupportsReasoning: Bool = false,
        image: ChatImageInput? = nil
    ) {
        self.model = model
        self.system = system
        self.prompt = prompt
        self.maxTokens = maxTokens
        self.reasoningEffort = reasoningEffort
        self.modelSupportsReasoning = modelSupportsReasoning
        self.image = image
    }
}

public struct ChatImageInput: Sendable, Equatable {
    public var mediaType: String
    public var base64Data: String

    public init(mediaType: String, base64Data: String) {
        self.mediaType = mediaType
        self.base64Data = base64Data
    }
}

public struct ChatCompletionOutput: Sendable, Equatable {
    public var text: String
    /// 模型这一轮的思考过程，来自结构化字段（`reasoning_content` / thinking 块）。
    /// 非流式路径同样要把它带出来——丢掉的话，同一个模型在流式界面上有思考、
    /// 在退回一次性请求时就凭空没有了，用户会以为是功能坏了。
    public var reasoning: String?
    public var inputTokens: Int?
    public var outputTokens: Int?
    /// 供应商明确表示是因为输出 token 上限而停止。调用方生成用户可见的完整答案时
    /// 必须拒绝发布这种半成品；排序 JSON 等结构化路径则会按解析失败处理。
    public var wasTruncated: Bool

    public init(
        text: String,
        reasoning: String? = nil,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        wasTruncated: Bool = false
    ) {
        self.text = text
        self.reasoning = reasoning
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.wasTruncated = wasTruncated
    }
}

public actor AIProviderClient {
    private let transport: any AIHTTPTransport

    public init(transport: any AIHTTPTransport = URLSessionAITransport()) {
        self.transport = transport
    }

    public func listModels(
        provider: ProviderConfiguration,
        apiKey: String?
    ) async throws -> [AIModelDescriptor] {
        let url = provider.modelsURL ?? provider.baseURL.appending(path: "models")
        let request = AIHTTPRequest(
            method: "GET",
            url: url,
            headers: try headers(for: provider, apiKey: apiKey)
        )
        let response = try await transport.send(request)
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: response.body)
        guard let root = object as? [String: Any] else { throw ProviderError.invalidResponse }
        let rawModels = (root["data"] as? [[String: Any]])
            ?? (root["models"] as? [[String: Any]])
            ?? []
        let models = rawModels.compactMap { raw -> AIModelDescriptor? in
            guard let id = (raw["id"] as? String) ?? (raw["model"] as? String), !id.isEmpty else {
                return nil
            }
            let name = (raw["display_name"] as? String) ?? (raw["name"] as? String) ?? id
            return AIModelDescriptor(id: id, displayName: name)
        }
        guard !models.isEmpty else { throw ProviderError.invalidResponse }
        return models.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func complete(
        provider: ProviderConfiguration,
        apiKey: String?,
        input: ChatCompletionInput
    ) async throws -> ChatCompletionOutput {
        let endpoint = provider.baseURL.appending(
            path: provider.dialect == .openAICompatible ? "chat/completions" : "messages"
        )
        let body = try chatBody(for: provider.dialect, input: input, streaming: false)
        var requestHeaders = try headers(for: provider, apiKey: apiKey)
        requestHeaders["Content-Type"] = "application/json"
        let response = try await transport.send(.init(
            method: "POST",
            url: endpoint,
            headers: requestHeaders,
            body: body
        ))
        try validate(response)
        return try decodeChat(response.body, dialect: provider.dialect)
    }

    /// 流式补全，逐段产出正文增量。两种方言的事件结构不同，这里统一成
    /// "只吐正文"：思考块、用量事件与心跳都被丢掉。
    public func streamComplete(
        provider: ProviderConfiguration,
        apiKey: String?,
        input: ChatCompletionInput
    ) async throws -> AsyncThrowingStream<AIStreamChunk, any Error> {
        let endpoint = provider.baseURL.appending(
            path: provider.dialect == .openAICompatible ? "chat/completions" : "messages"
        )
        let body = try chatBody(for: provider.dialect, input: input, streaming: true)
        var requestHeaders = try headers(for: provider, apiKey: apiKey)
        requestHeaders["Content-Type"] = "application/json"
        let raw = try await transport.stream(.init(
            method: "POST",
            url: endpoint,
            headers: requestHeaders,
            body: body
        ))
        let dialect = provider.dialect

        return AsyncThrowingStream { continuation in
            let task = Task {
                var parser = SSEParser()
                func emit(_ payload: String) throws -> Bool {
                    guard payload != SSEParser.doneSentinel else { return false }
                    // 最后一帧可能同时带最后几个字与 finish_reason。先交正文，再抛
                    // 截断状态；调用方能保留已经落进输入框的字，但不会误报完整。
                    for chunk in Self.chunks(from: payload, dialect: dialect)
                    where !chunk.value.isEmpty {
                        continuation.yield(chunk)
                    }
                    if Self.streamWasTruncated(payload, dialect: dialect) {
                        throw ProviderError.truncatedOutput
                    }
                    return true
                }
                do {
                    for try await chunk in raw {
                        for payload in parser.consume(chunk) {
                            guard try emit(payload) else {
                                continuation.finish()
                                return
                            }
                        }
                    }
                    for payload in parser.flush() {
                        guard try emit(payload) else { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func streamWasTruncated(
        _ payload: String,
        dialect: ProviderDialect
    ) -> Bool {
        guard let data = payload.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return false }
        switch dialect {
        case .openAICompatible:
            let choices = root["choices"] as? [[String: Any]]
            return (choices?.first?["finish_reason"] as? String) == "length"
        case .anthropicMessages:
            let delta = root["delta"] as? [String: Any]
            return (root["stop_reason"] as? String) == "max_tokens"
                || (delta?["stop_reason"] as? String) == "max_tokens"
        }
    }

    /// 思考过程在 OpenAI 兼容方言里的字段名。
    ///
    /// 这个字段不在 OpenAI 规范里，是各家推理模型各自加的扩展，名字还不统一：
    /// DeepSeek / Qwen / GLM / MiniMax 用 `reasoning_content`，OpenRouter 这类
    /// 网关透传成 `reasoning`。两个都认——认漏一个的后果不是少显示一段，而是
    /// 那家的模型在这里表现为"一直没有输出"，因为正文要等思考写完才开始。
    private static let openAIReasoningKeys = ["reasoning_content", "reasoning"]

    /// 既解流式增量，也兼容整份非流式响应——默认 transport 会把完整 JSON
    /// 当成一个负载送进来。
    ///
    /// 返回数组而不是单值：同一个负载里同时出现思考和正文是常态（思考的最后
    /// 一段和正文的第一段常常在同一帧），只返回其中一个就会丢字。
    static func chunks(from payload: String, dialect: ProviderDialect) -> [AIStreamChunk] {
        guard let data = payload.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return [] }
        var result: [AIStreamChunk] = []
        switch dialect {
        case .openAICompatible:
            let choice = (root["choices"] as? [[String: Any]])?.first
            // 增量帧与整份响应用的是不同的容器，字段名一样。
            for container in [choice?["delta"], choice?["message"]].compactMap({ $0 as? [String: Any] }) {
                for key in openAIReasoningKeys {
                    if let value = container[key] as? String, !value.isEmpty {
                        result.append(.reasoning(value))
                        break
                    }
                }
                if let value = container["content"] as? String, !value.isEmpty {
                    result.append(.text(value))
                }
            }
        case .anthropicMessages:
            if (root["type"] as? String) == "content_block_delta",
               let delta = root["delta"] as? [String: Any] {
                // thinking_delta 把内容放在 thinking 键里，text_delta 放在 text 里。
                if let value = delta["thinking"] as? String { result.append(.reasoning(value)) }
                if let value = delta["text"] as? String { result.append(.text(value)) }
            }
            if let content = root["content"] as? [[String: Any]] {
                for block in content {
                    switch block["type"] as? String {
                    case "thinking":
                        if let value = block["thinking"] as? String { result.append(.reasoning(value)) }
                    case "text":
                        if let value = block["text"] as? String { result.append(.text(value)) }
                    default:
                        continue
                    }
                }
            }
        }
        return result
    }

    public func embed(
        provider: ProviderConfiguration,
        apiKey: String?,
        model: String,
        input: String
    ) async throws -> [Float] {
        guard let first = try await embed(
            provider: provider,
            apiKey: apiKey,
            model: model,
            inputs: [input]
        ).first else { throw ProviderError.invalidResponse }
        return first
    }

    /// OpenAI 兼容端点原生接受字符串数组。一次批量提交显著减少长文档的
    /// 网络唤醒与限流概率，返回值按请求输入顺序排列。
    public func embed(
        provider: ProviderConfiguration,
        apiKey: String?,
        model: String,
        inputs: [String]
    ) async throws -> [[Float]] {
        guard provider.dialect == .openAICompatible else {
            throw ProviderError.unsupportedEmbeddingDialect
        }
        guard !inputs.isEmpty else { return [] }
        var requestHeaders = try headers(for: provider, apiKey: apiKey)
        requestHeaders["Content-Type"] = "application/json"
        let inputValue: Any = inputs.count == 1 ? inputs[0] : inputs
        let body = try JSONSerialization.data(withJSONObject: ["model": model, "input": inputValue])
        let response = try await transport.send(.init(
            method: "POST",
            url: provider.baseURL.appending(path: "embeddings"),
            headers: requestHeaders,
            body: body
        ))
        try validate(response)
        let object = try JSONSerialization.jsonObject(with: response.body)
        guard let root = object as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            throw ProviderError.invalidResponse
        }
        let ordered = data.enumerated().sorted { lhs, rhs in
            let left = (lhs.element["index"] as? NSNumber)?.intValue ?? lhs.offset
            let right = (rhs.element["index"] as? NSNumber)?.intValue ?? rhs.offset
            return left < right
        }
        let vectors = try ordered.map { entry -> [Float] in
            guard let numbers = entry.element["embedding"] as? [NSNumber], !numbers.isEmpty else {
                throw ProviderError.invalidResponse
            }
            return numbers.map(\.floatValue)
        }
        guard vectors.count == inputs.count else { throw ProviderError.invalidResponse }
        return vectors
    }

    private func headers(
        for provider: ProviderConfiguration,
        apiKey: String?
    ) throws -> [String: String] {
        var headers: [String: String] = [:]
        switch provider.authentication {
        case .none:
            break
        case .bearer:
            guard let apiKey, !apiKey.isEmpty else { throw ProviderError.missingCredential }
            headers["Authorization"] = "Bearer \(apiKey)"
        case .xAPIKey:
            guard let apiKey, !apiKey.isEmpty else { throw ProviderError.missingCredential }
            headers["X-Api-Key"] = apiKey
            headers["anthropic-version"] = "2023-06-01"
        }
        return headers
    }

    private func chatBody(
        for dialect: ProviderDialect,
        input: ChatCompletionInput,
        streaming: Bool
    ) throws -> Data {
        var body: [String: Any] = [
            "model": input.model,
            "max_tokens": input.maxTokens,
        ]
        if streaming { body["stream"] = true }
        switch dialect {
        case .openAICompatible:
            var messages: [[String: Any]] = []
            if let system = input.system { messages.append(["role": "system", "content": system]) }
            if let image = input.image {
                messages.append(["role": "user", "content": [
                    ["type": "text", "text": input.prompt],
                    ["type": "image_url", "image_url": [
                        "url": "data:\(image.mediaType);base64,\(image.base64Data)"
                    ]],
                ]])
            } else {
                messages.append(["role": "user", "content": input.prompt])
            }
            body["messages"] = messages
            if input.modelSupportsReasoning, input.reasoningEffort != .off {
                body["reasoning_effort"] = input.reasoningEffort.rawValue
                // 思考 token 也算在 max_tokens 里。调用方给的是**回答预算**，
                // 原样发出去等于让模型用同一份额度先想再答——想完就没了，
                // 返回一个 content 为空、finish_reason=length 的响应。
                //
                // 表现出来是"模型返回了空内容"：一次 60 秒的调用，没有任何结果，
                // 而且只发生在开了思考的模型上。Anthropic 那一支早就把两份预算
                // 加在一起了，这里漏了。
                body["max_tokens"] = reasoningBudget(input.reasoningEffort)
                    + max(1, input.maxTokens)
            }
        case .anthropicMessages:
            if let image = input.image {
                body["messages"] = [["role": "user", "content": [
                    ["type": "image", "source": [
                        "type": "base64",
                        "media_type": image.mediaType,
                        "data": image.base64Data,
                    ]],
                    ["type": "text", "text": input.prompt],
                ]]]
            } else {
                body["messages"] = [["role": "user", "content": input.prompt]]
            }
            if let system = input.system { body["system"] = system }
            if input.modelSupportsReasoning, input.reasoningEffort != .off {
                let budget = reasoningBudget(input.reasoningEffort)
                // Anthropic 方言要求 thinking budget 严格小于 max_tokens。调用方的
                // maxTokens 是“最终回答预算”，因此在 thinking 打开时把总预算扩为
                // thinking + 回答，而不是发一个 budget 比总预算还大的必败请求。
                body["max_tokens"] = budget + max(1, input.maxTokens)
                body["thinking"] = [
                    "type": "enabled",
                    "budget_tokens": budget,
                ]
            }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func decodeChat(_ data: Data, dialect: ProviderDialect) throws -> ChatCompletionOutput {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else { throw ProviderError.invalidResponse }
        let text: String?
        let wasTruncated: Bool
        let reasoning: String?
        switch dialect {
        case .openAICompatible:
            let choices = root["choices"] as? [[String: Any]]
            let message = choices?.first?["message"] as? [String: Any]
            text = message?["content"] as? String
            reasoning = Self.openAIReasoningKeys.lazy
                .compactMap { message?[$0] as? String }
                .first { !$0.isEmpty }
            wasTruncated = (choices?.first?["finish_reason"] as? String) == "length"
        case .anthropicMessages:
            let content = root["content"] as? [[String: Any]]
            text = content?.first(where: { ($0["type"] as? String) == "text" })?["text"] as? String
            reasoning = content?
                .first(where: { ($0["type"] as? String) == "thinking" })?["thinking"] as? String
            wasTruncated = (root["stop_reason"] as? String) == "max_tokens"
        }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            // 只有思考没有正文，而且是被上限截断的：预算全花在想上了。
            // 和"模型什么都没说"是两回事，报错要能指到那儿去。
            if wasTruncated, reasoning?.isEmpty == false { throw ProviderError.truncatedOutput }
            throw ProviderError.emptyOutput
        }
        let usage = root["usage"] as? [String: Any]
        return ChatCompletionOutput(
            text: text,
            reasoning: reasoning?.trimmingCharacters(in: .whitespacesAndNewlines),
            inputTokens: (usage?["prompt_tokens"] as? NSNumber)?.intValue
                ?? (usage?["input_tokens"] as? NSNumber)?.intValue,
            outputTokens: (usage?["completion_tokens"] as? NSNumber)?.intValue
                ?? (usage?["output_tokens"] as? NSNumber)?.intValue,
            wasTruncated: wasTruncated
        )
    }

    private func validate(_ response: AIHTTPResponse) throws {
        if let error = AIHTTPStatus.error(for: response) { throw error }
    }

    private func reasoningBudget(_ effort: AIReasoningEffort) -> Int {
        switch effort {
        case .off: 0
        case .low: 1_024
        case .medium: 4_096
        case .high: 8_192
        }
    }
}

public actor EmbeddingDimensionRegistry {
    private var dimensions: [String: Int]
    private let persistenceURL: URL?

    public init(dimensions: [String: Int] = [:], persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let persisted = try? JSONDecoder().decode([String: Int].self, from: data) {
            self.dimensions = persisted.merging(dimensions) { _, explicit in explicit }
        } else {
            self.dimensions = dimensions
        }
    }

    public func dimension(providerID: String, modelID: String) -> Int? {
        dimensions["\(providerID)::\(modelID)"]
    }

    @discardableResult
    public func recordOrDetectChange(
        providerID: String,
        modelID: String,
        vector: [Float]
    ) throws -> Bool {
        guard !vector.isEmpty else { throw ProviderError.invalidResponse }
        let key = "\(providerID)::\(modelID)"
        let changed = dimensions[key].map { $0 != vector.count } ?? false
        dimensions[key] = vector.count
        if let persistenceURL {
            let parent = persistenceURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            try JSONEncoder().encode(dimensions).write(to: persistenceURL, options: .atomic)
        }
        return changed
    }
}
