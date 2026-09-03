import Foundation
import Testing
@testable import MnemoCore

private actor RecordingTransport: AIHTTPTransport {
    private var responses: [AIHTTPResponse]
    private(set) var requests: [AIHTTPRequest] = []

    init(_ responses: [AIHTTPResponse]) { self.responses = responses }

    func send(_ request: AIHTTPRequest) async throws -> AIHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw ProviderError.invalidResponse }
        return responses.removeFirst()
    }

    func lastRequest() -> AIHTTPRequest? { requests.last }
    func requestCount() -> Int { requests.count }
}

private func jsonResponse(_ value: Any, status: Int = 200) throws -> AIHTTPResponse {
    AIHTTPResponse(statusCode: status, body: try JSONSerialization.data(withJSONObject: value))
}

@Test("N-18 两种协议方言使用各自端点、鉴权头与响应格式")
func providerDialectsEncodeIndependently() async throws {
    let anthropicTransport = RecordingTransport([
        try jsonResponse([
            "content": [
                ["type": "thinking", "thinking": "internal"],
                ["type": "text", "text": "完成"],
            ],
            "usage": ["input_tokens": 12, "output_tokens": 3],
        ]),
    ])
    let anthropicClient = AIProviderClient(transport: anthropicTransport)
    let minimax = try #require(ProviderPresets.configuration(id: "minimax"))
    let output = try await anthropicClient.complete(
        provider: minimax,
        apiKey: "test-credential",
        input: .init(
            model: "MiniMax-M2.7",
            prompt: "测试",
            reasoningEffort: .medium,
            modelSupportsReasoning: true
        )
    )
    #expect(output.text == "完成")
    let anthropicRequest = try #require(await anthropicTransport.lastRequest())
    #expect(anthropicRequest.url.path.hasSuffix("/anthropic/v1/messages"))
    #expect(anthropicRequest.headers["X-Api-Key"] == "test-credential")
    #expect(anthropicRequest.headers["Authorization"] == nil)
    let anthropicBody = try #require(
        try JSONSerialization.jsonObject(with: anthropicRequest.body ?? Data()) as? [String: Any]
    )
    let thinking = try #require(anthropicBody["thinking"] as? [String: Any])
    #expect((thinking["budget_tokens"] as? NSNumber)?.intValue == 4_096)

    let openAITransport = RecordingTransport([
        try jsonResponse(["choices": [["message": ["content": "ok"]]]]),
    ])
    let openAIClient = AIProviderClient(transport: openAITransport)
    let dashscope = try #require(ProviderPresets.configuration(id: "dashscope"))
    _ = try await openAIClient.complete(
        provider: dashscope,
        apiKey: "test-credential",
        input: .init(
            model: "qwen-test",
            prompt: "测试",
            reasoningEffort: .high,
            modelSupportsReasoning: false
        )
    )
    let openAIRequest = try #require(await openAITransport.lastRequest())
    #expect(openAIRequest.url.path.hasSuffix("/compatible-mode/v1/chat/completions"))
    #expect(openAIRequest.headers["Authorization"] == "Bearer test-credential")
    let openAIBody = try #require(
        try JSONSerialization.jsonObject(with: openAIRequest.body ?? Data()) as? [String: Any]
    )
    #expect(openAIBody["reasoning_effort"] == nil, "不支持思考的模型不得盲传参数")
}

@Test("图片输入按两种供应商方言编码，文字模型在请求前被门控")
func imageInputUsesDialectSpecificPayloadAndCapabilityGate() async throws {
    let image = ChatImageInput(mediaType: "image/jpeg", base64Data: "AQID")
    let openAITransport = RecordingTransport([
        try jsonResponse(["choices": [["message": ["content": "海边"]]]]),
    ])
    let openAIClient = AIProviderClient(transport: openAITransport)
    let dashscope = try #require(ProviderPresets.configuration(id: "dashscope"))
    _ = try await openAIClient.complete(
        provider: dashscope,
        apiKey: "test-credential",
        input: .init(model: "vision-model", prompt: "描述", image: image)
    )
    let openAIRequest = try #require(await openAITransport.lastRequest())
    let openAIBody = try #require(
        try JSONSerialization.jsonObject(with: openAIRequest.body ?? Data()) as? [String: Any]
    )
    let openAIMessages = try #require(openAIBody["messages"] as? [[String: Any]])
    let openAIContent = try #require(openAIMessages.last?["content"] as? [[String: Any]])
    let imageURL = try #require(openAIContent.last?["image_url"] as? [String: Any])
    #expect(imageURL["url"] as? String == "data:image/jpeg;base64,AQID")

    let anthropicTransport = RecordingTransport([
        try jsonResponse(["content": [["type": "text", "text": "海边"]]]),
    ])
    let anthropicClient = AIProviderClient(transport: anthropicTransport)
    let minimax = try #require(ProviderPresets.configuration(id: "minimax"))
    _ = try await anthropicClient.complete(
        provider: minimax,
        apiKey: "test-credential",
        input: .init(model: "MiniMax-M3", prompt: "描述", image: image)
    )
    let anthropicRequest = try #require(await anthropicTransport.lastRequest())
    let anthropicBody = try #require(
        try JSONSerialization.jsonObject(with: anthropicRequest.body ?? Data()) as? [String: Any]
    )
    let anthropicMessages = try #require(anthropicBody["messages"] as? [[String: Any]])
    let anthropicContent = try #require(anthropicMessages.first?["content"] as? [[String: Any]])
    let source = try #require(anthropicContent.first?["source"] as? [String: Any])
    #expect(source["media_type"] as? String == "image/jpeg")
    #expect(source["data"] as? String == "AQID")

    let blockedTransport = RecordingTransport([])
    let engine = AIExecutionEngine(client: AIProviderClient(transport: blockedTransport))
    let textOnlyCatalog = ModelCatalogSnapshot(providers: [
        .init(id: "minimax", displayName: "MiniMax", models: [
            .init(id: "MiniMax-M2.7", inputModalities: [.text]),
        ]),
    ])
    do {
        _ = try await engine.complete(
            feature: .imageUnderstanding,
            profile: .init(strong: .init(providerID: "minimax", modelID: "MiniMax-M2.7")),
            providers: [minimax],
            catalog: textOnlyCatalog,
            credentialLoader: { _ in "test-credential" },
            prompt: "描述",
            privacyText: "普通图片",
            image: image
        )
        Issue.record("文字模型不得接收图片请求")
    } catch let error as AIExecutionError {
        #expect(error == .unsupportedInputModality(.image))
    }
    #expect(await blockedTransport.requestCount() == 0)
}

