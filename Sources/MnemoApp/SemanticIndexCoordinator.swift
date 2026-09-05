import Foundation
import MnemoCore

struct IndexingRunResult: Sendable {
    var completed: Bool
    var dimensionChanged: Bool
    var waitingForEmbedding: Bool = false
    var autoRetryAfter: TimeInterval?
}

/// 一条链接配图的 OCR 是否还是"当前那一次"。
///
/// OCR 现在跑在后台、不挡这次索引算不算完成（见下面 `index` 里的说明）。
/// 问题是它跑得慢，跑的这几秒到几十秒里，同一条链接完全可能又被重新解析
/// 一次——旧的那次 OCR 跑完之后绝不能拿着过时的结果去覆盖新的一轮已经
/// 落好的内容。用一个按条目 id 递增的代次挡住："我出发时是第几代，落盘前
/// 还是不是当前代"，不是就悄悄放弃，交给取代它的那一轮自己写。
private actor ImageOCRGenerationTracker {
    static let shared = ImageOCRGenerationTracker()
    private var generations: [UUID: Int] = [:]

    func next(for itemID: UUID) -> Int {
        let value = (generations[itemID] ?? 0) + 1
        generations[itemID] = value
        return value
    }

    func isCurrent(_ generation: Int, for itemID: UUID) -> Bool {
        generations[itemID] == generation
    }
}

struct SemanticSearchRun: Sendable {
    var hits: [SemanticSearchHit]
    var understoodQuery: StructuredQuery
    var recommendations: [RetrievalRecommendation] = []
    /// 交给模型的白名单。它只能在这里面选，但这里不再只有词法/向量命中的
    /// 条目——否则没配 embedding 时"讲 rdma 的论文"这种自然语言永远是空。
    var candidates: [RetrievalRankingCandidate] = []
}

