import AppKit
import MnemoCore
import SwiftUI

private let dashScopeAPIKeyURL = URL(
    string: "https://bailian.console.aliyun.com/cn-beijing?spm=a2c4g.11186623.0.0.26124c35tqkZLF&tab=model#/api-key"
)!

private enum SettingsPage: String, CaseIterable, Identifiable {
    case providers = "供应商"
    case routing = "AI 功能"
    case embedding = "Embedding"
    case todos = "待办与提醒"
    case shortcuts = "快捷键"
    case storage = "存储与回收站"
    case appearance = "外观与行为"

    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .providers: "server.rack"
        case .routing: "point.3.connected.trianglepath.dotted"
        case .embedding: "square.stack.3d.down.forward"
        case .todos: "checklist"
        case .shortcuts: "command"
        case .storage: "internaldrive"
        case .appearance: "paintbrush"
        }
    }
}

struct ProviderSettingsView: View {
    @Bindable var settings: ProviderSettingsModel
    @Bindable var appModel: AppModel
    @Bindable var shortcuts: ShortcutSettingsModel
    @State private var page: SettingsPage = .providers
    @State private var showsCustomProvider = false
    @State private var savedPage: SettingsPage?
    @State private var savedAt: Date?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 226)
                .background(SettingsPalette.sidebar)
            Divider().opacity(0.55)
            VStack(spacing: 0) {
                Group {
                    switch page {
                    case .providers:
                        ProviderConfigurationPage(settings: settings)
                    case .routing:
                        AIRoutingSettingsPage(settings: settings)
                    case .embedding:
                        EmbeddingSettingsPage(settings: settings)
                    case .todos:
                        TodoSettingsPage(appModel: appModel, settings: settings)
                    case .shortcuts:
                        ShortcutSettingsPage(shortcuts: shortcuts)
                    case .storage:
                        StorageSettingsPage(appModel: appModel)
                    case .appearance:
                        AppearanceSettingsPage(settings: settings, appModel: appModel)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                settingsSaveBar
            }
            .background(SettingsPalette.background)
        }
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $showsCustomProvider) {
            CustomProviderSheet(settings: settings, isPresented: $showsCustomProvider)
        }
    }

    private var settingsSaveBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(page.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                Text(saveStatus)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("保存当前页") { saveCurrentPage() }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .padding(.horizontal, 22)
        .frame(height: 54)
        .background(SettingsPalette.sidebar)
        .overlay(alignment: .top) { Divider().opacity(0.55) }
    }

    private var saveStatus: String {
        guard savedPage == page, let savedAt else { return "修改后点击保存才应用" }
        return "已保存 · " + savedAt.formatted(date: .omitted, time: .shortened)
    }

    private func saveCurrentPage() {
        switch page {
        case .providers, .routing, .embedding:
            settings.saveSettings()
        case .appearance:
            settings.saveSettings()
            appModel.saveSettings()
        case .todos:
            appModel.saveSettings()
            settings.saveSettings()
        case .shortcuts:
            shortcuts.saveSettings()
        case .storage:
            appModel.saveSettings()
        }
        savedPage = page
        savedAt = .now
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MnemoIconPreview(choice: settings.iconChoice, size: 36)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mnemo").font(.system(size: 14, weight: .semibold))
                    Text("设置").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            ForEach(SettingsPage.allCases) { candidate in
                SidebarRow(
                    title: candidate.rawValue,
                    symbol: candidate.symbol,
                    selected: page == candidate
                ) {
                    withAnimation(.easeOut(duration: 0.16)) { page = candidate }
                }
            }

            if page == .providers {
                Text("已适配")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 18)
                    .padding(.top, 20)
                    .padding(.bottom, 6)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(settings.providers) { provider in
                            Button {
                                settings.selectProvider(provider.id)
                            } label: {
                                HStack(spacing: 9) {
                                    ProviderBrandIcon(provider: provider, size: 26)
                                    Text(provider.displayName)
                                        .font(.system(size: 11.5, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Circle()
                                        .fill(providerStatusColor(provider))
                                        .frame(width: 6, height: 6)
                                }
                                .padding(.horizontal, 11)
                                .frame(height: 36)
                                .contentShape(Rectangle())
                                .background(
                                    settings.selectedProviderID == provider.id
                                        ? SettingsPalette.selection : .clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                }
            }

            Spacer(minLength: 8)
            if page == .providers {
                Button { showsCustomProvider = true } label: {
                    Label("添加自定义供应商", systemImage: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 34)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(10)
            }
        }
    }

    private func providerStatusColor(_ provider: ProviderConfiguration) -> Color {
        if settings.providerErrors[provider.id] != nil { return .orange }
        if provider.isLocal || settings.keyPresence[provider.id] == true { return .green }
        return Color.secondary.opacity(0.35)
    }
}

private struct SidebarRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(
                selected ? SettingsPalette.selection : .clear,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
    }
}

private struct ProviderConfigurationPage: View {
    @Bindable var settings: ProviderSettingsModel
    @State private var credentialDraft = ""

    var body: some View {
        if let provider = settings.selectedProvider {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    pageHeader(provider)
                    SettingsCard(title: "连接", subtitle: "地址与协议由适配器提供；自定义供应商可另行添加。") {
                        LabeledValue(label: "API 地址", value: provider.baseURL.absoluteString)
                        LabeledValue(label: "协议", value: provider.dialect.displayName)
                        LabeledValue(label: "鉴权", value: provider.authentication.displayName)
                    }
                    SettingsCard(title: "凭据", subtitle: "API Key 只保存在 macOS 钥匙串，不写入配置文件或日志。") {
                        if provider.authentication == .none {
                            Label("本地供应商无需 API Key", systemImage: "checkmark.shield")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.green)
                        } else {
                            HStack(spacing: 10) {
                                SecureField(
                                    settings.keyPresence[provider.id] == true ? "输入新 Key 以替换" : "输入 API Key",
                                    text: $credentialDraft
                                )
                                .textFieldStyle(.roundedBorder)
                                Button("保存到钥匙串") {
                                    let value = credentialDraft
                                    credentialDraft = ""
                                    Task { await settings.saveCredential(value, providerID: provider.id) }
                                }
                                .disabled(credentialDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                if settings.keyPresence[provider.id] == true {
                                    Button("移除", role: .destructive) {
                                        Task { await settings.saveCredential("", providerID: provider.id) }
                                    }
                                }
                            }
                            HStack(spacing: 6) {
                                Image(systemName: settings.keyPresence[provider.id] == true
                                      ? "checkmark.circle.fill" : "circle.dashed")
                                Text(settings.keyPresence[provider.id] == true ? "钥匙串中已有凭据" : "尚未配置凭据")
                            }
                            .font(.system(size: 11))
                            .foregroundStyle(settings.keyPresence[provider.id] == true ? .green : .secondary)
                            if provider.id == "dashscope" {
                                Button {
                                    NSWorkspace.shared.open(dashScopeAPIKeyURL)
                                } label: {
                                    Label("前往阿里云百炼获取 API Key", systemImage: "arrow.up.right.square")
                                }
                                .buttonStyle(.link)
                                .font(.system(size: 11, weight: .medium))
                            }
                        }
                    }
                    modelCatalogCard(provider)
                }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
            }
        } else {
            ContentUnavailableView("选择供应商", systemImage: "server.rack")
        }
    }

    private func pageHeader(_ provider: ProviderConfiguration) -> some View {
        HStack(spacing: 14) {
            ProviderBrandIcon(provider: provider, size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(provider.displayName).font(.system(size: 22, weight: .bold))
                Text(provider.isLocal ? "本地 OpenAI 兼容服务" : "云端模型供应商")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if settings.chatProviderID == provider.id {
                StatusPill(text: "默认聊天", color: .blue)
            }
            if settings.embeddingProviderID == provider.id {
                StatusPill(text: "Embedding", color: .purple)
            }
        }
    }

    private func modelCatalogCard(_ provider: ProviderConfiguration) -> some View {
        let models = settings.models(for: provider.id)
        return SettingsCard(
            title: "模型目录",
            subtitle: "只在首次配置和手动刷新时更新"
        ) {
            HStack(spacing: 10) {
                Button {
                    Task { await settings.refreshModels(providerID: provider.id) }
                } label: {
                    Label(settings.isRefreshing.contains(provider.id) ? "正在读取" : "刷新可用模型",
                          systemImage: "arrow.clockwise")
                }
                .disabled(settings.isRefreshing.contains(provider.id))

                Button {
                    Task { await settings.refreshPublicModelMetadata() }
                } label: {
                    Label(settings.isRefreshingPublicMetadata ? "正在更新" : "刷新能力与价格",
                          systemImage: "chart.bar.doc.horizontal")
                }
                .disabled(settings.isRefreshingPublicMetadata)
                .help("从 models.dev 更新已适配供应商的 chat 能力与价格；不会替换供应商实际可用模型列表")

                Spacer(minLength: 8)
                Text("\(models.count) 个模型")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            // 角色指派和刷新是两件事，挤在一行四个长按钮会互相截断。
            HStack(spacing: 10) {
                Text("用作")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Button(settings.chatProviderID == provider.id ? "默认聊天 ✓" : "设为默认聊天") {
                    Task { await settings.setChatProvider(provider.id) }
                }
                .controlSize(.small)
                .disabled(settings.chatProviderID == provider.id)

                Spacer(minLength: 0)
            }

            if let error = settings.providerErrors[provider.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            } else if settings.isRefreshing.contains(provider.id) {
                ProgressView().controlSize(.small).padding(.top, 2)
            }

            if let error = settings.publicMetadataError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            } else if let fetchedAt = settings.catalog.fetchedAt {
                Text("能力与价格快照：\(fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }

            if models.isEmpty {
                Text("尚无缓存模型。您仍可在 AI 功能页手填模型名，Embedding 模型尤其如此。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 236), spacing: 8)], spacing: 8) {
                    ForEach(models) { model in
                        ModelCatalogRow(model: model)
                    }
                }
            }

            Text("这里只管对话模型。Embedding 是另一类模型、另一个端点，配置在左侧「Embedding」页。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

/// 目录里的一个模型。原来三行信息压在 60pt 里，最下面那行是 8.5pt——
/// 能力和价格实际上看不清。
private struct ModelCatalogRow: View {
    let model: AIModelDescriptor

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: model.supportsReasoning ? "brain" : "text.bubble")
                .font(.system(size: 13))
                .foregroundStyle(model.supportsReasoning ? .purple : .secondary)
                .frame(width: 20)
                .help(model.supportsReasoning ? "支持思考强度" : "普通对话模型")

            VStack(alignment: .leading, spacing: 3) {
                Text(model.displayName)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(model.id)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    ForEach(modalityLabels, id: \.self) { label in
                        Text(label)
                            .font(.system(size: 9.5, weight: .medium))
                            .padding(.horizontal, 5)
                            .frame(height: 15)
                            .background(SettingsPalette.selection, in: Capsule())
                    }
                    if let price {
                        Text(price)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: 68)
        .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 8))
        .help(model.id)
    }

    private var modalityLabels: [String] {
        model.inputModalities.sorted { $0.rawValue < $1.rawValue }.map(\.shortLabel)
    }

    private var price: String? {
        guard let input = model.inputPricePerMillion,
              let output = model.outputPricePerMillion else { return nil }
        let inputValue = NSDecimalNumber(decimal: input).stringValue
        let outputValue = NSDecimalNumber(decimal: output).stringValue
        return "$\(inputValue) / $\(outputValue) 每 1M"
    }
}

/// Embedding 单独一页。
///
/// 它和对话模型是两类东西：不同的端点、不同的模型、不同的返回（向量而不是
/// 文本）。把它挂在供应商页的一个「设为 Embedding」按钮上，既容易漏配，也让
/// 人误以为随便挑个对话模型就能用。
private struct EmbeddingSettingsPage: View {
    @Bindable var settings: ProviderSettingsModel
    @State private var credentialDraft = ""

    private var provider: ProviderConfiguration? {
        settings.providers.first { $0.id == settings.embeddingProviderID }
    }

    private var trimmedModelID: String {
        settings.embeddingModelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isConfigured: Bool { provider != nil && !trimmedModelID.isEmpty }

    /// 目录里长得像 embedding 的模型。供应商把两类模型混在一条列表里返回，
    /// 元数据没有类型字段，只能按名字挑。
    private var embeddingModels: [AIModelDescriptor] {
        guard let provider else { return [] }
        return settings.models(for: provider.id).filter(\.looksLikeEmbeddingModel)
    }

    /// 填了模型名，但它看着不像取向量的模型。
    private var modelLooksWrong: Bool {
        guard !trimmedModelID.isEmpty else { return false }
        return !AIModelDescriptor(id: trimmedModelID).looksLikeEmbeddingModel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                SettingsCard(
                    title: "用在哪里",
                    help: "没有 Embedding 时这些能力自动降级为本地关键词检索，不会报错也不会阻塞收纳。"
                ) {
                    HStack(spacing: 8) {
                        ForEach(Self.usages, id: \.0) { usage in
                            Label(usage.0, systemImage: usage.1)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 10)
                                .frame(height: 24)
                                .background(SettingsPalette.control, in: Capsule())
                        }
                    }
                }

                SettingsCard(title: "供应商", help: "可以和对话模型不是同一家；Key 按供应商各存各的。") {
                    Picker("", selection: Binding(
                        get: { settings.embeddingProviderID ?? "" },
                        set: { value in
                            Task { await settings.setEmbeddingProvider(value.isEmpty ? nil : value) }
                        }
                    )) {
                        Text("未选择").tag("")
                        ForEach(settings.providers) { candidate in
                            Label {
                                Text(candidate.displayName)
                            } icon: {
                                // Picker/菜单会把图标拍平成 NSImage 交给 AppKit，
                                // 必须用烘好颜色的小徽章，黑色模板图在这里会原样变黑。
                                if let badge = SettingsAssetCache.providerBadge(provider: candidate, points: 16) {
                                    Image(nsImage: badge)
                                } else {
                                    ProviderBrandIcon(provider: candidate, size: 14)
                                }
                            }
                            .tag(candidate.id)
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 300, alignment: .leading)

                    if let provider {
                        credentialRow(provider)
                    }
                }

                if let provider {
                    modelCard(provider)
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private static let usages: [(String, String)] = [
        ("语义检索", "magnifyingglass"),
        ("PDF 页块定位", "doc.text.magnifyingglass"),
        ("图片 OCR 检索", "photo"),
    ]

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.stack.3d.down.forward")
                .font(.system(size: 26))
                .foregroundStyle(isConfigured ? Color.accentColor : .secondary)
                .frame(width: 46, height: 46)
                .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("Embedding").font(.system(size: 22, weight: .bold))
                Text("把内容转成向量，支撑语义检索")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(
                text: isConfigured ? "已配置" : "未配置",
                color: isConfigured ? .green : .orange
            )
        }
    }

    @ViewBuilder
    private func credentialRow(_ provider: ProviderConfiguration) -> some View {
        if provider.authentication == .none {
            Label("本地供应商无需 API Key", systemImage: "checkmark.shield")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.green)
        } else {
            HStack(spacing: 10) {
                SecureField(
                    settings.keyPresence[provider.id] == true ? "输入新 Key 以替换" : "输入 API Key",
                    text: $credentialDraft
                )
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 320)
                Button("保存到钥匙串") {
                    let value = credentialDraft
                    credentialDraft = ""
                    Task { await settings.saveCredential(value, providerID: provider.id) }
                }
                .controlSize(.small)
                .disabled(credentialDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: settings.keyPresence[provider.id] == true
                      ? "checkmark.circle.fill" : "circle.dashed")
                Text(settings.keyPresence[provider.id] == true
                     ? "钥匙串中已有 \(provider.displayName) 的凭据"
                     : "尚未配置 \(provider.displayName) 的凭据")
            }
            .font(.system(size: 11))
            .foregroundStyle(settings.keyPresence[provider.id] == true ? .green : .secondary)
            if provider.id == "dashscope" {
                Button {
                    NSWorkspace.shared.open(dashScopeAPIKeyURL)
                } label: {
                    Label("前往阿里云百炼获取 API Key", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .medium))
            }
        }
    }

    private func modelCard(_ provider: ProviderConfiguration) -> some View {
        SettingsCard(
            title: "模型",
            subtitle: "只能填取向量的模型",
            help: "对话模型走的是另一个端点，配在这里会一路发到线上才失败。"
        ) {
            HStack(spacing: 8) {
                TextField("例如 text-embedding-3-large", text: Binding(
                    get: { settings.embeddingModelID },
                    set: { settings.setEmbeddingModelID($0) }
                ))
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(maxWidth: 320)

                if !embeddingModels.isEmpty {
                    Menu {
                        ForEach(embeddingModels) { model in
                            Button(model.displayName) { settings.setEmbeddingModelID(model.id) }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "square.stack.3d.up")
                                .font(.system(size: 10, weight: .semibold))
                            Text("目录").font(.system(size: 10.5, weight: .medium))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8)
                        .frame(height: 22)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsPalette.stroke) }
                    .help("只列出 \(provider.displayName) 目录里取向量的模型（共 \(embeddingModels.count) 个）")
                }

                Button {
                    Task { await settings.refreshModels(providerID: provider.id) }
                } label: {
                    Label(
                        settings.isRefreshing.contains(provider.id) ? "读取中" : "刷新",
                        systemImage: "arrow.clockwise"
                    )
                }
                .controlSize(.small)
                .disabled(settings.isRefreshing.contains(provider.id))
                Spacer(minLength: 0)
            }

            if modelLooksWrong {
                Label(
                    "「\(trimmedModelID)」看起来不是 Embedding 模型。对话模型无法返回向量，语义检索会一直失败。",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            } else if embeddingModels.isEmpty, !settings.isRefreshing.contains(provider.id) {
                Text("目录里还没有识别到 Embedding 模型。点刷新拉取，或直接手填模型名。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Text("Embedding 元数据不依赖 models.dev；首次实际调用会读取返回向量长度并锁定维度。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
        }
    }
}

private struct AIRoutingSettingsPage: View {
    @Bindable var settings: ProviderSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("AI 功能").font(.system(size: 22, weight: .bold))
                    Text("先设快速/强力默认路线，再按功能覆盖。未配置的功能不会偷偷调用模型。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                HStack(alignment: .top, spacing: 12) {
                    RouteEditorCard(
                        title: "快速默认",
                        subtitle: "命名、分类、场景识别、查询解析",
                        route: settings.routing.fast,
                        inherited: nil,
                        requiredModality: .text,
                        settings: settings,
                        onChange: settings.setFastRoute
                    )
                    RouteEditorCard(
                        title: "强力默认",
                        subtitle: "内容转换、PDF 问答",
                        route: settings.routing.strong,
                        inherited: nil,
                        requiredModality: .text,
                        settings: settings,
                        onChange: settings.setStrongRoute
                    )
                }

                SettingsCard(
                    title: "快捷回答",
                    subtitle: "⌘G 的回答边生成边写回选区输入框",
                    help: "回答流式写入你选中文字所在的输入框，第一句话到了就能读。微信等不向系统暴露输入框的应用改用模拟键盘输入，只在停留在该应用时进行且永不按回车；密码框、只读内容、访达一律不写，不满足时整段生成完再放进剪贴板。关闭后这条路径不触碰任何输入框。"
                ) {
                    Toggle(
                        "聚焦输入框时直接写入",
                        isOn: Binding(
                            get: { settings.streamsAnswerIntoFocusedInput },
                            set: { settings.setStreamsAnswerIntoFocusedInput($0) }
                        )
                    )
                    .font(.system(size: 12, weight: .medium))
                }

                Text("按功能覆盖")
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.top, 4)

                // 固定双列：adaptive 网格在滚动回弹宽度微变时会逐帧重算列数，
                // 每次重排还要重建 18 个 AppKit 弹出按钮——滚动卡顿的主要来源。
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                    ForEach(AIFeature.allCases) { feature in
                        RouteEditorCard(
                            title: feature.displayName,
                            subtitle: feature.privacyNote,
                            route: settings.routing.overrides[feature],
                            inherited: feature.usesStrongDefault
                                ? settings.routing.strong : settings.routing.fast,
                            requiredModality: feature.requiredInputModality,
                            settings: settings,
                            onChange: { settings.setRoute($0, for: feature) }
                        )
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 780, alignment: .leading)
        }
    }
}