@Test("供应商模型列表从官方端点一次读取并排序")
func providerModelListUsesOfficialEndpoint() async throws {
    let transport = RecordingTransport([
        try jsonResponse(["data": [
            ["id": "MiniMax-M2.7", "display_name": "M2.7"],
            ["id": "MiniMax-M2.5", "display_name": "M2.5"],
        ]]),
    ])
    let client = AIProviderClient(transport: transport)
    let provider = try #require(ProviderPresets.configuration(id: "minimax"))
    let models = try await client.listModels(provider: provider, apiKey: "test-credential")
    #expect(models.map(\.id) == ["MiniMax-M2.5", "MiniMax-M2.7"])
    let request = try #require(await transport.lastRequest())
    #expect(request.url.path.hasSuffix("/anthropic/v1/models"))
}

@Test("N-19 模型刷新完整成功后只发布一次，失败保留旧快照")
func modelCatalogPublishesAtomically() async throws {
    let original = ModelCatalogSnapshot(providers: [
        .init(id: "minimax", displayName: "MiniMax", models: [.init(id: "old")]),
    ])
    let store = ModelCatalogStore(bundled: original)
    do {
        _ = try await store.replaceModelsDevPayload(Data("{".utf8))
        Issue.record("非法 JSON 应失败")
    } catch {}
    #expect(await store.current() == original)
    #expect(await store.revision == 0)

    _ = try await store.replaceLiveModels(
        providerID: "minimax",
        displayName: "MiniMax",
        models: [.init(id: "new-b"), .init(id: "new-a")]
    )
    #expect(await store.current().models(providerID: "minimax").map(\.id) == ["new-a", "new-b"])
    #expect(await store.revision == 1)
}

@Test("models.dev 只补齐已适配供应商元数据，不扩大官方可用模型列表")
func modelsDevMetadataMergesWithoutReplacingAvailability() async throws {
    let original = ModelCatalogSnapshot(providers: [
        .init(id: "moonshot", displayName: "月之暗面", models: [
            .init(id: "kimi-current", displayName: "账号可见 Kimi"),
        ]),
        .init(id: "openai", displayName: "OpenAI", models: []),
    ])
    let payload: [String: Any] = [
        "moonshotai-cn": [
            "name": "Moonshot CN",
            "models": [
                "kimi-current": [
                    "name": "公共目录 Kimi",
                    "reasoning": true,
                    "modalities": ["input": ["text", "image"]],
                    "cost": ["input": 2.0, "output": 8.0],
                ],
                "not-visible-to-account": ["name": "不应加入", "modalities": ["input": ["text"]]],
            ],
        ],
        "openai": [
            "name": "OpenAI",
            "models": [
                "gpt-public": ["name": "GPT Public", "modalities": ["input": ["text"]]],
            ],
        ],
    ]
    let data = try JSONSerialization.data(withJSONObject: payload)
    let store = ModelCatalogStore(bundled: original)
    let merged = try await store.mergeModelsDevPayload(
        data,
        providerAliases: [
            "moonshot": ["moonshotai-cn"],
            "openai": ["openai"],
        ],
        eTag: "test-etag"
    )

    let moonshot = merged.models(providerID: "moonshot")
    #expect(moonshot.map(\.id) == ["kimi-current"])
    #expect(moonshot.first?.displayName == "账号可见 Kimi")
    #expect(moonshot.first?.supportsReasoning == true)
    #expect(moonshot.first?.inputPricePerMillion == Decimal(2))
    #expect(merged.models(providerID: "openai").map(\.id) == ["gpt-public"])
    #expect(merged.sourceETag == "test-etag")
}

@Test("N-39 每个 AI 功能可覆盖供应商、模型与思考强度")
func featureRoutesOverrideDefaultsAndGateReasoning() throws {
    let profile = AIRoutingProfile(
        fast: .init(providerID: "minimax", modelID: "fast", reasoningEffort: .low),
        strong: .init(providerID: "minimax", modelID: "strong", reasoningEffort: .high),
        overrides: [
            .automaticNaming: .init(providerID: "custom", modelID: "name-model", reasoningEffort: .medium),
        ]
    )
    #expect(profile.route(for: .automaticNaming)?.providerID == "custom")
    #expect(profile.route(for: .pdfQuestionAnswering)?.modelID == "strong")

    let unsupported = AIModelDescriptor(id: "name-model", supportsReasoning: false)
    let resolution = try #require(profile.resolvedRoute(for: .automaticNaming, model: unsupported))
    #expect(resolution.route.reasoningEffort == .off)
    #expect(resolution.notice != nil)
}

