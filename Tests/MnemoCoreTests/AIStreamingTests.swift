import Foundation
import Testing
@testable import MnemoCore

/// 按给定的字节切分产出流，用来复现"网络分片和事件边界无关"这件事。
private actor ChunkedTransport: AIHTTPTransport {
    private let chunks: [Data]
    private(set) var requests: [AIHTTPRequest] = []

    init(chunks: [Data]) { self.chunks = chunks }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        return AIHTTPResponse(statusCode: 200, body: chunks.reduce(into: Data()) { $0 += $1 })
    }

    func stream(_ request: AIHTTPRequest) async throws -> AsyncThrowingStream<Data, any Error> {
        requests.append(request)
        let chunks = chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }

    func lastRequest() -> AIHTTPRequest? { requests.last }
}

private let openAIProvider = ProviderConfiguration(
    id: "test-openai",
    displayName: "Test",
    dialect: .openAICompatible,
    baseURL: URL(string: "https://example.invalid/v1/")!,
    iconID: "test"
)

private let anthropicProvider = ProviderConfiguration(
    id: "test-anthropic",
    displayName: "Test",
    dialect: .anthropicMessages,
    baseURL: URL(string: "https://example.invalid/v1/")!,
    authentication: .xAPIKey,
    iconID: "test"
)

