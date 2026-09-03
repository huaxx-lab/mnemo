import Foundation
import Testing
@testable import MnemoCore

private func event(_ text: String, kind: ItemKind = .text) -> ClipboardContextEvent {
    ClipboardContextEvent(fingerprint: text, kind: kind, text: text)
}

@Test("本地粗筛挡掉不承载诉求的剪贴板内容，不烧 token 也不播动效")
func clipboardGateSkipsUninterestingContent() {
    #expect(!ClipboardContextGate.shouldConsider(event("ok")))
    #expect(!ClipboardContextGate.shouldConsider(event("https://example.com/a/b")))
    #expect(!ClipboardContextGate.shouldConsider(
        event(String(repeating: "正文", count: 2_000))
    ))
    #expect(ClipboardContextGate.shouldConsider(event("请提交 csa-ud 的论文")))
}

@Test("只有带数字或连接符的标识才算确定性证据，普通词不算")
func identifierTokensRejectOrdinaryWords() {
    let tokens = ContextIntentParser.identifierTokens(in: "请提交 csa-ud 的论文，编号 iwqos2026")
    #expect(tokens.contains("csa-ud"))
    #expect(tokens.contains("iwqos2026"))
    // "论文""提交"这类普通词不能算证据，否则任何一句话都会被判成可自动执行
    #expect(!tokens.contains("论文"))
    #expect(!tokens.contains("提交"))

    #expect(ContextIntentParser.identifierTokens(in: "帮我找一下那篇论文").isEmpty)
}

@Test("意图解析识别论文与税号场景")
func intentParsingDetectsFields() {
    let paper = ContextIntentParser.parse(event("请提交 csa-ud 的论文"))
    #expect(paper.fields.contains(.paper))
    #expect(paper.preferredKinds.contains(.pdf))
    #expect(paper.deterministicEvidence.contains("csa-ud"))

    let tax = ContextIntentParser.parse(event("请填写公司税号与开户行"))
    #expect(tax.fields.contains(.taxNumber))
    #expect(tax.fields.contains(.bankAccount))
    // 没有标识串，就没有确定性证据
    #expect(tax.deterministicEvidence.isEmpty)
}

@Test("唯一确定时才允许自动写回剪贴板")
func autoCopyRequiresAUniqueDeterministicTarget() {
    let a = UUID()
    let intent = ContextIntent(deterministicEvidence: ["csa-ud"])

    let unique = [
        ContextualCandidate(itemID: a, title: "CSA-UD 主论文", kind: .pdf, localScore: 0.9,
                            evidence: ["csa-ud"]),
        ContextualCandidate(itemID: UUID(), title: "别的论文", kind: .pdf, localScore: 0.4),
    ]
    #expect(ContextualAutoCopy.uniqueTarget(candidates: unique, intent: intent) == a)
}

@Test("证据命中多于一个时只推荐，不自动执行")
func autoCopyRefusesWhenAmbiguous() {
    let intent = ContextIntent(deterministicEvidence: ["csa-ud"])
    let ambiguous = [
        ContextualCandidate(itemID: UUID(), title: "CSA-UD 主论文", kind: .pdf, localScore: 0.9,
                            evidence: ["csa-ud"]),
        ContextualCandidate(itemID: UUID(), title: "CSA-UD 扩展工作", kind: .pdf, localScore: 0.8,
                            evidence: ["csa-ud"]),
    ]
    #expect(ContextualAutoCopy.uniqueTarget(candidates: ambiguous, intent: intent) == nil)
}

@Test("只有语义相似时绝不自动写回，模型置信度不是授权")
func autoCopyRefusesWithoutDeterministicEvidence() {
    let onlySemantic = ContextIntent(semanticQuery: "那篇讲丢包恢复的论文")
    let candidates = [
        ContextualCandidate(itemID: UUID(), title: "语义感知 RDMA 丢包恢复",
                            kind: .pdf, localScore: 0.99),
    ]
    #expect(ContextualAutoCopy.uniqueTarget(candidates: candidates, intent: onlySemantic) == nil)
}

@Test("候选的证据只认本地可验证字段")
func evidenceMatchesLocalFieldsOnly() {
    let intent = ContextIntent(deterministicEvidence: ["csa-ud", "iwqos2026"])
    let hit = ContextIntentParser.evidence(
        for: intent,
        title: "面向超大规模训练的丢包恢复",
        filename: "iwqos2026-paper333-2.pdf",
        tags: ["网络"],
        group: nil
    )
    #expect(hit == ["iwqos2026"])

    let miss = ContextIntentParser.evidence(
        for: intent, title: "无关内容", filename: nil, tags: [], group: nil
    )
    #expect(miss.isEmpty)
}