private struct RouteEditorCard: View {
    let title: String
    let subtitle: String
    let route: FeatureRoute?
    let inherited: FeatureRoute?
    let requiredModality: ModelModality
    @Bindable var settings: ProviderSettingsModel
    let onChange: (FeatureRoute?) -> Void

    private var effective: FeatureRoute? { route ?? inherited }
    private var isOverride: Bool { route != nil }

    private static let labelWidth: CGFloat = 54

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if isOverride, let active = route {
                Divider().opacity(0.5)
                // 三行控件用同一套标签列宽对齐；原来供应商/思考强度靠 Picker
                // 自带标签、模型只有占位符，三行的左边缘各在各的位置。
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        fieldLabel("供应商")
                        providerPicker(active)
                    }
                    GridRow {
                        fieldLabel("模型")
                        modelField(active)
                    }
                    GridRow {
                        fieldLabel("思考强度")
                        reasoningPicker(active)
                    }
                }
                capabilityNote(active)
            } else if let inherited {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.turn.down.right")
                    Text("跟随 \(providerName(inherited.providerID)) · \(inherited.modelID)")
                        .lineLimit(1)
                }
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            } else {
                Text("关闭；该组功能不会调用远端模型")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(SettingsPalette.stroke) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle(isOn: Binding(
                get: { isOverride },
                set: { enabled in onChange(enabled ? (effective ?? initialRoute()) : nil) }
            )) {
                Text(isOverride ? "已覆盖" : "跟随默认")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .fixedSize()
            .help(inherited == nil ? "启用此默认路线" : "覆盖默认路线")
            .accessibilityLabel("\(title) 使用独立模型")
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .frame(width: Self.labelWidth, alignment: .trailing)
    }

    private func providerPicker(_ active: FeatureRoute) -> some View {
        Picker("", selection: Binding(
            get: { active.providerID },
            set: { providerID in
                onChange(FeatureRoute(
                    providerID: providerID,
                    modelID: settings.models(for: providerID).first?.id ?? ""
                ))
            }
        )) {
            ForEach(settings.providers) { provider in
                // 带上品牌图标：一排纯文字里很难快速找到自己配的那家。
                Label {
                    Text(provider.displayName)
                } icon: {
                    if let badge = SettingsAssetCache.providerBadge(provider: provider, points: 16) {
                        Image(nsImage: badge)
                    } else {
                        ProviderBrandIcon(provider: provider, size: 14)
                    }
                }
                .tag(provider.id)
            }
        }
        .labelsHidden()
        .controlSize(.small)
        .accessibilityLabel("供应商")
    }

    private func modelField(_ active: FeatureRoute) -> some View {
        HStack(spacing: 6) {
            TextField("模型名", text: Binding(
                get: { active.modelID },
                set: { onChange(FeatureRoute(
                    providerID: active.providerID,
                    modelID: $0,
                    reasoningEffort: active.reasoningEffort
                )) }
            ))
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            let catalog = settings.models(for: active.providerID)
            if !catalog.isEmpty {
                // 原来这里是一个 22pt 宽、没有标签也没有 tooltip 的裸 chevron，
                // 看不出是"从目录选模型"。
                Menu {
                    ForEach(catalog) { model in
                        let supported = model.inputModalities.contains(requiredModality)
                        Button {
                            onChange(FeatureRoute(
                                providerID: active.providerID,
                                modelID: model.id,
                                reasoningEffort: model.supportsReasoning ? active.reasoningEffort : .off
                            ))
                        } label: {
                            Text(modelMenuTitle(model, supported: supported))
                        }
                        .disabled(!supported)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "square.stack.3d.up")
                            .font(.system(size: 10, weight: .semibold))
                        Text("目录").font(.system(size: 10.5, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .background(SettingsPalette.control, in: RoundedRectangle(cornerRadius: 6))
                .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(SettingsPalette.stroke) }
                .help("从 \(providerName(active.providerID)) 的模型目录里选（共 \(catalog.count) 个）")
                .accessibilityLabel("从模型目录选择")
            }
        }
    }

    /// 菜单项直接写清楚为什么不能选，不要给一个没有解释的灰条目。
    private func modelMenuTitle(_ model: AIModelDescriptor, supported: Bool) -> String {
        var suffix: [String] = []
        if model.supportsReasoning { suffix.append("可思考") }
        if !supported { suffix.append("不支持\(requiredModality.shortLabel)输入") }
        guard !suffix.isEmpty else { return model.displayName }
        return "\(model.displayName)  ·  \(suffix.joined(separator: " · "))"
    }

    private func reasoningPicker(_ active: FeatureRoute) -> some View {
        Picker("", selection: Binding(
            get: { active.reasoningEffort },
            set: { onChange(FeatureRoute(
                providerID: active.providerID,
                modelID: active.modelID,
                reasoningEffort: $0
            )) }
        )) {
            ForEach(AIReasoningEffort.allCases, id: \.self) { effort in
                Text(effort.displayName).tag(effort)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .controlSize(.small)
        // Grid 里的分段控件不会自己要宽度，会被压到只剩一格，四个标签叠成一个
        // 蓝色小方块——截图里那个看不出是什么的东西就是它。fixedSize 让它按
        // 标签的自然宽度撑开；下限兜一道底，免得某个语言下标签特别短时又被
        // 挤回去。
        .fixedSize()
        .frame(minWidth: 168, alignment: .leading)
        .disabled(!selectedModelSupportsReasoning(active))
        .help(selectedModelSupportsReasoning(active)
              ? "按供应商协议发送思考强度" : "当前模型未声明支持思考强度")
        .accessibilityLabel("思考强度")
    }

    @ViewBuilder
    private func capabilityNote(_ active: FeatureRoute) -> some View {
        if let issue = capabilityIssue(active) {
            Label(issue, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
        } else if !active.modelID.isEmpty, selectedModel(active) == nil {
            Label("手填模型未在目录中，输入能力将在首次调用时验证",
                  systemImage: "questionmark.circle")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    private func initialRoute() -> FeatureRoute {
        if let inherited { return inherited }
        let provider = settings.providers.first { settings.keyPresence[$0.id] == true || $0.isLocal }
            ?? settings.providers.first
        let providerID = provider?.id ?? ""
        return FeatureRoute(
            providerID: providerID,
            modelID: settings.models(for: providerID).first?.id ?? ""
        )
    }

    private func selectedModelSupportsReasoning(_ route: FeatureRoute) -> Bool {
        selectedModel(route)?.supportsReasoning == true
    }

    private func selectedModel(_ route: FeatureRoute) -> AIModelDescriptor? {
        settings.models(for: route.providerID).first { $0.id == route.modelID }
    }

    private func capabilityIssue(_ route: FeatureRoute) -> String? {
        guard let model = selectedModel(route),
              !model.inputModalities.contains(requiredModality) else { return nil }
        return "该模型不支持\(requiredModality.shortLabel)输入，此功能不会发起请求"
    }

    private func providerName(_ id: String) -> String {
        settings.providers.first { $0.id == id }?.displayName ?? id
    }
}

/// 待办与提醒。
private struct TodoSettingsPage: View {
    @Bindable var appModel: AppModel
    @Bindable var settings: ProviderSettingsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("待办与提醒").font(.system(size: 22, weight: .bold))
                    Text("从复制的文字和固定的截图里认出取餐码、快递、截止日期，到点提醒你。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "识别待办",
                    subtitle: "全部在本机完成，不联网",
                    help: "取餐码、取件码这类字面命中的直接建，刘海上留一个叉可以撤销；靠语义抠出来的（某月某日交什么）会先弹一个对号一个叉，你点了才算。同一件事只提一次。"
                ) {
                    Toggle("从复制的文字里识别", isOn: $appModel.todoIntakeEnabled)
                        .font(.system(size: 12, weight: .medium))
                    Toggle("固定截图后识别里面的文字", isOn: $appModel.screenshotTodoScanEnabled)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(!appModel.todoIntakeEnabled)
                    Text("截图只在你按下固定之后才识别——那时它本来就要走一遍本机 OCR，不额外多花一次。手机通用剪贴板同步过来的内容不受这条限制，一律识别。")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)

                    Divider().padding(.vertical, 3)

                    Toggle("不询问，直接加入待办", isOn: $appModel.todoAutoCreateEnabled)
                        .font(.system(size: 12, weight: .medium))
                        .disabled(!appModel.todoIntakeEnabled)
                    Text("默认关。打开之后连「拿不准」的那些也会直接建，撤销仍然在刘海卡片上。")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "到点提醒",
                    subtitle: "系统通知和刘海卡片共用同一套规则",
                    help: "系统通知提前排进通知中心，即使 Mnemo 没在跑也会响；刘海卡片只在应用运行时出现，胜在一个对号就能完成。两边都会去重，同一件事不会响两次。"
                ) {
                    Toggle("开启待办提醒", isOn: reminderBinding(\.isEnabled))
                        .font(.system(size: 12, weight: .medium))

                    HStack(spacing: 10) {
                        Text("提前").font(.system(size: 12))
                        Picker("", selection: reminderBinding(\.leadMinutes)) {
                            Text("到点").tag(0)
                            Text("5 分钟").tag(5)
                            Text("10 分钟").tag(10)
                            Text("30 分钟").tag(30)
                            Text("1 小时").tag(60)
                            Text("1 天").tag(1_440)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Spacer(minLength: 0)
                    }
                    .disabled(!appModel.reminderSettings.isEnabled)

                    Toggle("系统通知", isOn: reminderBinding(\.usesSystemNotification))
                        .font(.system(size: 12, weight: .medium))
                        .disabled(!appModel.reminderSettings.isEnabled)
                    Toggle("刘海卡片", isOn: reminderBinding(\.usesNotchAlert))
                        .font(.system(size: 12, weight: .medium))
                        .disabled(!appModel.reminderSettings.isEnabled)

                    Divider().padding(.vertical, 3)

                    Toggle("逾期后继续提醒", isOn: reminderBinding(\.repeatsWhenOverdue))
                        .font(.system(size: 12, weight: .medium))
                        .disabled(!appModel.reminderSettings.isEnabled)
                    HStack(spacing: 10) {
                        Text("间隔").font(.system(size: 12))
                        Picker("", selection: reminderBinding(\.overdueIntervalMinutes)) {
                            Text("30 分钟").tag(30)
                            Text("1 小时").tag(60)
                            Text("3 小时").tag(180)
                            Text("1 天").tag(1_440)
                        }
                        .labelsHidden()
                        .frame(width: 140)
                        Spacer(minLength: 0)
                    }
                    .disabled(!appModel.reminderSettings.isEnabled
                              || !appModel.reminderSettings.repeatsWhenOverdue)
                }

                SettingsCard(
                    title: "免打扰",
                    subtitle: "这段时间内不响，到点的提醒等过了再补",
                    help: "跨零点是常见设置（比如 23 点到次日 7 点），这里按跨零点处理。"
                ) {
                    HStack(spacing: 10) {
                        Toggle("启用", isOn: quietHoursBinding)
                            .font(.system(size: 12, weight: .medium))
                        Spacer(minLength: 12)
                        Picker("", selection: hourBinding(isStart: true)) {
                            ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                        }
                        .labelsHidden().frame(width: 90)
                        Text("到").font(.system(size: 12))
                        Picker("", selection: hourBinding(isStart: false)) {
                            ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                        }
                        .labelsHidden().frame(width: 90)
                    }
                    .disabled(!appModel.reminderSettings.isEnabled)
                }

                SettingsCard(
                    title: "待办协调",
                    subtitle: "聊天里改了时间、说了取消，能对上已有的那条",
                    help: "本地已经能处理「组会改到四点」这类明说的改动。模型补的是它够不着的部分：指代（「那个报告的事」）、口语（「搞定了」）、以及不在词表里的说法。没配路由时整条链退化成纯本地，一次调用都不会发。"
                ) {
                    if settings.routing.route(for: .todoRevision) == nil {
                        Label(
                            "尚未配置。当前只用本地规则协调，不会调用模型。",
                            systemImage: "info.circle"
                        )
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Label(
                            "已配置。只在本地判定这段话与任务有关时才调用。",
                            systemImage: "checkmark.circle"
                        )
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Text("在「AI 功能」页里为「待办协调」指定供应商与模型。")
                        .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
            }
            .padding(24)
        }
    }

    private func reminderBinding<Value>(
        _ keyPath: WritableKeyPath<TodoReminderSettings, Value>
    ) -> Binding<Value> {
        Binding(
            get: { appModel.reminderSettings[keyPath: keyPath] },
            set: { appModel.reminderSettings[keyPath: keyPath] = $0 }
        )
    }

    private var quietHoursBinding: Binding<Bool> {
        Binding(
            get: { appModel.reminderSettings.hasQuietHours },
            set: { enabled in
                appModel.reminderSettings.quietHoursStart = enabled ? 23 : nil
                appModel.reminderSettings.quietHoursEnd = enabled ? 7 : nil
            }
        )
    }

    private func hourBinding(isStart: Bool) -> Binding<Int> {
        Binding(
            get: {
                isStart
                    ? (appModel.reminderSettings.quietHoursStart ?? 23)
                    : (appModel.reminderSettings.quietHoursEnd ?? 7)
            },
            set: { value in
                if isStart {
                    appModel.reminderSettings.quietHoursStart = value
                } else {
                    appModel.reminderSettings.quietHoursEnd = value
                }
            }
        )
    }
}

/// 快捷键。
private struct ShortcutSettingsPage: View {
    @Bindable var shortcuts: ShortcutSettingsModel
    @State private var recording: ShortcutAction?
    @State private var conflictMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("快捷键").font(.system(size: 22, weight: .bold))
                    Text("全局生效。点右侧按钮开始录制，按 Esc 取消。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "全局动作",
                    subtitle: "默认组合避开了系统占用的 ⌘Space 与 ⌘P",
                    help: "全局快捷键在 Mnemo 运行期间会从所有应用手里接管这个组合。⌃⌘ 一族基本没有系统占用；⌘G 在多数应用里是「查找下一个」，保留它是明确的取舍。"
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(ShortcutAction.allCases.enumerated()), id: \.element) { index, action in
                            if index > 0 { Divider().padding(.vertical, 8) }
                            row(action)
                        }
                    }

                    if let conflictMessage {
                        Label(conflictMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(.orange)
                    }

                    HStack {
                        Spacer()
                        Button("全部恢复默认") {
                            shortcuts.resetAll()
                            conflictMessage = nil
                        }
                        .font(.system(size: 11))
                    }
                }
            }
            .padding(24)
        }
    }

    private func row(_ action: ShortcutAction) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(action.title).font(.system(size: 12.5, weight: .medium))
                Text(action.detail).font(.system(size: 10.5)).foregroundStyle(.secondary)
                if shortcuts.unavailable.contains(action) {
                    // 注册失败几乎总是被别人先占了。不说清楚的话，用户按了没反应
                    // 又查不出原因，只会以为功能坏了。
                    Label("这个组合已被系统或其他应用占用，换一个", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { shortcuts.isEnabled(action) },
                set: { shortcuts.setEnabled($0, for: action) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)

            Button {
                recording = recording == action ? nil : action
                conflictMessage = nil
            } label: {
                Text(recording == action ? "按下新组合…" : shortcuts.combination(for: action).displayString)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .frame(minWidth: 108)
                    .frame(height: 26)
                    .background(
                        recording == action ? SettingsPalette.selection : SettingsPalette.control,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(recording == action ? Color.accentColor : SettingsPalette.stroke)
                    }
            }
            .buttonStyle(.plain)
            .disabled(!shortcuts.isEnabled(action))
            .overlay {
                if recording == action {
                    ShortcutRecorder(
                        combination: shortcuts.combination(for: action),
                        isRecording: true,
                        onRecord: { combination in
                            if let conflicting = shortcuts.set(combination, for: action) {
                                conflictMessage =
                                    "\(combination.displayString) 已经分配给「\(conflicting.title)」"
                            } else {
                                conflictMessage = nil
                            }
                            recording = nil
                        },
                        onCancel: { recording = nil }
                    )
                    .allowsHitTesting(false)
                }
            }

            Button {
                shortcuts.reset(action)
                conflictMessage = nil
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 10, weight: .semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("恢复默认")
        }
    }
}

private struct StorageSettingsPage: View {
    @Bindable var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("存储与回收站").font(.system(size: 22, weight: .bold))
                    Text("副本由 Mnemo 管理；引用型 Pin 的原文件始终留在原处。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    usageTile("使用中的副本", bytes: appModel.activeStorageBytes,
                              symbol: "internaldrive", color: .accentColor)
                    usageTile("回收站副本", bytes: appModel.trashStorageBytes,
                              symbol: "trash", color: .orange)
                }

                SettingsCard(
                    title: "整库备份",
                    subtitle: "副本随归档保存；原文件引用只保存路径与元数据，向量和 API Key 不导出。"
                ) {
                    HStack(spacing: 10) {
                        Button {
                            Task { await appModel.exportLibraryArchive() }
                        } label: {
                            Label("导出备份", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            Task { await appModel.importLibraryArchive() }
                        } label: {
                            Label("导入备份", systemImage: "square.and.arrow.down")
                        }
                        Spacer()
                        if appModel.isProcessingArchive {
                            HStack(spacing: 7) {
                                ProgressView().controlSize(.small)
                                Text("正在校验与整理")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            .transition(.opacity)
                        }
                    }
                    .disabled(appModel.isProcessingArchive)
                    .frame(minHeight: 30)
                    .animation(.easeInOut(duration: 0.18), value: appModel.isProcessingArchive)
                }

                SettingsCard(
                    title: "回收站",
                    subtitle: "删除后保留 30 天；恢复会沿用原索引，不重复调用 AI。"
                ) {
                    HStack {
                        Text("\(appModel.trashedItems.count) 个 Pin")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("清空回收站", role: .destructive) {
                            Task { await appModel.emptyTrash() }
                        }
                        .disabled(appModel.trashedItems.isEmpty)
                    }

                    if appModel.trashedItems.isEmpty {
                        Label("回收站为空", systemImage: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 80)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(appModel.trashedItems.sorted { $0.holding.size > $1.holding.size }) { item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.kind.storageSymbol)
                                        .frame(width: 24)
                                        .foregroundStyle(.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                                        Text("\(StorageByteFormat.short(item.holding.size)) · \(remainingText(item))")
                                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("恢复") { Task { await appModel.restoreFromTrash(item.id) } }
                                        .controlSize(.small)
                                }
                                .frame(height: 48)
                                Divider().opacity(0.45)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task { await appModel.reload() }
    }

    private func usageTile(_ title: String, bytes: Int64, symbol: String, color: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 38, height: 38)
                .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(StorageByteFormat.short(bytes))
                    .font(.system(size: 17, weight: .semibold, design: .rounded))
            }
            Spacer()
        }
        .padding(13)
        .frame(maxWidth: .infinity)
        .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(SettingsPalette.stroke) }
    }

    private func remainingText(_ item: Item) -> String {
        guard let trashedAt = item.trashedAt else { return "等待清理" }
        let elapsed = max(0, Date.now.timeIntervalSince(trashedAt))
        let remaining = max(0, 30 - Int(elapsed / 86_400))
        return "剩余约 \(remaining) 天"
    }
}

private enum StorageByteFormat {
    static func short(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension ItemKind {
    var storageSymbol: String {
        switch self {
        case .text: "text.alignleft"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .link: "link"
        case .file: "doc"
        case .binary: "shippingbox"
        }
    }
}

private struct AppearanceSettingsPage: View {
    @Bindable var settings: ProviderSettingsModel
    @Bindable var appModel: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("外观与行为").font(.system(size: 22, weight: .bold))
                    Text("使用项目已有的 Mnemo 图标，并控制临时剪贴板轨道。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "App 图标",
                    subtitle: "点一下立即生效，不需要保存；下次打包也会用这一套。"
                ) {
                    HStack(spacing: 14) {
                        ForEach(AppIconChoice.allCases) { choice in
                            Button { settings.setIcon(choice) } label: {
                                VStack(spacing: 8) {
                                    MnemoIconPreview(choice: choice, size: 70)
                                    Text(choice.title).font(.system(size: 11, weight: .medium))
                                }
                                .padding(10)
                                .background(settings.iconChoice == choice
                                            ? SettingsPalette.selection : SettingsPalette.control,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 12)
                                        .strokeBorder(settings.iconChoice == choice ? Color.accentColor : .clear)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }

                SettingsCard(
                    title: "剪贴板临时历史",
                    subtitle: "Mac 与手机各保留最近 5 条，互不挤占；固定 Pin 永不参与淘汰。"
                ) {
                    HStack(spacing: 18) {
                        Label("Mac · 5 条", systemImage: "macbook")
                        Label("iPhone / iPad · 5 条", systemImage: "iphone")
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12, weight: .medium))
                }

                SettingsCard(
                    title: "开机自启",
                    subtitle: "登录后自动在刘海里待命",
                    help: "由系统的登录项管理，你也可以在「系统设置 → 通用 → 登录项」里看到并关掉。"
                ) {
                    Toggle("开机时自动启动 Mnemo", isOn: $appModel.launchesAtLogin)
                        .font(.system(size: 12, weight: .medium))
                    if LaunchAtLogin.isBlockedBySystem {
                        Label("系统里被禁用了，需要到「系统设置 → 通用 → 登录项」放行",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.orange)
                    }
                }

                SettingsCard(
                    title: "自动归入分组",
                    subtitle: "新内容如果明显属于某个已建好的分组，就自己归进去",
                    help: "模型只能在你已经建好的分组里选，建组永远是你的动作；拿不准时它什么都不做。触发时机和检索索引一样——随手复制的临时内容不会每次都去问。"
                ) {
                    Toggle("自动归入已有分组", isOn: $appModel.autoGroupingEnabled)
                        .font(.system(size: 12, weight: .medium))
                    Text(appModel.autoGroupingEnabled
                         ? "拖进来的内容会自己找位置；归错了拖出来就行"
                         : "只按你手动拖出来的分组归类")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }

                SettingsCard(
                    title: "默认浏览器",
                    subtitle: "链接没有对应 App 时用哪个浏览器打开",
                    help: "「跟随来源」会记住每条链接当初是从哪个浏览器拖进来的——登录态、扩展、书签都在那边。指定一个之后它一律优先。"
                ) {
                    VStack(spacing: 8) {
                        BrowserChoiceRow(
                            name: "跟随来源",
                            detail: "从哪个浏览器拖进来的，就回哪个去（默认）",
                            icon: nil,
                            isSelected: appModel.preferredBrowserBundleID == nil
                        ) { appModel.preferredBrowserBundleID = nil }
                        ForEach(LinkOpener.installedBrowsers) { browser in
                            BrowserChoiceRow(
                                name: browser.name,
                                detail: browser.bundleID,
                                icon: LinkOpener.browserIcon(browser.bundleID),
                                isSelected: appModel.preferredBrowserBundleID == browser.bundleID
                            ) { appModel.preferredBrowserBundleID = browser.bundleID }
                        }
                    }
                }

                SettingsCard(
                    title: "刘海展开方式",
                    subtitle: "用什么手势把工作台从刘海里拉出来",
                    help: "悬停要求指针在刘海上停住约 0.4 秒才展开，扫过去不算。刘海正下方就是菜单栏，默认只认点击，避免路过时被面板挡住。"
                ) {
                    // 三档各占一行，说明写在选项旁边。
                    //
                    // 用过分段控件：三个中文标签里最长的那个是"点击或悬停"，
                    // 分段控件按等宽切分再截断，第三格就只剩一半——看起来
                    // 像只有两档可选。选项不多的时候，一行一个更诚实。
                    VStack(spacing: 8) {
                        ForEach(NotchExpandTrigger.allCases, id: \.self) { trigger in
                            ExpandTriggerRow(
                                trigger: trigger,
                                isSelected: appModel.expandTrigger == trigger
                            ) { appModel.expandTrigger = trigger }
                        }
                    }
                }

                SettingsCard(
                    title: "状态提示",
                    subtitle: "专注完成或出错时刘海边缘发光",
                    help: "系统「减弱动态效果」开启时自动改为静态提示。"
                ) {
                    Toggle("刘海边缘状态光", isOn: $appModel.edgeStatusEffectsEnabled)
                        .font(.system(size: 12, weight: .medium))
                }
            }
            .padding(24)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }
}

/// 默认浏览器的一行选项。图标用浏览器自己的应用图标——用户在 Dock 里看到的
/// Chrome 是什么样，这里就该是什么样，不自己画一套。
private struct BrowserChoiceRow: View {
    let name: String
    let detail: String
    let icon: NSImage?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 18, height: 18)
                } else {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.system(size: 12, weight: .medium))
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? SettingsPalette.selection : SettingsPalette.control,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ExpandTriggerRow: View {
    let trigger: NotchExpandTrigger
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 12))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(trigger.displayName)
                        .font(.system(size: 12, weight: .medium))
                    Text(trigger.explanation)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? SettingsPalette.selection : SettingsPalette.control,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CustomProviderSheet: View {
    @Bindable var settings: ProviderSettingsModel
    @Binding var isPresented: Bool
    @State private var name = ""
    @State private var endpoint = ""
    @State private var dialect: ProviderDialect = .openAICompatible
    @State private var authentication: ProviderAuthentication = .bearer
    @State private var validationMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加自定义供应商").font(.system(size: 18, weight: .bold))
            Form {
                TextField("名称", text: $name)
                TextField("API 地址", text: $endpoint)
                Picker("协议", selection: $dialect) {
                    ForEach(ProviderDialect.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                Picker("鉴权", selection: $authentication) {
                    ForEach(ProviderAuthentication.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
            }
            .formStyle(.grouped)
            if let validationMessage {
                Text(validationMessage).font(.system(size: 11)).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("取消") { isPresented = false }
                Button("添加") { add() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
    }

    private func add() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: endpoint), url.scheme != nil else {
            validationMessage = "请输入名称和完整 API 地址"
            return
        }
        settings.addCustomProvider(
            name: trimmed,
            baseURL: url,
            dialect: dialect,
            authentication: authentication
        )
        isPresented = false
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let helpText: String?
    @ViewBuilder let content: Content

    init(title: String, subtitle: String? = nil, help: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.helpText = help
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(SettingsPalette.stroke) }
        // 详细说明挪进悬停提示：卡片本身只留一行能扫读的副标题。
        .modifier(OptionalHelpModifier(helpText))
    }
}

private struct OptionalHelpModifier: ViewModifier {
    let text: String?
    init(_ text: String?) { self.text = text }
    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
    }
}

private struct LabeledValue: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            Text(value).textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
    }
}

private struct StatusPill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct ProviderBrandIcon: View {
    let provider: ProviderConfiguration
    var size: CGFloat

    var body: some View {
        Group {
            if let badge = SettingsAssetCache.providerBadge(provider: provider, points: size) {
                // 彩色徽章已经烘进位图：圆角底、品牌色、字形比例都在里面，
                // SwiftUI 和 AppKit 菜单拿到的是同一个图，不会再一会彩色一会黑白。
                Image(nsImage: badge)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                // 没有品牌 SVG 的供应商：SF Symbol + 圆角底色，与烘焙徽章同形。
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .fill(brandColor.opacity(0.15))
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.5, weight: .semibold))
                        .foregroundStyle(brandColor)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }

    private var symbol: String {
        switch provider.iconID {
        case "openai": "circle.hexagongrid.fill"
        case "anthropic": "a.circle.fill"
        case "google": "g.circle.fill"
        case "deepseek": "whale.fill"
        case "dashscope": "cloud.fill"
        case "minimax": "waveform.path"
        case "ollama": "desktopcomputer"
        case "lmstudio": "macstudio.fill"
        case "openrouter": "arrow.triangle.branch"
        case "volcengine": "flame.fill"
        default: "sparkles"
        }
    }

    private var brandColor: Color {
        switch provider.iconID {
        case "openai": .primary
        case "anthropic": Color(red: 0.75, green: 0.43, blue: 0.28)
        case "google": Color(red: 0.25, green: 0.51, blue: 0.96)
        case "deepseek": Color(red: 0.25, green: 0.43, blue: 0.98)
        case "dashscope": Color(red: 0.39, green: 0.26, blue: 0.93)
        case "minimax": Color(red: 0.96, green: 0.35, blue: 0.18)
        case "siliconflow": Color(red: 0.08, green: 0.67, blue: 0.55)
        case "volcengine": Color(red: 0.12, green: 0.45, blue: 0.97)
        case "openrouter": Color(red: 0.42, green: 0.35, blue: 0.86)
        default: .secondary
        }
    }
}

private struct MnemoIconPreview: View {
    let choice: AppIconChoice
    let size: CGFloat

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "pin.fill")
                    .resizable().scaledToFit().padding(size * 0.25)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }
        .frame(width: size, height: size)
    }

    private var image: NSImage? {
        SettingsAssetCache.appIcon(choice)
    }
}

