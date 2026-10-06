import GlassRemoteCore
import SwiftUI

@MainActor
public protocol GlassPlatformIntegrating: AnyObject {
    func chooseLocalDownloadDirectory(startingAt path: String?) async throws -> String?
    func prepareLocalDownloadDirectory(_ path: String) async throws -> String?
    func chooseThumbnailDirectory() async throws -> URL?
    func canRevealDownloadedItem(for torrent: TorrentSummary) -> Bool
    func revealDownloadedItem(for torrent: TorrentSummary)
    func canPreviewDownloadedItem(for torrent: TorrentSummary) -> Bool
    func previewDownloadedItem(for torrent: TorrentSummary)
}

public extension GlassPlatformIntegrating {
    func prepareLocalDownloadDirectory(_ path: String) async throws -> String? { path }

    func chooseThumbnailDirectory() async throws -> URL? {
        try await chooseLocalDownloadDirectory(startingAt: nil).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

@MainActor
public final class UnavailableGlassPlatformIntegration: GlassPlatformIntegrating {
    public static let shared = UnavailableGlassPlatformIntegration()

    private init() {}

    public func chooseLocalDownloadDirectory(startingAt path: String?) async throws -> String? {
        nil
    }

    public func canRevealDownloadedItem(for torrent: TorrentSummary) -> Bool {
        false
    }

    public func revealDownloadedItem(for torrent: TorrentSummary) {}

    public func canPreviewDownloadedItem(for torrent: TorrentSummary) -> Bool {
        false
    }

    public func previewDownloadedItem(for torrent: TorrentSummary) {}
}

@MainActor
public struct GlassCommandActions {
    public let addServer: () -> Void
    public let addMagnet: () -> Void
    public let addTorrentFile: () -> Void
    public let openMagnet: (String) -> Void
    public let toggleDownloadingFilter: () -> Void
    public let isDownloadingFilterActive: Bool
    public let canRemoveSelectedTorrent: Bool
    public let removeSelectedTorrent: (_ deleteData: Bool) -> Void

    public init(
        addServer: @escaping () -> Void,
        addMagnet: @escaping () -> Void,
        addTorrentFile: @escaping () -> Void,
        openMagnet: @escaping (String) -> Void,
        toggleDownloadingFilter: @escaping () -> Void,
        isDownloadingFilterActive: Bool,
        canRemoveSelectedTorrent: Bool,
        removeSelectedTorrent: @escaping (_ deleteData: Bool) -> Void
    ) {
        self.addServer = addServer
        self.addMagnet = addMagnet
        self.addTorrentFile = addTorrentFile
        self.openMagnet = openMagnet
        self.toggleDownloadingFilter = toggleDownloadingFilter
        self.isDownloadingFilterActive = isDownloadingFilterActive
        self.canRemoveSelectedTorrent = canRemoveSelectedTorrent
        self.removeSelectedTorrent = removeSelectedTorrent
    }
}

private struct GlassCommandActionsKey: FocusedValueKey {
    typealias Value = GlassCommandActions
}

private struct GlassTuningPresentedKey: FocusedValueKey {
    typealias Value = Binding<Bool>
}

private struct GlassInspectorFileFilterFocusedKey: FocusedValueKey {
    typealias Value = Bool
}

public extension FocusedValues {
    var glassTuningPresented: Binding<Bool>? {
        get { self[GlassTuningPresentedKey.self] }
        set { self[GlassTuningPresentedKey.self] = newValue }
    }

    var glassCommandActions: GlassCommandActions? {
        get { self[GlassCommandActionsKey.self] }
        set { self[GlassCommandActionsKey.self] = newValue }
    }

    var glassInspectorFileFilterFocused: Bool? {
        get { self[GlassInspectorFileFilterFocusedKey.self] }
        set { self[GlassInspectorFileFilterFocusedKey.self] = newValue }
    }
}
