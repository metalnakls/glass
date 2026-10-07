import AppKit
import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import UniformTypeIdentifiers

/// Magnets use the file-import editor as soon as metainfo arrives.
struct AddMagnetView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @State var magnet: String
    let submit: @MainActor (TorrentFileAddDraft, UUID, String, String?, TorrentAddFileSelection, TorrentAddNamingPlan?) async -> TorrentFileAddSubmissionResult
    let didFinishAdding: @MainActor (UUID, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: TorrentFileAddDraft?
    @State private var selectedDestinationID: UUID?
    @State private var downloadDirectory: String?
    @State private var defaultDownloadDirectory: String?
    @State private var errorMessage: String?
    @State private var requestRevision = 0

    private var destinationID: UUID { selectedDestinationID ?? model.selectedSourceID }
    private var destination: Binding<UUID> {
        Binding(get: { destinationID }, set: { selectedDestinationID = $0 })
    }
    private var link: String? { normalizedMagnetLink(from: magnet) }
    private var title: String {
        URLComponents(string: magnet)?.queryItems?.first { $0.name == "dn" }?.value ?? glassText("New Torrent")
    }

    var body: some View {
        Group {
            if let draft {
                AddTorrentBatchView(model: model, platformIntegration: platformIntegration,
                    drafts: [draft], initialSourceID: destinationID,
                    initialDirectory: downloadDirectory ?? defaultDownloadDirectory,
                    submit: submit, didFinishAdding: didFinishAdding)
            } else {
                GlassAddCard {
                    GlassChromeScrollView {
                        VStack {
                            if link == nil {
                                ContentUnavailableView(glassText("No torrent selected"), systemImage: "link",
                                    description: Text(glassText("Copy a magnet link, then paste it here.")))
                            } else if let errorMessage {
                                ContentUnavailableView {
                                    Label(glassText("Couldn’t Load Torrent"), systemImage: "exclamationmark.triangle")
                                } description: { Text(errorMessage) } actions: {
                                    Button(glassText("Retry")) { self.errorMessage = nil; requestRevision += 1 }
                                }
                            } else {
                                ProgressView(glassText("Fetching torrent details…"))
                            }
                        }.frame(maxWidth: .infinity, minHeight: GlassModalMetrics.addTorrent.height / 2)
                    }
                } header: {
                    GlassAddHeader {
                        Text(title).font(.title.bold()).lineLimit(1)
                            .frame(height: GlassControlMetrics.height, alignment: .leading)
                    } location: {
                        TorrentDownloadLocationPicker(model: model, platformIntegration: platformIntegration,
                            sourceID: destination, directory: $downloadDirectory,
                            defaultDirectory: $defaultDownloadDirectory, errorMessage: $errorMessage,
                            isDisabled: false)
                    }
                } dock: {
                    HStack {
                        GlassPillButton(iconOnly: true) { dismiss() } label: { Image(systemName: "xmark") }
                            .accessibilityLabel(glassText("Cancel")).keyboardShortcut(.cancelAction)
                        Spacer()
                        GlassPillButton { addWhileLoading() } label: { Text(glassText("Add")) }
                            .disabled(link == nil).keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .frame(width: GlassModalMetrics.addTorrent.width, height: GlassModalMetrics.addTorrent.height)
        .onPasteCommand(of: [.url, .plainText]) { providers in
            Task {
                for provider in providers {
                    if let pasted = await MagnetPaste.load(from: provider) {
                        if let link { model.cancelMagnetPreview(link) }
                        magnet = pasted; draft = nil; errorMessage = nil
                        break
                    }
                }
            }
        }
        .task(id: "\(magnet):\(requestRevision)") {
            guard let link else { return }
            do {
                let data = try await model.resolveMagnetMetainfo(link)
                try Task.checkCancellation()
                draft = TorrentFileAddDraft(data: data, preview: TorrentFilePreview(data: data, fallbackURL: nil), sourceURL: nil)
            } catch is CancellationError { }
            catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
        .onDisappear { if let link { model.cancelMagnetPreview(link) } }
    }

    private func addWhileLoading() {
        guard let link else { return }
        let sourceID = destinationID
        guard model.enqueueMagnet(link, downloadDirectory: downloadDirectory ?? defaultDownloadDirectory,
            sourceID: sourceID, startPaused: NSEvent.modifierFlags.contains(.command)) != nil else {
            errorMessage = model.errorMessage
            return
        }
        model.selectedProfileID = sourceID
        model.selectedTorrentGroup = .all
        dismiss()
    }
}
