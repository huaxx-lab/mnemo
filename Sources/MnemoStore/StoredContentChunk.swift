import Foundation
import MnemoCore
import SwiftData

@Model
public final class StoredContentChunk {
    #Unique<StoredContentChunk>([\.id])

    public var id: UUID = UUID()
    public var itemID: UUID = UUID()
    public var ordinal: Int = 0
    public var pageNumber: Int?
    public var sourceRaw: String = ContentChunkSource.inlineText.rawValue
    public var text: String = ""
    public var vector: [Float]?
    public var contentHash: String = ""
    public var embeddingModelID: String?
    public var indexedAt: Date?

    public init(_ chunk: ContentChunk) {
        id = chunk.id
        itemID = chunk.itemID
        ordinal = chunk.ordinal
        pageNumber = chunk.pageNumber
        sourceRaw = chunk.source.rawValue
        text = chunk.text
        vector = chunk.vector
        contentHash = chunk.contentHash
        embeddingModelID = chunk.embeddingModelID
        indexedAt = chunk.indexedAt
    }

    var asChunk: ContentChunk {
        ContentChunk(
            id: id,
            itemID: itemID,
            ordinal: ordinal,
            pageNumber: pageNumber,
            source: ContentChunkSource(rawValue: sourceRaw) ?? .fileText,
            text: text,
            vector: vector,
            contentHash: contentHash,
            embeddingModelID: embeddingModelID,
            indexedAt: indexedAt
        )
    }
}
