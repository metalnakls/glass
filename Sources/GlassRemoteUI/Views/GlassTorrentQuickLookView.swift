import AppKit
import GlassRemoteCore
import SwiftUI

/// Finder's preview uses the same file browser and naming engine as the app.
public struct GlassTorrentQuickLookView: View {
    private let url: URL
    @State private var preview: TorrentFilePreview?
    @State private var renamedFiles: [TorrentFileBrowserEntry] = []
    @State private var originalNames = false
    @State private var loaded = false
    @State private var search = ""
    @State private var flagsMonitor: Any?
    private var title: String {
        guard let preview else { return url.deletingPathExtension().lastPathComponent }
        if originalNames { return preview.name }
        return TorrentNameCleaner.plan(rootName: preview.name, files: [], selectedFileIndices: [])?.rootName ?? preview.name
    }

    public init(url: URL) { self.url = url }

    public var body: some View {
        VStack(spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).textCase(nil).font(.largeTitle.bold()).lineLimit(2)
                Spacer(minLength: 20)
                if let preview { Text(formatBytes(preview.size)).textCase(nil).font(.title3).monospacedDigit() }
            }
            if let preview {
                ScrollView {
                TorrentFilesBrowser(entries: originalNames ? preview.files.enumerated().map {
                    TorrentFileBrowserEntry(index: $0.offset, file: $0.element, rootName: preview.name)
                } : renamedFiles, searchText: $search, onSetWanted: { _, _ in },
                    onSetPriority: { _, _ in }, onSetAllWanted: { _ in }, showsControls: false,
                    isCompact: true, showsActionBar: false)
                }
            } else if loaded {
                ContentUnavailableView(glassText("No data found"), systemImage: "questionmark.folder")
            } else { Spacer(); ProgressView(); Spacer() }
        }
        .padding(28)
        .task(id: url) {
            let result = await Task.detached(priority: .userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let handle = try? FileHandle(forReadingFrom: url) else { return nil as TorrentFilePreview? }
                defer { try? handle.close() }
                guard let data = try? handle.read(upToCount: 8 * 1_024 * 1_024 + 1),
                      data.count <= 8 * 1_024 * 1_024,
                      !TorrentMetainfoIdentity.hashes(in: data).isEmpty else { return nil }
                return TorrentFilePreview(data: data, fallbackURL: url)
            }.value
            guard !Task.isCancelled else { return }
            preview = result
            if let result {
                let plan = await Task.detached(priority: .userInitiated) {
                    TorrentNameCleaner.plan(rootName: result.name, files: result.files,
                        selectedFileIndices: Set(result.files.indices))
                }.value
                let names = Dictionary(uniqueKeysWithValues: (plan?.pathRenames ?? []).map { ($0.path, $0.name) })
                renamedFiles = result.files.enumerated().map {
                    let original = $0.element.name
                    let name = names[original]
                    return TorrentFileBrowserEntry(index: $0.offset, file: $0.element, rootName: result.name, displayName: name)
                }
            }
            loaded = true
        }
        .onAppear {
            originalNames = NSEvent.modifierFlags.contains(.option)
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                originalNames = event.modifierFlags.contains(.option)
                return event
            }
        }
        .onDisappear {
            if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
            flagsMonitor = nil
        }
    }
}
