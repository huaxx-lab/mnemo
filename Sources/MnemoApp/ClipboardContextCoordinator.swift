import Foundation
import MnemoCore

/// 剪贴板上下文推荐的编排。
///
/// 闸门从便宜到贵依次收窄，任何一道不过就停下，不做后面的事：
/// 1. 本地粗筛（`ClipboardContextGate`）——太短、纯链接之类直接丢掉；
/// 2. 本地意图解析——抽出确定性标识，这一步决定了后面能不能自动写回；
/// 3. 模型路由——判断"这像不像在索取库里已有的材料"，只回答是与否；
/// 4. 本地召回 + 候选内重排——模型只能在真实候选里选。
@MainActor
enum ClipboardContextCoordinator {
    private static func kindLabel(_ kind: ItemKind) -> String {
        switch kind {
        case .pdf: "库里的 PDF"
        case .image: "库里的图片"
        case .link: "库里的链接"
        case .text: "库里的文字"
        case .file, .binary: "库里的文件"
        }
    }


    /// 这条 Pin 在本机的可读内容：内联正文加上已建好的分块（OCR、PDF 页、全文）。
    /// 校验模型指认的片段只认这一份，模型看到的摘要不算数。
    private static func localText(
        of itemID: UUID,
        items: [Item],
        library: Library
    ) async -> String {
        var parts: [String] = []
        if let item = items.first(where: { $0.id == itemID }) {
            parts.append(item.title)
            if let filename = item.originalFilename { parts.append(filename) }
            if case .inline(let text) = item.holding { parts.append(text) }
        }
        let chunks = (try? await library.chunks(for: itemID)) ?? []
        parts.append(contentsOf: chunks.sorted { $0.ordinal < $1.ordinal }.map(\.text))
        return parts.joined(separator: "\n")
    }

