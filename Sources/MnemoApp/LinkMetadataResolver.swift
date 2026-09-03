import Foundation
import LinkPresentation

@MainActor
enum LinkMetadataResolver {
    static func title(for url: URL) async -> String? {
        let provider = LPMetadataProvider()
        provider.timeout = 8
        do {
            let metadata = try await withTaskCancellationHandler {
                try await provider.startFetchingMetadata(for: url)
            } onCancel: {
                provider.cancel()
            }
            guard let title = metadata.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty else { return nil }
            return String(title.prefix(80))
        } catch {
            return nil
        }
    }
}