@Test("AI 执行入口按功能路由，并在网络请求前阻止敏感内容")
func aiExecutionEngineRoutesAndScreensPrivacy() async throws {
    let transport = RecordingTransport([
        try jsonResponse(["content": [["type": "text", "text": "{\"title\":\"报销论文\",\"group\":\"工作\",\"tags\":[\"论文\",\"报销\"]}"]]]),
        try jsonResponse(["content": [["type": "text", "text": "已获用户允许"]]]),
    ])
    let client = AIProviderClient(transport: transport)
    let engine = AIExecutionEngine(client: client)
    let minimax = try #require(ProviderPresets.configuration(id: "minimax"))
    let profile = AIRoutingProfile(
        fast: .init(providerID: "minimax", modelID: "MiniMax-M2.7", reasoningEffort: .medium)
    )
    let catalog = ModelCatalogSnapshot(providers: [
        .init(id: "minimax", displayName: "MiniMax", models: [
            .init(id: "MiniMax-M2.7", supportsReasoning: true),
        ]),
    ])
    let result = try await engine.complete(
        feature: .automaticNaming,
        profile: profile,
        providers: [minimax],
        catalog: catalog,
        credentialLoader: { _ in "test-credential" },
        prompt: "命名这段内容",
        privacyText: "一篇关于报销流程的论文"
    )
    #expect(result.providerID == "minimax")
    #expect(result.modelID == "MiniMax-M2.7")
    let request = try #require(await transport.lastRequest())
    let body = try #require(
        try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
    )
    #expect(body["model"] as? String == "MiniMax-M2.7")
    #expect(body["thinking"] != nil)

    let enrichment = try AIStructuredOutput.enrichment(from: "```json\n\(result.output.text)\n```")
    #expect(enrichment.title == "报销论文")
    #expect(enrichment.group == "工作")
    #expect(enrichment.tags == ["报销", "论文"])

    do {
        _ = try await engine.complete(
            feature: .automaticNaming,
            profile: profile,
            providers: [minimax],
            catalog: catalog,
            credentialLoader: { _ in "test-credential" },
            prompt: "不得发送",
            privacyText: "api_token-abcdefghijklmnop"
        )
        Issue.record("敏感内容必须在请求前被拦截")
    } catch let error as AIExecutionError {
        guard case .privacyBlocked = error else {
            Issue.record("应返回 privacyBlocked，实际 \(error)")
            return
        }
    }
    #expect(await transport.requestCount() == 1)

    _ = try await engine.complete(
        feature: .automaticNaming,
        profile: profile,
        providers: [minimax],
        catalog: catalog,
        credentialLoader: { _ in "test-credential" },
        prompt: "用户已明确允许",
        privacyText: "api_token-abcdefghijklmnop",
        allowSensitiveContent: true
    )
    #expect(await transport.requestCount() == 2, "逐条覆盖只应放行用户明确授权后的请求")
}

@Test("N-36 Embedding 维度取首次返回长度并检测变化")
func embeddingDimensionIsRuntimeDetected() async throws {
    let transport = RecordingTransport([
        try jsonResponse(["data": [["embedding": [0.1, 0.2, 0.3]]]]),
    ])
    let client = AIProviderClient(transport: transport)
    let provider = try #require(ProviderPresets.configuration(id: "dashscope"))
    let vector = try await client.embed(
        provider: provider,
        apiKey: "test-credential",
        model: "manually-entered-embedding-model",
        input: "probe"
    )
    let dimensions = EmbeddingDimensionRegistry()
    #expect(try await dimensions.recordOrDetectChange(
        providerID: provider.id,
        modelID: "manually-entered-embedding-model",
        vector: vector
    ) == false)
    #expect(await dimensions.dimension(
        providerID: provider.id,
        modelID: "manually-entered-embedding-model"
    ) == 3)
    #expect(try await dimensions.recordOrDetectChange(
        providerID: provider.id,
        modelID: "manually-entered-embedding-model",
        vector: [0, 1]
    ) == true)
}

@Test("Embedding 维度记录跨启动持久化")
func embeddingDimensionPersistsAcrossRegistryInstances() async throws {
    let root = URL.temporaryDirectory.appending(path: "mnemo-dimension-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appending(path: "dimensions.json")
    let first = EmbeddingDimensionRegistry(persistenceURL: file)
    #expect(try await first.recordOrDetectChange(
        providerID: "dashscope", modelID: "embedding", vector: [0, 1, 2]
    ) == false)

    let restored = EmbeddingDimensionRegistry(persistenceURL: file)
    #expect(await restored.dimension(providerID: "dashscope", modelID: "embedding") == 3)
    #expect(try await restored.recordOrDetectChange(
        providerID: "dashscope", modelID: "embedding", vector: [0, 1]
    ) == true)
}