@MainActor
private enum SettingsAssetCache {
    private static var providerGlyphs: [String: NSImage] = [:]
    private static var missingProviderIcons: Set<String> = []
    /// 徽章按**渲染尺寸**分别缓存。之前只有 16pt / 36pt 两档，26pt 和 46pt 的
    /// 调用都拿 36pt 那一张去缩放，46pt 处就是放大——MiniMax 那种细笔画的
    /// 标志放大之后只剩一团糊色块。
    private static var badgeCache: [String: NSImage] = [:]
    private static var appIcons: [AppIconChoice: NSImage] = [:]

    /// 供应商徽章（品牌色圆角底 + 品牌色字形）烘进位图。
    ///
    /// 两件事必须一起做，少一件就会退化：
    ///
    /// 1. **颜色烘进位图**。字形原本是黑色模板位图，SwiftUI 里重着色是彩色的，
    ///    AppKit 菜单把 Label 图标拍平后又原样显示成黑色——同一图标一会彩色
    ///    一会黑白。烘进去之后任何渲染管道拿到的都是同一张彩色徽章。
    /// 2. **从矢量直接画到目标像素**。旧实现先把 SVG 光栅成 32×32，再把这张
    ///    小图画进 40px 的字形框里——一次放大，边缘全糊。现在 SVG 一路保持
    ///    矢量，只在最后按 `points × 3` 一次成像。
    static func providerBadge(provider: ProviderConfiguration, points: CGFloat) -> NSImage? {
        let key = "\(provider.iconID)@\(Int(points.rounded()))"
        if let cached = badgeCache[key] { return cached }
        guard let glyph = providerGlyph(named: provider.iconID) else { return nil }
        let badge = renderBadge(
            glyph: glyph,
            tint: brandNSColor(for: provider.iconID),
            points: points
        )
        badgeCache[key] = badge
        return badge
    }