@Test("去重键覆盖内容、来源、库版本与路由")
func processingKeyDistinguishesEveryDimension() {
    let base = ContextualProcessingKey(
        contentFingerprint: "a", sourceContext: "Safari",
        libraryVersion: "v1", route: "minimax/M3"
    )
    #expect(base == ContextualProcessingKey(
        contentFingerprint: "a", sourceContext: "Safari",
        libraryVersion: "v1", route: "minimax/M3"
    ))
    // 库内容变了要重新判断
    #expect(base != ContextualProcessingKey(
        contentFingerprint: "a", sourceContext: "Safari",
        libraryVersion: "v2", route: "minimax/M3"
    ))
    // 换了模型也要重新判断
    #expect(base != ContextualProcessingKey(
        contentFingerprint: "a", sourceContext: "Safari",
        libraryVersion: "v1", route: "openai/gpt"
    ))
}

@Test("发票与税号是两种意图：一个要整段抬头，一个只要那串号码")
func intentSeparatesInvoiceFromTaxNumber() {
    let invoice = ContextIntentParser.parse(event("麻烦帮我开个发票"))
    #expect(invoice.fields.contains(.invoice))

    let tax = ContextIntentParser.parse(event("你们公司税号是多少"))
    #expect(tax.fields.contains(.taxNumber))
}

@Test("字段抽取精确到值本身，抽不出就返回 nil")
func fieldExtractionReturnsTheValueOnly() {
    let block = """
    公司抬头：某某科技有限公司
    税号：91330100MA2XXXXXXA
    开户行：招商银行杭州分行 6225880123456789
    邮箱 finance@example.com
    快递单号：SF1234567890
    """
    #expect(ContextFieldExtractor.value(of: .taxNumber, in: block) == "91330100MA2XXXXXXA")
    #expect(ContextFieldExtractor.value(of: .email, in: block) == "finance@example.com")
    #expect(ContextFieldExtractor.value(of: .bankAccount, in: block) == "6225880123456789")
    #expect(ContextFieldExtractor.value(of: .trackingNumber, in: block) == "SF1234567890")

    // 发票抬头是一整段，论文是一个文件，都不该被切成一个字段
    #expect(ContextFieldExtractor.value(of: .invoice, in: block) == nil)
    #expect(ContextFieldExtractor.value(of: .paper, in: block) == nil)
    // 库里没记就不能瞎猜
    #expect(ContextFieldExtractor.value(of: .taxNumber, in: "今天天气不错") == nil)
}

@Test("库里只有一条 Pin 记着税号时才自动写回那串号码")
func uniqueFieldValueRequiresExactlyOneSource() {
    let a = UUID()
    let single = ContextualAutoCopy.uniqueFieldValue(
        field: .taxNumber,
        texts: [(a, "税号：91330100MA2XXXXXXA"), (UUID(), "和税号无关的一段话")]
    )
    #expect(single?.itemID == a)
    #expect(single?.value == "91330100MA2XXXXXXA")

    // 两家公司的税号都在库里 —— 有歧义，只推荐
    #expect(ContextualAutoCopy.uniqueFieldValue(
        field: .taxNumber,
        texts: [(UUID(), "税号：91330100MA2XXXXXXA"), (UUID(), "税号：91110108MA0YYYYYYB")]
    ) == nil)

    // 同一串号码存了两份仍然算唯一：用户拿到的是同一个结果
    #expect(ContextualAutoCopy.uniqueFieldValue(
        field: .taxNumber,
        texts: [(UUID(), "税号：91330100MA2XXXXXXA"), (UUID(), "税号 91330100MA2XXXXXXA")]
    )?.value == "91330100MA2XXXXXXA")

    #expect(ContextualAutoCopy.uniqueFieldValue(field: .taxNumber, texts: []) == nil)
}
@Test("要论文而库里统共只有一篇时直接准备好，不用再问")
func autoCopyWhenTheRequestedKindIsUnique() {
    let paper = UUID()
    let intent = ContextIntent(preferredKinds: [.pdf])
    let library = [
        ContextualCandidate(itemID: paper, title: "唯一的一篇论文", kind: .pdf, localScore: 0.6),
        ContextualCandidate(itemID: UUID(), title: "一段文字", kind: .text, localScore: 0.9),
    ]
    #expect(ContextualAutoCopy.uniqueByKind(candidates: library, intent: intent) == paper)

    // 两篇就有歧义，退回去让用户选
    let ambiguous = library + [
        ContextualCandidate(itemID: UUID(), title: "另一篇论文", kind: .pdf, localScore: 0.5),
    ]
    #expect(ContextualAutoCopy.uniqueByKind(candidates: ambiguous, intent: intent) == nil)

    // 请求没点名类型时这条规则不适用
    #expect(ContextualAutoCopy.uniqueByKind(candidates: library, intent: ContextIntent()) == nil)
}