@Test("Embedding 分块数组只发一次请求，并按响应 index 恢复输入顺序")
func embeddingBatchUsesOneRequestAndRestoresOrder() async throws {
    let transport = RecordingTransport([
        try jsonResponse(["data": [
            ["index": 1, "embedding": [0.0, 1.0]],
            ["index": 0, "embedding": [1.0, 0.0]],
        ]]),
    ])
    let client = AIProviderClient(transport: transport)
    let provider = try #require(ProviderPresets.configuration(id: "dashscope"))
    let vectors = try await client.embed(
        provider: provider,
        apiKey: "test-credential",
        model: "embedding-model",
        inputs: ["第一页", "第二页"]
    )
    #expect(vectors == [[1, 0], [0, 1]])
    #expect(await transport.requestCount() == 1)
    let request = try #require(await transport.lastRequest())
    let body = try #require(
        try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
    )
    #expect((body["input"] as? [String]) == ["第一页", "第二页"])
}

@Test("F-19 本地敏感筛查阻止常见凭据与通过校验位的号码外发")
func privacyFilterRunsLocally() {
    let result = PrivacyFilter.screen(
        "身份证 11010519491231002X，银行卡 4532015112830366，api_token-abcdefghijklmnop"
    )
    #expect(!result.canSendExternally)
    #expect(result.matches.contains(.chineseIdentityNumber))
    #expect(result.matches.contains(.bankCardNumber))
    #expect(result.matches.contains(.apiCredential))
}

@Test("N-40 场景模型只能排序白名单，低置信度不会自动产生危险动作")
func sceneRecognitionValidatesRecommendations() throws {
    let candidates = SceneRecognition.localCandidates(for: .init(
        kind: .text,
        text: "发票抬头：某公司；税号：123；开户行：某银行"
    ))
    #expect(candidates.contains { $0.id == .extractTaxNumber })

    let malicious = try JSONSerialization.data(withJSONObject: [
        "recommendations": [
            ["actionID": "deleteEverything", "confidence": 1.0, "reason": "bad"],
            ["actionID": "extractTaxNumber", "confidence": 0.2, "reason": "low"],
        ],
    ])
    let output = SceneRecognition.validatedRecommendations(modelJSON: malicious, candidates: candidates)
    #expect(output.count <= 3)
    #expect(output.allSatisfy { [.copy, .open, .preview].contains($0.id) })
}

@Test("N-23 查询昨天的图片先本地解析时间与类型")
func queryUnderstandingParsesDeterministicFilters() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let query = QueryUnderstanding.localParse("昨天那个跟报销有关的截图", now: now, calendar: calendar)
    #expect(query.kinds == [.image])
    #expect(query.startDate != nil)
    #expect(query.endDate != nil)
    #expect(query.semanticText.contains("报销"))
    let paperQuery = QueryUnderstanding.localParse("找那篇跨模态论文", now: now, calendar: calendar)
    #expect(paperQuery.kinds == [.pdf])
    #expect(VectorSearch.cosine([0, 0], [1, 1]) == 0)
    #expect(VectorSearch.cosine([1, 0], [1, 0]) == 1)
}

@Test("论文按最佳页块返回页码，图片 OCR 在没有视觉描述时仍可本地召回")
func semanticSearchAggregatesPaperPagesAndImageOCR() throws {
    let paper = Item(
        title: "多模态检索论文",
        kind: .pdf,
        holding: .inline("placeholder"),
        tags: ["论文"]
    )
    let image = Item(
        title: "会议截图",
        kind: .image,
        holding: .inline("placeholder")
    )
    let chunks = [
        ContentChunk(
            itemID: paper.id,
            ordinal: 0,
            pageNumber: 2,
            source: .pdfPage,
            text: "背景与相关工作",
            vector: [1, 0],
            embeddingModelID: "old-model",
            indexedAt: .now
        ),
        ContentChunk(
            itemID: paper.id,
            ordinal: 1,
            pageNumber: 7,
            source: .pdfPage,
            text: "核心方法讨论向量索引与跨模态语义检索",
            vector: [0, 1],
            embeddingModelID: "old-model",
            indexedAt: .now
        ),
        ContentChunk(
            itemID: image.id,
            ordinal: 0,
            source: .imageOCR,
            text: "量子计算项目周会 周五下午三点"
        ),
    ]

    let paperHits = SemanticSearch.rank(
        items: [paper, image],
        chunks: chunks,
        query: StructuredQuery(kinds: [.pdf], semanticText: "跨模态论文"),
        queryVector: [0, 1],
        currentEmbeddingModelID: "new-model"
    )
    #expect(paperHits.count == 1)
    #expect(paperHits.first?.itemID == paper.id)
    #expect(paperHits.first?.pageNumber == 7)
    #expect(paperHits.first?.isUsingStaleVector == true)

    var editedPaper = paper
    editedPaper.contentHash = nil
    let dirtyHits = SemanticSearch.rank(
        items: [editedPaper],
        chunks: chunks,
        query: StructuredQuery(kinds: [.pdf], semanticText: "跨模态论文"),
        queryVector: [0, 1],
        currentEmbeddingModelID: "old-model"
    )
    #expect(dirtyHits.first?.isUsingStaleVector == true, "内容版本变更时旧模型向量也必须标脏")

    let imageHits = SemanticSearch.rank(
        items: [paper, image],
        chunks: chunks,
        query: StructuredQuery(kinds: [.image], semanticText: "量子计算"),
        queryVector: nil,
        currentEmbeddingModelID: nil
    )
    #expect(imageHits.first?.itemID == image.id)
    #expect(imageHits.first?.source == .imageOCR)
    #expect(imageHits.first?.snippet.contains("量子计算") == true)


    let photoQuery = QueryUnderstanding.localParse("帮我找一张央视报道牛来的照片")
    #expect(photoQuery.kinds == [.image])
    #expect(photoQuery.semanticText.contains("央视报道牛来"))
    #expect(!photoQuery.semanticText.contains("照片"))
    #expect(!photoQuery.semanticText.contains("帮我"))

    let copiedRequest = QueryUnderstanding.localParse("给我发一张央视新闻报道牛来的图片")
    #expect(copiedRequest.kinds == [.image])
    #expect(copiedRequest.semanticText == "央视新闻报道牛来")

    // 剪贴板意图和查询解析共用同一份类型词表：给一边补了词，另一边必须也认得，
    // 否则检索没有类型过滤，一条正好含关键词的文字会把要找的图挤掉。
    let figureRequest = QueryUnderstanding.localParse("带有 test-time 的图")
    #expect(figureRequest.kinds == [.image])
    #expect(figureRequest.semanticText.contains("test-time"))
    #expect(ContentTypeVocabulary.kinds(in: "研究生数学建模的手册") == [.pdf])
    #expect(ContentTypeVocabulary.kinds(in: "图书馆几点关门").isEmpty)
}

