import Charts
import SwiftUI
import MnemoCore

/// 检索库（RAG）的体检页。
///
/// 这个库平时是黑箱：东西扔进去了，能不能被搜到全靠试。出问题时最常见的
/// 困惑是"我明明存了，为什么搜不到"——而答案往往是某一类内容根本没进
/// 向量库（抓取失败、没配 Embedding、正文是空的）。把这些平时看不见的
/// 分布摆出来，用户自己就能看出哪一类内容有窟窿。
///
/// 统计一律现算不缓存：库的规模在个人使用量级（分块数千），一次全量扫描
/// 是毫秒级；而缓存一份统计意味着要在每条增删改上维护它，代价和出错面都
/// 比省下的那点时间大得多。
struct RAGLibraryStats: Sendable {
    struct Bucket: Identifiable, Sendable {
        var id: String { label }
        var label: String
        var count: Int
    }

    var itemCount = 0
    var trashedCount = 0
    var chunkCount = 0
    var vectorizedChunks = 0
    var totalTextChars = 0
    var embeddingModels: [String] = []
    var vectorDimensions: [Int] = []

    var kindBuckets: [Bucket] = []
    var sourceBuckets: [Bucket] = []
    var platformBuckets: [Bucket] = []
    var dailyIntake: [(day: Date, count: Int)] = []

    /// 有内容但一个分块都没有的条目——它们在界面上看着好好的，检索里
    /// 却完全不存在。这一项是这个页面存在的主要理由。
    var itemsWithoutChunks: [String] = []
    /// 链接抓回来了、但正文分块是空的：卡片有标题，问它内容却答不上来。
    var linksWithoutBody: [String] = []

    var vectorizedRatio: Double {
        chunkCount == 0 ? 0 : Double(vectorizedChunks) / Double(chunkCount)
    }

    static func build(items: [Item], trashed: [Item], chunks: [ContentChunk]) -> RAGLibraryStats {
        var stats = RAGLibraryStats()
        stats.itemCount = items.count
        stats.trashedCount = trashed.count
        stats.chunkCount = chunks.count

        var kinds: [ItemKind: Int] = [:]
        var platforms: [String: Int] = [:]
        var days: [Date: Int] = [:]
        let calendar = Calendar.current
        for item in items {
            kinds[item.kind, default: 0] += 1
            if item.kind == .link {
                let name = item.linkURL.flatMap(LinkPlatform.resolve)?.displayName ?? "其他站点"
                platforms[name, default: 0] += 1
            }
            days[calendar.startOfDay(for: item.createdAt), default: 0] += 1
        }

        var sources: [ContentChunkSource: Int] = [:]
        var models: Set<String> = []
        var dimensions: Set<Int> = []
        var chunkedItems: Set<UUID> = []
        var itemsWithBody: Set<UUID> = []
        for chunk in chunks {
            sources[chunk.source, default: 0] += 1
            stats.totalTextChars += chunk.text.count
            chunkedItems.insert(chunk.itemID)
            if chunk.source == .linkPage { itemsWithBody.insert(chunk.itemID) }
            if let vector = chunk.vector, !vector.isEmpty {
                stats.vectorizedChunks += 1
                dimensions.insert(vector.count)
            }
            if let model = chunk.embeddingModelID { models.insert(model) }
        }
        stats.embeddingModels = models.sorted()
        stats.vectorDimensions = dimensions.sorted()

        stats.kindBuckets = kinds
            .map { Bucket(label: $0.key.statsLabel, count: $0.value) }
            .sorted { $0.count > $1.count }
        stats.sourceBuckets = sources
            .map { Bucket(label: $0.key.statsLabel, count: $0.value) }
            .sorted { $0.count > $1.count }
        stats.platformBuckets = platforms
            .map { Bucket(label: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        // 最近 14 天，缺的那天补 0——不补的话柱子会挤在一起，看不出"这几天
        // 什么都没存"这件同样重要的事。
        let today = calendar.startOfDay(for: .now)
        stats.dailyIntake = (0..<14).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, days[day] ?? 0)
        }

        stats.itemsWithoutChunks = items
            .filter { !chunkedItems.contains($0.id) }
            .map(\.title)
        stats.linksWithoutBody = items
            .filter { $0.kind == .link && !itemsWithBody.contains($0.id) }
            .map(\.title)
        return stats
    }
}