@Test("场景不止论文和税号：简历、合同、快递单号、会议链接都能认出来")
func cueTableCoversMoreScenarios() {
    func fields(_ text: String) -> Set<ContextIntent.Field> {
        ContextIntentParser.parse(event(text)).fields
    }
    #expect(fields("方便发一下简历吗").contains(.resume))
    #expect(fields("把合同发我看看").contains(.contract))
    #expect(fields("快递单号是多少").contains(.trackingNumber))
    #expect(fields("发个会议链接").contains(.meetingLink))
    #expect(fields("那个 github 仓库地址").contains(.repositoryLink))
    #expect(fields("刚才那张截图发我").contains(.image))
    #expect(fields("加个微信号").contains(.wechatID))

    // 简历、合同、论文都偏好 PDF；截图偏好图片
    #expect(ContextIntentParser.parse(event("发一下简历")).preferredKinds.contains(.pdf))
    #expect(ContextIntentParser.parse(event("那张截图")).preferredKinds.contains(.image))
    #expect(ContextIntentParser.parse(event("帮我找一张央视报道牛来的照片")).preferredKinds.contains(.image))
    #expect(ContextIntentParser.isExplicitRequest("帮我找一张央视报道牛来的照片"))
    #expect(ContextIntentParser.isExplicitRequest("给我发一张央视新闻的图片"))
    let exactRequest = ContextIntentParser.parse(event("给我发一张央视新闻报道牛来的图片"))
    #expect(exactRequest.fields.contains(.image))
    #expect(exactRequest.preferredKinds == [.image])
    #expect(ContextIntentParser.isExplicitRequest(exactRequest.semanticQuery))
}

@Test("判定为检索请求的复制不进剪贴板轨道，普通复制照常保留")
func retrievalOnlyRequestsNeverEnterHistory() {
    #expect(ContextIntentParser.isRetrievalOnlyRequest(event("给我发一张央视新闻报道牛来的图片")))
    #expect(ContextIntentParser.isRetrievalOnlyRequest(event("帮我找一下 csa-ud 的论文")))
    #expect(ContextIntentParser.isRetrievalOnlyRequest(event("你们公司税号是多少")))

    // 只是摘抄一段带场景词的正文，不是诉求：必须继续留在最近五条里
    #expect(!ContextIntentParser.isRetrievalOnlyRequest(
        event("这篇论文提出了一种新的拥塞控制算法")
    ))
    // 没有场景词的普通请求也不算：删掉它等于吞掉用户真正想存的内容
    #expect(!ContextIntentParser.isRetrievalOnlyRequest(event("帮我看看这段话通不通顺")))
    // 粗筛挡下的内容不进入这条判定
    #expect(!ContextIntentParser.isRetrievalOnlyRequest(event("图片")))
}

@Test("没有请求动词的短名词短语也按检索处理，长正文不算")
func shortNounPhrasesAreTreatedAsQueries() {
    // 用户的原话：复制一句"央视关于牛来报道的图片"，没有"帮我""发我"
    #expect(ContextIntentParser.looksLikeRetrievalPhrase(event("央视关于牛来报道的图片")))
    #expect(ContextIntentParser.looksLikeRetrievalPhrase(event("央视牛年报道图片集锦")))
    #expect(ContextIntentParser.looksLikeRetrievalPhrase(event("csa-ud 那篇论文")))

    // 光一个类型词没有主题，不能触发
    #expect(!ContextIntentParser.looksLikeRetrievalPhrase(event("图片图片")))
    // 整段正文只是恰好含有"图片"
    #expect(!ContextIntentParser.looksLikeRetrievalPhrase(
        event("这份报告的第三章讨论了图片压缩算法在移动端的表现，并给出了对比数据")
    ))
    // 多行内容是摘抄，不是一句诉求
    #expect(!ContextIntentParser.looksLikeRetrievalPhrase(event("央视报道的图片\n第二行")))
    // 没点名类型的短语交给模型判，本地不抢
    #expect(!ContextIntentParser.looksLikeRetrievalPhrase(event("公司的税号")))
}