@Test("Agent 检索推荐只能重排 RAG 候选并去除重复与未知 ID")
func agenticRetrievalRecommendationsAreCandidateBound() throws {
    let first = UUID()
    let second = UUID()
    let unknown = UUID()
    let payload = """
    {"recommendations":[
      {"itemID":"\(second.uuidString)","confidence":0.91,"reason":"最符合查询描述"},
      {"itemID":"\(unknown.uuidString)","confidence":0.99,"reason":"不在候选中"},
      {"itemID":"\(second.uuidString)","confidence":0.80,"reason":"重复"},
      {"itemID":"\(first.uuidString)","confidence":1.8,"reason":"包含补充证据"}
    ]}
    """.data(using: .utf8)!

    let recommendations = AgenticRetrieval.validatedRecommendations(
        modelJSON: payload,
        allowedItemIDs: [first, second]
    )
    #expect(recommendations.map(\.itemID) == [second, first])
    #expect(recommendations[1].confidence == 1)

    let hits = [
        SemanticSearchHit(itemID: first, snippet: "first", score: 0.8),
        SemanticSearchHit(itemID: second, snippet: "second", score: 0.7),
    ]
    #expect(AgenticRetrieval.reorder(hits, using: recommendations).map(\.itemID) == [second, first])
    #expect(AgenticRetrieval.selectedHits(from: hits, using: [recommendations[0]]).map(\.itemID) == [second])
    #expect(AgenticRetrieval.selectedHits(from: hits, using: []).isEmpty)
}

@Test("有效空推荐与格式错误必须区分，模型白名单会移除未选候选")
func retrievalSelectionDistinguishesEmptyFromMalformed() {
    let first = UUID()
    let second = UUID()
    let empty = #"{"recommendations":[]}"#.data(using: .utf8)!

    #expect(AgenticRetrieval.selection(
        modelJSON: empty,
        allowedItemIDs: [first, second]
    ) == .selected([]))
    #expect(AgenticRetrieval.selection(
        modelJSON: nil,
        allowedItemIDs: [first, second]
    ) == .malformed)
    #expect(AgenticRetrieval.selection(
        modelJSON: #"{"answer":"没有相关项"}"#.data(using: .utf8),
        allowedItemIDs: [first, second]
    ) == .malformed)

    let selected = RetrievalRecommendation(itemID: first, confidence: 0.9, reason: "相关")
    let hits = [
        SemanticSearchHit(itemID: first, snippet: "相关", score: 0.9),
        SemanticSearchHit(itemID: second, snippet: "无关", score: 0.8),
    ]
    #expect(AgenticRetrieval.selectedHits(from: hits, using: [selected]).map(\.itemID) == [first])
    #expect(AgenticRetrieval.selectedHits(from: hits, using: []).isEmpty)
}

@Test("模型只能指认库里已有的一段文字，不能自己写一个")
func copyTextMustComeFromLocalContent() {
    let note = """
    pi agent 的主页 https://pi.ai/agent
    备注：内测邀请码稍后补
    """

    // 逐字出现：可用
    #expect(CopyPayloadResolver.verified("https://pi.ai/agent", in: note) == "https://pi.ai/agent")
    // 空白差异容忍（模型常吃掉换行）
    #expect(CopyPayloadResolver.verified("pi agent   的主页", in: note) == "pi agent   的主页")
    // 改写过的网址必须拒绝——粘出去就是错的
    #expect(CopyPayloadResolver.verified("https://pi.ai/agents", in: note) == nil)
    #expect(CopyPayloadResolver.verified("https://www.pi.ai/agent", in: note) == nil)
    // 空、超长一律不算
    #expect(CopyPayloadResolver.verified("   ", in: note) == nil)
    #expect(CopyPayloadResolver.verified(nil, in: note) == nil)
    #expect(CopyPayloadResolver.verified(String(repeating: "a", count: 401), in: note) == nil)
}

@Test("推荐可以带上要复制的那一段")
func recommendationCarriesCopyText() {
    let first = UUID()
    let payload = """
    {"recommendations":[
      {"itemID":"\(first.uuidString)","confidence":0.9,"reason":"标题命中",
       "copyText":"https://pi.ai/agent"}
    ]}
    """.data(using: .utf8)!
    let recommendations = AgenticRetrieval.validatedRecommendations(
        modelJSON: payload,
        allowedItemIDs: [first]
    )
    #expect(recommendations.first?.copyText == "https://pi.ai/agent")

    // 没给就是没给，不能凭空补
    let bare = #"{"recommendations":[{"itemID":"\#(first.uuidString)","confidence":0.5,"reason":"x"}]}"#
    #expect(AgenticRetrieval.validatedRecommendations(
        modelJSON: bare.data(using: .utf8),
        allowedItemIDs: [first]
    ).first?.copyText == nil)
}

