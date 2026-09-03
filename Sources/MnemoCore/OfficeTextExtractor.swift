import Foundation
import ZIPFoundation

/// 从 Office 文档里抽出可检索的正文。
///
/// OOXML（docx / xlsx / pptx）都是 zip 包 XML：docx 正文在 word/document.xml，
/// xlsx 的字符串在 xl/sharedStrings.xml、每页在 xl/worksheets/sheet*.xml，
/// pptx 每页在 ppt/slides/slide*.xml。抽取不追求排版还原，只追求"文字都在"——
/// 它唯一的服务对象是检索：用户之后用自然语言问，这些内容能被命中。
///
/// 老格式（.doc/.xls/.ppt 二进制）走系统的 textutil：它是 macOS 自带的成熟
/// 转换器，比自己解析二进制格式可靠得多。textutil 不支持的（xls）就放弃，
/// 宁可少识别也不抽出乱码。
public enum OfficeTextExtractor {
    /// 支持抽正文的扩展名。
    public static let supportedExtensions: Set<String> = [
        "docx", "xlsx", "pptx", "doc", "rtf", "odt",
    ]

    public static func canExtract(from url: URL) -> Bool {
        supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static func extract(from url: URL) -> String? {
        switch url.pathExtension.lowercased() {
        case "docx": return extractWord(from: url)
        case "xlsx": return extractSpreadsheet(from: url)
        case "pptx": return extractSlides(from: url)
        case "doc", "rtf", "odt": return extractViaTextutil(url)
        default: return nil
        }
    }

    // MARK: - docx

    private static func extractWord(from url: URL) -> String? {
        guard let archive = try? Archive(url: url, accessMode: .read),
              let document = archive["word/document.xml"],
              let data = try? readEntry(document, from: archive) else { return nil }
        return WordDocumentParser.parse(data)
    }

    // MARK: - xlsx

    private static func extractSpreadsheet(from url: URL) -> String? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        var sharedStrings: [String] = []
        if let shared = archive["xl/sharedStrings.xml"],
           let data = try? readEntry(shared, from: archive) {
            sharedStrings = SharedStringsParser.parse(data)
        }
        var sheets: [String] = []
        for entry in archive where entry.path.hasPrefix("xl/worksheets/sheet") {
            guard entry.path.hasSuffix(".xml"),
                  let data = try? readEntry(entry, from: archive) else { continue }
            if let text = SheetParser.parse(data, sharedStrings: sharedStrings) {
                sheets.append(text)
            }
        }
        guard !sheets.isEmpty else { return nil }
        return sheets.joined(separator: "\n\n")
    }

    // MARK: - pptx

    private static func extractSlides(from url: URL) -> String? {
        guard let archive = try? Archive(url: url, accessMode: .read) else { return nil }
        let slideEntries = archive
            .filter { $0.path.hasPrefix("ppt/slides/slide") && $0.path.hasSuffix(".xml") }
            // slide1, slide2 … slide10：按数字排，字符串排序会把 10 排到 2 前面。
            .sorted { lhs, rhs in
                slideNumber(lhs.path) < slideNumber(rhs.path)
            }
        var slides: [String] = []
        for entry in slideEntries {
            guard let data = try? readEntry(entry, from: archive) else { continue }
            let text = PlainTextRunsParser.parse(data, tag: "a:t")
            if !text.isEmpty { slides.append(text) }
        }
        guard !slides.isEmpty else { return nil }
        return slides.joined(separator: "\n\n")
    }

    private static func slideNumber(_ path: String) -> Int {
        let name = (path as NSString).deletingPathExtension
        let digits = name.drop(while: { !$0.isNumber })
        return Int(digits) ?? .max
    }

    // MARK: - 老格式走系统转换器

    private static func extractViaTextutil(_ url: URL) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard let _ = try? process.run() else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    private static func readEntry(_ entry: Entry, from archive: Archive) throws -> Data {
        var data = Data()
        _ = try archive.extract(entry) { slice in data.append(slice) }
        return data
    }
}

// MARK: - XML 解析

/// 三个解析器共用同一台 XMLParser：OOXML 的标签带命名空间前缀（w:t、a:t），
/// 用限定名比较即可，不必真的解析命名空间。
private final class WordDocumentParser: NSObject, XMLParserDelegate {
    private var paragraphs: [String] = []
    private var current: [String] = []
    private var inText = false

    static func parse(_ data: Data) -> String? {
        let delegate = WordDocumentParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        parser.parse()
        let text = delegate.paragraphs
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "w:p": current = []
        case "w:t": inText = true
        case "w:tab": current.append(" ")
        case "w:br": current.append("\n")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch elementName {
        case "w:t": inText = false
        case "w:p": paragraphs.append(current.joined())
        default: break
        }
    }
}

private final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current: [String] = []
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let delegate = SharedStringsParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == "si" { current = [] }
        if elementName == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        if elementName == "t" { inText = false }
        if elementName == "si" { strings.append(current.joined()) }
    }
}

private final class SheetParser: NSObject, XMLParserDelegate {
    private var rows: [String] = []
    private var cells: [String] = []
    private var inValue = false
    private var cellType: String?
    private var currentCell: [String] = []
    private let sharedStrings: [String]

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    static func parse(_ data: Data, sharedStrings: [String]) -> String? {
        let delegate = SheetParser(sharedStrings: sharedStrings)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        let text = delegate.rows
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return text.isEmpty ? nil : text
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        switch elementName {
        case "row": cells = []
        case "c":
            cellType = attributeDict["t"]
            currentCell = []
        case "v", "t": inValue = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { currentCell.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        switch elementName {
        case "v", "t": inValue = false
        case "c":
            let raw = currentCell.joined()
            if cellType == "s", let index = Int(raw), sharedStrings.indices.contains(index) {
                cells.append(sharedStrings[index])
            } else if !raw.isEmpty {
                cells.append(raw)
            }
        case "row":
            rows.append(cells.joined(separator: "  "))
        default: break
        }
    }
}

/// 只收集某个标签里的文字（PPT 的 a:t）。
private final class PlainTextRunsParser: NSObject, XMLParserDelegate {
    private let tag: String
    private var runs: [String] = []
    private var inside = false

    init(tag: String) { self.tag = tag }

    static func parse(_ data: Data, tag: String) -> String {
        let delegate = PlainTextRunsParser(tag: tag)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.runs.joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        if elementName == tag { inside = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inside { runs.append(string) }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        if elementName == tag { inside = false }
    }
}
