import AppKit
import ImageIO
import PDFKit
import MnemoCore
import Vision

enum SemanticContentExtractor {

    static func extract(item: Item, library: Library) async -> [ContentChunk] {
        switch item.holding {
        case .inline(let text):
            return ContentChunking.chunks(
                itemID: item.id,
                text: text,
                source: .inlineText,
                pageNumber: nil,
                ordinalBase: 0
            )
        case .copy, .reference:
            guard let url = try? await library.resolvedFileURL(for: item) else { return [] }
            switch item.kind {
            case .pdf:
                return await extractPDF(itemID: item.id, url: url)
            case .image:
                return await extractImage(
                    itemID: item.id,
                    url: url,
                    filename: item.originalFilename ?? item.title
                )
            case .text:
                guard let text = await Task.detached(priority: .utility, operation: {
                    try? String(contentsOf: url, encoding: .utf8)
                }).value else { return [] }
                return ContentChunking.chunks(
                    itemID: item.id,
                    text: text,
                    source: .fileText,
                    pageNumber: nil,
                    ordinalBase: 0
                )
            case .file, .binary:
                // Office 文档（Word / Excel / PPT）：没有这一步，拖进来的
                // docx、xlsx 在检索眼里只是一个文件名，正文永远搜不到。
                guard OfficeTextExtractor.canExtract(from: url),
                      let text = await Task.detached(
                        priority: .utility,
                        operation: { OfficeTextExtractor.extract(from: url) }
                      ).value else { return [] }
                return ContentChunking.chunks(
                    itemID: item.id,
                    text: text,
                    source: .fileText,
                    pageNumber: nil,
                    ordinalBase: 0
                )
            default:
                return []
            }
        }
    }

    /// 对链接的首图跑 OCR。
    ///
    /// 小红书这类平台的内容常常**根本不在文字里**：正文一句"见图"，真正的
    /// 信息全写在配图上。首图已经被 LinkCoverStore 下载并缓存成 PNG 了，
    /// 复用它不需要再发一次网络请求。
    ///
    /// 用 imageOCR 这个 source，和截图走同一条路：召回时能说清楚"这句话是
    /// 从图里读出来的"，也和现有的隐私、重建逻辑保持一致。
    static func linkCoverChunks(
        itemID: UUID,
        coverURL: URL,
        ordinalBase: Int
    ) async -> [ContentChunk] {
        await extractImage(itemID: itemID, url: coverURL, filename: "")
            .enumerated()
            .map { offset, chunk in
                var value = chunk
                value.ordinal = ordinalBase + offset
                return value
            }
    }

    private static func extractPDF(itemID: UUID, url: URL) async -> [ContentChunk] {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url) else { return [] }
            var result: [ContentChunk] = []
            var ordinal = 0
            for index in 0..<document.pageCount {
                guard !Task.isCancelled else { return [] }
                let pageChunks: [ContentChunk] = autoreleasepool {
                    guard let text = document.page(at: index)?.string,
                          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return []
                    }
                    return ContentChunking.chunks(
                        itemID: itemID,
                        text: text,
                        source: .pdfPage,
                        pageNumber: index + 1,
                        ordinalBase: ordinal
                    )
                }
                result.append(contentsOf: pageChunks)
                ordinal += pageChunks.count
            }
            return result
        }.value
    }

    /// 只做文字识别的轻量入口，给「手机同步过来的内容」这条独立路径用。
    ///
    /// 本机截图走的是另一条路：固定之后由索引管线顺带 OCR，这里一次都不跑。
    /// 手机来的不一样——它没有"固定"这个动作可等，而且量本来就小（手机上
    /// 复制一次东西的频率远低于 Mac 本机），所以直接全精度认一遍。
    /// 不写分块、不建索引、不碰网络，识别出的文本用过即弃。
    static func recognizeText(in data: Data, maxPixelSize: Int = 2_048) async -> String {
        await Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                  ) else { return "" }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            do { try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request]) }
            catch { return "" }
            guard !Task.isCancelled else { return "" }
            return (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }

    private static func extractImage(
        itemID: UUID,
        url: URL,
        filename: String
    ) async -> [ContentChunk] {
        await Task.detached(priority: .utility) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cgImage = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4096,
                        kCGImageSourceShouldCacheImmediately: true,
                    ] as CFDictionary
                  ) else {
                return []
            }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            let classification = VNClassifyImageRequest()
            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do { try handler.perform([request, classification]) }
            catch { return [] }
            guard !Task.isCancelled else { return [] }
            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            var result = text.isEmpty ? [] : ContentChunking.chunks(
                itemID: itemID,
                text: text,
                source: .imageOCR,
                pageNumber: nil,
                ordinalBase: 0
            )

            // 本机 Vision 标签补足“没有文字的图片”检索；标签随后和 OCR 一样
            // 只按用户配置进入 Embedding，不需要把原图上传给聊天模型。
            let labels = (classification.results ?? [])
                .filter { $0.confidence >= 0.08 }
                .prefix(12)
                .map(\.identifier)
            let visualDescription = ([filename] + labels).joined(separator: ", ")
            if !labels.isEmpty {
                result.append(ContentChunk(
                    itemID: itemID,
                    ordinal: result.count,
                    source: .imageCaption,
                    text: visualDescription
                ))
            }
            return result
        }.value
    }

}