@Test("对话模型不能被当成 embedding 模型")
func embeddingModelDetectionRejectsChatModels() {
    func descriptor(_ id: String) -> AIModelDescriptor { AIModelDescriptor(id: id) }

    #expect(descriptor("text-embedding-3-large").looksLikeEmbeddingModel)
    #expect(descriptor("qwen3.7-text-embedding").looksLikeEmbeddingModel)
    #expect(descriptor("bge-m3").looksLikeEmbeddingModel)
    #expect(descriptor("voyage-3").looksLikeEmbeddingModel)

    #expect(!descriptor("MiniMax-M3").looksLikeEmbeddingModel)
    #expect(!descriptor("gpt-4o").looksLikeEmbeddingModel)
    #expect(!descriptor("claude-opus-4").looksLikeEmbeddingModel)
    // rerank 同族命名，但返回分数不是向量
    #expect(!descriptor("bge-reranker-v2").looksLikeEmbeddingModel)
}

@Test("快捷推荐控制器区分交付与回答，并把结果约束在本地候选")
func recommendationAgentDecisionRoutesIntentAndBoundsIDs() throws {
    let paper = UUID()
    let unknown = UUID()
    let answerPayload = """
    {"intent":"answer","recommendations":[
      {"itemID":"\(paper.uuidString)","confidence":0.93,"reason":"论文机制命中", "copyText":null},
      {"itemID":"\(unknown.uuidString)","confidence":1,"reason":"并非本地候选"}
    ]}
    """.data(using: .utf8)!

    guard case .selected(let answer) = AgenticRetrieval.decision(
        modelJSON: answerPayload,
        allowedItemIDs: [paper]
    ) else {
        Issue.record("有效的 answer 决策必须可解码")
        return
    }
    #expect(answer.intent == .answer)
    #expect(answer.recommendations.map(\.itemID) == [paper])

    let retrievePayload = """
    {"intent":"retrieve","recommendations":[
      {"itemID":"\(paper.uuidString)","confidence":0.8,"reason":"用户要原文件"}
    ]}
    """.data(using: .utf8)!
    guard case .selected(let retrieve) = AgenticRetrieval.decision(
        modelJSON: retrievePayload,
        allowedItemIDs: [paper]
    ) else {
        Issue.record("有效的 retrieve 决策必须可解码")
        return
    }
    #expect(retrieve.intent == .retrieve)

    // 旧搜索流不带 intent，继续解释成 retrieve；显式未知动作则拒绝，不能误复制。
    let legacy = """
    {"recommendations":[{"itemID":"\(paper.uuidString)","confidence":0.7,"reason":"旧格式"}]}
    """.data(using: .utf8)!
    guard case .selected(let legacyDecision) = AgenticRetrieval.decision(
        modelJSON: legacy,
        allowedItemIDs: [paper]
    ) else {
        Issue.record("旧推荐信封必须兼容")
        return
    }
    #expect(legacyDecision.intent == .retrieve)
    #expect(AgenticRetrieval.decision(
        modelJSON: legacy,
        allowedItemIDs: [paper],
        requiresExplicitIntent: true
    ) == .malformed, "Command-G 缺 intent 时必须修复，不能默认交付文件")
    let invalid = """
    {"intent":"summarize","recommendations":[{"itemID":"\(paper.uuidString)","confidence":1,"reason":"x"}]}
    """.data(using: .utf8)!
    #expect(AgenticRetrieval.decision(
        modelJSON: invalid,
        allowedItemIDs: [paper]
    ) == .malformed)
}

@Test("Few-shot 跨内容类型成对区分原对象与知识结果")
func recommendationIntentFewShotPairsDeliveryAndAnswer() {
    let examples = RecommendationIntentFewShot.examples
    func intent(_ request: String) -> RecommendationResponseIntent? {
        examples.first { $0.request == request }?.intent
    }

    // PDF / 文档
    #expect(intent("把 CSA-UD 的 PDF 给我") == .retrieve)
    #expect(intent("CSA-UD 讲了什么") == .answer)
    // 图片
    #expect(intent("把那张网络拓扑图给我") == .retrieve)
    #expect(intent("这张网络拓扑图说明了什么") == .answer)
    // 链接 / 网页
    #expect(intent("给我 pi agent 的网址") == .retrieve)
    #expect(intent("pi agent 那个页面主要介绍什么") == .answer)
    // 表格 / 数据
    #expect(intent("把上季度的数据表发我") == .retrieve)
    #expect(intent("上季度的数据反映了什么趋势") == .answer)
    // 日志
    #expect(intent("复制昨晚那段错误日志") == .retrieve)
    #expect(intent("昨晚的错误日志说明为什么失败") == .answer)
    // 代码
    #expect(intent("把部署脚本发我") == .retrieve)
    #expect(intent("这个部署脚本做了什么，有什么风险") == .answer)
    // 普通文字 / 记录
    #expect(intent("把会议记录原文给我") == .retrieve)
    #expect(intent("总结会议结论和待办") == .answer)
    // 英文
    #expect(intent("Send me the terminal guide PDF") == .retrieve)
    #expect(intent("What does the terminal guide explain?") == .answer)

    let kinds = Set(examples.map(\.intent))
    #expect(kinds == [.retrieve, .answer])
    #expect(RecommendationIntentFewShot.promptBlock.contains(#"{"intent":"answer"}"#))
    #expect(RecommendationIntentFewShot.promptBlock.contains(#"{"intent":"retrieve"}"#))
}