@Test("词表认不出的说法照样要检索：判据是库里有没有，不是说法在不在表里")
func retrievalDoesNotDependOnAClosedVocabulary() {
    // 表里有的说法当然算
    let handbook = ContextIntentParser.parse(event("研究生数学建模的手册"))
    #expect(handbook.fields.contains(.handbook))
    #expect(ContextIntentParser.isLocalRetrievalQuery(event("研究生数学建模的手册")))

    // 表里没有的说法（"网址"不在场景词表，"pi""agent"也不算标识）本地判不出，
    // 但形态上是一句短话，仍然要做一次本地召回——词表不能成为终点
    let unknown = event("pi agent 网址给我")
    #expect(!ContextIntentParser.isLocalRetrievalQuery(unknown))
    #expect(ContextRetrievalGate.shouldRecall(unknown))
    #expect(ContextRetrievalGate.shouldRecall(event("上次那个乱七八糟的东西")))

    // 成段正文和多行摘抄不看，避免每复制一段文字都去检索
    #expect(!ContextRetrievalGate.shouldRecall(
        event("这份报告的第三章讨论了图片压缩算法在移动端的表现，并给出了完整的对比数据与结论")
    ))
    #expect(!ContextRetrievalGate.shouldRecall(event("第一行内容\n第二行内容")))
}

@Test("显示与否由证据决定：明确索取照给，碰巧复制的短话要真命中")
func suggestionsRequireRealEvidence() {
    // 明确的索取即使只有弱命中也照常给——用户已经说了他要什么
    #expect(ContextRetrievalGate.shouldSuggest(bestLocalScore: 0.1, isExplicitRequest: true))

    // 只是碰巧复制了一句短话：必须真的对上库里的东西
    #expect(!ContextRetrievalGate.shouldSuggest(bestLocalScore: 0.2, isExplicitRequest: false))
    #expect(ContextRetrievalGate.shouldSuggest(
        bestLocalScore: ContextRetrievalGate.evidenceThreshold,
        isExplicitRequest: false
    ))
    // 门槛要挡得住"碰巧有个共同的词"：整句原样命中是 0.6，零散二字组远低于此
    #expect(ContextRetrievalGate.evidenceThreshold >= LexicalMatch.maximumPartialScore)
    #expect(ContextRetrievalGate.evidenceThreshold < LexicalMatch.fullPhraseScore)
}

@Test("点名了具体标识的索取，即使没有场景词也算明确检索")
func explicitRequestsWithIdentifiersCountAsQueries() {
    // 用户原话：没有"图片""截图"这类词，但点名了 test-time
    let request = event("带有 test-time 的图给我")
    #expect(ContextIntentParser.parse(request).deterministicEvidence.contains("test-time"))
    #expect(ContextIntentParser.isRetrievalOnlyRequest(request))
    // "的图""张图"这类搭配现在也认得，"图"单独一个字仍然不算
    #expect(ContextIntentParser.parse(request).preferredKinds.contains(.image))
    #expect(ContextIntentParser.parse(event("图书馆几点关门")).fields.isEmpty)

    // 只有标识没有请求词的仍然只是摘抄
    #expect(!ContextIntentParser.isRetrievalOnlyRequest(event("test-time scaling 是一种推理期方法")))
}

@Test("我要 / 想要 也是明确的索取")
func firstPersonRequestsCountAsExplicit() {
    #expect(ContextIntentParser.isRetrievalOnlyRequest(event("我要终端使用指南")))
    #expect(ContextIntentParser.isRetrievalOnlyRequest(event("想要那份研究生数模手册")))
    // 仍然要有场景词或标识，否则任何一句"我要下班了"都会被判成检索
    #expect(!ContextIntentParser.isRetrievalOnlyRequest(event("我要下班了今天真累")))
}

@Test("敏感字段即便唯一确定也不自动写回，只推荐")
func sensitiveFieldsAreNeverCopiedAutomatically() {
    #expect(ContextIntent.Field.bankAccount.isSensitive)
    #expect(ContextIntent.Field.idNumber.isSensitive)
    #expect(!ContextIntent.Field.taxNumber.isSensitive)
    #expect(!ContextIntent.Field.email.isSensitive)
}