enum SemanticIndexCoordinator {
    static func index(
        item: Item,
        library: Library,
        settings: ProviderSettingsModel,
        forceRefreshLink: Bool = false
    ) async -> IndexingRunResult {
        var chunks = await SemanticContentExtractor.extract(item: item, library: library)
        // 上一版分块。图片的画面描述是这条管线里最贵的一次调用（一张图连着
        // 一次视觉请求），而它只取决于图片本身——OCR 和标签一字不差就说明
        // 图片没变，那段描述也就还成立。
        //
        // 不复用的代价是实打实的：没配 embedding 时 `indexedAt` 会被留空，
        // 于是每次启动、每次网络恢复、每次改 Embedding 设置，队列都会把这些
        // 图片重新捡回来跑一遍，每一遍都重新问一次视觉模型。
        let previousChunks = (try? await library.chunks(for: item.id)) ?? []
        if item.kind == .image, !Task.isCancelled {
            let previousLocal = previousChunks
                .filter { $0.source != .imageCaption }
                .sorted { $0.ordinal < $1.ordinal }
            let reusableCaption = previousChunks.first { $0.source == .imageCaption }
            let localUnchanged = !previousLocal.isEmpty
                && previousLocal.map(\.contentHash) == chunks.map(\.contentHash)

            if localUnchanged, let reusableCaption, !reusableCaption.text.isEmpty {
                chunks.append(ContentChunk(
                    itemID: item.id,
                    ordinal: chunks.count,
                    source: .imageCaption,
                    text: reusableCaption.text
                ))
            } else {
                let localText = chunks.map(\.text).joined(separator: "\n")
                if let caption = await settings.describeImage(item, localText: localText, library: library),
                   !caption.isEmpty {
                    chunks.append(ContentChunk(
                        itemID: item.id,
                        ordinal: chunks.count,
                        source: .imageCaption,
                        text: caption
                    ))
                }
            }
        }
        // 链接：把它指向的东西取回来，变成可检索的文字。
        //
        // 在这之前链接条目的"内容"就是那串 URL 本身，所以自然语言永远搜不到
        // 链接里讲了什么。抓回来之后它和截图走完全相同的下游——分块、
        // Embedding、问答，一条路。
        var fetchedPageTitle: String?
        if item.kind == .link, !Task.isCancelled,
           case .inline = item.holding {
            let previousPage = previousChunks
                .filter { $0.source == .linkPage }
                .sorted { $0.ordinal < $1.ordinal }
            if !forceRefreshLink, !previousPage.isEmpty {
                // 正常重建时沿用网页正文，避免每次改标签都重新请求第三方站点。
                for page in previousPage {
                    chunks.append(ContentChunk(
                        itemID: item.id,
                        ordinal: chunks.count,
                        source: .linkPage,
                        text: page.text
                    ))
                }
            } else if let url = item.linkURL, LinkContentFetcher.isFetchable(url) {
                guard let fetched = await LinkContentFetcher.fetch(url) else {
                    // 强制刷新失败时保留旧 RAG，绝不能先删旧内容再返回失败。
                    return IndexingRunResult(
                        completed: false,
                        dimensionChanged: false,
                        waitingForEmbedding: false
                    )
                }
                fetchedPageTitle = fetched.title
                // 有天然分段就按段切（论坛一层楼一块），否则按字数切。
                let pageChunks = fetched.segments.map { segments in
                    ContentChunking.chunks(
                        itemID: item.id,
                        segments: segments,
                        source: .linkPage,
                        pageNumber: nil,
                        ordinalBase: chunks.count
                    )
                } ?? ContentChunking.chunks(
                    itemID: item.id,
                    text: fetched.text,
                    source: .linkPage,
                    pageNumber: nil,
                    ordinalBase: chunks.count
                )
                guard !pageChunks.isEmpty else {
                    return IndexingRunResult(
                        completed: false,
                        dimensionChanged: false,
                        waitingForEmbedding: false
                    )
                }
                chunks.append(contentsOf: pageChunks)
            }
        }

        // 强制刷新时先取得 OCR 图源再索引，不能先读旧图、结束后才异步下载新图。
        let isXiaohongshu = LinkRefreshPolicy.isNote(item.linkURL)
        var refreshedImages = false
        if isXiaohongshu,
           forceRefreshLink || LinkCoverStore.ocrSourceURLs(for: item.id).isEmpty,
           let url = item.linkURL {
            let preview = await LinkCoverStore.refreshForIndex(url, itemID: item.id)
            guard !Task.isCancelled else {
                return IndexingRunResult(completed: false, dimensionChanged: false)
            }
            refreshedImages = preview.hasImages
            fetchedPageTitle = fetchedPageTitle ?? preview.title
        }
        // OCR 是这条链路里最贵的一步：一张图在本机跑 Vision 精确识别 + 分类，
        // 实测能到二十几秒，而抓正文、抓标题都是一两秒的事。把它放在"这次
        // 索引算不算完成"前面，等于让用户为了一张配图等上原本不必要的几十
        // 秒——很容易被当成"卡死了"，等不及点第二次反而弹出"重新解析失败"。
        //
        // 现在这一步不挡：先用得到的旧配图分块（没有就先空着）把文字、标题
        // 正常落库，OCR 在后台单独跑完再补一次更小的落盘。用户看到的是"内容
        // 很快就好了，配图里的文字晚一点点补上"，而不是"半天没反应"。
        var pendingOCRImageURLs: [URL] = []
        if item.kind == .link, !Task.isCancelled {
            let imageURLs = LinkCoverStore.ocrSourceURLs(for: item.id)
            let previousImageChunks = previousChunks.filter {
                $0.source == .imageOCR || $0.source == .imageCaption
            }
            // 不再对 240px 封面兜底 OCR：它可能只是平台 logo。
            if imageURLs.isEmpty || (isXiaohongshu && forceRefreshLink && !refreshedImages) {
                chunks.append(contentsOf: previousImageChunks)
            } else {
                chunks.append(contentsOf: previousImageChunks)
                pendingOCRImageURLs = imageURLs
            }
        }
        for index in chunks.indices { chunks[index].ordinal = index }

        // 用户自己写的那一句排在最前面：改过的标题、加上的标签、分组。
        //
        // 它必须和正文走同一条路（分块 → Embedding → 召回），否则"我备注过
        // 这是阿里云的密钥"只存在于界面上。备注常常正是用户唯一记得住的说法，
        // 而文件内容里根本没有那几个字。
        if let annotation = UserAnnotationText.build(
            title: item.titledLocally ? nil : item.title,
            tags: item.tags,
            group: item.group
        ) {
            chunks.insert(
                ContentChunk(
                    itemID: item.id,
                    ordinal: 0,
                    source: .userAnnotation,
                    text: annotation
                ),
                at: 0
            )
            for index in chunks.indices { chunks[index].ordinal = index }
        }

        guard !chunks.isEmpty else {
            try? await library.replaceChunks(for: item.id, with: [])
            return IndexingRunResult(completed: true, dimensionChanged: false)
        }

        // 内容没变的分块直接沿用上一版的向量。
        //
        // 改一个标签就要把整份 PDF 的每一页重新 embed 一遍是说不过去的——
        // 那是几十次真实的远端调用，而其中只有一句话真的变了。按 contentHash
        // 对账，命中就搬过来。这条对所有重建索引都成立，不只是改备注这一次。
        let reusableVectors = Dictionary(
            previousChunks
                .filter { $0.vector != nil && $0.embeddingModelID != nil }
                .map { ($0.contentHash, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        // 只沿用**当前这个 embedding 模型**产出的向量：换了模型，维度和语义
        // 空间都不同，混着用等于把两套坐标系拼在一起。
        let currentEmbeddingModelID = await settings.embeddingModelID
        for index in chunks.indices {
            guard let previous = reusableVectors[chunks[index].contentHash],
                  previous.embeddingModelID == currentEmbeddingModelID else { continue }
            chunks[index].vector = previous.vector
            chunks[index].embeddingModelID = previous.embeddingModelID
            chunks[index].indexedAt = previous.indexedAt
        }

        var shouldRetry = false
        var autoRetryAfter: TimeInterval?
        var privacyBlocked = false
        var embeddingUnconfigured = false
        var dimensionChanged = false
        var modelID: String?
        let indexedAt = Date.now
        let batchSize = 16
        for start in stride(from: 0, to: chunks.count, by: batchSize) {
            guard !Task.isCancelled else {
                return IndexingRunResult(completed: false, dimensionChanged: dimensionChanged)
            }
            let end = min(chunks.count, start + batchSize)
            let pending = (start..<end).filter { chunks[$0].vector == nil }
            guard !pending.isEmpty else {
                // 这一批全是沿用下来的向量，一次调用都不用发。
                modelID = modelID ?? chunks[start..<end].compactMap(\.embeddingModelID).first
                continue
            }
            let attempts = await settings.embed(
                pending.map { chunks[$0].text },
                allowSensitiveContent: item.allowsSensitiveAI
            )
            for (offset, attempt) in attempts.enumerated() {
                guard pending.indices.contains(offset) else { continue }
                let index = pending[offset]
                guard chunks.indices.contains(index) else { continue }
                switch attempt {
                case .success(let embedding):
                    chunks[index].vector = embedding.vector
                    chunks[index].embeddingModelID = embedding.modelID
                    chunks[index].indexedAt = indexedAt
                    modelID = embedding.modelID
                    dimensionChanged = dimensionChanged || embedding.dimensionChanged
                case .privacyBlocked:
                    // OCR/全文仍然只保存在本机并可做关键词检索；不反复重试外发。
                    privacyBlocked = true
                    break
                case .notConfigured:
                    embeddingUnconfigured = true
                case .configurationFailure:
                    shouldRetry = true
                case .retryableFailure(let retryAfter):
                    shouldRetry = true
                    let delay = retryAfter ?? 2
                    autoRetryAfter = min(autoRetryAfter ?? delay, delay)
                }
            }
        }

        // 任一远端分块尚未完成时，保留上一版分块和向量；下一次恢复队列后
        // 从完整的新内容版本重新生成，避免新旧分块混合落盘。
        if shouldRetry {
            return IndexingRunResult(
                completed: false,
                dimensionChanged: dimensionChanged,
                waitingForEmbedding: true,
                autoRetryAfter: autoRetryAfter
            )
        }

        do {
            // `item` 可能在抓网页的几秒里被元数据任务更新过。重新读当前版本，
            // 只把本轮索引负责的字段合并进去，避免用旧快照覆盖新标题/标签。
            let isNearby = await MainActor.run { NearbyDeviceOrigin.contains(item.id) }
            guard !Task.isCancelled,
                  var updated = try await library.item(id: item.id),
                  updated.state == .active, !updated.isPrivate,
                  updated.holding == item.holding,
                  updated.origin != .clipboard || updated.isPinned
                    || isNearby else {
                return IndexingRunResult(completed: false, dimensionChanged: dimensionChanged)
            }
            // 正文抓取和标题来自**同一个 HTTP 响应**，必须同一次落库。过去标题
            // 依赖另一条 LPMetadataProvider 任务：正文进 RAG 了，卡片却仍叫
            // “无法访问链接内容”。只有临时本地标题能被自动替换；用户手写标题
            // (`titledLocally == false`) 永远保留。
            if LinkRefreshPolicy.mayReplaceTitle(updated),
               let title = fetchedPageTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty, title != updated.title {
                updated.title = String(title.prefix(80))
                // 网页自己给出的标题已经不是“本地凑出来的临时名”。后续普通
                // 元数据补抓不再反复覆盖它；用户手写标题同样一直受保护。
                updated.titledLocally = false
                updated.titleOrigin = "page"
            }

            if isXiaohongshu, forceRefreshLink, refreshedImages {
                updated.linkExtractionVersion = LinkRefreshPolicy.xiaohongshuVersion
            }
            if let modelID,
               let aggregate = averageVector(chunks.compactMap(\.vector)) {
                updated.vector = aggregate
                updated.contentHash = chunks.map(\.contentHash).joined(separator: ":")
                updated.embeddingModelID = modelID
                updated.indexedAt = indexedAt
                updated.aiPrivacyBlocked = false
            } else if privacyBlocked || embeddingUnconfigured {
                // 新内容不能外发时，旧向量也不能继续代表当前内容；保留本地
                // 全文/OCR 分块供关键词检索，并记录已处理的内容版本。
                updated.vector = nil
                updated.contentHash = chunks.map(\.contentHash).joined(separator: ":")
                updated.embeddingModelID = nil
                // indexedAt 留空：这一版内容还没拿到向量。用户之后配好
                // embedding，队列会凭它把这些条目重新捡回来。
                updated.indexedAt = nil
                updated.aiPrivacyBlocked = privacyBlocked
            }
            // 分块与承载聚合向量/标题的 Item 必须同一个事务提交。
            // 即使本轮只重写分块，当前 Item 也一起提交，确保不会出现新正文配旧向量。
            try await library.replaceChunks(for: item.id, with: chunks, updating: updated)
        } catch {
            return IndexingRunResult(
                completed: false,
                dimensionChanged: dimensionChanged,
                waitingForEmbedding: false
            )
        }
        // 文字、标题这一版已经落盘；配图的 OCR 单独在后台跑完再补一次
        // 小得多的落盘，不拖这次"完成"的判定。
        if !pendingOCRImageURLs.isEmpty {
            let generation = await ImageOCRGenerationTracker.shared.next(for: item.id)
            let holding = item.holding
            Task.detached(priority: .utility) {
                await Self.completeImageOCR(
                    itemID: item.id,
                    holding: holding,
                    imageURLs: pendingOCRImageURLs,
                    library: library,
                    settings: settings,
                    generation: generation
                )
            }
        }
        return IndexingRunResult(
            completed: true,
            dimensionChanged: dimensionChanged,
            waitingForEmbedding: false
        )
    }

    /// 配图 OCR 的后台补丁：跑完就整份重读当前分块，把旧的配图分块换成
    /// 新的，其余（正文、用户标注）原样不动，只给真正新的分块补 embedding，
    /// 一次性原子落盘——和主流程同一条"分块与 Item 同一事务"的规矩。
    ///
    /// 落盘前查一次代次：跑这几秒到二十几秒的期间，同一条链接完全可能已经
    /// 被更新的一轮重新解析取代，这时候悄悄放弃，绝不能拿过时结果反过来
    /// 盖掉更新的内容。
    private static func completeImageOCR(
        itemID: UUID,
        holding: Holding,
        imageURLs: [URL],
        library: Library,
        settings: ProviderSettingsModel,
        generation: Int
    ) async {
        var ocrChunks: [ContentChunk] = []
        for (index, imageURL) in imageURLs.enumerated() {
            guard !Task.isCancelled else { return }
            var imageChunks = await SemanticContentExtractor.linkCoverChunks(
                itemID: itemID, coverURL: imageURL, ordinalBase: 0
            )
            for i in imageChunks.indices { imageChunks[i].pageNumber = index + 1 }
            ocrChunks.append(contentsOf: imageChunks)
        }
        guard !Task.isCancelled,
              await ImageOCRGenerationTracker.shared.isCurrent(generation, for: itemID),
              let current = try? await library.item(id: itemID),
              current.state == .active, !current.isPrivate, current.holding == holding
        else { return }

        var chunks = (try? await library.chunks(for: itemID)) ?? []
        chunks.removeAll { $0.source == .imageOCR || $0.source == .imageCaption }
        chunks.append(contentsOf: ocrChunks)
        for index in chunks.indices { chunks[index].ordinal = index }

        let currentEmbeddingModelID = await settings.embeddingModelID
        var modelID: String?
        var shouldRetry = false
        let indexedAt = Date.now
        let batchSize = 16
        for start in stride(from: 0, to: chunks.count, by: batchSize) {
            guard !Task.isCancelled else { return }
            let end = min(chunks.count, start + batchSize)
            let pending = (start..<end).filter {
                chunks[$0].vector == nil || chunks[$0].embeddingModelID != currentEmbeddingModelID
            }
            guard !pending.isEmpty else {
                modelID = modelID ?? chunks[start..<end].compactMap(\.embeddingModelID).first
                continue
            }
            let attempts = await settings.embed(
                pending.map { chunks[$0].text },
                allowSensitiveContent: current.allowsSensitiveAI
            )
            for (offset, attempt) in attempts.enumerated() {
                guard pending.indices.contains(offset) else { continue }
                let index = pending[offset]
                guard chunks.indices.contains(index) else { continue }
                switch attempt {
                case .success(let embedding):
                    chunks[index].vector = embedding.vector
                    chunks[index].embeddingModelID = embedding.modelID
                    chunks[index].indexedAt = indexedAt
                    modelID = embedding.modelID
                case .privacyBlocked, .notConfigured:
                    break
                case .configurationFailure, .retryableFailure:
                    // 后台补丁不接自动重试那一整套：这本来就是"晚一点点补上"，
                    // 下次正常重建索引会按 contentHash 把这批 OCR 文本重新捡回去，
                    // 不需要在这里再单独维护一条重试链路。
                    shouldRetry = true
                }
            }
        }
        guard !shouldRetry else { return }

        guard !Task.isCancelled,
              await ImageOCRGenerationTracker.shared.isCurrent(generation, for: itemID),
              var updated = try? await library.item(id: itemID),
              updated.state == .active, !updated.isPrivate, updated.holding == holding
        else { return }
        if let modelID, let aggregate = averageVector(chunks.compactMap(\.vector)) {
            updated.vector = aggregate
            updated.contentHash = chunks.map(\.contentHash).joined(separator: ":")
            updated.embeddingModelID = modelID
            updated.indexedAt = indexedAt
            updated.aiPrivacyBlocked = false
        }
        try? await library.replaceChunks(for: itemID, with: chunks, updating: updated)
    }

    static func search(
        query: String,
        items: [Item],
        library: Library,
        settings: ProviderSettingsModel,
        allowsNetwork: Bool,
        usesEmbedding: Bool? = nil,
        /// 调用方已经判定出的类型。剪贴板那条路解析过一次意图，结论必须带过来，
        /// 否则这里重新猜一遍，"带有 test-time 的图"就会因为认不出类型而不过滤，
        /// 让一条正好含 test-time 的文字把要找的图挤掉。
        kinds: Set<ItemKind> = []
    ) async -> SemanticSearchRun {
        let startedAt = Date()
        let local = QueryUnderstanding.localParse(query)
        let shouldEmbed = usesEmbedding ?? allowsNetwork

        // 查询理解和查询向量互不依赖，别再排成一队等。
        //
        // 原来是"先等模型拆完条件，再拿拆出来的文字去要向量"，两次网络往返
        // 串行发生，回答的第一个字要等到第三次往返才开始——用户感觉到的"慢"
        // 大半在这里，不在检索本身（分块向量早就存在库里，从不重算）。
        // 向量用本地解析出的主题词：模型那一步主要是去掉套话，和本地口径接近，
        // 不值得为它多等一个往返。
        async let understoodQuery: StructuredQuery = allowsNetwork
            ? await settings.understandQuery(query)
            : local
        async let embedded: EmbeddingAttempt? = shouldEmbed && !local.semanticText.isEmpty
            ? await settings.embed(local.semanticText)
            : nil

        var structured = await understoodQuery
        let attempt = await embedded
        if structured.kinds.isEmpty { structured.kinds = kinds }
        let queryVector: [Float]?
        var currentModelID: String?
        // 没有向量时必须说清楚是哪一种"没有"：配置缺失、隐私拦截、凭据/配置错误
        // 还是可重试的网络失败。之前一律只显示"向量 无"，查起来完全没有方向。
        let vectorState: String
        switch attempt {
        case .success(let embedding):
            queryVector = embedding.vector
            currentModelID = embedding.modelID
            vectorState = "有"
        case .notConfigured:
            queryVector = nil
            vectorState = "无·未配置"
        case .privacyBlocked:
            queryVector = nil
            vectorState = "无·隐私拦截"
        case .configurationFailure:
            queryVector = nil
            vectorState = "无·凭据或配置失败"
        case .retryableFailure:
            queryVector = nil
            vectorState = "无·网络失败可重试"
        case nil:
            queryVector = nil
            vectorState = "无·未发起"
        }
        let understandingCost = Date().timeIntervalSince(startedAt)
        // 检索只可能命中确定性过滤之后的那批条目，所以只取它们的分块。
        // 过滤把结果滤空时（查询理解把类型猜错）退回全库，否则模型连判断的
        // 机会都没有——这一步和 rankingCandidates 用的是同一个口径。
        let scope = VectorSearch.filter(items, by: structured)
        let scopeIDs = Set((scope.isEmpty ? items : scope).map(\.id))
        let chunks = (try? await library.chunks(for: scopeIDs)) ?? []
        var hits = SemanticSearch.rank(
            items: items,
            chunks: chunks,
            query: structured,
            queryVector: queryVector,
            currentEmbeddingModelID: currentModelID
        )
        // 类型是**猜**出来的，不该变成一道能把答案整个滤掉的墙。
        //
        // "我要终端使用指南"里的"指南"会把类型判成 PDF / 文件；这份指南要是
        // 存成一条文字或一个链接，带类型的召回就是空集，于是复制推荐什么都不给，
        // 而搜索页没有这道过滤，照样找得到——用户看到的就是"搜索行、推荐不行"。
        // 带类型先试，滤空了就退回不限类型再试一次。
        if hits.isEmpty, !structured.kinds.isEmpty {
            var relaxed = structured
            relaxed.kinds = []
            let widened = (try? await library.chunks(for: Set(items.map(\.id)))) ?? chunks
            hits = SemanticSearch.rank(
                items: items,
                chunks: widened,
                query: relaxed,
                queryVector: queryVector,
                currentEmbeddingModelID: currentModelID
            )
            if !hits.isEmpty { structured = relaxed }
        }
        await AppModel.ContextTrace.log(String(
            format: "检索耗时 理解+向量 %.2fs / 召回 %.2fs / 命中 %d 条（向量 %@）",
            understandingCost,
            Date().timeIntervalSince(startedAt) - understandingCost,
            hits.count,
            vectorState
        ))
        // 排序与解释都由流式回答那一次调用完成，这里不再额外打一次模型。
        return SemanticSearchRun(
            hits: hits,
            understoodQuery: structured,
            candidates: RetrievalEvidence.candidates(
                hits: hits, items: items, chunks: chunks, query: structured
            )
        )
    }

    /// 本轮回答要读的本地证据，以及这批证据允不允许绕过敏感筛查。
    private struct AnswerEvidenceBundle {
        var evidence: [RecommendationAnswerEvidence]
        var allowsSensitiveContent: Bool
    }

    /// 快捷回答的一轮"读证据"。所有状态都在这个 async 调用的局部变量里，
    /// 返回后即释放；不会把 messages、证据或中间行动写入模型或磁盘。
    private static func answerEvidence(
        question: String,
        itemIDs: [UUID],
        items: [Item],
        library: Library,
        settings: ProviderSettingsModel
    ) async -> AnswerEvidenceBundle? {
        let allowed = Set(itemIDs)
        guard !allowed.isEmpty else { return nil }
        let evidenceStarted = Date()
        let chunks = (try? await library.chunks(for: allowed)) ?? []
        let chunksLoaded = Date()
        let queryText = QueryUnderstanding.localParse(question).semanticText
        let queryVector: [Float]?
        switch await settings.embed(queryText.isEmpty ? question : queryText) {
        case .success(let embedding): queryVector = embedding.vector
        case .notConfigured, .privacyBlocked, .configurationFailure, .retryableFailure:
            queryVector = nil
        }

        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let chunksByItem = Dictionary(grouping: chunks, by: \.itemID)
        var evidence: [RecommendationAnswerEvidence] = []
        var includedItems: [Item] = []
        // controller 的顺序就是证据优先级；不重新按 UUID 排，以免丢掉模型本轮选择。
        for itemID in itemIDs where evidence.count < 3 {
            guard let item = itemByID[itemID] else { continue }
            var excerpts = RecommendationAnswerEvidenceSelector.select(
                chunks: chunksByItem[itemID] ?? [],
                query: queryText.isEmpty ? question : queryText,
                queryVector: queryVector
            )
            if excerpts.isEmpty, case .inline(let text) = item.holding, !text.isEmpty {
                excerpts = [String(text.prefix(
                    RecommendationAnswerEvidenceSelector.maximumExcerptCharacters
                ))]
            }
            guard !excerpts.isEmpty else { continue }
            includedItems.append(item)
            evidence.append(RecommendationAnswerEvidence(
                itemID: item.id,
                title: item.title,
                filename: item.originalFilename,
                excerpts: excerpts
            ))
        }
        guard !evidence.isEmpty, !Task.isCancelled else { return nil }
        await AppModel.ContextTrace.log(String(
            format: "证据准备 %.2fs（读分块 %.2fs + 查询向量 %.2fs）",
            Date().timeIntervalSince(evidenceStarted),
            chunksLoaded.timeIntervalSince(evidenceStarted),
            Date().timeIntervalSince(chunksLoaded)
        ))
        return AnswerEvidenceBundle(
            evidence: evidence,
            // 默认 false = 正常执行本地隐私筛查。只有本轮实际纳入证据的每个 Pin
            // 都被用户逐条允许过敏感 AI 外发时才绕过；普通内容无需这个开关也能发送。
            allowsSensitiveContent: !includedItems.isEmpty
                && includedItems.allSatisfy(\.allowsSensitiveAI)
        )
    }

    /// 整段生成完再交付（剪贴板路径）。
    static func answerRecommendation(
        question: String,
        itemIDs: [UUID],
        items: [Item],
        library: Library,
        settings: ProviderSettingsModel
    ) async -> String? {
        guard let bundle = await answerEvidence(
            question: question,
            itemIDs: itemIDs,
            items: items,
            library: library,
            settings: settings
        ) else { return nil }
        return await settings.answerRecommendation(
            question: question,
            evidence: bundle.evidence,
            allowSensitiveContent: bundle.allowsSensitiveContent
        )
    }

    /// 逐段交付（写进前台输入框的路径）。读证据这一步没法流式——它要等本地
    /// chunk 和 embedding；能提前的只有生成，所以证据一就绪就立刻开流。
    static func streamAnswerRecommendation(
        question: String,
        itemIDs: [UUID],
        items: [Item],
        library: Library,
        settings: ProviderSettingsModel
    ) -> AsyncThrowingStream<AIStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                guard let bundle = await answerEvidence(
                    question: question,
                    itemIDs: itemIDs,
                    items: items,
                    library: library,
                    settings: settings
                ) else {
                    continuation.finish()
                    return
                }
                let deltas = await settings.streamAnswerRecommendation(
                    question: question,
                    evidence: bundle.evidence,
                    allowSensitiveContent: bundle.allowsSensitiveContent
                )
                do {
                    for try await delta in deltas {
                        try Task.checkCancellation()
                        continuation.yield(delta)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func answerPDF(
        item: Item,
        question: String,
        library: Library,
        settings: ProviderSettingsModel
    ) async -> String? {
        let chunks = ((try? await library.chunks(for: item.id)) ?? [])
            .filter { $0.source == .pdfPage && !$0.text.isEmpty }
        guard !chunks.isEmpty, !question.isEmpty else { return nil }

        let queryVector: [Float]?
        switch await settings.embed(question) {
        case .success(let embedding): queryVector = embedding.vector
        case .notConfigured, .privacyBlocked, .configurationFailure, .retryableFailure:
            queryVector = nil
        }
        let terms = question.lowercased().split(whereSeparator: { $0.isWhitespace })
        let ranked = chunks.map { chunk -> (ContentChunk, Float) in
            let semantic = queryVector.flatMap { query in
                chunk.vector.map { VectorSearch.cosine(query, $0) }
            } ?? 0
            let lower = chunk.text.lowercased()
            let lexical = Float(terms.filter { lower.contains($0) }.count) * 0.12
            return (chunk, semantic + lexical)
        }.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.ordinal < rhs.0.ordinal
        }
        let context = ranked.prefix(4).map { chunk, _ in
            "[第 \(chunk.pageNumber ?? 0) 页]\n\(chunk.text.prefix(2_800))"
        }.joined(separator: "\n\n")
        return await settings.answerPDF(
            question: question,
            context: context,
            allowSensitiveContent: item.allowsSensitiveAI
        )
    }

    private static func averageVector(_ vectors: [[Float]]) -> [Float]? {
        guard let dimension = vectors.first?.count,
              dimension > 0,
              vectors.allSatisfy({ $0.count == dimension }) else { return nil }
        var result = Array(repeating: Float.zero, count: dimension)
        for vector in vectors {
            for index in vector.indices { result[index] += vector[index] }
        }
        return result.map { $0 / Float(vectors.count) }
    }
}
