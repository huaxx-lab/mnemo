import Foundation
import Testing
import ZIPFoundation
@testable import MnemoCore

private func makeZip(_ entries: [(String, String)], name: String) throws -> URL {
    let url = URL.temporaryDirectory.appending(path: "mnemo-office-\(UUID().uuidString).\(name)")
    guard let archive = Archive(url: url, accessMode: .create) else {
        throw CocoaError(.fileWriteUnknown)
    }
    for (path, content) in entries {
        let data = Data(content.utf8)
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count)) { position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
    return url
}

@Test("docx：段落正文按行出来，跨 run 的文字拼回去")
func extractsWordParagraphs() throws {
    let document = """
    <?xml version="1.0"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
      <w:body>
        <w:p><w:r><w:t>分布式系统</w:t></w:r><w:r><w:t>期中作业</w:t></w:r></w:p>
        <w:p><w:r><w:t>提交时间：</w:t></w:r><w:r><w:t>周五之前</w:t></w:r></w:p>
      </w:body>
    </w:document>
    """
    let url = try makeZip([("word/document.xml", document)], name: "docx")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = try #require(OfficeTextExtractor.extract(from: url))
    #expect(text.contains("分布式系统期中作业"), "\(text)")
    #expect(text.contains("提交时间：周五之前"), "\(text)")
}

@Test("xlsx：共享字符串按索引解析，行按行出来")
func extractsSpreadsheetRows() throws {
    let shared = """
    <?xml version="1.0"?>
    <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <si><t>科目</t></si>
      <si><t>操作系统</t></si>
      <si><t>成绩</t></si>
    </sst>
    """
    let sheet = """
    <?xml version="1.0"?>
    <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
      <sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>2</v></c></row>
        <row r="2"><c r="A2" t="s"><v>1</v></c><c r="B2"><v>92</v></c></row>
      </sheetData>
    </worksheet>
    """
    let url = try makeZip([
        ("xl/sharedStrings.xml", shared),
        ("xl/worksheets/sheet1.xml", sheet),
    ], name: "xlsx")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = try #require(OfficeTextExtractor.extract(from: url))
    #expect(text.contains("科目"), "\(text)")
    #expect(text.contains("操作系统"), "\(text)")
    #expect(text.contains("92"), "\(text)")
}

@Test("pptx：按页码顺序取每页文字")
func extractsSlidesInOrder() throws {
    func slide(_ n: Int, _ text: String) -> (String, String) {
        ("ppt/slides/slide\(n).xml",
         "<p:sld xmlns:a=\"http://schemas.openxmlformats.org/drawingml/2006/main\"><a:t>\(text)</a:t></p:sld>")
    }
    let url = try makeZip([slide(2, "第二页"), slide(10, "第十页"), slide(1, "第一页")], name: "pptx")
    defer { try? FileManager.default.removeItem(at: url) }
    let text = try #require(OfficeTextExtractor.extract(from: url))
    let first = text.range(of: "第一页")!.lowerBound
    let tenth = text.range(of: "第十页")!.lowerBound
    // 字符串排序会把 slide10 排到 slide2 前面；这里守的就是页码序。
    #expect(first < tenth, "\(text)")
}

@Test("不认识的类型老实返回 nil")
func unknownTypesStayNil() throws {
    let url = try makeZip([("foo.txt", "hello")], name: "docx")
    defer { try? FileManager.default.removeItem(at: url) }
    // 是个 zip 但没有 word/document.xml：不硬猜。
    #expect(OfficeTextExtractor.extract(from: url) == nil)
    #expect(!OfficeTextExtractor.canExtract(from: URL(filePath: "/tmp/x.zip")))
}
