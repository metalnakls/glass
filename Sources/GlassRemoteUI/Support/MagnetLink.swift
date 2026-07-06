import Foundation

func normalizedMagnetLink(from text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: "magnet:?", options: [.anchored, .caseInsensitive]) != nil else { return nil }
    return trimmed
}

func magnetLink(from url: URL) -> String? {
    guard url.scheme?.lowercased() == "magnet" else { return nil }
    return url.absoluteString
}
