import AppKit
import Combine
import MnemoCore
import SwiftUI

/// 首次安装的配置引导。
///
/// 原则：**已经配好的不再追问**。每一步先读当前配置——钥匙串里有没有凭据、
/// 路由指向哪个模型、Embedding 填了什么——有就直接显示成"已配置"，
/// 没有才给输入框。所以重装、升级或从设置页配过的人再打开这里，看到的是
/// 一份现状清单，而不是一张空表。
private let onboardingDashScopeAPIKeyURL = URL(
    string: "https://bailian.console.aliyun.com/cn-beijing?spm=a2c4g.11186623.0.0.26124c35tqkZLF&tab=model#/api-key"
)!

struct OnboardingView: View {
    @Bindable var settings: ProviderSettingsModel
    var finish: () -> Void

    @State private var step: Step = .welcome
    @State private var hasAccessibility = AXIsProcessTrusted()
    @State private var keyDraft = ""
    @State private var isSavingKey = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let permissionPoll = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, permission, model, index, done
        var id: Int { rawValue }
    }

    var body: some View {
        ZStack {
            OnboardingPalette.canvas.ignoresSafeArea()

            VStack(spacing: 0) {
                // 顶部步骤指示器
                stepDots.padding(.top, 28)

                Spacer(minLength: 20)

                // 主内容：带动画切换
                Group {
                    switch step {
                    case .welcome: welcomePage
                    case .permission: permissionPage
                    case .model: modelPage
                    case .index: indexPage
                    case .done: donePage
                    }
                }
                .id(step)
                .frame(maxWidth: 580)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: step)

                Spacer(minLength: 20)

                // 底部导航
                bottomBar.padding(.bottom, 32)
            }
        }
        .frame(minWidth: 720, minHeight: 540)
        .onReceive(permissionPoll) { _ in
            let granted = AXIsProcessTrusted()
            if granted != hasAccessibility { hasAccessibility = granted }
        }
    }

    // MARK: - 顶部步骤指示器

    private var stepDots: some View {
        HStack(spacing: 10) {
            ForEach(Step.allCases) { item in
                let isCurrent = item == step
                let isPast = item.rawValue < step.rawValue
                Circle()
                    .fill(isCurrent
                          ? OnboardingPalette.accent
                          : (isPast ? OnboardingPalette.accent.opacity(0.35) : Color.secondary.opacity(0.22)))
                    .frame(width: isCurrent ? 10 : 8, height: isCurrent ? 10 : 8)
                    .animation(.snappy(duration: 0.22), value: step)
            }
        }
    }

    // MARK: - 底部导航

    private var bottomBar: some View {
        HStack(spacing: 14) {
            if step != .welcome {
                Button("上一步") {
                    withAnimation(.snappy(duration: 0.22)) { move(-1) }
                }
                .buttonStyle(OnboardingNavButtonStyle(emphasis: .secondary))
            }

            Spacer()

            Button(step == .done ? "开始使用" : "下一步") {
                withAnimation(.snappy(duration: 0.22)) { move(1) }
            }
            .buttonStyle(OnboardingNavButtonStyle(emphasis: .primary))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: 580)
    }

    private func move(_ delta: Int) {
        let next = min(max(step.rawValue + delta, 0), Step.allCases.count - 1)
        step = Step(rawValue: next) ?? step
    }

    // MARK: - 各页内容

    private var welcomePage: some View {
        VStack(spacing: 28) {
            OnboardingAppIcon(size: 80)
                .shadow(color: OnboardingPalette.accent.opacity(0.22), radius: 24, y: 8)

            VStack(spacing: 6) {
                Text("Mnemo")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("刘海收纳与快捷推荐")
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                featureRow(
                    symbol: "tray.and.arrow.down",
                    title: "拖到刘海就收好了",
                    detail: "文件、截图、链接、文字都能直接拖进刘海；复制后也会自动留在最近几条里。"
                )
                featureRow(
                    symbol: "command",
                    title: "选中文字按 ⌘G",
                    detail: "要文件就交回剪贴板；问内容就基于你的资料给出完整中文回答。"
                )
                featureRow(
                    symbol: "lock.shield",
                    title: "东西留在本机",
                    detail: "内容、索引都存在你的机器上；API 凭据存进钥匙串，零服务器成本。"
                )
            }
        }
        .padding(.horizontal, 20)
    }

    private func featureRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(OnboardingPalette.accent)
                .frame(width: 36, height: 36)
                .background(OnboardingPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(OnboardingPalette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private var permissionPage: some View {
        VStack(spacing: 24) {
            pageHeader(
                symbol: "hand.raised",
                title: "授予权限",
                subtitle: "只有辅助功能是必需的；完全磁盘访问按需再开。"
            )

            VStack(spacing: 12) {
                permissionCard(
                    symbol: "cursorarrow.and.square.on.square.dashed",
                    title: "辅助功能",
                    detail: "⌘G 要读取你在别的应用里选中的那段文字，这项是必需的。授权后回到这里会自动变成已授权。",
                    isGranted: hasAccessibility,
                    actionTitle: hasAccessibility ? nil : "去授权",
                    action: { Clipboard.promptForAccessibility() }
                )
                permissionCard(
                    symbol: "externaldrive",
                    title: "完全磁盘访问（可选）",
                    detail: "只有从微信这类应用的聊天里直接拖文件时才需要。没有它，其余功能照常工作。",
                    isGranted: nil,
                    actionTitle: "打开设置",
                    action: {
                        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
                        NSWorkspace.shared.open(url)
                    }
                )
            }
        }
        .padding(.horizontal, 20)
    }

    private func permissionCard(
        symbol: String,
        title: String,
        detail: String,
        isGranted: Bool?,
        actionTitle: String?,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(statusTint(isGranted))
                .frame(width: 38, height: 38)
                .background(statusTint(isGranted).opacity(0.10), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(title).font(.system(size: 13.5, weight: .semibold))
                    if let isGranted {
                        OnboardingStatusPill(status: isGranted ? .done("已授权") : .todo("未授权"))
                    } else {
                        OnboardingStatusPill(status: .optional("可选"))
                    }
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let actionTitle {
                    Button(actionTitle, action: action)
                        .font(.system(size: 12))
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(OnboardingPalette.card, in: RoundedRectangle(cornerRadius: 14))
    }

    private func statusTint(_ granted: Bool?) -> Color {
        guard let granted else { return .secondary }
        return granted ? OnboardingPalette.success : OnboardingPalette.warning
    }

    private var modelPage: some View {
        VStack(spacing: 24) {
            pageHeader(
                symbol: "bubble.left.and.text.bubble.right",
                title: "连上一个模型",
                subtitle: "填一次凭据、选一个模型，命名、检索和回答就都能用了。"
            )

            VStack(alignment: .leading, spacing: 18) {
                // 供应商
                VStack(alignment: .leading, spacing: 6) {
                    Text("供应商")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Picker("", selection: providerBinding) {
                        ForEach(settings.providers, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280, alignment: .leading)
                }

                Divider().opacity(0.4)

                // API 凭据
                VStack(alignment: .leading, spacing: 6) {
                    Text("API 凭据")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    if settings.keyPresence[chatProviderID] == true {
                        HStack(spacing: 10) {
                            OnboardingStatusPill(status: .done("已存入钥匙串"))
                            Button("更换") { settings.keyPresence[chatProviderID] = false }
                                .font(.system(size: 11))
                        }
                    } else {
                        HStack(spacing: 10) {
                            SecureField("粘贴 API Key", text: $keyDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 340)
                            Button(isSavingKey ? "保存中…" : "保存") { saveKey() }
                                .disabled(keyDraft.trimmingCharacters(in: .whitespaces).isEmpty || isSavingKey)
                        }
                        Text("凭据只写入 macOS 钥匙串，不会出现在配置文件或日志里。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    if let error = settings.providerErrors[chatProviderID] {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }

                Divider().opacity(0.4)

                // 模型
                VStack(alignment: .leading, spacing: 6) {
                    Text("模型")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    let models = settings.models(for: chatProviderID)
                    if models.isEmpty {
                        HStack(spacing: 10) {
                            Text("还没有模型列表")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Button("拉取模型") {
                                Task { await settings.refreshModels(providerID: chatProviderID) }
                            }
                            .disabled(settings.isRefreshing.contains(chatProviderID))
                        }
                    } else {
                        Picker("", selection: chatModelBinding) {
                            Text("未选择").tag("")
                            ForEach(models, id: \.id) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: 340, alignment: .leading)
                        Text("选中的模型会同时用于命名、检索理解与快捷回答。")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(18)
            .background(OnboardingPalette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 20)
    }

    private var indexPage: some View {
        VStack(spacing: 24) {
            pageHeader(
                symbol: "square.stack.3d.up",
                title: "语义索引",
                subtitle: "配了 Embedding，检索才听得懂自然语言的说法。"
            )

            VStack(alignment: .leading, spacing: 18) {
                Text("Embedding 是单独的一类模型：它把内容变成向量，检索靠它才能理解「讲丢包恢复的那篇」这种说法。不配也能用，只是退化成关键词检索。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 6) {
                    Text("供应商")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Picker("", selection: embeddingProviderBinding) {
                        Text("未启用").tag("")
                        ForEach(settings.providers, id: \.id) { provider in
                            Text(provider.displayName).tag(provider.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: 280, alignment: .leading)
                    if settings.embeddingProviderID == "dashscope" {
                        Button {
                            NSWorkspace.shared.open(onboardingDashScopeAPIKeyURL)
                        } label: {
                            Label("前往阿里云百炼获取 API Key", systemImage: "arrow.up.right.square")
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11, weight: .medium))
                    }
                }

                Divider().opacity(0.4)

                VStack(alignment: .leading, spacing: 6) {
                    Text("模型名")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    TextField("例如 text-embedding-3-large", text: embeddingModelBinding)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 340)
                    Text("对话模型不能当 Embedding 用，两者走的是不同接口。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .background(OnboardingPalette.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(.horizontal, 20)
    }

    private var donePage: some View {
        VStack(spacing: 28) {
            Image(systemName: readiness.isAIReady ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .semibold))
                .foregroundStyle(readiness.isAIReady ? OnboardingPalette.success : OnboardingPalette.warning)
                .symbolEffect(.bounce, options: .repeat(.periodic(5, delay: 3)))

            VStack(spacing: 6) {
                Text(readiness.isAIReady ? "都配好了" : "还差一点")
                    .font(.system(size: 24, weight: .bold))
                Text("随时可以从菜单栏图标重新打开这份引导。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 14) {
                Text("当前配置")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

                VStack(spacing: 10) {
                    summaryRow("对话模型", value: chatSummary, isReady: readiness.isAIReady)
                    summaryRow("语义索引", value: embeddingSummary, isReady: readiness.hasEmbeddingModel)
                    summaryRow("辅助功能", value: hasAccessibility ? "已授权" : "未授权，⌘G 无法读取选区", isReady: hasAccessibility)
                }
                .padding(14)
                .background(OnboardingPalette.card, in: RoundedRectangle(cornerRadius: 12))

                Text("记住这几个键")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.top, 4)

                VStack(spacing: 10) {
                    shortcutRow("⌘G", "读取选中文字，直接给推荐或完整回答")
                    shortcutRow("⌘P", "把当前剪贴板收进 Mnemo")
                    shortcutRow("⌘Space", "打开或收起刘海面板")
                    shortcutRow("拖到刘海", "文件、图片、链接直接入库")
                }
                .padding(14)
                .background(OnboardingPalette.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - 通用组件

    private func pageHeader(symbol: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(OnboardingPalette.accent)
                .frame(width: 52, height: 52)
                .background(OnboardingPalette.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
            Text(title)
                .font(.system(size: 22, weight: .bold))
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func summaryRow(_ title: String, value: String, isReady: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(isReady ? OnboardingPalette.success : OnboardingPalette.warning)
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 68, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func shortcutRow(_ key: String, _ detail: String) -> some View {
        HStack(spacing: 10) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(OnboardingPalette.chip, in: RoundedRectangle(cornerRadius: 6))
                .frame(minWidth: 74, alignment: .leading)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 现状读取与写入

    private var readiness: OnboardingReadiness {
        OnboardingReadiness(
            hasAccessibilityPermission: hasAccessibility,
            hasChatCredential: settings.keyPresence[chatProviderID] == true,
            hasChatModel: !currentChatModelID.isEmpty,
            hasEmbeddingModel: settings.embeddingProviderID?.isEmpty == false
                && !settings.embeddingModelID.trimmingCharacters(in: .whitespaces).isEmpty
        )
    }

    private var chatProviderID: String { settings.chatProviderID ?? settings.selectedProviderID }

    private var currentChatModelID: String {
        settings.routing.route(for: .retrievalRecommendation)?.modelID
            ?? settings.routing.fast?.modelID
            ?? ""
    }

    private var chatSummary: String {
        guard readiness.isAIReady else { return "还没配好，AI 功能暂时不可用" }
        let provider = settings.providers.first { $0.id == chatProviderID }?.displayName ?? chatProviderID
        return "\(provider) · \(currentChatModelID)"
    }

    private var embeddingSummary: String {
        guard readiness.hasEmbeddingModel, let id = settings.embeddingProviderID else {
            return "未启用，检索退化为关键词匹配"
        }
        let provider = settings.providers.first { $0.id == id }?.displayName ?? id
        return "\(provider) · \(settings.embeddingModelID)"
    }

    private var providerBinding: Binding<String> {
        Binding(
            get: { chatProviderID },
            set: { id in
                settings.selectProvider(id)
                Task { await settings.setChatProvider(id) }
            }
        )
    }

    private var chatModelBinding: Binding<String> {
        Binding(
            get: { currentChatModelID },
            set: { id in
                guard !id.isEmpty else {
                    settings.setFastRoute(nil)
                    settings.setStrongRoute(nil)
                    return
                }
                let route = FeatureRoute(providerID: chatProviderID, modelID: id)
                settings.setFastRoute(route)
                settings.setStrongRoute(route)
            }
        )
    }

    private var embeddingProviderBinding: Binding<String> {
        Binding(
            get: { settings.embeddingProviderID ?? "" },
            set: { id in Task { await settings.setEmbeddingProvider(id.isEmpty ? nil : id) } }
        )
    }

    private var embeddingModelBinding: Binding<String> {
        Binding(
            get: { settings.embeddingModelID },
            set: { settings.setEmbeddingModelID($0) }
        )
    }

    private func saveKey() {
        let value = keyDraft
        isSavingKey = true
        Task {
            await settings.saveCredential(value, providerID: chatProviderID)
            keyDraft = ""
            isSavingKey = false
        }
    }
}

// MARK: - 小组件

private enum OnboardingPalette {
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let card = Color(nsColor: .controlBackgroundColor)
    static let chip = Color.primary.opacity(0.08)
    static let accent = Color.accentColor
    static let success = Color(red: 0.24, green: 0.68, blue: 0.46)
    static let warning = Color(red: 0.92, green: 0.62, blue: 0.20)
}

private enum OnboardingStatus {
    case done(String)
    case todo(String)
    case optional(String)

    var text: String {
        switch self {
        case .done(let value), .todo(let value), .optional(let value): value
        }
    }
    var tint: Color {
        switch self {
        case .done: OnboardingPalette.success
        case .todo: OnboardingPalette.warning
        case .optional: .secondary
        }
    }
    var symbol: String {
        switch self {
        case .done: "checkmark.circle.fill"
        case .todo: "exclamationmark.circle.fill"
        case .optional: "circle.dashed"
        }
    }
}

private struct OnboardingStatusPill: View {
    let status: OnboardingStatus

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: status.symbol).font(.system(size: 10, weight: .semibold))
            Text(status.text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(status.tint)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(status.tint.opacity(0.12), in: Capsule())
    }
}

private struct OnboardingNavButtonStyle: ButtonStyle {
    enum Emphasis { case primary, secondary }
    var emphasis: Emphasis

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: emphasis == .primary ? .semibold : .medium))
            .foregroundStyle(emphasis == .primary ? .white : .primary)
            .padding(.horizontal, 18)
            .frame(height: 34)
            .background(
                emphasis == .primary
                    ? OnboardingPalette.accent.opacity(configuration.isPressed ? 0.82 : 1)
                    : OnboardingPalette.chip,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

/// 引导页应用图标：直接用当前选中的那套 .icns，换了图标这里跟着变。
private struct OnboardingAppIcon: View {
    let size: CGFloat

    var body: some View {
        if let image = NSApp.applicationIconImage {
            Image(nsImage: image).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.24)
                .fill(OnboardingPalette.accent.opacity(0.15))
                .frame(width: size, height: size)
        }
    }
}
