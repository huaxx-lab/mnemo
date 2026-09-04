import Foundation
import Testing
@testable import MnemoCore
@testable import MnemoStore

@Test("SwiftData 同一事务替换 RAG 分块和条目索引状态")
func swiftDataAtomicIndexReplacement() async throws {
    let container = try SwiftDataItemStore.makeContainer(inMemory: true)
    let store = SwiftDataItemStore(modelContainer: container)
    let itemID = UUID()
    var item = Item(
        id: itemID,
        title: "无法访问链接内容",
        kind: .link,
        holding: .inline("https://linux.do/t/topic/2808529"),
        titledLocally: true
    )
    try await store.insert(item)
    try await store.replaceChunks(
        itemID: itemID,
        with: [ContentChunk(itemID: itemID, ordinal: 0, source: .linkPage, text: "旧正文")]
    )

    let indexedAt = Date(timeIntervalSince1970: 1_800_000_000)
    item.title = "解读 DeepSeek Harness 的核心论文"
    item.titledLocally = false
    item.vector = [0.4, 0.6]
    item.contentHash = "new-content"
    item.embeddingModelID = "embedding-v2"
    item.indexedAt = indexedAt
    let chunks = [
        ContentChunk(
            itemID: itemID,
            ordinal: 0,
            source: .linkPage,
            text: "《解读 DeepSeek Harness 的核心论文》\n#1 alice：新版完整正文",
            vector: [0.4, 0.6],
            embeddingModelID: "embedding-v2",
            indexedAt: indexedAt
        )
    ]

    try await store.replaceChunks(itemID: itemID, with: chunks, updating: item)

    let storedItem = try #require(try await store.item(id: itemID))
    let storedChunks = try await store.chunks(itemID: itemID)
    #expect(storedItem.title == item.title)
    #expect(storedItem.titledLocally == false)
    #expect(storedItem.vector == [0.4, 0.6])
    #expect(storedItem.contentHash == "new-content")
    #expect(storedItem.embeddingModelID == "embedding-v2")
    #expect(storedItem.indexedAt == indexedAt)
    #expect(storedChunks.map(\.text) == chunks.map(\.text))
    #expect(storedChunks.first?.vector == [0.4, 0.6])
}
