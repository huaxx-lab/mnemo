import Foundation
import Testing
@testable import MnemoCore

@Test("中文查询按二字组切词，不再要求整句原样出现")
func lexicalMatchHandlesChineseQueries() {
    let ocr = "央视新闻报道：某地牛群走失，警方已介入处理"

    #expect(LexicalMatch.score(text: ocr, query: "央视新闻报道") == LexicalMatch.fullPhraseScore)

    // 部分命中也要有分。旧实现要求整句 contains，这里必然是 0，
    // 于是没配 embedding 时这张截图根本搜不到。
    let partial = LexicalMatch.score(text: ocr, query: "央视报道牛的截图")
    #expect(partial > 0)
    #expect(partial <= LexicalMatch.maximumPartialScore)

    #expect(LexicalMatch.score(text: ocr, query: "季度财报表格") == 0)
}

@Test("英文按空格切词，单字母噪音不参与")
func lexicalMatchHandlesEnglishQueries() {
    let text = "Communication Semantic Aware RDMA Loss Recovery"
    #expect(LexicalMatch.score(text: text, query: "rdma loss") > 0)
    #expect(LexicalMatch.score(text: text, query: "RDMA") == LexicalMatch.fullPhraseScore)
    #expect(LexicalMatch.score(text: text, query: "kubernetes") == 0)

    let terms = LexicalMatch.terms(in: "a rdma loss")
    #expect(!terms.contains("a"), "单字母不该成为检索词")
    #expect(terms.contains("rdma"))
}

@Test("空查询不匹配任何内容")
func lexicalMatchIgnoresEmptyQuery() {
    #expect(LexicalMatch.score(text: "任意内容", query: "   ") == 0)
}