@Test("场景词加请求词就能本地判定，不必每次都问模型")
func explicitRequestIsDetectedLocally() {
    #expect(ContextIntentParser.isExplicitRequest("给我发一下讲 UD 传输的论文"))
    #expect(ContextIntentParser.isExplicitRequest("你们公司税号是多少"))
    #expect(ContextIntentParser.isExplicitRequest("麻烦把合同发我"))
    #expect(ContextIntentParser.isExplicitRequest("Can you send the paper"))

    // 只是摘抄一段带"论文"的正文，不是诉求
    #expect(!ContextIntentParser.isExplicitRequest("这篇论文提出了一种新的拥塞控制算法"))
    #expect(!ContextIntentParser.isExplicitRequest("税号格式为 18 位统一社会信用代码"))
}

@Test("待办识别只在用户已经表达「留下它」时进行")
func todoRecognitionRequiresExplicitIntent() {
    // 拖进刘海 / ⌘P 主动收纳：入库即固定，动作本身就是表达。
    #expect(TodoRecognitionPolicy.shouldRecognize(isPinned: true, isFromNearbyDevice: false))

    // 手机 / 平板同步：内容来自另一台设备，Mac 上没有动作可等。
    #expect(TodoRecognitionPolicy.shouldRecognize(isPinned: false, isFromNearbyDevice: true))
    #expect(TodoRecognitionPolicy.shouldRecognize(isPinned: true, isFromNearbyDevice: true))

    // Mac 被动捕获的复制与截图：量大且多为过路内容，等固定。
    // 这一条曾经被漏掉，导致每复制一段文字就发一次模型请求。
    #expect(!TodoRecognitionPolicy.shouldRecognize(isPinned: false, isFromNearbyDevice: false))
}

@Test("未固定的本机剪贴板内容默认也不进索引，RAG 一并挡住")
func unpinnedLocalClipboardStaysOutOfIndex() {
    // 待办识别和 RAG 是两道闸门，但对"本机随手复制"给出同一个答案。
    #expect(!ClipboardContentProcessingPolicy.shouldProcess(
        origin: .clipboard,
        isPinned: false,
        wasAuthorizedAtCapture: false
    ))
    // 固定之后两者都放行。
    #expect(ClipboardContentProcessingPolicy.shouldProcess(
        origin: .clipboard,
        isPinned: true,
        wasAuthorizedAtCapture: false
    ))
    // 拖入 / 主动收纳不是 clipboard 来源，从来不受这道闸门限制。
    #expect(ClipboardContentProcessingPolicy.shouldProcess(
        origin: .manual,
        isPinned: true,
        wasAuthorizedAtCapture: false
    ))
}

@Test("带资料类型词的未来行动不会被当成检索查询吞掉")
func futureTaskStatementsEnterClipboardHistory() {
    for text in [
        "今天要看完项目并写完论文",
        "今天要看完项目并写完论文儿",
        "今天要写完论文",
        "明天需要提交论文",
        "下午三点找一下论文并发给老师",
    ] {
        let copied = event(text)
        #expect(!ContextIntentParser.isRetrievalOnlyRequest(copied))
        #expect(!ContextIntentParser.looksLikeRetrievalPhrase(copied))
        #expect(!ContextIntentParser.shouldSuppressPassiveCapture(copied))
    }

    // 宽松的短语召回不能删除原文；只有明确索取才不污染临时轨道。
    #expect(!ContextIntentParser.shouldSuppressPassiveCapture(event("csa-ud 那篇论文")))
    #expect(ContextIntentParser.shouldSuppressPassiveCapture(event("帮我找一下 csa-ud 的论文")))
}

@Test("本机未来任务先进入临时轨道，固定之前不识别也不索引")
func futureTaskCopyWaitsForPinBeforeProcessing() {
    let copied = event("今天要看完项目并写完论文儿")

    #expect(!ContextIntentParser.shouldSuppressPassiveCapture(copied))
    #expect(!TodoRecognitionPolicy.shouldRecognize(
        isPinned: false,
        isFromNearbyDevice: false
    ))
    #expect(!ClipboardContentProcessingPolicy.shouldProcess(
        origin: .clipboard,
        isPinned: false,
        wasAuthorizedAtCapture: false
    ))

    #expect(TodoRecognitionPolicy.shouldRecognize(
        isPinned: true,
        isFromNearbyDevice: false
    ))
    #expect(ClipboardContentProcessingPolicy.shouldProcess(
        origin: .clipboard,
        isPinned: true,
        wasAuthorizedAtCapture: false
    ))
}