@Test("回答和交付只投影一个输出通道")
func recommendationAgentOutputIsExclusive() {
    let paper = UUID()
    let answer = RecommendationAgentDecision(
        intent: .answer,
        recommendations: [.init(itemID: paper, confidence: 0.9, reason: "证据")]
    )
    let retrieve = RecommendationAgentDecision(
        intent: .retrieve,
        recommendations: [.init(itemID: paper, confidence: 0.9, reason: "交付")]
    )

    #expect(answer.output(selectedItemIDs: [paper]) == .answer(evidenceItemIDs: [paper]))
    #expect(retrieve.output(selectedItemIDs: [paper]) == .deliver(itemIDs: [paper]))
}

@Test("唯一结果自动复制只保留给 retrieve")
func uniqueResultAutoCopyRequiresRetrieveIntent() {
    let itemID = UUID()
    let selected = [itemID]
    let evidenced: Set<UUID> = [itemID]
    let retrieve = RecommendationAgentDecision(
        intent: .retrieve,
        recommendations: [.init(itemID: itemID, confidence: 0.9, reason: "唯一交付")]
    )
    let answer = RecommendationAgentDecision(
        intent: .answer,
        recommendations: [.init(itemID: itemID, confidence: 0.9, reason: "唯一证据")]
    )

    #expect(RecommendationAutoCopyPolicy.convergedTarget(
        decision: retrieve,
        selectedItemIDs: selected,
        locallyEvidencedItemIDs: evidenced,
        modelWasAvailable: true,
        hasSensitiveIntent: false
    ) == itemID)
    #expect(RecommendationAutoCopyPolicy.convergedTarget(
        decision: answer,
        selectedItemIDs: selected,
        locallyEvidencedItemIDs: evidenced,
        modelWasAvailable: true,
        hasSensitiveIntent: false
    ) == nil)
    #expect(RecommendationAutoCopyPolicy.convergedTarget(
        decision: retrieve,
        selectedItemIDs: selected,
        locallyEvidencedItemIDs: [],
        modelWasAvailable: true,
        hasSensitiveIntent: false
    ) == nil)
    #expect(RecommendationAutoCopyPolicy.convergedTarget(
        decision: retrieve,
        selectedItemIDs: selected,
        locallyEvidencedItemIDs: evidenced,
        modelWasAvailable: true,
        hasSensitiveIntent: true
    ) == nil)
}

@Test("完整快捷回答自动写入剪贴板且状态取决于真实写入结果")
func completedAnswerAutoCopyPublishesActualWriteOutcome() {
    var copied: [String] = []
    let success = RecommendationAutoCopyPolicy.answerDelivery(answer: "  完整中文回答。  ") {
        copied.append($0)
        return true
    }
    #expect(success?.answer == "完整中文回答。")
    #expect(success?.didWrite == true)
    #expect(success?.errorMessage == nil)
    #expect(copied == ["完整中文回答。"])

    let failure = RecommendationAutoCopyPolicy.answerDelivery(answer: "回答") { _ in false }
    #expect(failure?.answer == "回答")
    #expect(failure?.didWrite == false)
    #expect(failure?.errorMessage != nil)

    var emptyWriteWasCalled = false
    #expect(RecommendationAutoCopyPolicy.answerDelivery(answer: "   ") { _ in
        emptyWriteWasCalled = true
        return true
    } == nil)
    #expect(!emptyWriteWasCalled, "空 / 失败回答不能覆盖剪贴板")
}

@Test("answer 输出会丢弃模型附带的 copyText")
func answerDecisionCannotCarryCopyPayload() {
    let itemID = UUID()
    let payload = """
    {"intent":"answer","recommendations":[
      {"itemID":"\(itemID.uuidString)","confidence":0.9,"reason":"用于回答", "copyText":"不应复制"}
    ]}
    """.data(using: .utf8)!
    guard case .selected(let decision) = AgenticRetrieval.decision(
        modelJSON: payload,
        allowedItemIDs: [itemID]
    ) else {
        Issue.record("answer 决策必须可解析")
        return
    }
    #expect(decision.recommendations.first?.copyText == nil)
}

@Test("快捷回答证据选择不再使用 180 字候选截断")
func recommendationAnswerEvidenceUsesFullLocalChunks() {
    let itemID = UUID()
    // 故意把命中放到 2,400 字之后，确保取的是命中窗口而非页首硬截断。
    let prefix = String(repeating: "背景材料。", count: 520)
    let mechanism = "CSA-UD 使用位图引导的缓冲区映射结构，并通过无序交付减少重排等待。"
    let chunks = [
        ContentChunk(
            itemID: itemID,
            ordinal: 0,
            pageNumber: 1,
            source: .pdfPage,
            text: prefix + mechanism
        ),
        ContentChunk(
            itemID: itemID,
            ordinal: 1,
            pageNumber: 2,
            source: .pdfPage,
            text: "另一页讨论实验设置。"
        ),
    ]
    let excerpts = RecommendationAnswerEvidenceSelector.select(
        chunks: chunks,
        query: "CSA-UD 核心观点",
        queryVector: nil
    )
    #expect(excerpts.first?.contains(mechanism) == true)
    #expect(excerpts.first?.count ?? 0 > 180)
    #expect(excerpts.first?.hasPrefix("[第 1 页]") == true)
}

