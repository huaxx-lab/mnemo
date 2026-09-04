import MnemoCore
import SwiftUI

/// 更新窗。四种状态同一张脸：图标和标题永远在上，底下只换"此刻该干什么"。
struct UpdateWindow: View {
    // 协调器是 @Observable：直接读属性即可，SwiftUI 自己追踪依赖。
    private var coordinator = UpdateCoordinator.shared

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().padding(.top, 16)
            content
            footer
        }
        .frame(width: 480, height: 520)
    }

    private var header: some View {
        HStack(spacing: 14) {
            if let icon = NSApp.applicationIconImage {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Mnemo 更新")
                    .font(.system(size: 17, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
    }

    private var subtitle: String {
        switch coordinator.phase {
        case .idle, .checking: "正在检查新版本…"
        case .upToDate: "当前 \(coordinator.currentVersion) 已是最新"
        case .available(let release): "发现新版本 \(release.version)"
        case .downloading: "正在下载…"
        case .installing: "正在安装…"
        case .failed: "出了点问题"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.phase {
        case .idle, .checking:
            Spacer()
            ProgressView().controlSize(.regular)
            Spacer()
        case .upToDate:
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.green)
                Text("已经是最新版本")
                    .font(.system(size: 14, weight: .medium))
            }
            Spacer()
        case .available(let release):
            releaseNotes(release)
        case .downloading(let progress, let received, let total):
            Spacer()
            VStack(spacing: 12) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                HStack {
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                    Spacer(minLength: 0)
                    if total > 0 {
                        Text("\(ByteFormat.short(received)) / \(ByteFormat.short(total))")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .frame(width: 300)
            }
            Spacer()
        case .installing:
            Spacer()
            VStack(spacing: 10) {
                ProgressView().controlSize(.regular)
                Text("正在替换应用并准备重启…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        case .failed(let reason):
            Spacer()
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 30))
                    .foregroundStyle(.orange)
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            Spacer()
        }
    }

    private func releaseNotes(_ release: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("v\(coordinator.currentVersion)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Text("v\(release.version)")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
            }
            // 发布说明是 Markdown。用纯 Text 渲染的话，`##` 和 `-` 会原样
            // 显示成符号，读起来像没排版的源码。复用应用里已有的 MarkdownText
            // （标题、列表、行内格式、代码块都支持）。
            ScrollView {
                MarkdownText(
                    raw: release.notes.isEmpty ? release.title : release.notes,
                    font: .system(size: 12)
                )
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary.opacity(0.6))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            switch coordinator.phase {
            case .idle, .checking:
                EmptyView()
            case .upToDate:
                Button("好") { coordinator.dismiss() }
                    .keyboardShortcut(.defaultAction)
            case .available(let release):
                Button("稍后") { coordinator.dismiss() }
                Button("下载并更新") { coordinator.downloadAndInstall(release) }
                    .keyboardShortcut(.defaultAction)
            case .downloading:
                Button("取消下载") { coordinator.cancelDownload() }
            case .installing:
                EmptyView()
            case .failed:
                Button("关闭") { coordinator.dismiss() }
                Button("重试") { coordinator.checkNow() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }
}

private enum ByteFormat {
    static func short(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}