@Test("SSE 负载被任意切分后仍能还原成完整事件")
func sseParserReassemblesSplitFrames() {
    var parser = SSEParser()
    // 把一条事件从 "cont" 和 "ent" 之间切开，边界落在 JSON 字符串内部。
    var payloads = parser.consume(Data(#"data: {"a":"cont"#.utf8))
    #expect(payloads.isEmpty)
    payloads += parser.consume(Data("ent\"}\n\n".utf8))
    #expect(payloads == [#"{"a":"content"}"#])
}

@Test("SSE 忽略心跳与非 data 字段，并识别结束哨兵")
func sseParserSkipsCommentsAndFields() {
    var parser = SSEParser()
    let raw = ": ping\nevent: message\ndata: {\"n\":1}\n\nid: 7\ndata: [DONE]\n\n"
    let payloads = parser.consume(Data(raw.utf8))
    #expect(payloads == ["{\"n\":1}", SSEParser.doneSentinel])
}

@Test("SSE 最后一行没有换行结尾时 flush 也能结算")
func sseParserFlushesTrailingLine() {
    var parser = SSEParser()
    #expect(parser.consume(Data("data: {\"n\":1}".utf8)).isEmpty)
    #expect(parser.flush() == ["{\"n\":1}"])
}

@Test("OpenAI 方言的流式增量被拼成完整文本，并带上 stream 标记")
func streamCompleteDecodesOpenAIDeltas() async throws {
    let chunks = [
        Data("data: {\"choices\":[{\"delta\":{\"content\":\"讲 RDMA \"}}]}\n\n".utf8),
        Data("data: {\"choices\":[{\"delta\":{\"content\":\"的论文有一篇\"}}]}\n\n".utf8),
        Data("data: [DONE]\n\n".utf8),
    ]
    let transport = ChunkedTransport(chunks: chunks)
    let client = AIProviderClient(transport: transport)

    let stream = try await client.streamComplete(
        provider: openAIProvider,
        apiKey: "k",
        input: .init(model: "m", prompt: "q")
    )
    var text = ""
    for try await chunk in stream { text += chunk.value }
    #expect(text == "讲 RDMA 的论文有一篇")

    let body = try #require(await transport.lastRequest()?.body)
    let decoded = try JSONSerialization.jsonObject(with: body)
    let root = try #require(decoded as? [String: Any])
    #expect(root["stream"] as? Bool == true)
}

@Test("Anthropic 方言只取 content_block_delta 的正文")
func streamCompleteDecodesAnthropicDeltas() async throws {
    let chunks = [
        Data("data: {\"type\":\"message_start\"}\n\n".utf8),
        Data("data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"税号在\"}}\n\n".utf8),
        Data("data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"发票那张图里\"}}\n\n".utf8),
        Data("data: {\"type\":\"message_stop\"}\n\n".utf8),
    ]
    let client = AIProviderClient(transport: ChunkedTransport(chunks: chunks))
    let stream = try await client.streamComplete(
        provider: anthropicProvider,
        apiKey: "k",
        input: .init(model: "m", prompt: "q")
    )
    var text = ""
    for try await chunk in stream { text += chunk.value }
    #expect(text == "税号在发票那张图里")
}

@Test("非流式响应走默认 transport 时仍能产出完整文本")
func streamCompleteFallsBackToWholeResponse() async throws {
    // 默认 stream 实现把整份 JSON 当成一个负载，没有 data: 前缀。
    let body = Data("data: {\"choices\":[{\"message\":{\"content\":\"整份响应\"}}]}\n\n".utf8)
    let client = AIProviderClient(transport: ChunkedTransport(chunks: [body]))
    let stream = try await client.streamComplete(
        provider: openAIProvider,
        apiKey: "k",
        input: .init(model: "m", prompt: "q")
    )
    var text = ""
    for try await chunk in stream { text += chunk.value }
    #expect(text == "整份响应")
}

@Test("流式回答把分隔符前的总结上屏，分隔符后的推荐只认库里真实存在的 Pin")
func agenticAnswerSplitsSummaryFromRecommendations() {
    let known = UUID()
    let unknown = UUID()
    var accumulator = AgenticAnswerAccumulator()
    accumulator.consume("库里有一篇讲 RDMA 的论文。")
    accumulator.consume("\n---PINS---\n{\"recommendations\":[")
    accumulator.consume("{\"itemID\":\"\(known.uuidString)\",\"confidence\":0.9,\"reason\":\"标题命中\"},")
    accumulator.consume("{\"itemID\":\"\(unknown.uuidString)\",\"confidence\":1,\"reason\":\"模型编的\"}]}")

    #expect(accumulator.displaySummary == "库里有一篇讲 RDMA 的论文。")
    let recommendations = accumulator.recommendations(allowedItemIDs: [known])
    #expect(recommendations.map(\.itemID) == [known])
}

@Test("分隔符被切成两半时，残缺前缀不会闪到界面上")
func agenticAnswerHidesPartialDelimiter() {
    var accumulator = AgenticAnswerAccumulator()
    accumulator.consume("找到了。\n---PI")
    #expect(accumulator.displaySummary == "找到了。")
    accumulator.consume("NS---\n{\"recommendations\":[]}")
    #expect(accumulator.displaySummary == "找到了。")
}

@Test("模型把推荐 JSON 包在围栏或多余文字里也能取出")
func agenticAnswerExtractsFencedJSON() {
    let id = UUID()
    var accumulator = AgenticAnswerAccumulator()
    accumulator.consume("好的。\n---PINS---\n```json\n")
    accumulator.consume("{\"recommendations\":[{\"itemID\":\"\(id.uuidString)\",\"confidence\":0.5,\"reason\":\"r\"}]}")
    accumulator.consume("\n```\n就这些。")
    #expect(accumulator.recommendations(allowedItemIDs: [id]).count == 1)
}

@Test("没有推荐段时总结照常可用，卡片为空而不是报错")
func agenticAnswerWithoutRecommendations() {
    var accumulator = AgenticAnswerAccumulator()
    accumulator.consume("库里没有相关内容。")
    #expect(accumulator.displaySummary == "库里没有相关内容。")
    #expect(accumulator.recommendations(allowedItemIDs: [UUID()]).isEmpty)
}

@Test("模型忘了写分隔符时，推荐照样取得到，JSON 不会糊在总结里")
func agenticAnswerRecoversWhenDelimiterIsMissing() {
    let id = UUID()
    var accumulator = AgenticAnswerAccumulator()
    accumulator.consume("库里有一篇讲 RDMA 的论文。\n")
    accumulator.consume("{\"recommendations\":[{\"itemID\":\"\(id.uuidString)\",\"confidence\":0.8,\"reason\":\"标题命中\"}]}")

    #expect(accumulator.recommendations(allowedItemIDs: [id]).map(\.itemID) == [id])
    #expect(accumulator.finalizedSummary == "库里有一篇讲 RDMA 的论文。")
}

@Test("OpenAI 流达到 token 上限时先保留已到正文，再明确报截断")
func openAIStreamReportsTruncation() async throws {
    let chunks = [
        Data("data: {\"choices\":[{\"delta\":{\"content\":\"这是一段未完\"}}]}\n\n".utf8),
        Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"length\"}]}\n\n".utf8),
    ]
    let client = AIProviderClient(transport: ChunkedTransport(chunks: chunks))
    let stream = try await client.streamComplete(
        provider: openAIProvider,
        apiKey: "k",
        input: .init(model: "m", prompt: "q")
    )
    var text = ""
    do {
        for try await chunk in stream { text += chunk.value }
        Issue.record("token 上限必须以截断错误结束")
    } catch let error as ProviderError {
        #expect(error == .truncatedOutput)
    }
    #expect(text == "这是一段未完")
}

@Test("Anthropic message_delta 的 max_tokens 也不能冒充正常结束")
func anthropicStreamReportsTruncation() async throws {
    let chunks = [
        Data("data: {\"type\":\"content_block_delta\",\"delta\":{\"text\":\"半句\"}}\n\n".utf8),
        Data("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"}}\n\n".utf8),
    ]
    let client = AIProviderClient(transport: ChunkedTransport(chunks: chunks))
    let stream = try await client.streamComplete(
        provider: anthropicProvider,
        apiKey: "k",
        input: .init(model: "m", prompt: "q")
    )
    var text = ""
    do {
        for try await chunk in stream { text += chunk.value }
        Issue.record("token 上限必须以截断错误结束")
    } catch let error as ProviderError {
        #expect(error == .truncatedOutput)
    }
    #expect(text == "半句")
}

@Test("空行是 SSE 的事件边界：丢掉它就一个事件都解不出来")
func sseParserNeedsBlankLineBoundaries() {
    // 真实回归：URLSession 的 `bytes.lines` 会吞掉空行。少了边界，data 行只会
    // 一直堆积，直到流结束才被拼成一坨非法 JSON，上层看到的是"零增量"。
    var withoutBlanks = SSEParser()
    var payloads = withoutBlanks.consume(Data("data: {\"n\":1}\n".utf8))
    payloads += withoutBlanks.consume(Data("data: {\"n\":2}\n".utf8))
    #expect(payloads.isEmpty, "没有空行就不该产出事件")

    var withBlanks = SSEParser()
    var streamed = withBlanks.consume(Data("data: {\"n\":1}\n".utf8))
    streamed += withBlanks.consume(Data("\n".utf8))
    streamed += withBlanks.consume(Data("data: {\"n\":2}\n".utf8))
    streamed += withBlanks.consume(Data("\n".utf8))
    #expect(streamed == ["{\"n\":1}", "{\"n\":2}"])
}
