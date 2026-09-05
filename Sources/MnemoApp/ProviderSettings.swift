import AppKit
import CryptoKit
import Foundation
import ImageIO
import Observation
import MnemoCore

enum CredentialStoreError: Error, LocalizedError {
    case unexpectedStatus(OSStatus)
    case invalidData

    var errorDescription: String? {
        switch self {
        case .unexpectedStatus(let status): "凭据操作失败（\(status)）"
        case .invalidData: "凭据文件无法读取"
        }
    }
}

/// 凭据的存放：一个普通配置文件，不再用钥匙串。
///
/// 为什么换：这个应用是 ad-hoc 签名自分发，每发一版就是一次新的 cdhash，
/// 而钥匙串的 ACL 是按"创建它的那个二进制"认亲的——于是**每次装新版都要
/// 逐个供应商输一次密码**。Codex 一类工具直接把凭据放 `~/.codex/auth.json`，
/// 我们也照办：`~/.mnemo/credentials.json`，权限 0600，只有本用户能读。
///
/// 安全性上没有实质让步：登录钥匙串的默认保护是登录密码，而这个文件放在
/// 用户主目录里、权限 0600，威胁模型相同；换来的是升级零打扰。

actor CredentialStore {
    struct File: Codable {
        var version: Int = 1
        var providers: [String: String] = [:]
    }

    private let fileURL: URL
    /// 进程内缓存：避免同一次功能链上反复读盘。
    private var cache: [String: String?] = [:]

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: ".mnemo/credentials.json", directoryHint: .notDirectory)
    }

    func read(providerID: String) throws -> String? {
        if let cached = cache[providerID] { return cached }
        if let value = try loadFile().providers[providerID], !value.isEmpty {
            cache[providerID] = value
            return value
        }
        cache[providerID] = String?.none
        return nil
    }

    func save(_ credential: String, providerID: String) throws {
        var file = (try? loadFile()) ?? File()
        file.providers[providerID] = credential
        try writeFile(file)
        cache[providerID] = credential
    }

    func delete(providerID: String) throws {
        var file = try loadFile()
        file.providers.removeValue(forKey: providerID)
        try writeFile(file)
        cache[providerID] = String?.none
    }

    private func loadFile() throws -> File {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return File() }
        guard let file = try? JSONDecoder().decode(File.self, from: data) else {
            throw CredentialStoreError.invalidData
        }
        return file
    }

    private func writeFile(_ file: File) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(file)
        try data.write(to: fileURL, options: .atomic)
        // 0600：只有本用户能读。写完之后显式补一次，atomic 写在不同 umask 下
        // 可能给出更宽的权限。
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: fileURL.path
        )
    }
}

enum AppIconChoice: String, CaseIterable, Codable, Hashable, Identifiable {
    case classic = "a-classic"
    case staggered = "b-staggered"
    case dark = "c-dark"

    var id: String { rawValue }
    var title: String {
        switch self {
        // 形体统一是「开口朝上的磁石」，三套只差配色；rawValue 保持不变，
        // 换名字不会把已经存下来的选择弄丢。
        case .classic: "象牙"
        case .staggered: "深空"
        case .dark: "纯黑"
        }
    }
    var resourceName: String { "mnemo-\(rawValue)" }
}

@MainActor
@Observable
final class ProviderSettingsModel {
    private struct Persisted: Codable {
        var customProviders: [ProviderConfiguration]
        var chatProviderID: String?
        var embeddingProviderID: String?
        var embeddingModelID: String
        var routing: AIRoutingProfile
        var icon: AppIconChoice
        var officiallyRefreshedProviderIDs: [String]?
        var streamsAnswerIntoFocusedInput: Bool?
    }

    private static let persistenceKey = "Pinland.provider-settings.v1"
    /// 给打包脚本读取的纯文本镜像。完整设置仍在 JSON Data 里；脚本不该为了
    /// 找一个图标值而实现一遍 Codable / plist Data 解码。
    private static let selectedIconKey = "Pinland.selectedAppIcon"
    private static let modelsDevURL = URL(string: "https://models.dev/api.json")!
    private static let modelsDevAliases: [String: [String]] = [
        "openai": ["openai"],
        "anthropic": ["anthropic"],
        "google": ["google"],
        "deepseek": ["deepseek"],
        "moonshot": ["moonshotai-cn", "moonshotai"],
        "zhipu": ["zhipuai", "zhipuai-coding-plan"],
        "dashscope": ["alibaba-cn", "alibaba"],
        "siliconflow": ["siliconflow-cn", "siliconflow"],
        "volcengine": ["volcengine"],
        "minimax": ["minimax", "minimax-cn"],
        "openrouter": ["openrouter"],
        "ollama": ["ollama-cloud"],
        "lmstudio": ["lmstudio"],
    ]

    private let credentialStore = CredentialStore()
    private let client = AIProviderClient()
    private let executionEngine = AIExecutionEngine()
    private let embeddingDimensions: EmbeddingDimensionRegistry
    @ObservationIgnored var resumeIndexingAction: (() -> Void)?
    @ObservationIgnored var resumeAIEnrichmentAction: (() -> Void)?
    @ObservationIgnored var iconChangeAction: ((AppIconChoice) -> Void)?
    /// 命名/分类时取条目提取文本（图片 OCR、视觉标签、PDF 页块）的钩子。
    /// 没有它，图片的命名 prompt 只有"类型+文件名"，模型只能瞎编标题。
    @ObservationIgnored var enrichmentContentProvider: ((Item) async -> String?)?
    @ObservationIgnored private var embeddingResumeTask: Task<Void, Never>?
    @ObservationIgnored private var aiResumeTask: Task<Void, Never>?
    @ObservationIgnored private var embeddingCache: [String: [Float]] = [:]
    @ObservationIgnored private var embeddingCacheOrder: [String] = []
    @ObservationIgnored private var queryUnderstandingCache: [String: StructuredQuery] = [:]
    @ObservationIgnored private var queryUnderstandingCacheOrder: [String] = []
    // 快捷 Agent 的 messages / 工具状态绝不跨轮保存。这里只有“同一请求 + 同一候选 +
    // 同一路由”的最终决策缓存，避免重复按快捷键再次计费；它不参与下一轮 prompt。
    @ObservationIgnored private var retrievalDecisionCache: [String: RecommendationAgentDecision] = [:]
    @ObservationIgnored private var retrievalDecisionCacheOrder: [String] = []
    private let catalogStore: ModelCatalogStore

    var providers: [ProviderConfiguration]
    var selectedProviderID: String
    var chatProviderID: String?
    var embeddingProviderID: String?
    var embeddingModelID: String
    var routing: AIRoutingProfile
    var catalog: ModelCatalogSnapshot
    var isRefreshing: Set<String> = []
    var isRefreshingPublicMetadata = false
    var providerErrors: [String: String] = [:]
    var publicMetadataError: String?
    var keyPresence: [String: Bool] = [:]
    var iconChoice: AppIconChoice
    var statusMessage: String?
    private var officiallyRefreshedProviderIDs: Set<String>
    /// 快捷回答的落点：光标停在输入框里就边生成边写进去，否则整段进剪贴板。
    /// 默认开——这条路径的等待感几乎全在"整段生成完才动"上。
    private(set) var streamsAnswerIntoFocusedInput: Bool

    init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Pinland", directoryHint: .isDirectory) // 这条路径是数据的**家**，不是品牌名。整个库、向量索引、文件仓、
            // 目录缓存都在 ~/Library/Application Support/Pinland 里。应用改名
            // 不换数据的家——换一次家等于把用户攒下的所有东西留在原地。
        catalogStore = ModelCatalogStore(
            bundled: BundledModelCatalog.snapshot,
            cacheURL: support.appending(path: "model-catalog.json")
        )
        embeddingDimensions = EmbeddingDimensionRegistry(
            persistenceURL: support.appending(path: "embedding-dimensions.json")
        )

        let saved = UserDefaults.standard.data(forKey: Self.persistenceKey)
            .flatMap { try? JSONDecoder().decode(Persisted.self, from: $0) }
        providers = ProviderPresets.all + (saved?.customProviders ?? [])
        selectedProviderID = saved?.chatProviderID ?? "minimax"
        chatProviderID = saved?.chatProviderID
        embeddingProviderID = saved?.embeddingProviderID
        embeddingModelID = saved?.embeddingModelID ?? "qwen3.7-text-embedding"
        routing = saved?.routing ?? AIRoutingProfile()
        catalog = BundledModelCatalog.snapshot
        let savedIcon = saved?.icon ?? .staggered
        iconChoice = savedIcon
        officiallyRefreshedProviderIDs = Set(saved?.officiallyRefreshedProviderIDs ?? [])
        streamsAnswerIntoFocusedInput = saved?.streamsAnswerIntoFocusedInput ?? true
        UserDefaults.standard.set(savedIcon.rawValue, forKey: Self.selectedIconKey)

