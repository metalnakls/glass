import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

/// Local folders are choices. A share uses its server's configured download folder.
struct TorrentDownloadLocationPicker: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Binding var sourceID: UUID
    @Binding var directory: String?
    @Binding var defaultDirectory: String?
    @Binding var errorMessage: String?
    var isDisabled = false

    @State private var isEditingServer = false
    @State private var previousProfileIDs = Set<UUID>()
    @State private var isChoosingFolder = false

    @State private var isPresented = false
    @State private var optionHeld = false
    @AppStorage("GlassAdd.locationIconOrder") private var iconOrder = ""
    @AppStorage("GlassAdd.hiddenLocations") private var hiddenLocations = ""
    @AppearanceStorage("GlassAdd.locationColumns") private var iconColumns = 3
    @AppearanceStorage("GlassAdd.recentLocations") private var recentCount = 4

    var body: some View {
        Button { withAnimation(.smooth) { isPresented.toggle() } } label: {
            HStack(spacing: 8) {
                NativeLocationIcon(path: nativeLocationPath,
                    sourceID: sourceID == model.localSourceID ? nil : sourceID,
                    serverName: model.sourceName(for: sourceID), size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(locationName).textCase(nil).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    if let bytes = model.serverFreeSpace[sourceID]?.availableBytes {
                        Text("\(formatBytes(bytes)) \(glassText("free"))").font(.caption2)
                    }
                }
                Image(systemName: "chevron.down").font(.caption)
            }
            .modifier(InspectorGlassPill(interactive: true))
        }
        .buttonStyle(.plain).disabled(isDisabled || isChoosingFolder)
        .animation(.smooth, value: locationName)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: max(1, min(6, iconColumns))), spacing: 14) {
                    ForEach(quickLocations) { location in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                if let path = location.path { Task { await prepareMacFolder(path); isPresented = false } }
                                else { select(location.sourceID, directory: nil); isPresented = false }
                            } label: {
                                VStack(spacing: 6) {
                                    NativeLocationIcon(path: location.path,
                                        sourceID: location.path == nil ? location.sourceID : nil,
                                        serverName: location.name, size: 38)
                                    Text(location.name).textCase(nil).font(.caption).lineLimit(1)
                                }.frame(maxWidth: .infinity).padding(6)
                            }.buttonStyle(.plain)
                            .draggable(location.key)
                            .dropDestination(for: String.self) { keys, _ in
                                guard let key = keys.first else { return false }
                                var order = quickLocations.map(\.key)
                                guard let from = order.firstIndex(of: key), let to = order.firstIndex(of: location.key) else { return false }
                                order.remove(at: from); order.insert(key, at: min(to, order.count))
                                iconOrder = order.joined(separator: "|"); GlassHaptics.perform(.drag); return true
                            }
                            if optionHeld {
                                Button { hiddenLocations += "|" + location.key } label: {
                                    Image(systemName: "minus.circle.fill")
                                }.buttonStyle(.plain)
                            }
                        }
                        .rotationEffect(.degrees(optionHeld ? 1.5 : 0))
                        .animation(optionHeld ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true) : .smooth, value: optionHeld)
                    }
                }
                let recents = model.downloadDirectories(for: model.localSourceID).filter {
                    !hiddenLocations.components(separatedBy: "|").contains($0)
                }
                ForEach(Array(recents.prefix(max(0, recentCount))), id: \.self) { path in
                    HStack {
                        Button { Task { await prepareMacFolder(path); isPresented = false } } label: {
                            HStack(spacing: 8) {
                                NativeLocationIcon(path: path, sourceID: nil, serverName: "", size: 22)
                                Text(URL(fileURLWithPath: path).lastPathComponent).textCase(nil)
                            }
                        }.buttonStyle(.plain)
                        Spacer()
                        if optionHeld {
                            Button { hiddenLocations += "|" + path } label: { Image(systemName: "minus.circle.fill") }.buttonStyle(.plain)
                        }
                    }
                }
                Divider()
                Button(glassText("Choose location…"), systemImage: "folder.badge.plus") {
                    Task { await chooseMacFolder(); isPresented = false }
                }.buttonStyle(.plain)
                Button(glassText("Add server…"), systemImage: "plus") {
                    previousProfileIDs = Set(model.profiles.map(\.id)); isPresented = false; isEditingServer = true
                }.buttonStyle(.plain)
            }
            .padding(18).frame(width: CGFloat(max(1, min(6, iconColumns))) * 82 + 36)
            .background(ModifierKeyObserver { optionHeld = $0 })
        }
        .sheet(isPresented: $isEditingServer, onDismiss: {
            if let added = model.profiles.first(where: { !previousProfileIDs.contains($0.id) }) {
                select(added.id, directory: nil)
            }
        }) {
            NavigationStack { ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: nil) }
                .toolbarVisibility(.visible, for: .windowToolbar)
        }
        .task(id: sourceID) {
            let requestedSourceID = sourceID
            defaultDirectory = nil
            let path = await model.defaultDownloadDirectory(for: requestedSourceID)
            guard !Task.isCancelled, requestedSourceID == sourceID else { return }
            defaultDirectory = path
        }
    }

    private struct QuickLocation: Identifiable {
        let sourceID: UUID
        let key: String
        var id: String { key }
        let name: String
        let path: String?
    }
    private var quickLocations: [QuickLocation] {
        var choices = model.profiles.reversed().map {
            QuickLocation(sourceID: $0.id, key: $0.id.uuidString, name: shareName(for: $0.id), path: nil)
        }
        choices += standardFolders.map {
            QuickLocation(sourceID: model.localSourceID, key: $0, name: URL(fileURLWithPath: $0).lastPathComponent, path: $0)
        }
        let hidden = Set(hiddenLocations.components(separatedBy: "|"))
        let order = iconOrder.components(separatedBy: "|")
        let ranked = choices.enumerated().filter { !hidden.contains($0.element.key) }
        return ranked.sorted {
            let lhs = order.firstIndex(of: $0.element.key)
            let rhs = order.firstIndex(of: $1.element.key)
            if lhs == nil && rhs == nil { return $0.offset < $1.offset }
            if lhs == nil { return $0.element.path == nil }
            if rhs == nil { return $1.element.path != nil }
            return lhs! < rhs!
        }.map(\.element)
    }

    private var standardFolders: [String] {
        [FileManager.SearchPathDirectory.moviesDirectory, .downloadsDirectory].compactMap {
            FileManager.default.urls(for: $0, in: .userDomainMask).first?.path
        }
    }

    private func locationButton(_ path: String) -> some View {
        Button(URL(fileURLWithPath: path).lastPathComponent,
            systemImage: sourceID == model.localSourceID && currentDirectory == path ? "checkmark" : "folder") {
            Task { await prepareMacFolder(path) }
        }
        .help(path)
    }

    private func shareName(for id: UUID) -> String {
        TorrentDownloadLocation.shareName(link: TorrentThumbnailService.shared.link(for: id), fallback: model.sourceName(for: id))
    }

    private var currentDirectory: String? { directory ?? defaultDirectory }
    private var locationName: String {
        if sourceID != model.localSourceID { return shareName(for: sourceID) }
        guard let currentDirectory else { return "Default Folder" }
        return URL(fileURLWithPath: currentDirectory).lastPathComponent
    }
    private var nativeLocationPath: String? {
        guard let currentDirectory else { return nil }
        if sourceID == model.localSourceID { return currentDirectory }
        guard let link = TorrentThumbnailService.shared.link(for: sourceID) else { return nil }
        return TorrentThumbnailFolderLink.directoryURL(remoteRoot: link.remoteRoot,
            localRoot: URL(fileURLWithPath: link.localPath, isDirectory: true), directory: currentDirectory)?.path
    }
    private var isFavorite: Bool {
        currentDirectory.map { model.favoriteDownloadDirectories(for: model.localSourceID).contains($0) } ?? false
    }

    private func select(_ id: UUID, directory path: String?) {
        GlassHaptics.perform(.selection)
        if sourceID != id { defaultDirectory = nil }
        sourceID = id
        directory = path
    }

    private func prepareMacFolder(_ path: String) async {
        isChoosingFolder = true
        defer { isChoosingFolder = false }
        do {
            if let authorized = try await platformIntegration.prepareLocalDownloadDirectory(path) {
                select(model.localSourceID, directory: authorized)
            }
        } catch { errorMessage = error.localizedDescription }
    }

    private func chooseMacFolder() async {
        isChoosingFolder = true
        defer { isChoosingFolder = false }
        do {
            if let path = try await platformIntegration.chooseLocalDownloadDirectory(
                startingAt: sourceID == model.localSourceID ? currentDirectory : nil
            ) {
                select(model.localSourceID, directory: path)
            }
        } catch { errorMessage = error.localizedDescription }
    }
}