    private static func brandNSColor(for iconID: String) -> NSColor {
        switch iconID {
        case "openai": NSColor(red: 0.10, green: 0.11, blue: 0.12, alpha: 1)
        case "anthropic": NSColor(red: 0.80, green: 0.40, blue: 0.24, alpha: 1)
        case "google": NSColor(red: 0.25, green: 0.51, blue: 0.96, alpha: 1)
        case "deepseek": NSColor(red: 0.25, green: 0.43, blue: 0.98, alpha: 1)
        case "dashscope": NSColor(red: 0.39, green: 0.26, blue: 0.93, alpha: 1)
        case "minimax": NSColor(red: 0.93, green: 0.30, blue: 0.22, alpha: 1)
        case "moonshot": NSColor(red: 0.11, green: 0.13, blue: 0.20, alpha: 1)
        case "zhipu": NSColor(red: 0.15, green: 0.35, blue: 0.92, alpha: 1)
        case "siliconflow": NSColor(red: 0.08, green: 0.67, blue: 0.55, alpha: 1)
        case "volcengine": NSColor(red: 0.12, green: 0.45, blue: 0.97, alpha: 1)
        case "openrouter": NSColor(red: 0.42, green: 0.35, blue: 0.86, alpha: 1)
        case "ollama": NSColor(red: 0.24, green: 0.24, blue: 0.26, alpha: 1)
        case "lmstudio": NSColor(red: 0.30, green: 0.33, blue: 0.40, alpha: 1)
        default: NSColor.secondaryLabelColor
        }
    }