    static func resolve(
        event: ClipboardContextEvent,
        items: [Item],
        sourceItemID: UUID?,
        library: Library,
        settings: ProviderSettingsModel,
        /// 用户主动按下快捷键。两道闸门都为他让路：形态不必像一句短话
        /// （选中的可能是一整段），证据弱也照样显示——他已经说了他要什么。
        isExplicitTrigger: Bool = false
    ) async -> AppModel.ContextResolution {
        guard !items.isEmpty else { return .init() }

        let intent = ContextIntentParser.parse(event)
        AppModel.ContextTrace.log(
            "意图 fields=\(intent.fields.map(\.rawValue).sorted()) "
            + "kinds=\(intent.preferredKinds.map(\.rawValue).sorted()) "
            + "证据=\(intent.deterministicEvidence.count) 条"
        )

        // 形态闸门：一句短话才看，成段正文直接放过。这一步不花任何调用。
        guard isExplicitTrigger || ContextRetrievalGate.shouldRecall(event) else {
            AppModel.ContextTrace.log("形态不像一句诉求，不检索")
            return .init()
        }
        // 明确的索取（有请求动词 + 场景词或标识）才算"确信是查询"：只有这种
        // 才把原文撤出剪贴板轨道。碰巧复制到的一句短话不动它。
        let isExplicit = isExplicitTrigger || ContextIntentParser.isLocalRetrievalQuery(event)
        let queryOnly = AppModel.ContextResolution(isRetrievalQuery: isExplicit)

        let run = await SemanticIndexCoordinator.search(
            query: intent.semanticQuery.isEmpty ? event.text : intent.semanticQuery,
            items: items,
            library: library,
            settings: settings,
            // 意图解析保持本地确定性，但查询向量使用已配置的 Embedding。快捷路径
            // 和搜索页因此共享同一份语义索引，不再退化成只有字面匹配。
            allowsNetwork: false,
            usesEmbedding: true,
            kinds: intent.preferredKinds
        )
        // 触发这次识别的那条复制自己不能成为推荐结果。
        let pool = run.candidates.filter { $0.itemID != sourceItemID }
        let bestEvidence = pool.filter(\.hasLocalEvidence).map(\.localScore).max() ?? 0
        AppModel.ContextTrace.log(
            "本地候选 \(pool.count) 条，最强证据 \(String(format: "%.2f", bestEvidence))"
        )
        // 证据闸门：库里没有真的对得上的东西就别打扰。这是取代词表的那一步——
        // 用户怎么说都行，只要东西在库里；东西不在，说得再像请求也不该弹。
        guard ContextRetrievalGate.shouldSuggest(
            bestLocalScore: bestEvidence,
            isExplicitRequest: isExplicit
        ) else {
            AppModel.ContextTrace.log("证据不足，不推荐")
            return queryOnly
        }
        guard !pool.isEmpty else { return queryOnly }

        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let candidates = pool.map { candidate -> ContextualCandidate in
            let item = itemByID[candidate.itemID]
            return ContextualCandidate(
                itemID: candidate.itemID,
                title: candidate.title,
                kind: candidate.kind,
                localScore: Double(candidate.localScore),
                evidence: ContextIntentParser.evidence(
                    for: intent,
                    title: candidate.title,
                    filename: item?.originalFilename,
                    tags: item?.tags ?? [],
                    group: item?.group
                )
            )
        }

        // 自动写回的资格只由本地事实决定，模型无权把它从 false 变成 true。
        // 三条判据，任何一条唯一确定就放行；都不唯一就只推荐。
        //
        // 1) 字段型：用户要的是某个字段的值，库里只有一条 Pin 能给出它。
        //    敏感字段（银行账号、证件号）即便唯一也不自动写——粘错地方代价太大。
        var autoCopyValue: (itemID: UUID, value: String)?
        for field in intent.fields where !field.isSensitive {
            let texts = items.compactMap { item -> (UUID, String)? in
                guard item.id != sourceItemID,
                      case .inline(let text) = item.holding else { return nil }
                return (item.id, text)
            }
            if let hit = ContextualAutoCopy.uniqueFieldValue(field: field, texts: texts) {
                autoCopyValue = hit
                break
            }
        }

        // 2) 标识型：请求里的唯一标识只命中一个真实候选。
        // 3) 类型唯一：必须在整个活动库里验证这种类型确实只有一个，不能只看
        // 截断后的候选池，否则“候选里只有一篇”会被误说成“库里只有一篇”。
        let fullLibraryCandidates = items.compactMap { item -> ContextualCandidate? in
            guard item.id != sourceItemID else { return nil }
            return ContextualCandidate(
                itemID: item.id,
                title: item.title,
                kind: item.kind,
                localScore: candidates.first(where: { $0.itemID == item.id })?.localScore ?? 0,
                evidence: ContextIntentParser.evidence(
                    for: intent,
                    title: item.title,
                    filename: item.originalFilename,
                    tags: item.tags,
                    group: item.group
                )
            )
        }
        let autoCopyTarget = autoCopyValue?.itemID
            ?? ContextualAutoCopy.uniqueTarget(candidates: fullLibraryCandidates, intent: intent)
            ?? ContextualAutoCopy.uniqueByKind(candidates: fullLibraryCandidates, intent: intent)

        func localSuggestion(
            for candidate: ContextualCandidate,
            autoCopied: Bool
        ) -> AppModel.ContextSuggestion {
            let reason = candidate.evidence.isEmpty
                ? Self.kindLabel(candidate.kind)
                : "命中 \(candidate.evidence.joined(separator: "、"))"
            return AppModel.ContextSuggestion(
                itemID: candidate.itemID,
                title: candidate.title,
                reason: String(reason.prefix(60)),
                kind: candidate.kind,
                didAutoCopy: autoCopied
            )
        }

        // 被动复制仍然走最短的确定性自动交付路径；Command-G 必须先让 Agent
        // 判断 retrieve / answer。否则“CSA-UD 是怎么运行的核心观点”带有 csa-ud
        // 这个唯一标识，会在意图判断之前直接把 PDF / 摘要复制出去，永远到不了回答。
        if !isExplicitTrigger, let autoCopyTarget,
           let target = candidates.first(where: { $0.itemID == autoCopyTarget }) {
            return AppModel.ContextResolution(
                suggestions: [localSuggestion(for: target, autoCopied: true)],
                isRetrievalQuery: isExplicit,
                // 字段型写回的是那一串值本身，不是整条 Pin：用户要税号，
                // 不是要一整段带抬头、开户行、地址的文本。
                autoCopyText: autoCopyValue?.value,
                autoCopyItemID: autoCopyValue == nil ? autoCopyTarget : nil
            )
        }

        let modelPool = Array(pool.prefix(12))
        let ranking = await settings.recommendSearchResults(
            query: intent.semanticQuery.isEmpty ? event.text : intent.semanticQuery,
            candidates: modelPool,
            // 排序偏好读原文，不读 semanticQuery：后者已经把"最新"这类词剥掉了，
            // 剥掉是为了不污染向量，不是为了让下游忘记用户提过这件事。
            recency: RecencyVocabulary.preference(in: event.text)
        )
        let decision: RecommendationAgentDecision?
        let ranked: [RetrievalRecommendation]
        let modelWasAvailable: Bool
        switch ranking {
        case .selected(let selected):
            decision = selected
            ranked = selected.recommendations
            modelWasAvailable = true
        case .unavailable:
            decision = nil
            ranked = []
            modelWasAvailable = false
        }
        func suggestion(
            for candidate: ContextualCandidate,
            autoCopied: Bool = false
        ) -> AppModel.ContextSuggestion {
            // 模型没给理由时不能拿剪贴板原文顶上——那会把用户刚复制的一整段
            // 文字（甚至终端输出）当成"推荐理由"显示出来。
            guard let modelReason = ranked.first(where: { $0.itemID == candidate.itemID })?.reason else {
                return localSuggestion(for: candidate, autoCopied: autoCopied)
            }
            return AppModel.ContextSuggestion(
                itemID: candidate.itemID,
                title: candidate.title,
                reason: String(modelReason.prefix(60)),
                kind: candidate.kind,
                didAutoCopy: autoCopied
            )
        }

        // 模型看过候选之后一个都没选中，就是"库里没有相关的"。
        //
        // 这时**什么都不显示**。退回本地最高分会把一个无关的东西推上来——
        // 用户复制一句话就被弹一条不相干的推荐，比不推荐更烦。
        // 用"模型有没有选它"当信号，而不是它自报的那个数字。
        //
        // 自报置信度没有校准：同一个模型对明明正确的命中也可能写 0.2。拿它当
        // 硬门槛的后果是模型明明选中了两篇论文，却一条都不显示。prompt 里已经
        // 写明"宁可返回空数组也不要凑数"，所以它列出来就意味着值得看。
        var picks = Array(
            ranked.compactMap { recommendation in
                candidates.first { $0.itemID == recommendation.itemID }
            }.prefix(3)
        )

        // 模型明确返回空数组时就是“没有相关项”，不能再把无关图片补回来。
        // 只有模型不可用时才降级到有真实本地证据且类型匹配的候选；补位候选
        // hasLocalEvidence=false，不得借故冒充命中。
        if picks.isEmpty, !modelWasAvailable, !intent.preferredKinds.isEmpty {
            let candidateByID = Dictionary(uniqueKeysWithValues: pool.map { ($0.itemID, $0) })
            picks = Array(
                candidates
                    .filter { candidate in
                        intent.preferredKinds.contains(candidate.kind)
                            && candidateByID[candidate.itemID]?.hasLocalEvidence == true
                    }
                    .sorted { $0.localScore > $1.localScore }
                    .prefix(3)
            )
            if !picks.isEmpty {
                AppModel.ContextTrace.log("模型不可用，降级到本地证据 \(picks.count) 条")
            }
        }
        AppModel.ContextTrace.log(
            "模型选中 \(ranked.count) 条，最终展示 \(picks.count) 条"
        )
        guard !picks.isEmpty else { return queryOnly }

        let selectedItemIDs = picks.map(\.itemID)
        let output = decision?.output(selectedItemIDs: selectedItemIDs)
            ?? .deliver(itemIDs: selectedItemIDs)

        // 一轮只有一个面向用户的输出。answer 模式里的候选是**内部证据**，不再
        // 同时投影为文件推荐行；否则“CSA-UD 讲了什么”会看起来既要发论文又要总结。
        // AppModel 只拿这些白名单 ID 读取分块，最终 UI 只有回答卡。
        if case .answer(let evidenceItemIDs) = output {
            AppModel.ContextTrace.log("判定为解释型请求，只生成回答，证据 \(evidenceItemIDs.count) 条")
            return AppModel.ContextResolution(
                isRetrievalQuery: isExplicit,
                answerRequest: event.text,
                answerEvidenceItemIDs: evidenceItemIDs
            )
        }

        // 模型看完候选只留下一个时，用户要的就是这一个：直接替他准备好，
        // 省掉"再点一下复制"。这条授权有明确边界，不是"模型说了算"：
        //
        // - 只有模型真的可用并且**恰好收敛到一条**才算数，多于一条仍然只推荐；
        // - 敏感字段（银行账号、证件号）无论如何都不自动写，粘错代价太大；
        // - 这一条必须真的被本地检索命中（`hasLocalEvidence`）：纯粹"补位进候选池
        //   给模型看"的条目不具备资格，模型对补位项一样会说好。
        //   不再额外要求命中本地词表点名的类型——本地词表认不出、由模型判定为
        //   检索的请求（"工业信息学汇刊第二卷第五期"）意图本来就是空的，
        //   拿它当条件等于这类请求永远享受不到自动写回；
        // - 真正的写入仍由 AppModel 异步确认系统粘贴板成功后才显示对号。
        let sensitiveIntent = intent.fields.contains { $0.isSensitive }
        let locallyEvidencedIDs = Set(pool.filter(\.hasLocalEvidence).map(\.itemID))
        if let autoCopyItemID = RecommendationAutoCopyPolicy.convergedTarget(
            decision: decision,
            selectedItemIDs: selectedItemIDs,
            locallyEvidencedItemIDs: locallyEvidencedIDs,
            modelWasAvailable: modelWasAvailable,
            hasSensitiveIntent: sensitiveIntent
        ), let only = picks.first(where: { $0.itemID == autoCopyItemID }) {
            // 用户要的可能只是这条 Pin 里的一小段——"给我 pi agent 的网址"要的是
            // 那条链接，不是整段笔记。模型可以指认，但只能指认**已经存在**的文字：
            // 拿真实本地内容逐字校验，校验不过就退回整条，绝不把模型写出来的
            // 网址塞进剪贴板。
            let localText = await Self.localText(of: only.itemID, items: items, library: library)
            let span = CopyPayloadResolver.verified(
                ranked.first(where: { $0.itemID == only.itemID })?.copyText,
                in: localText
            )
            AppModel.ContextTrace.log(
                span == nil ? "模型收敛到唯一结果，自动准备整条" : "模型指认片段，自动准备该片段"
            )
            return AppModel.ContextResolution(
                suggestions: [suggestion(for: only, autoCopied: true)],
                isRetrievalQuery: isExplicit,
                autoCopyText: span,
                autoCopyItemID: span == nil ? only.itemID : nil
            )
        }

        // 仍然是多个候选或不满足上面的边界时只推荐，由用户点选，
        // 模型自报的置信度不是授权。
        return AppModel.ContextResolution(
            suggestions: picks.map { suggestion(for: $0) },
            isRetrievalQuery: isExplicit
        )
    }
}