@Test("补全响应识别两种协议的 token 上限截断")
func completionOutputReportsProviderTruncation() async throws {
    let openAITransport = RecordingTransport([
        try jsonResponse([
            "choices": [[
                "message": ["content": "只输出了一半"],
                "finish_reason": "length",
            ]],
        ]),
    ])
    let openAIClient = AIProviderClient(transport: openAITransport)
    let dashscope = try #require(ProviderPresets.configuration(id: "dashscope"))
    let openAIOutput = try await openAIClient.complete(
        provider: dashscope,
        apiKey: "test-credential",
        input: .init(model: "qwen-test", prompt: "测试")
    )
    #expect(openAIOutput.wasTruncated)

    let anthropicTransport = RecordingTransport([
        try jsonResponse([
            "content": [["type": "text", "text": "同样只到半句"]],
            "stop_reason": "max_tokens",
        ]),
    ])
    let anthropicClient = AIProviderClient(transport: anthropicTransport)
    let minimax = try #require(ProviderPresets.configuration(id: "minimax"))
    let anthropicOutput = try await anthropicClient.complete(
        provider: minimax,
        apiKey: "test-credential",
        input: .init(model: "MiniMax-M3", prompt: "测试")
    )
    #expect(anthropicOutput.wasTruncated)
}

@Test("追问内容的请求即使点名了对象，也会被纠正成 answer 并丢掉复制载荷")
func intentFloorCorrectsExplanationRequests() {
    let item = UUID()
    let retrieveDecision = RecommendationAgentDecision(
        intent: .retrieve,
        recommendations: [
            RetrievalRecommendation(
                itemID: item, confidence: 0.9, reason: "命中", copyText: "一段原文"
            )
        ]
    )

    // 实测失败样本：点名了截图，追问的却是内容。
    let corrected = retrieveDecision.correctedByIntentFloor(request: "qkv 截图里讲了什么")
    #expect(corrected.intent == .answer)
    #expect(corrected.recommendations.first?.copyText == nil)
    #expect(corrected.recommendations.first?.itemID == item)

    // 真的要原对象时不得改判，否则"把截图发我"会变成生成一段话。
    #expect(retrieveDecision.correctedByIntentFloor(request: "把 qkv 截图发我").intent == .retrieve)
    // "把总结发我"要的是那份总结文件本身，"总结"二字不能当作追问内容。
    #expect(retrieveDecision.correctedByIntentFloor(request: "把总结发我").intent == .retrieve)
    // 模型已经判成 answer 的不受影响。
    let answerDecision = RecommendationAgentDecision(intent: .answer, recommendations: [])
    #expect(answerDecision.correctedByIntentFloor(request: "把截图发我").intent == .answer)
}

@Test("思考预算永远小于总输出预算，短 JSON 任务不会发出必败请求")
func reasoningBudgetNeverExceedsMaxTokens() async throws {
    // 这是"OCR 明明成功、待办却时有时无"的直接成因：待办协调只给 220 token，
    // 而继承来的低思考预算是 1024，Anthropic 方言要求 budget < max_tokens，
    // 于是每一次请求都被供应商拒绝，错误又被上层降级成静默。
    let transport = RecordingTransport([
        try jsonResponse([
            "content": [["type": "text", "text": "{}"]],
            "usage": ["input_tokens": 10, "output_tokens": 2],
        ]),
    ])
    let client = AIProviderClient(transport: transport)
    let minimax = try #require(ProviderPresets.configuration(id: "minimax"))
    _ = try await client.complete(
        provider: minimax,
        apiKey: "test-credential",
        input: .init(
            model: "MiniMax-M3",
            prompt: "短任务",
            maxTokens: 220,
            reasoningEffort: .low,
            modelSupportsReasoning: true
        )
    )
    let request = try #require(await transport.lastRequest())
    let body = try #require(
        try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
    )
    let maxTokens = try #require((body["max_tokens"] as? NSNumber)?.intValue)
    let thinking = try #require(body["thinking"] as? [String: Any])
    let budget = try #require((thinking["budget_tokens"] as? NSNumber)?.intValue)

    #expect(budget < maxTokens, "思考预算 \(budget) 必须小于总预算 \(maxTokens)")
    // 调用方要的 220 token 回答空间必须还在，不能被思考吃掉。
    #expect(maxTokens - budget >= 220)
}

@Test("关闭思考时总预算就是调用方给的数字，不额外膨胀")
func maxTokensUnchangedWithoutReasoning() async throws {
    let transport = RecordingTransport([
        try jsonResponse(["content": [["type": "text", "text": "ok"]]]),
    ])
    let client = AIProviderClient(transport: transport)
    let minimax = try #require(ProviderPresets.configuration(id: "minimax"))
    _ = try await client.complete(
        provider: minimax,
        apiKey: "test-credential",
        input: .init(model: "MiniMax-M3", prompt: "短任务", maxTokens: 220)
    )
    let request = try #require(await transport.lastRequest())
    let body = try #require(
        try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any]
    )
    #expect((body["max_tokens"] as? NSNumber)?.intValue == 220)
    #expect(body["thinking"] == nil)
}