private extension ItemKind {
    var statsLabel: String {
        switch self {
        case .text: "文本"
        case .image: "图片"
        case .pdf: "PDF"
        case .link: "链接"
        case .file: "文件"
        case .binary: "其他"
        }
    }
}

private extension ContentChunkSource {
    var statsLabel: String {
        switch self {
        case .inlineText: "内联文本"
        case .fileText: "文件正文"
        case .pdfPage: "PDF 页"
        case .imageOCR: "图片 OCR"
        case .imageCaption: "画面描述"
        case .linkPage: "链接正文"
        case .userAnnotation: "用户备注"
        }
    }
}

struct RAGLibraryStatsPage: View {
    @Bindable var appModel: AppModel

    @State private var stats: RAGLibraryStats?
    @State private var isLoading = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let stats {
                    overviewTiles(stats)
                    vectorCoverageCard(stats)
                    distributionCards(stats)
                    intakeCard(stats)
                    healthCard(stats)
                } else if isLoading {
                    ProgressView("正在统计检索库")
                        .frame(maxWidth: .infinity, minHeight: 240)
                }
            }
            .padding(22)
        }
        .task { await reload() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("检索库详情").font(.system(size: 22, weight: .bold))
                Text("这里是「能不能被搜到」的真实状态：没有分块的条目，检索里就不存在。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await reload() }
            } label: {
                Label("重新统计", systemImage: "arrow.clockwise")
            }
            .disabled(isLoading)
        }
    }

    private func overviewTiles(_ stats: RAGLibraryStats) -> some View {
        HStack(spacing: 12) {
            statTile("Pin 总数", value: "\(stats.itemCount)",
                     detail: stats.trashedCount > 0 ? "回收站另有 \(stats.trashedCount)" : "全部在库",
                     symbol: "square.stack.3d.up", color: .accentColor)
            statTile("检索分块", value: "\(stats.chunkCount)",
                     detail: "约 \(compactChars(stats.totalTextChars)) 字",
                     symbol: "text.alignleft", color: .teal)
            statTile("已向量化", value: percent(stats.vectorizedRatio),
                     detail: "\(stats.vectorizedChunks)/\(stats.chunkCount) 块",
                     symbol: "point.3.filled.connected.trianglepath.dotted",
                     color: stats.vectorizedRatio > 0.98 ? .green : .orange)
            statTile("占用空间", value: StorageByteFormat.short(appModel.activeStorageBytes),
                     detail: "副本与索引", symbol: "internaldrive", color: .indigo)
        }
    }

    private func vectorCoverageCard(_ stats: RAGLibraryStats) -> some View {
        SettingsCard(
            title: "向量覆盖",
            subtitle: "只有向量化过的分块才能被自然语言召回；没配 Embedding 时会停在这里。"
        ) {
            HStack(spacing: 22) {
                ZStack {
                    Circle().stroke(SettingsPalette.stroke, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: max(0.001, stats.vectorizedRatio))
                        .stroke(
                            stats.vectorizedRatio > 0.98 ? Color.green : Color.orange,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                    Text(percent(stats.vectorizedRatio))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                }
                .frame(width: 96, height: 96)

                VStack(alignment: .leading, spacing: 8) {
                    LabeledContent("已向量化") { Text("\(stats.vectorizedChunks) 块") }
                    LabeledContent("待向量化") {
                        Text("\(stats.chunkCount - stats.vectorizedChunks) 块")
                            .foregroundStyle(
                                stats.vectorizedChunks == stats.chunkCount
                                    ? Color.secondary : Color.orange
                            )
                    }
                    LabeledContent("Embedding 模型") {
                        Text(stats.embeddingModels.isEmpty ? "未配置" : stats.embeddingModels.joined(separator: "、"))
                            .lineLimit(1)
                    }
                    if stats.vectorDimensions.count > 1 {
                        // 维度不一致意味着换过模型且没重建：两批向量在同一个
                        // 空间里比距离是没有意义的，检索结果会莫名其妙。
                        Label(
                            "存在 \(stats.vectorDimensions.map(String.init).joined(separator: " / ")) 多种维度，建议重建索引",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.system(size: 11)).foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11.5))
                Spacer()
            }
        }
    }

    private func distributionCards(_ stats: RAGLibraryStats) -> some View {
        VStack(spacing: 18) {
            SettingsCard(
                title: "分块来源分布",
                subtitle: "检索命中的其实是这些分块，不是卡片本身。"
            ) {
                barChart(stats.sourceBuckets, color: .teal)
            }
            HStack(alignment: .top, spacing: 18) {
                SettingsCard(title: "内容类型", subtitle: "按 Pin 计") {
                    barChart(stats.kindBuckets, color: .accentColor)
                }
                SettingsCard(title: "链接来源站点", subtitle: "按 Pin 计") {
                    if stats.platformBuckets.isEmpty {
                        emptyHint("还没有链接")
                    } else {
                        barChart(Array(stats.platformBuckets.prefix(8)), color: .pink)
                    }
                }
            }
        }
    }

    private func intakeCard(_ stats: RAGLibraryStats) -> some View {
        SettingsCard(title: "最近 14 天入库", subtitle: "每天新增的 Pin 数量。") {
            Chart(stats.dailyIntake, id: \.day) { entry in
                BarMark(
                    x: .value("日期", entry.day, unit: .day),
                    y: .value("数量", entry.count)
                )
                .foregroundStyle(Color.accentColor.gradient)
                .cornerRadius(3)
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 3)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                }
            }
            .frame(height: 150)
        }
    }

    private func healthCard(_ stats: RAGLibraryStats) -> some View {
        SettingsCard(
            title: "检索健康检查",
            subtitle: "下面这些条目在界面上看得见，但检索里是空的。"
        ) {
            VStack(alignment: .leading, spacing: 12) {
                healthRow(
                    title: "完全没有分块的 Pin",
                    names: stats.itemsWithoutChunks,
                    okText: "每个 Pin 都有可检索内容",
                    hint: "多半是抓取失败或内容为空——对链接可以右键「重新解析」。"
                )
                healthRow(
                    title: "抓不到正文的链接",
                    names: stats.linksWithoutBody,
                    okText: "所有链接都抓到了正文",
                    hint: "图片直链、下载直链本来就没有正文，属于正常；文章类链接出现在这里才需要处理。"
                )
            }
        }
    }

    @ViewBuilder
    private func healthRow(title: String, names: [String], okText: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: names.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .foregroundStyle(names.isEmpty ? .green : .orange)
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(names.isEmpty ? okText : "\(names.count) 个")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !names.isEmpty {
                Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(names.prefix(6), id: \.self) { name in
                        Text("· " + name)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    if names.count > 6 {
                        Text("· 还有 \(names.count - 6) 个")
                            .font(.system(size: 10.5)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private func barChart(_ buckets: [RAGLibraryStats.Bucket], color: Color) -> some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("数量", bucket.count),
                y: .value("类别", bucket.label)
            )
            .foregroundStyle(color.gradient)
            .cornerRadius(4)
            .annotation(position: .trailing, alignment: .leading) {
                Text("\(bucket.count)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .frame(height: max(70, CGFloat(buckets.count) * 26 + 16))
    }

    private func statTile(
        _ title: String, value: String, detail: String, symbol: String, color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                Spacer()
            }
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 10.5)).foregroundStyle(.secondary)
                Text(detail).font(.system(size: 9.5)).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(SettingsPalette.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(SettingsPalette.stroke) }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 70)
    }

    private func percent(_ value: Double) -> String {
        value <= 0 ? "0%" : String(format: "%.0f%%", value * 100)
    }

    private func compactChars(_ count: Int) -> String {
        count >= 10_000 ? String(format: "%.1f 万", Double(count) / 10_000) : "\(count)"
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        let library = appModel.library
        let items = (try? await library.items()) ?? []
        let trashed = (try? await library.items(includingTrashed: true))?.filter { $0.trashedAt != nil } ?? []
        let chunks = (try? await library.allChunks()) ?? []
        stats = RAGLibraryStats.build(items: items, trashed: trashed, chunks: chunks)
    }
}