    /// 3× 采样：设置窗多数时候在 2× 屏上，多一档余量让 26pt 这种非整数缩放
    /// 也不会出现半像素毛边；成本只是一张几 KB 的位图，而且按尺寸缓存。
    private static let badgeSampleScale: CGFloat = 3

    private static func renderBadge(glyph: NSImage, tint: NSColor, points: CGFloat) -> NSImage {
        let px = Int((points * badgeSampleScale).rounded())
        guard px > 0, let rep = makeBitmap(pixels: px) else { return glyph }
        // 位图的像素数是 points×3，但一旦声明 rep.size 为 points，绘图坐标系
        // 就是 point 而不是 pixel——这里必须按 points 落笔，多出来的采样率由
        // 后端自己吃掉。写成像素数会把圆角矩形画到画布外面三倍去。
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let side = points
        // 圆角徽章底
        tint.withAlphaComponent(0.15).setFill()
        NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: side, height: side),
            xRadius: side * 0.28,
            yRadius: side * 0.28
        ).fill()
        // 品牌色字形（占 58%，对齐 macOS 应用图标里字形与底板的视觉比例）
        let glyphSide = side * 0.58
        let origin = (side - glyphSide) / 2
        drawTinted(
            glyph,
            tint: tint,
            in: NSRect(x: origin, y: origin, width: glyphSide, height: glyphSide)
        )
        NSGraphicsContext.restoreGraphicsState()
        let result = NSImage(size: NSSize(width: points, height: points))
        result.addRepresentation(rep)
        return result
    }

    /// 把黑字形按品牌色画进当前上下文。
    ///
    /// `sourceAtop` 只覆盖已有 alpha 的像素，透明区不受影响；限制在字形自己的
    /// 矩形里，免得把底板一起染成不透明的实色（那正是"图标变成一个纯色方块"
    /// 的成因）。
    private static func drawTinted(_ glyph: NSImage, tint: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: rect)
        glyph.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        context.setBlendMode(.sourceAtop)
        context.setFillColor(tint.cgColor)
        context.fill(rect)
        context.restoreGState()
    }

    private static func makeBitmap(pixels: Int) -> NSBitmapImageRep? {
        NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixels,
            pixelsHigh: pixels,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
    }

    /// 品牌字形，**保持矢量**。
    ///
    /// SVG 的 NSImageRep 像素尺寸是 0×0，`size` 也可能为零；这里按 viewBox
    /// 归一到 64pt 逻辑尺寸，让后面无论画到多大都从矢量重新成像。
    /// 这张图只在离屏合成徽章时用，绝不直接交给 SwiftUI —— 交出去会被
    /// Picker/Menu 拍平成一张按理想尺寸铺开的巨图。
    private static func providerGlyph(named name: String) -> NSImage? {
        if let cached = providerGlyphs[name] { return cached }
        guard !missingProviderIcons.contains(name) else { return nil }
        let urls = [
            Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "ProviderIcons"),
            Bundle.module.url(forResource: name, withExtension: "svg"),
        ].compactMap { $0 }
        guard let image = urls.lazy.compactMap(NSImage.init(contentsOf:)).first else {
            missingProviderIcons.insert(name)
            return nil
        }
        if image.size.width <= 0 || image.size.height <= 0 {
            image.size = NSSize(width: 64, height: 64)
        }
        providerGlyphs[name] = image
        return image
    }

    static func appIcon(_ choice: AppIconChoice) -> NSImage? {
        if let cached = appIcons[choice] { return cached }
        let names = [choice.resourceName, "pinland-\(choice.rawValue)"]
        for name in names {
            if let url = Bundle.main.url(forResource: name, withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                appIcons[choice] = image
                return image
            }
        }
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appending(path: "icon/build/\(choice.resourceName).icns")
        guard let image = NSImage(contentsOf: url) else { return nil }
        appIcons[choice] = image
        return image
    }
}

