import Foundation

@MainActor
public final class GlassOpenURLRouter {
    public static let shared = GlassOpenURLRouter()

    private var pendingURLs: [URL] = []
    private var registration: (id: UUID, handler: @MainActor ([URL]) -> Void)?

    private init() {}

    @discardableResult
    public func register(_ handler: @escaping @MainActor ([URL]) -> Void) -> UUID {
        let id = UUID()
        registration = (id, handler)
        guard !pendingURLs.isEmpty else { return id }
        let urls = pendingURLs
        pendingURLs = []
        handler(urls)
        return id
    }

    public func unregister(_ id: UUID) {
        guard registration?.id == id else { return }
        registration = nil
    }

    public func open(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        if let handler = registration?.handler {
            handler(urls)
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }
}