        Task {
            catalog = await catalogStore.current()
            await refreshCredentialPresence()
            applyIconChoice()
        }
    }

    var selectedProvider: ProviderConfiguration? {
        providers.first { $0.id == selectedProviderID }
    }

    func models(for providerID: String) -> [AIModelDescriptor] {
        catalog.models(providerID: providerID)
    }

    func selectProvider(_ id: String) { selectedProviderID = id }

    func saveCredential(_ value: String, providerID: String) async {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if trimmed.isEmpty {
                try await credentialStore.delete(providerID: providerID)
                keyPresence[providerID] = false
                statusMessage = "已移除凭据"
            } else {
                try await credentialStore.save(trimmed, providerID: providerID)
                keyPresence[providerID] = true
                statusMessage = "凭据已保存"
                if !officiallyRefreshedProviderIDs.contains(providerID) {
                    await refreshModels(providerID: providerID)
                }
                if embeddingProviderID == providerID { scheduleIndexResume() }
                scheduleAIResume()
            }
            providerErrors[providerID] = nil
        } catch {
            providerErrors[providerID] = error.localizedDescription
        }
    }

    func refreshModels(providerID: String) async {
        guard !isRefreshing.contains(providerID),
              let provider = providers.first(where: { $0.id == providerID }) else { return }
        isRefreshing.insert(providerID)
        providerErrors[providerID] = nil
        defer { isRefreshing.remove(providerID) }
        do {
            let key = try await credentialStore.read(providerID: providerID)
            let live = try await client.listModels(provider: provider, apiKey: key)
            catalog = try await catalogStore.replaceLiveModels(
                providerID: providerID,
                displayName: provider.displayName,
                models: live
            )
            officiallyRefreshedProviderIDs.insert(providerID)
            persist()
            statusMessage = "已更新 \(live.count) 个模型"
        } catch {
            // 旧 catalog 完全不动，视图不会先清空再回填。
            providerErrors[providerID] = error.localizedDescription
        }
    }

    /// 用户主动刷新 models.dev 的 chat 能力、限制与价格快照。Embedding 不依赖
    /// 这个目录；刷新失败时 catalog 保持原对象，界面不会经历清空和逐项回填。
    func refreshPublicModelMetadata() async {
        guard !isRefreshingPublicMetadata else { return }
        isRefreshingPublicMetadata = true
        publicMetadataError = nil
        defer { isRefreshingPublicMetadata = false }
        do {
            var request = URLRequest(url: Self.modelsDevURL)
            request.timeoutInterval = 20
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if let eTag = catalog.sourceETag {
                request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ModelCatalogError.invalidPayload
            }
            if http.statusCode == 304 {
                statusMessage = "模型能力与价格已经是最新快照"
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            catalog = try await catalogStore.mergeModelsDevPayload(
                data,
                providerAliases: Self.modelsDevAliases,
                eTag: http.value(forHTTPHeaderField: "ETag")
            )
            statusMessage = "已更新模型能力与价格"
        } catch {
            publicMetadataError = "公共元数据刷新失败：\(error.localizedDescription)"
        }
    }

    func setChatProvider(_ id: String?) async {
        chatProviderID = id
        persist()
        guard let id, !officiallyRefreshedProviderIDs.contains(id) else { return }
        await refreshModels(providerID: id)
    }

    func setEmbeddingProvider(_ id: String?) async {
        embeddingProviderID = id
        persist()
        scheduleIndexResume()
        guard let id, !officiallyRefreshedProviderIDs.contains(id) else { return }
        await refreshModels(providerID: id)
    }

    func setEmbeddingModelID(_ id: String) {
        embeddingModelID = id
        persist()
        scheduleIndexResume()
    }

    func setStreamsAnswerIntoFocusedInput(_ enabled: Bool) {
        streamsAnswerIntoFocusedInput = enabled
        persist(resumeAI: false)
    }

    func setRoute(_ route: FeatureRoute?, for feature: AIFeature) {
        routing.overrides[feature] = route
        persist()
    }

    func setFastRoute(_ route: FeatureRoute?) {
        routing.fast = route
        persist()
    }

    func setStrongRoute(_ route: FeatureRoute?) {
        routing.strong = route
        persist()
    }

    func addCustomProvider(
        name: String,
        baseURL: URL,
        dialect: ProviderDialect,
        authentication: ProviderAuthentication
    ) {
        let base = name.lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        var id = base.isEmpty ? "custom" : base
        var suffix = 2
        while providers.contains(where: { $0.id == id }) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        providers.append(.init(
            id: id,
            displayName: name,
            dialect: dialect,
            baseURL: baseURL,
            authentication: authentication,
            iconID: "custom"
        ))
        selectedProviderID = id
        persist()
    }

    /// 换图标**立即生效**，不等页面底部的"保存"。
    ///
    /// 保存栏是给那些"改错了要付代价"的设置准备的——路由、提醒时间、快捷键。
    /// 图标恰恰相反：它即时可见、随手可逆、错了也没有任何后果。要求用户先点
    /// 一下预览、再点一下保存，只会让人以为"选了没反应"。
    func setIcon(_ choice: AppIconChoice) {
        guard iconChoice != choice else { return }
        iconChoice = choice
        persist(resumeAI: false)
        UserDefaults.standard.set(choice.rawValue, forKey: Self.selectedIconKey)
        applyIconChoice()
        iconChangeAction?(choice)
    }

    /// 显式保存入口。设置页每一页的底栏都走这里，保证不仅写入偏好，还重新
    /// 应用图标与后台路由；解决“界面选了，但实际没生效”的不确定感。
    func saveSettings() {
        persist(resumeAI: true)
        UserDefaults.standard.set(iconChoice.rawValue, forKey: Self.selectedIconKey)
        applyIconChoice()
        iconChangeAction?(iconChoice)
        scheduleIndexResume()
        statusMessage = "设置已保存"
    }

    func persist(resumeAI: Bool = true) {
        let custom = providers.filter { ProviderPresets.configuration(id: $0.id) == nil }
        let value = Persisted(
            customProviders: custom,
            chatProviderID: chatProviderID,
            embeddingProviderID: embeddingProviderID,
            embeddingModelID: embeddingModelID,
            routing: routing,
            icon: iconChoice,
            officiallyRefreshedProviderIDs: officiallyRefreshedProviderIDs.sorted(),
            streamsAnswerIntoFocusedInput: streamsAnswerIntoFocusedInput
        )
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: Self.persistenceKey)
        }
        if resumeAI { scheduleAIResume() }
    }

    func credential(providerID: String) async throws -> String? {
        try await credentialStore.read(providerID: providerID)
    }

    /// 对一个新进入 Mnemo 的内容执行命名与分类。是否锁定保留不参与判断；两个功能分别走各自的路由；任一路由
    /// 未配置或敏感筛查拦截时，保留本地标题，不把失败扩大成入库失败。
    func enrich(_ item: Item) async -> ItemAIEnrichment? {
        let source = await aiSourceText(for: item)
        let namingRoute = item.titledLocally ? routing.route(for: .automaticNaming) : nil
        let classificationRoute = item.group == nil && item.tags.isEmpty
            ? routing.route(for: .automaticClassification)
            : nil
        guard namingRoute != nil || classificationRoute != nil else { return nil }
        var merged = ItemAIEnrichment(
            title: item.title,
            group: item.group,
            tags: item.tags,
            didGenerateTitle: false,
            didGenerateClassification: false,
            wasPrivacyBlocked: false
        )
        var changed = false
        var privacyBlocked = false

        // 两个功能路由完全相同时，一次结构化输出同时完成，避免重复 token 与网络唤醒。
        if let namingRoute, namingRoute == classificationRoute {
            do {
                let value: ItemAIEnrichment = try await completeStructured(
                    feature: .automaticNaming,
                    system: "你是 Mnemo 的内容整理器。只返回 JSON 对象，不要 Markdown。",
                    prompt: "生成不超过 20 个汉字的标题、一个简短分组和最多 5 个标签。返回 {\"title\":\"...\",\"group\":\"...\",\"tags\":[\"...\"]}。\n\n\(source)",
                    privacyText: source,
                    maxTokens: 220,
                    allowSensitiveContent: item.allowsSensitiveAI,
                    parse: AIStructuredOutput.enrichment(from:)
                )
                return ItemAIEnrichment(
                    title: value.title,
                    group: value.group,
                    tags: value.tags,
                    didGenerateTitle: true,
                    didGenerateClassification: true
                )
            } catch let error as AIExecutionError {
                if case .privacyBlocked = error {
                    return ItemAIEnrichment(
                        title: item.title,
                        group: item.group,
                        tags: item.tags,
                        didGenerateTitle: false,
                        didGenerateClassification: false,
                        wasPrivacyBlocked: true
                    )
                }
                return nil
            } catch {
                return nil
            }
        }

        if namingRoute != nil, !Task.isCancelled {
            do {
                let value: ItemAIEnrichment = try await completeStructured(
                    feature: .automaticNaming,
                    system: "你是 Mnemo 的标题整理器。只返回 JSON 对象，不要 Markdown。",
                    prompt: "为下列内容生成不超过 20 个汉字的标题。返回 {\"title\":\"...\"}。\n\n\(source)",
                    privacyText: source,
                    maxTokens: 120,
                    allowSensitiveContent: item.allowsSensitiveAI,
                    parse: AIStructuredOutput.enrichment(from:)
                )
                merged.title = value.title
                merged.didGenerateTitle = true
                changed = true
            } catch let error as AIExecutionError {
                if case .privacyBlocked = error { privacyBlocked = true }
            } catch {
                // 未配置、隐私拦截、网络失败都只保留本地回退值。
            }
        }

        if classificationRoute != nil, !Task.isCancelled {
            do {
                let value: ItemAIEnrichment = try await completeStructured(
                    feature: .automaticClassification,
                    system: "你是 Mnemo 的内容分类器。只返回 JSON 对象，不要 Markdown。",
                    prompt: "为内容给出一个简短分组和最多 5 个标签。返回 {\"title\":\"分类摘要\",\"group\":\"...\",\"tags\":[\"...\"]}。\n\n\(source)",
                    privacyText: source,
                    maxTokens: 160,
                    allowSensitiveContent: item.allowsSensitiveAI,
                    parse: AIStructuredOutput.enrichment(from:)
                )
                merged.group = value.group
                merged.tags = value.tags
                merged.didGenerateClassification = true
                changed = true
            } catch let error as AIExecutionError {
                if case .privacyBlocked = error { privacyBlocked = true }
            } catch {
                // 分类失败不覆盖已成功的命名，也不影响 Pin 可用性。
            }
        }
        merged.wasPrivacyBlocked = privacyBlocked
        return (changed || privacyBlocked) && !Task.isCancelled ? merged : nil
    }

    // MARK: - 分组

    /// 给刚拖出来的一组卡片起个名字。
    ///
    /// 用户把两张卡叠在一起的那一刻，心里已经有一个词了（"招聘信息""房子"），
    /// 只是懒得打。让模型看一眼这两张是什么，把那个词说出来——猜错了改一下
    /// 就是，总好过一律叫"新分组 1"。
    ///
    /// 走分类那条路由：这本来就是分类任务，不值得为它单开一个功能项让用户
    /// 再配一遍模型。
    func nameGroup(summaries: [String]) async -> String? {
        guard routing.route(for: .automaticClassification) != nil else { return nil }
        let joined = summaries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(6)
            .enumerated()
            .map { "\($0.offset + 1). \(String($0.element.prefix(200)))" }
            .joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        do {
            return try await completeStructured(
                feature: .automaticClassification,
                system: "你是 Mnemo 的分组命名器。只返回 JSON 对象，不要 Markdown。",
                prompt: """
                下面几条内容被用户归成了一组。用一个**不超过 6 个汉字**的短语概括它们的共同点，\
                当作这个分组的名字。像文件夹名一样：名词短语，不要动词句，不要标点，不要引号。
                返回 {"name":"..."}。

                \(joined)
                """,
                privacyText: joined,
                maxTokens: 60,
                allowSensitiveContent: false,
                parse: { output in
                    let data = try AIStructuredOutput.objectData(from: output)
                    guard let object = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any],
                          let name = object["name"] as? String else {
                        throw AIExecutionError.malformedStructuredOutput
                    }
                    let trimmed = name.trimmingCharacters(
                        in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"「」''"))
                    )
                    guard !trimmed.isEmpty else {
                        throw AIExecutionError.malformedStructuredOutput
                    }
                    return String(trimmed.prefix(12))
                }
            )
        } catch {
            // 起名字失败不影响分组成立，本地那个"新分组 N"顶上。
            return nil
        }
    }

    /// 这条新内容属于已有的哪个分组，或者哪个都不属于。
    ///
    /// 模型只能在**给定的编号**里选，或者返回 0 表示不归。这样它指认不了
    /// 清单外的东西，也没法凭空造一个新分组——建组永远是用户的动作。
    func assignGroup(summary: String, groupNames: [String]) async -> Int? {
        guard routing.route(for: .automaticClassification) != nil,
              !groupNames.isEmpty else { return nil }
        let content = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard content.count >= 4 else { return nil }
        let list = groupNames.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")
        do {
            let index: Int = try await completeStructured(
                feature: .automaticClassification,
                system: "你是 Mnemo 的归类器。只返回 JSON 对象，不要 Markdown。",
                prompt: """
                用户有这些分组：
                \(list)

                下面这条新内容明显属于其中某一组吗？只有**很确定**时才选，\
                拿不准一律返回 0——归错一条比漏归一条更烦人。
                返回 {"group":编号}，不属于任何一组时 {"group":0}。

                \(String(content.prefix(600)))
                """,
                privacyText: content,
                maxTokens: 40,
                allowSensitiveContent: false,
                parse: { output in
                    let data = try AIStructuredOutput.objectData(from: output)
                    guard let object = try? JSONSerialization.jsonObject(with: data)
                            as? [String: Any] else {
                        throw AIExecutionError.malformedStructuredOutput
                    }
                    // 模型偶尔把编号写成字符串。它表达的意思没有歧义，接住即可。
                    if let value = object["group"] as? Int { return value }
                    if let text = object["group"] as? String, let value = Int(text) { return value }
                    throw AIExecutionError.malformedStructuredOutput
                }
            )
            guard index >= 1, index <= groupNames.count else { return nil }
            return index - 1
        } catch {
            return nil
        }
    }

    /// 待办协调：这段新看到的文字，对现有待办做了什么。
    ///
    /// 调用时机由 App 层把关：只有拖入、显式收纳、固定后的 Mac 内容或
    /// 通用剪贴板会走到这里。模型负责泛化语义，本地层负责证据、编号与动作白名单。
    /// 没配路由就返回 unavailable，整条链退化成纯本地，不会偷偷发请求。
    ///
    /// 模型的权限边界写死在两处，不靠提示词自觉：
    ///
    /// 1. 现有待办以**编号**给出，真实 ID 它看不到，所以指认不了清单外的东西；
    /// 2. 返回的编号越界、动作和字段对不上，一律在解析层降级成"什么都不做"。
    func reviseTodos(
        text: String,
        candidates: [TodoRevisionCandidate],
        now: Date = .now
    ) async -> TodoInterpretation {
        guard let route = routing.route(for: .todoRevision) else { return .unavailable }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 4 else { return .unavailable }
        do {
            // 每次新识别都通过工具获取本轮时钟；不复用昨天的相对时间决策。
            return .decided(try await TodoToolSession.run(
                text: trimmed,
                candidateIndices: Set(candidates.map(\.index)),
                now: now,
                calendar: .autoupdatingCurrent
            ) { turns in
                let result = try await self.complete(
                    feature: .todoRevision,
                    system: TodoRevisionPrompt.toolSystem,
                    prompt: TodoRevisionPrompt.toolUserMessage(text: trimmed, candidates: candidates),
                    privacyText: trimmed + "\n" + candidates.compactMap(\.sourceContext).joined(separator: "\n"),
                    maxTokens: 2_400,
                    tools: TodoTools.all,
                    turns: turns
                )
                return result.output
            })
        } catch is CancellationError {
            return .unavailable
        } catch {
            // 失败不缓存，也不当成"模型说没事"。过去这里静默返回 nil，
            // OCR 明明成功却没有任何候选，用户只能感受到"很不稳定"。
            let reason = error.localizedDescription
            providerErrors[route.providerID] = "待办理解失败：\(reason)"
            statusMessage = "待办理解失败，稍后自动重试"
            NSLog("[MnemoTodo] model failed: %@", reason)
            return .failed(reason: reason)
        }
    }

    /// 输入过程中只做本地解析；用户显式提交后才调用这里。相同查询与路由在
    /// 本次运行中复用结果，避免回车、按钮和焦点变化造成重复计费。
    func understandQuery(_ query: String, now: Date = .now) async -> StructuredQuery {
        let fallback = QueryUnderstanding.localParse(query, now: now)
        guard let route = routing.route(for: .queryParsing),
              !route.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        let rawKey = [
            route.providerID,
            route.modelID,
            route.reasoningEffort.rawValue,
            query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: "|")
        let cacheKey = SHA256.hash(data: Data(rawKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let cached = queryUnderstandingCache[cacheKey] { return cached }

        struct Payload: Decodable {
            var kinds: [String]?
            var startDate: String?
            var endDate: String?
            var semanticText: String?
        }

        do {
            let understood: StructuredQuery = try await completeStructured(
                feature: .queryParsing,
                system: "你是 Mnemo 的搜索查询解析器。只拆条件，不回答问题；只返回 JSON。",
                prompt: """
                当前时间：\(ISO8601DateFormatter().string(from: now))
                把查询拆成：kinds（只能是 text/image/pdf/link/file/binary）、startDate、endDate（ISO 8601，可为 null）、semanticText。
                返回 {"kinds":[],"startDate":null,"endDate":null,"semanticText":"..."}。
                查询：\(query.prefix(1_000))
                """,
                privacyText: query,
                maxTokens: 240,
                parse: { output in
                    let data = try AIStructuredOutput.objectData(from: output)
                    let payload = try JSONDecoder().decode(Payload.self, from: data)
                    let kinds = Set((payload.kinds ?? []).compactMap(ItemKind.init(rawValue:)))
                    let iso = ISO8601DateFormatter()
                    let parseDate: (String?) -> Date? = { value in
                        guard let value else { return nil }
                        if let date = iso.date(from: value) { return date }
                        return try? Date(value, strategy: .iso8601.year().month().day())
                    }
                    let semantic = (payload.semanticText ?? fallback.semanticText)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return StructuredQuery(
                        kinds: kinds,
                        startDate: parseDate(payload.startDate) ?? fallback.startDate,
                        endDate: parseDate(payload.endDate) ?? fallback.endDate,
                        // 排序偏好不问模型：它是本地词表逐字判出来的确定事实，
                        // 而模型这一步只负责拆条件。让它有机会覆盖，等于给
                        // "最新一版"这种明确要求加了一次没有必要的失败机会。
                        recency: fallback.recency,
                        semanticText: semantic.isEmpty && kinds.isEmpty
                            ? fallback.semanticText
                            : semantic
                    )
                }
            )
            if queryUnderstandingCache[cacheKey] == nil {
                queryUnderstandingCacheOrder.append(cacheKey)
            }
            queryUnderstandingCache[cacheKey] = understood
            while queryUnderstandingCacheOrder.count > 64 {
                queryUnderstandingCache[queryUnderstandingCacheOrder.removeFirst()] = nil
            }
            return understood
        } catch {
            return fallback
        }
    }

    /// Agent-style final stage: the model may only rank IDs returned by local RAG.
    /// Query parsing and embedding remain separate tools so model output can never
    /// invent a file that was not found on this Mac.
    // 曾经有一次布尔模型调用在这里判断"这段复制要不要检索"。它对同一句话
    // 时而判是时而判否，没配模型时又恒返回否（被当成了"答案是否"），
    // 现在换成了 ContextRetrievalGate：形态 + 本地证据，不花调用也不看词表。

    /// 这段刚被复制的文字，是不是用户在"找东西"。
    ///
    /// 唯一用途是决定它要不要留进剪贴板轨道——有些应用一选中就自动写剪贴板，
    /// 那些片段大多是一句在找什么的话，留下来只会把真正想存的挤掉。
    ///
    /// 用模型而不是词表：说法无穷无尽（手册、指南、网址、"pi agent 的网址"），
    /// 词表永远追不上。判不出或没配模型时一律返回 false——宁可多留一条，
    /// 也不能把用户真想存的东西悄悄删掉。
    func isRetrievalQuery(_ text: String) async -> Bool {
        guard routing.route(for: .sceneRecognition) != nil else { return false }
        do {
            return try await completeStructured(
                feature: .sceneRecognition,
                system: """
                判断一段刚被复制的文字是不是"用户在找某样东西"——例如向别人索取\
                一份材料、问某个字段的值、描述他想要的那张图或那篇文档。
                摘抄的正文、代码、随手拷的一句话都不算。只返回 JSON。
                """,
                prompt: "刚复制的内容：\n\(text.prefix(600))\n只返回 {\"isQuery\":true/false}",
                privacyText: text,
                maxTokens: 60,
                parse: { output in
                    guard let data = AgenticAnswerAccumulator.extractJSONObject(from: output),
                          let root = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { throw AIExecutionError.malformedStructuredOutput }
                    return (root["isQuery"] as? Bool) ?? false
                }
            )
        } catch {
            return false
        }
    }

    /// Agent 式搜索的一次回答。总结逐段到达，卡片等流结束才确定。
    enum SearchAnswerEvent: Sendable {
        /// 累计到当前的可展示总结，直接替换上一次，不要自己拼接。
        case summary(String)
        /// 累计到当前的思考过程，同样是替换语义。它和 summary 是两条独立通道：
        /// 界面把它折叠起来单独展示，绝不能拼进正文。
        case reasoning(String)
        case recommendations(RetrievalSelection)
    }

    private struct SearchAnswerPrompt {
        var system: String
        var prompt: String
        var privacyText: String
    }

    /// 自然语言搜索：模型在本地 RAG 候选之内回答"库里有没有、是哪一个"，
    /// 再挑出要展示的 Pin。它只能引用候选里的 itemID —— 是排序与解释，
    /// 不是内容来源。答案走 SSE 逐段上屏。
    func streamSearchAnswer(
        query: String,
        candidates: [RetrievalRankingCandidate],
        recency: RecencyPreference? = nil
    ) -> AsyncThrowingStream<SearchAnswerEvent, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    let request = try self.searchAnswerPrompt(
                        query: query,
                        candidates: candidates,
                        recency: recency
                    )
                    var accumulator = AgenticAnswerAccumulator()
                    var lastSummary = ""
                    var lastReasoning = ""
                    var reasoning = ""
                    var receivedAnything = false

                    func publishSummary() {
                        let summary = accumulator.displaySummary
                        // 分隔符残缺时 displaySummary 不变，别为没变化的文本刷 UI。
                        guard summary != lastSummary else { return }
                        lastSummary = summary
                        continuation.yield(.summary(summary))
                    }

                    func publishReasoning() {
                        guard reasoning != lastReasoning else { return }
                        lastReasoning = reasoning
                        continuation.yield(.reasoning(reasoning))
                    }

                    for try await chunk in try await self.searchAnswerDeltas(request) {
                        try Task.checkCancellation()
                        receivedAnything = true
                        switch chunk {
                        case .reasoning(let value):
                            reasoning += value
                            publishReasoning()
                        case .text(let value):
                            // 正文通道里还可能内联着 <think>，交给 accumulator 现切。
                            accumulator.consume(value)
                            if !accumulator.reasoning.isEmpty, accumulator.reasoning != reasoning {
                                reasoning = accumulator.reasoning
                                publishReasoning()
                            }
                            publishSummary()
                        }
                    }

                    // 供应商不支持 stream、或返回的不是 SSE 时，流会空着正常结束：
                    // 没有文字也没有报错。退回一次性请求，否则界面上就是"什么都
                    // 没发生"，用户无从判断是没结果还是没跑起来。
                    if !receivedAnything {
                        let result = try await self.complete(
                            feature: .retrievalRecommendation,
                            system: request.system,
                            prompt: request.prompt,
                            privacyText: request.privacyText,
                            maxTokens: 1_400
                        )
                        accumulator.consume(result.output.text)
                        publishSummary()
                    }

                    // 收尾时用 finalizedSummary：模型忘了写分隔符的话，JSON 会
                    // 混在正文里，这一步把它摘掉再定稿。finish() 先把推理过滤器
                    // 扣住的尾巴交出来，否则最后几个字会永远留在缓冲里。
                    accumulator.finish()
                    if !accumulator.reasoning.isEmpty, accumulator.reasoning != reasoning {
                        reasoning = accumulator.reasoning
                        publishReasoning()
                    }
                    let finalSummary = accumulator.finalizedSummary
                    if finalSummary != lastSummary { continuation.yield(.summary(finalSummary)) }
                    continuation.yield(.recommendations(
                        accumulator.recommendationSelection(
                            allowedItemIDs: Set(candidates.map(\.itemID))
                        )
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 提示词里那段共用的时间说明。
    private static func temporalGuidance(now: Date, recency: RecencyPreference?) -> String {
        let preference = switch recency {
        case .newest:
            "用户这次明确要「最新」的一版：同族里优先选 versionRank=1，跨条目优先选 contentDate 最大的。"
        case .oldest:
            "用户这次明确要「最早」的一版：同族里优先选 versionRank 最大的，跨条目优先选 contentDate 最小的。"
        case nil:
            "用户没有说要哪一版。同一份东西有多版又无从判断时，给最新的一版，并在回答里提一句还有更早的版本。"
        }
        return """
        现在是 \(RetrievalTemporalFormat.absolute(now))。候选里的时间都是绝对时间，直接比大小，不要自己换算。
        - contentDate 是内容自己的时间。contentDateIsFromFile=false 表示这条只有入库时间可用（剪贴板文字、截图），它说明的是什么时候存进来的，不代表内容是那天写的。
        - capturedAt 是收进 Mnemo 的时间。用户说「上周存的」指它，说「三月那版」指 contentDate。
        - versionGroup 表示本地认出这几条是同一份东西的不同版本，versionRank=1 是其中最新的一版。缺这几个字段只说明本地没把握分族，你仍然可以按 contentDate 自己判断。
        \(preference)
        """
    }

    private func searchAnswerPrompt(
        query: String,
        candidates: [RetrievalRankingCandidate],
        recency: RecencyPreference?,
        now: Date = .now
    ) throws -> SearchAnswerPrompt {
        let candidateObjects = RetrievalEvidence.payload(candidates, snippetKey: "excerpt", now: now)
        let data = try JSONSerialization.data(withJSONObject: candidateObjects)
        let candidateJSON = String(decoding: data, as: UTF8.self)

        return SearchAnswerPrompt(
            system: """
            你是 Mnemo 的库内检索助手。用户的库已经检索过，下面的候选就是全部\
            可用材料，没有别的地方可查。

            关于候选字段：
            - title 可能是 AI 生成的概括，filename 往往才带着真正的标识（会议、编号、DOI）。
            - excerpt 就是这条候选的完整可读正文，不是摘要，答案如果在它里面就一定看得到。
            - excerptOmitted=true 表示这一条的正文太长、本次没有随负载给出，不是它没有内容。
            - hasLocalEvidence=false 表示本地没有任何关键词或向量命中，它只是被\
            补进来供你按标题和文件名判断，不要因为它出现在列表里就当作证据。

            关于时间：
            \(Self.temporalGuidance(now: now, recency: recency))

            输出格式，严格照做：
            1. 先用用户提问所用的语言写回答，**最多两句**：第一句直接说找到的是哪一个，
            第二句只在确有必要时补一个关键辨认依据（版本、日期、文件名）。不要复述你的
            比对过程，不要罗列你排除了哪些候选，不要用「根据」「让我们」这类开场。\
            候选里确实没有合适的就直说没有，并给一句可操作的建议（换个说法、或先补充内容）。
            2. 另起一行，单独写 \(AgenticAnswerAccumulator.delimiter)
            3. 再输出 JSON，不要加代码围栏：
            {"recommendations":[{"itemID":"候选里的 UUID","confidence":0.0,"reason":"不超过 30 字"}]}
            4. JSON 之后不要再写任何内容。

            硬性约束：
            - itemID 只能原样抄候选里的，一个字符都不能改，更不能编造。
            - 没有把握就少推荐几个，宁可返回空数组，也不要凑数。
            - 不要在回答里罗列 itemID 或 JSON，那是给程序看的。
            """,
            prompt: """
            用户要找：\(query.prefix(1_000))

            候选（共 \(candidates.count) 条）：
            \(candidateJSON)
            """,
            privacyText: "\(query)\n\(candidates.map(\.snippet).joined(separator: "\n"))"
        )
    }

    private func searchAnswerDeltas(
        _ request: SearchAnswerPrompt
    ) async throws -> AsyncThrowingStream<AIStreamChunk, any Error> {
        let credentialStore = credentialStore
        return try await executionEngine.streamComplete(
            feature: .retrievalRecommendation,
            profile: routing,
            providers: providers,
            catalog: catalog,
            credentialLoader: { providerID in
                try await credentialStore.read(providerID: providerID)
            },
            system: request.system,
            prompt: request.prompt,
            privacyText: request.privacyText,
            maxTokens: 1_400
        )
    }

    enum RetrievalRankingResult: Sendable {
        /// 模型成功给出了机器可读结论；空数组表示“没有相关候选”，也是有效结论。
        case selected(RecommendationAgentDecision)
        /// 未配置、网络失败或结构化输出损坏。调用方可以明确降级到本地证据，
        /// 但不能把它误当成模型主动返回空数组。
        case unavailable
    }

    /// 快捷推荐 Agent 的第一步：在真实 RAG 候选内选择证据，并决定接下来要
    /// “交付内容”还是“回答问题”。每次调用只构造一条全新的 system + user 消息；
    /// 不读取、不保存历史 message，也不把上一次工具结果塞进下一轮。
    func recommendSearchResults(
        query: String,
        candidates: [RetrievalRankingCandidate],
        recency: RecencyPreference? = nil,
        now: Date = .now
    ) async -> RetrievalRankingResult {
        guard !candidates.isEmpty,
              let route = routing.route(for: .retrievalRecommendation),
              !route.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unavailable
        }
        let fingerprint = candidates.map {
            [
                $0.itemID.uuidString, $0.title, $0.kind.rawValue, $0.filename ?? "",
                $0.group ?? "", $0.tags.joined(separator: ","), String($0.localScore),
                String($0.hasLocalEvidence), $0.snippet,
                // 时间进指纹：同一批候选被重新索引、文件被改动之后，"最新那版"
                // 的答案会变，不能拿旧结论顶上。
                RetrievalTemporalFormat.absolute($0.temporal.contentDate),
                $0.versionGroup ?? "", $0.versionRank.map(String.init) ?? "",
            ].joined(separator: "|")
        }.joined(separator: "\n")
        let providerFingerprint = providers.first(where: { $0.id == route.providerID }).map {
            "\($0.baseURL.absoluteString)|\($0.dialect.rawValue)"
        } ?? ""
        let rawKey = [
            RecommendationIntentFewShot.version,
            route.providerID, providerFingerprint, route.modelID, route.reasoningEffort.rawValue,
            query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            // 排序偏好属于问题的一部分：「tii 论文」和「tii 论文最新版」不是
            // 同一个问题，共用一条缓存等于第二问永远拿到第一问的答案。
            recency?.rawValue ?? "any",
            // 「最新」是相对现在说的。跨天之后同一句话的正确答案可能不同，
            // 让缓存至多活一天。
            RetrievalTemporalFormat.dayKey(now),
            fingerprint,
        ].joined(separator: "|")
        let cacheKey = SHA256.hash(data: Data(rawKey.utf8))
            .map { String(format: "%02x", $0) }.joined()
        if let cached = retrievalDecisionCache[cacheKey] { return .selected(cached) }

        // 和流式搜索共用“先压每项、再完整序列化”的规则，绝不从 JSON 中间截断。
        let candidateObjects = RetrievalEvidence.payload(candidates, snippetKey: "snippet", now: now)
        guard let data = try? JSONSerialization.data(withJSONObject: candidateObjects),
              let candidateJSON = String(data: data, encoding: .utf8) else { return .unavailable }
        let allowedIDs = Set(candidates.map(\.itemID))
        let controllerStarted = Date()
        do {
            let decision: RecommendationAgentDecision = try await completeStructured(
                feature: .retrievalRecommendation,
                system: """
                你是 Mnemo 快捷推荐 Agent 的控制器。每次调用都是完全独立的新任务，
                没有历史对话。你只能选择本次给出的本地候选 itemID，不能创造文件、
                链接、字段值或候选外事实。只返回 JSON。
                """,
                prompt: """
                用户请求：\(query.prefix(1_000))

                先判断用户最终期待收到的**唯一输出**。这个判断与候选类型无关：
                PDF、普通文件、图片、网页、文字笔记、表格、日志、代码都可能被交付，
                也都可能只作为解释 / 分析 / 总结的内部证据。
                - retrieve：最终产物是库里已有的对象或精确原值。用户要拿到、发送、复制、
                  下载、粘贴文件 / 图片 / 链接 / 表格 / 代码 / 日志 / 号码 / 本地原文。
                - answer：最终产物是新生成的知识结果。用户要知道内容讲了什么、含义、原因、
                  运行方式、观点、结论、趋势、风险、差异、摘要或分析。候选只作内部证据。

                不能同时选择两种输出，也不能按“是不是论文”判断。先在脑中补全一句：
                “回答结束时，用户应该拿到的是 ____。”若空格里是原对象 / 原值就 retrieve；
                若是解释 / 结论 / 分析就 answer。

                特别注意：请求里点名了某个对象，不等于用户要那个对象。
                “qkv 截图里讲了什么”点名了截图，但追问的是内容，最终产物是解释，
                因此是 answer。只有真正无法判断意图时才选 retrieve。

                Few-shot 边界示例（示例中的判断只示范 intent，不提供候选 ID）：
                \(RecommendationIntentFewShot.promptBlock)

                关于时间：
                \(Self.temporalGuidance(now: now, recency: recency))

                根据候选标题、类型、命中片段、时间与本地分数选择最多 3 项证据 / 交付目标。
                只列确实相关的；不相关就返回空数组，不要凑数。
                hasLocalEvidence=false 表示本地没有词法或向量证据，只是补进候选池供判断。
                itemID 必须原样抄候选里的 UUID。

                intent=retrieve 时，recommendations 是要展示 / 交付的结果；用户只要候选
                里的一小段原值（网址、单号、某个名字）时才填写 copyText，且必须逐字
                出现在 snippet 里。要整份内容时留空。
                intent=answer 时，recommendations 只是回答器要读取的内部证据 ID；copyText
                必须留空，界面不会展示这些文件卡，只显示下一步生成的回答。

                返回：
                {"intent":"retrieve|answer","recommendations":[{"itemID":"UUID","confidence":0.0,"reason":"简短依据","copyText":"可选原文"}]}

                候选：\(candidateJSON)
                """,
                privacyText: "\(query)\n\(candidates.map(\.snippet).joined(separator: "\n"))",
                maxTokens: 700,
                parse: { output in
                    let modelJSON = try AIStructuredOutput.objectData(from: output)
                    guard case .selected(let decision) = AgenticRetrieval.decision(
                        modelJSON: modelJSON,
                        allowedItemIDs: allowedIDs,
                        limit: 3,
                        requiresExplicitIntent: true
                    ) else { throw AIExecutionError.malformedStructuredOutput }
                    // 请求明确在追问内容时，把 retrieve 纠正回 answer：模型偶尔
                    // 被"点名了某个对象"带偏，塞一段原文当答案。
                    return decision.correctedByIntentFloor(request: query)
                }
            )
            AppModel.ContextTrace.log(String(
                format: "控制器耗时 %.2fs（意图判断 + 候选选择，非流式，必须整段返回）",
                Date().timeIntervalSince(controllerStarted)
            ))
            retrievalDecisionCache[cacheKey] = decision
            retrievalDecisionCacheOrder.append(cacheKey)
            while retrievalDecisionCacheOrder.count > 64 {
                retrievalDecisionCache[retrievalDecisionCacheOrder.removeFirst()] = nil
            }
            return .selected(decision)
        } catch {
            // 失败不写“已尝试”黑名单；网络或 Key 修复后，同一个请求可以重试。
            return .unavailable
        }
    }

    var clipboardContextRouteFingerprint: String? {
        let features: [AIFeature] = [.sceneRecognition, .retrievalRecommendation]
        let routes = features.compactMap { feature -> String? in
            guard let route = routing.route(for: feature),
                  let provider = providers.first(where: { $0.id == route.providerID }) else { return nil }
            return [
                feature.rawValue, provider.id, provider.baseURL.absoluteString,
                provider.dialect.rawValue, route.modelID, route.reasoningEffort.rawValue,
            ].joined(separator: "|")
        }
        let embedding = [embeddingProviderID ?? "", embeddingModelID].joined(separator: "|")
        return (routes + [embedding]).joined(separator: "||")
    }

    var sceneRecommendationRouteFingerprint: String? {
        guard let route = routing.route(for: .sceneRecognition),
              !route.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let provider = providers.first(where: { $0.id == route.providerID }) else { return nil }
        return [
            provider.id,
            provider.baseURL.absoluteString,
            provider.dialect.rawValue,
            route.modelID,
            route.reasoningEffort.rawValue,
        ].joined(separator: "|")
    }

    /// `nil` 表示没有配置或本次调用失败；调用方会继续显示本地白名单建议，
    /// 并在配置或网络状态变化前避免重复请求。
    func sceneRecommendations(for item: Item) async -> [SceneRecommendation]? {
        let text = inlineText(for: item)
        let context = SceneContext(kind: item.kind, text: text, sourceApplication: nil)
        let candidates = SceneRecognition.localCandidates(for: context)
        guard routing.route(for: .sceneRecognition) != nil else { return nil }

        let candidateJSON = candidates.map {
            ["actionID": $0.id.rawValue, "title": $0.title, "reason": $0.localReason]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: candidateJSON),
              let candidateText = String(data: data, encoding: .utf8) else { return nil }
        let privacyText = text ?? item.originalFilename ?? item.title
        do {
            let modelJSON: Data = try await completeStructured(
                feature: .sceneRecognition,
                system: "你只能排序用户给出的动作候选，不能发明动作。只返回 JSON。",
                prompt: "根据内容选择最多 3 项。返回 {\"recommendations\":[{\"actionID\":\"...\",\"confidence\":0.0,\"reason\":\"...\"}]}。候选：\(candidateText)\n内容：\(privacyText.prefix(3000))",
                privacyText: privacyText,
                maxTokens: 320,
                allowSensitiveContent: item.allowsSensitiveAI,
                parse: AIStructuredOutput.objectData(from:)
            )
            return SceneRecognition.validatedRecommendations(modelJSON: modelJSON, candidates: candidates)
        } catch {
            return nil
        }
    }

    /// 所有会覆盖剪贴板的加工都由详情页按钮显式触发后才到这里。
    func transform(_ item: Item, action: SceneActionID) async -> String? {
        guard let text = inlineText(for: item) else { return nil }
        switch action {
        case .plainText:
            return text
        case .extractTaxNumber:
            return Self.extractTaxNumber(from: text)
        case .translate, .summarize:
            guard routing.route(for: .pasteTransformation) != nil else { return nil }
            let instruction = action == .translate
                ? "翻译为简体中文；如果原文已经是中文则翻译为自然英文。只输出译文。"
                : "提炼为不超过 5 条的简洁要点。只输出结果。"
            do {
                let result = try await complete(
                    feature: .pasteTransformation,
                    system: "你是 Mnemo 的用户触发式文本加工器。",
                    prompt: "\(instruction)\n\n\(text.prefix(8_000))",
                    privacyText: text,
                    maxTokens: 900,
                    allowSensitiveContent: item.allowsSensitiveAI
                )
                return ReasoningTrace.stripped(result.output.text)
            } catch {
                return nil
            }
        default:
            return nil
        }
    }

    /// 回答步骤单独的 token 预算。快捷回答可能需要解释长文 / 图表；1,800 对稍长
    /// 的中文回答仍会顶到上限，放宽到 4,096。流式写入不会因此拖慢首字，只影响
    /// 最长能写多少；供应商若仍明确截断，仍按未完成处理。
    private static let answerMaxTokens = 4_096

    /// 快捷推荐 Agent 的最后一步。输入只包含本轮 controller 选中的真实本地证据；
    /// 不接收上轮 messages，也不复用 `copyText`。用户已明确要求这条路径用中文，
    /// 因此即使论文证据是英文，交付的解释也必须完整地写成简体中文。
    private func answerPrompt(
        question: String,
        evidence: [RecommendationAnswerEvidence],
        wantsPlainText: Bool
    ) -> SearchAnswerPrompt? {
        guard !evidence.isEmpty,
              routing.route(for: .retrievalRecommendation) != nil else { return nil }
        let evidenceObjects: [[String: Any]] = evidence.map { item in
            var object: [String: Any] = [
                "itemID": item.itemID.uuidString,
                "title": item.title,
                "excerpts": item.excerpts,
            ]
            if let filename = item.filename { object["filename"] = filename }
            return object
        }
        guard let data = try? JSONSerialization.data(withJSONObject: evidenceObjects),
              let evidenceJSON = String(data: data, encoding: .utf8) else { return nil }
        // 写进别人的输入框时不要 Markdown 记号：聊天框、搜索框不会渲染，
        // 用户看到的就是一堆 ** 和 #。剪贴板那条路径仍然允许简洁 Markdown。
        let formatRule = wantsPlainText
            ? "输出纯文本，不要 Markdown 记号、不要代码围栏、不要标题符号；分点时直接用「1. 」这类中文行文。"
            : "可以使用简洁 Markdown。"
        return SearchAnswerPrompt(
            system: """
            你是 Mnemo 快捷推荐 Agent 的回答器。这是一次完全独立的新任务，
            不存在也不得假定任何历史对话。只能依据本轮提供的本地证据回答，
            不补充候选外事实。无论证据是什么语言，都用自然、完整的简体中文回答。
            如果证据不足以回答，就明确指出缺什么；不要用半句原文、不要输出 JSON、
            不要提 itemID。\(formatRule)

            只交结论，不交过程。用户看到的是刘海下面一张很小的卡片，位置只够
            放几句话：
            - 第一句就是答案本身，不要用「根据提供的材料」「让我们来看」这类开场；
            - 不要复述你的分析步骤，不要写「首先…其次…最后」这种推演骨架，
              也不要把证据里的原文一段段搬过来再逐句解释；
            - 不要写「总结」「综上所述」这类小标题——整段本来就是总结；
            - 除非用户问的就是「怎么做」，否则不要展开机制细节。
            默认三句话以内讲完；用户明确要求展开时才更长，但也不超过一段。
            回答结束前检查最后一句是否完整。
            """,
            prompt: """
            用户问题：\(question.prefix(1_000))

            本轮本地证据：
            \(evidenceJSON)

            直接给结论。默认三句话以内，多一句都不要；证据不足就说缺什么。
            必要时才点一句结论来自哪份资料或哪一页。不要机械翻译摘录，
            不要在句子中途结束。
            """,
            privacyText: "\(question)\n\(evidence.flatMap(\.excerpts).joined(separator: "\n"))"
        )
    }

    func answerRecommendation(
        question: String,
        evidence: [RecommendationAnswerEvidence],
        allowSensitiveContent: Bool
    ) async -> String? {
        guard let request = answerPrompt(
            question: question,
            evidence: evidence,
            wantsPlainText: false
        ) else { return nil }
        do {
            let result = try await complete(
                feature: .retrievalRecommendation,
                system: request.system,
                prompt: request.prompt,
                privacyText: request.privacyText,
                // 供应商若仍报告 token 上限就不把半成品发布出去。
                maxTokens: Self.answerMaxTokens,
                allowSensitiveContent: allowSensitiveContent
            )
            let answer = ReasoningTrace.stripped(result.output.text)
            guard !answer.isEmpty, !result.output.wasTruncated else { return nil }
            return answer
        } catch {
            return nil
        }
    }

    /// 同一个回答，逐段到达。
    ///
    /// 只在"直接写进前台输入框"这条路径上用：那里的等待感几乎全来自"整段生成完
    /// 才动一下"，而不是总时长。剪贴板那条仍走非流式——它还能靠 finish_reason
    /// 拒收半截答案，而已经写进输入框的字是撤不回来的。
    func streamAnswerRecommendation(
        question: String,
        evidence: [RecommendationAnswerEvidence],
        allowSensitiveContent: Bool
    ) -> AsyncThrowingStream<AIStreamChunk, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor [weak self] in
                guard let self, let request = self.answerPrompt(
                    question: question,
                    evidence: evidence,
                    wantsPlainText: true
                ) else {
                    continuation.finish()
                    return
                }
                let answerStarted = Date()
                do {
                    var receivedAnything = false
                    var receivedText = false
                    // 这条路径把 .text 直接写进用户的前台输入框。思考过程必须
                    // 走另一条 case——一旦落进输入框就撤不回来了。
                    var traceFilter = ReasoningTrace.Filter()
                    for try await raw in try await self.answerDeltas(
                        request,
                        allowSensitiveContent: allowSensitiveContent
                    ) {
                        try Task.checkCancellation()
                        let split = traceFilter.consume(raw)
                        if !split.reasoning.isEmpty {
                            receivedAnything = true
                            continuation.yield(.reasoning(split.reasoning))
                        }
                        guard !split.text.isEmpty else { continue }
                        if !receivedText {
                            AppModel.ContextTrace.log(String(
                                format: "回答首字 %.2fs（从发出请求到第一个增量）",
                                Date().timeIntervalSince(answerStarted)
                            ))
                        }
                        receivedAnything = true
                        receivedText = true
                        continuation.yield(.text(split.text))
                    }
                    let tail = traceFilter.flush()
                    if !tail.reasoning.isEmpty { continuation.yield(.reasoning(tail.reasoning)) }
                    if !tail.text.isEmpty {
                        receivedText = true
                        continuation.yield(.text(tail.text))
                    }
                    // 只收到思考、一个正文字符都没有：这一轮没有答案。让它走
                    // 下面的非流式回退，而不是把一段推演当成答案交出去。
                    if !receivedText { receivedAnything = false }
                    // 供应商不支持 SSE 时，流会空着正常结束：没有文字也没有报错。
                    // 退回一次性请求，否则输入框里什么都不会出现。
                    if !receivedAnything {
                        let result = try await self.complete(
                            feature: .retrievalRecommendation,
                            system: request.system,
                            prompt: request.prompt,
                            privacyText: request.privacyText,
                            maxTokens: Self.answerMaxTokens,
                            allowSensitiveContent: allowSensitiveContent
                        )
                        guard !result.output.wasTruncated else {
                            throw ProviderError.truncatedOutput
                        }
                        let text = ReasoningTrace.stripped(result.output.text)
                        // 整段一次性 yield 会让输入框"啪"地出现一大坨。切成小段
                        // 交出去，写入端仍按节流逐段落地，观感与真流式一致。
                        var rest = text[...]
                        while !rest.isEmpty {
                            let end = rest.index(
                                rest.startIndex, offsetBy: 12, limitedBy: rest.endIndex
                            ) ?? rest.endIndex
                            continuation.yield(.text(String(rest[..<end])))
                            rest = rest[end...]
                        }
                        AppModel.ContextTrace.log("快捷回答：供应商未返回 SSE，已退回一次性请求")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func answerDeltas(
        _ request: SearchAnswerPrompt,
        allowSensitiveContent: Bool
    ) async throws -> AsyncThrowingStream<AIStreamChunk, any Error> {
        let credentialStore = credentialStore
        return try await executionEngine.streamComplete(
            feature: .retrievalRecommendation,
            profile: routing,
            providers: providers,
            catalog: catalog,
            credentialLoader: { providerID in
                try await credentialStore.read(providerID: providerID)
            },
            system: request.system,
            prompt: request.prompt,
            privacyText: request.privacyText,
            maxTokens: Self.answerMaxTokens,
            allowSensitiveContent: allowSensitiveContent
        )
    }

    func answerPDF(
        question: String,
        context: String,
        allowSensitiveContent: Bool
    ) async -> String? {
        guard routing.route(for: .pdfQuestionAnswering) != nil else { return nil }
        do {
            let result = try await complete(
                feature: .pdfQuestionAnswering,
                system: """
                你是 Mnemo 的 PDF 问答助手。只依据给出的页码和正文回答；证据不足就明确说明。
                引用内容时注明页码。直接给结论，不要复述分析步骤、不要写「首先…其次…」，
                也不要把原文整段搬来再解释。默认三到五句讲完。
                """,
                prompt: "问题：\(question.prefix(1_000))\n\n相关页面：\n\(context.prefix(12_000))",
                privacyText: "\(question)\n\(context)",
                maxTokens: 1_000,
                allowSensitiveContent: allowSensitiveContent
            )
            return ReasoningTrace.stripped(result.output.text)
        } catch {
            return nil
        }
    }

    func describeImage(_ item: Item, localText: String, library: Library) async -> String? {
        guard routing.route(for: .imageUnderstanding) != nil,
              let url = try? await library.resolvedFileURL(for: item) else { return nil }
        let image = await Task.detached(priority: .utility) { () -> ChatImageInput? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1536,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                  ),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(
                    using: .jpeg,
                    properties: [.compressionFactor: 0.82]
                  ) else { return nil }
            return ChatImageInput(mediaType: "image/jpeg", base64Data: data.base64EncodedString())
        }.value
        guard let image, !Task.isCancelled else { return nil }
        let privacyText = ([item.originalFilename ?? item.title, localText]
            .filter { !$0.isEmpty }).joined(separator: "\n")
        do {
            let result = try await complete(
                feature: .imageUnderstanding,
                system: "你是 Mnemo 的图片索引器。客观描述画面主体、场景、颜色、用途和可搜索关键词，不推断敏感身份。",
                prompt: "用一段不超过 120 字的中文描述这张图片，末尾附 5 到 10 个检索关键词。",
                privacyText: privacyText,
                maxTokens: 240,
                image: image,
                allowSensitiveContent: item.allowsSensitiveAI
            )
            return ReasoningTrace.stripped(result.output.text)
        } catch {
            return nil
        }
    }

    func embed(_ text: String, allowSensitiveContent: Bool = false) async -> EmbeddingAttempt {
        await embed([text], allowSensitiveContent: allowSensitiveContent).first
            ?? .retryableFailure(retryAfter: nil)
    }

    func embed(
        _ texts: [String],
        allowSensitiveContent: Bool = false
    ) async -> [EmbeddingAttempt] {
        guard !texts.isEmpty else { return [] }
        guard let providerID = embeddingProviderID,
              let provider = providers.first(where: { $0.id == providerID }),
              !embeddingModelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Array(repeating: .notConfigured, count: texts.count)
        }
        let modelID = embeddingModelID
        var results = Array(
            repeating: EmbeddingAttempt.retryableFailure(retryAfter: nil),
            count: texts.count
        )
        var pendingKeys: [String] = []
        var pendingText: [String] = []
        var pendingIndices: [String: [Int]] = [:]

        for (index, original) in texts.enumerated() {
            var text = original
            if !provider.isLocal, !allowSensitiveContent {
                let screening = PrivacyFilter.screen(text)
                guard screening.canSendExternally else {
                    results[index] = .privacyBlocked
                    continue
                }
                // 手机号遮掉再拿去做向量：留着不发是对的，但整条不建索引
                // 等于这条内容永远搜不到。
                if !screening.matches.isEmpty { text = PrivacyFilter.redacted(text) }
            }
            let key = embeddingCacheKey(
                provider: provider,
                modelID: modelID,
                text: text
            )
            if let vector = embeddingCache[key] {
                results[index] = .success(RuntimeEmbedding(
                    vector: vector,
                    providerID: providerID,
                    modelID: modelID,
                    dimensionChanged: false
                ))
            } else if pendingIndices[key] != nil {
                pendingIndices[key, default: []].append(index)
            } else {
                pendingKeys.append(key)
                pendingText.append(text)
                pendingIndices[key] = [index]
            }
        }

        guard !pendingText.isEmpty else { return results }
        do {
            let trace = PerformanceTrace.begin("EmbeddingBatch")
            defer { PerformanceTrace.end("EmbeddingBatch", id: trace) }
            let key = try await credentialStore.read(providerID: providerID)
            let vectors = try await client.embed(
                provider: provider,
                apiKey: key,
                model: modelID,
                inputs: pendingText
            )
            var sawDimensionChange = false
            for (offset, vector) in vectors.enumerated() {
                guard pendingKeys.indices.contains(offset) else { continue }
                let cacheKey = pendingKeys[offset]
                let changed = try await embeddingDimensions.recordOrDetectChange(
                    providerID: providerID,
                    modelID: modelID,
                    vector: vector
                )
                sawDimensionChange = sawDimensionChange || changed
                cacheEmbedding(vector, for: cacheKey)
                for index in pendingIndices[cacheKey] ?? [] {
                    results[index] = .success(RuntimeEmbedding(
                        vector: vector,
                        providerID: providerID,
                        modelID: modelID,
                        dimensionChanged: changed
                    ))
                }
            }
            if sawDimensionChange {
                embeddingCache.removeAll(keepingCapacity: true)
                embeddingCacheOrder.removeAll(keepingCapacity: true)
                statusMessage = "Embedding 维度发生变化，旧索引将重新建立"
            }
            return results
        } catch let error as ProviderError {
            providerErrors[providerID] = error.localizedDescription
            let attempt: EmbeddingAttempt
            switch error {
            case .rateLimited(let retryAfter):
                attempt = .retryableFailure(retryAfter: retryAfter)
            case .server(let status, _) where status >= 500:
                attempt = .retryableFailure(retryAfter: nil)
            default:
                attempt = .configurationFailure
            }
            for key in pendingKeys {
                for index in pendingIndices[key] ?? [] { results[index] = attempt }
            }
            return results
        } catch {
            providerErrors[providerID] = error.localizedDescription
            let attempt: EmbeddingAttempt = error is URLError
                ? .retryableFailure(retryAfter: nil)
                : .configurationFailure
            for key in pendingKeys {
                for index in pendingIndices[key] ?? [] { results[index] = attempt }
            }
            return results
        }
    }

    private func embeddingCacheKey(
        provider: ProviderConfiguration,
        modelID: String,
        text: String
    ) -> String {
        let value = "\(provider.id)\u{0}\(provider.baseURL.absoluteString)\u{0}\(modelID)\u{0}\(text)"
        return SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func cacheEmbedding(_ vector: [Float], for key: String) {
        if embeddingCache[key] == nil { embeddingCacheOrder.append(key) }
        embeddingCache[key] = vector
        while embeddingCacheOrder.count > 256 {
            embeddingCache[embeddingCacheOrder.removeFirst()] = nil
        }
    }

    private func complete(
        feature: AIFeature,
        system: String,
        prompt: String,
        privacyText: String?,
        maxTokens: Int,
        image: ChatImageInput? = nil,
        allowSensitiveContent: Bool = false,
        tools: [AITool] = [],
        turns: [AIChatTurn] = []
    ) async throws -> AIExecutionResult {
        let credentialStore = credentialStore
        let routeProviderID = routing.route(for: feature)?.providerID
        let isBackgroundFeature = feature == .automaticNaming
            || feature == .automaticClassification
            || feature == .imageUnderstanding
        let retryLimit = isBackgroundFeature ? 2 : 1
        let maximumAutomaticDelay: TimeInterval = isBackgroundFeature ? 60 : 8
        var retryCount = 0

        while true {
            do {
                let result = try await executionEngine.complete(
                    feature: feature,
                    profile: routing,
                    providers: providers,
                    catalog: catalog,
                    credentialLoader: { providerID in
                        try await credentialStore.read(providerID: providerID)
                    },
                    system: system,
                    prompt: prompt,
                    privacyText: privacyText,
                    maxTokens: maxTokens,
                    image: image,
                    allowSensitiveContent: allowSensitiveContent,
                    tools: tools,
                    turns: turns
                )
                if let routeProviderID { providerErrors[routeProviderID] = nil }
                return result
            } catch let error as ProviderError {
                guard case .rateLimited(let serverDelay) = error,
                      retryCount < retryLimit else { throw error }
                let exponentialDelay = pow(2, Double(retryCount))
                let delay = max(1, serverDelay ?? exponentialDelay)
                guard delay <= maximumAutomaticDelay else { throw error }
                retryCount += 1
                if let routeProviderID {
                    providerErrors[routeProviderID] = "请求较多，\(Int(ceil(delay))) 秒后自动重试（\(retryCount)/\(retryLimit)）"
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// 结构化响应仅在“请求成功但格式无法解析”时修复一次。路由、网络、
    /// 限流和隐私错误直接返回，避免把失败放大成重复调用。
    private func completeStructured<T>(
        feature: AIFeature,
        system: String,
        prompt: String,
        privacyText: String?,
        maxTokens: Int,
        allowSensitiveContent: Bool = false,
        parse: (String) throws -> T
    ) async throws -> T {
        let first = try await complete(
            feature: feature,
            system: system,
            prompt: prompt,
            privacyText: privacyText,
            maxTokens: maxTokens,
            allowSensitiveContent: allowSensitiveContent
        )
        do {
            return try parse(first.output.text)
        } catch {
            guard !Task.isCancelled else { throw CancellationError() }
            let repaired = try await complete(
                feature: feature,
                system: "你是 JSON 格式修复器。只返回一个满足原要求的 JSON 对象，不要解释或 Markdown。",
                prompt: "原任务：\n\(prompt.prefix(4_000))\n\n需要修复的输出：\n\(first.output.text.prefix(4_000))",
                privacyText: privacyText,
                maxTokens: maxTokens,
                allowSensitiveContent: allowSensitiveContent
            )
            return try parse(repaired.output.text)
        }
    }

    /// 命名/分类的输入文本。内联文本直接用；图片/PDF/文件走提取钩子拿
    /// OCR、视觉标签或页块文本——只有"类型+文件名"时模型编不出有意义的标题。
    private func aiSourceText(for item: Item) async -> String {
        // 对链接，holding 只是 URL / 分享文案，不是内容。以前内联分支先返回，
        // 导致即便 linkPage 已经正确抓到，自动命名仍只看那串网址，生成
        // “生活分享精选推荐”这类泛化标题，再把页面标题覆盖掉。链接必须先读
        // 已落库的结构化正文；只有索引尚未完成时才退回 URL。
        if item.kind == .link,
           let extracted = await enrichmentContentProvider?(item),
           !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(extracted.prefix(6_000))
        }
        if let text = inlineText(for: item) { return String(text.prefix(6_000)) }
        if let extracted = await enrichmentContentProvider?(item),
           !extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            switch item.kind {
            case .image: return "图片里识别出的文字与画面内容：\n\(extracted)"
            case .pdf: return "PDF 页面的文字内容：\n\(extracted)"
            default: return extracted
            }
        }
        let kind = item.kind.rawValue
        return "类型：\(kind)\n文件名：\(item.originalFilename ?? item.title)"
    }

    private func inlineText(for item: Item) -> String? {
        guard case .inline(let text) = item.holding else { return nil }
        return text
    }

    private static func extractTaxNumber(from text: String) -> String? {
        let pattern = #"(?:税号|纳税人识别号)\s*[:：]?\s*([A-Za-z0-9]{8,24})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: (text as NSString).length)
              ),
              match.numberOfRanges > 1 else { return nil }
        return (text as NSString).substring(with: match.range(at: 1))
    }

    private func refreshCredentialPresence() async {
        for provider in providers {
            keyPresence[provider.id] = ((try? await credentialStore.read(providerID: provider.id)) ?? nil) != nil
        }
    }

    /// 把选择投影到当前进程。
    ///
    /// **只动运行时图标，不写 Finder 自定义图标。**
    ///
    /// 曾经这里调过 `NSWorkspace.setIcon(_:forFile:)`，想让 Finder 立刻跟着变。
    /// 那会在 bundle 根目录写一个 `Icon\r` 资源文件，而**自定义图标的优先级高于
    /// `AppIcon.icns`**：一旦写下，之后无论重新打包成哪一套，Finder 都还显示被
    /// 钉死的那一张——正是"安装完是黑的，设置里却是白的"的成因。
    ///
    /// Finder 里的图标由构建脚本决定：它读同一份保存值，把对应的 icns 复制成
    /// `AppIcon.icns`。一个来源，两处一致。
    func applyIconChoice() {
        let name = iconChoice.resourceName
        let candidates = [
            Bundle.main.url(forResource: name, withExtension: "icns"),
            Bundle.module.url(forResource: name, withExtension: "icns"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appending(path: "icon/build/\(name).icns"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let image = NSImage(contentsOf: url) else {
            statusMessage = "找不到所选图标资源"
            return
        }
        NSApp.applicationIconImage = image
    }

    private func scheduleIndexResume() {
        embeddingResumeTask?.cancel()
        embeddingResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.resumeIndexingAction?()
        }
    }

    private func scheduleAIResume() {
        aiResumeTask?.cancel()
        aiResumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.resumeAIEnrichmentAction?()
        }
    }
}