private enum SettingsPalette {
    static let background = Color(nsColor: .windowBackgroundColor)
    static let sidebar = Color(nsColor: .underPageBackgroundColor).opacity(0.92)
    static let card = Color(nsColor: .controlBackgroundColor).opacity(0.78)
    static let control = Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.50)
    static let selection = Color.accentColor.opacity(0.16)
    static let stroke = Color.primary.opacity(0.10)
}

private extension ProviderDialect {
    var displayName: String {
        switch self {
        case .openAICompatible: "OpenAI 兼容"
        case .anthropicMessages: "Anthropic Messages"
        }
    }
}

private extension ProviderAuthentication {
    var displayName: String {
        switch self {
        case .bearer: "Bearer Token"
        case .xAPIKey: "X-Api-Key"
        case .none: "无需鉴权"
        }
    }
}

private extension AIReasoningEffort {
    var displayName: String {
        switch self {
        case .off: "关闭"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        }
    }
}

private extension AIFeature {
    var displayName: String {
        switch self {
        case .automaticNaming: "自动命名"
        case .automaticClassification: "自动分类"
        case .sceneRecognition: "场景推荐"
        case .queryParsing: "自然语言检索解析"
        case .retrievalRecommendation: "RAG 检索推荐"
        case .pasteTransformation: "粘贴前转换"
        case .pdfQuestionAnswering: "PDF 问答"
        case .imageUnderstanding: "图片理解"
        case .todoRevision: "待办协调"
        }
    }

    var privacyNote: String {
        switch self {
        case .automaticNaming: "本地敏感筛查后生成短标题"
        case .automaticClassification: "只返回受支持的类型与标签"
        case .sceneRecognition: "模型仅排序本地白名单，最多 3 项"
        case .queryParsing: "先本地解析时间、类型与关键词"
        case .retrievalRecommendation: "只重排本地召回候选并给出理由"
        case .pasteTransformation: "必须由用户明确点击后执行"
        case .pdfQuestionAnswering: "仅发送命中的相关页块"
        case .imageUnderstanding: "缩图后发送；OCR 敏感筛查先在本机执行"
        case .todoRevision: "只在本地已判定与任务有关时调用；模型只能在给定编号里选"
        }
    }
}

private extension ModelModality {
    var shortLabel: String {
        switch self {
        case .text: "文字"
        case .image: "图片"
        case .audio: "音频"
        case .video: "视频"
        case .pdf: "PDF"
        }
    }
}
