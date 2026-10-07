import AppKit
import UniformTypeIdentifiers

@MainActor enum MagnetPaste {
    static func load(from provider: NSItemProvider) async -> String? {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            ? UTType.url.identifier : UTType.plainText.identifier
        guard provider.hasItemConformingToTypeIdentifier(type) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, _ in
                let text = data.flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: text.flatMap(normalizedMagnetLink(from:)))
            }
        }
    }
}
