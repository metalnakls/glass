import AppKit
import CoreTransferable
import GlassRemoteCore
import GlassRemoteServices
import SwiftUI
import UniformTypeIdentifiers

public struct GlassRootView: View {
    private let externalTuningPresentation: Binding<Bool>?
    @State private var isTuningPresented = false
    private let isTestWorkspace: Bool
    private let liveModel: RemoteAppModel
    @State private var testSession = TorrentTestSessionState()
    @State private var tuningSection = TuningSection.icons
    private var usesTestModel: Bool { tuningPresentation.wrappedValue && testSession.isEnabled }
    private var model: RemoteAppModel { usesTestModel ? testSession.model : liveModel }
    private var tuneOnLeft: Bool { GlassTuningMode.isEnabled && tuningPresentation.wrappedValue && tuningSection == .inspector }
    private let platformIntegration: any GlassPlatformIntegrating

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @SceneStorage("GlassRoot.inspectorPresented") private var isInspectorPresented = true
    @AppStorage("GlassRoot.selectedSourceID") private var storedSelectedSourceID = ""
    @AppearanceStorage("GlassList.dropBlurRadius") private var dropBlurRadius = 8.0
    @State private var isTorrentDropTargeted = false
    @State private var selectedTorrentID: String?
    @State private var presentation = TorrentListPresentationModel()
    @State private var openURLRegistrationID: UUID?
    @State private var pendingTorrentReveal: PendingTorrentReveal?
    @State private var torrentRevealToken = UUID()
    @State private var isFileImporterPresented = false
    @State private var activeSheet: ActiveSheet?
    @State private var addDrafts = TorrentAddDraftStore()
    @State private var torrentImports = TorrentImportQueue()
    @State private var pendingProfileDeletion: RemoteProfile?
    @State private var pendingRenames: [PendingRemovalKey: PendingTorrentRename] = [:]
    @State private var pendingRemovals: [PendingTorrentRemoval] = []
    @State private var pendingRemovalResetToken = UUID()
    @State private var committingRemovalKeys = Set<PendingRemovalKey>()
    @State private var pendingRemovalTask: Task<Void, Never>?

    public init(
        model: RemoteAppModel,
        platformIntegration: any GlassPlatformIntegrating = UnavailableGlassPlatformIntegration.shared,
        isTestWorkspace: Bool = false,
        tuningPresented: Binding<Bool>? = nil
    ) {
        self.externalTuningPresentation = tuningPresented
        self.isTestWorkspace = isTestWorkspace
        self.liveModel = model
        self.platformIntegration = platformIntegration
    }

    public var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
            if tuneOnLeft {
                SelectionAppearanceView(testSession: testSession, section: $tuningSection)
                    .frame(maxWidth: 300, maxHeight: .infinity)
                    .padding(.horizontal, 38)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .blurReplace))
            } else {
            TorrentWorkspaceView(
                model: model,
                platformIntegration: platformIntegration,
                selection: $selectedTorrentID,
                presentation: presentation,
                torrentRevealToken: torrentRevealToken,
                pendingRenames: pendingRenames,
                pendingRemovals: pendingRemovals,
                committingRemovalKeys: committingRemovalKeys,
                pendingRemovalResetToken: pendingRemovalResetToken,
                pendingRemovalDuration: pendingRemovalDuration,
                drafts: addDrafts.mostRecentFirst,
                resumeDraft: restoreDraft,
                discardDraft: discardDraft,
                commitRename: { torrent, sourceID, name in submitRename(torrent, sourceID: sourceID, newName: name) },
                remove: scheduleRemoval,
                removeSelected: removeSelectedTorrent,
                undoRemovals: cancelPendingRemovals,
                dismissRemovals: dismissPendingRemovals
            )
            .overlay(alignment: .bottom) {
                if usesTestModel {
                    TorrentTestActions(session: testSession)
                        .padding(.horizontal, 16).padding(.bottom, 16)
                }
            }
            }
            }
        }
        .animation(accessibilityReduceMotion ? nil : .smooth(duration: 0.25), value: tuneOnLeft)
        .environment(\.glassSampleArtwork, usesTestModel)
        .environment(\.locale, GlassFormatting.shared.locale)
        .inspector(isPresented: inspectorPresentation) {
            let showsTune = GlassTuningMode.isEnabled && tuningPresentation.wrappedValue
            ZStack {
                // Keep selection, search and staged file edits alive beneath Tune.
                TorrentSelectionInspector(
                    model: model,
                    platformIntegration: platformIntegration,
                    selectedID: selectedTorrentID,
                    presentation: presentation,
                    isVisible: !showsTune || tuneOnLeft
                )
                .opacity(showsTune && !tuneOnLeft ? 0 : 1)
                .blur(radius: showsTune && !tuneOnLeft ? 6 : 0)
                .allowsHitTesting(!showsTune || tuneOnLeft)
                .accessibilityHidden(showsTune && !tuneOnLeft)
                if showsTune && !tuneOnLeft {
                    SelectionAppearanceView(testSession: testSession, section: $tuningSection)
                        .transition(.blurReplace)
                }
            }
            .animation(accessibilityReduceMotion ? nil : .smooth, value: showsTune)
            .inspectorColumnWidth(min: 260, ideal: 300, max: 340)
        }
        .blur(radius: isTorrentDropTargeted ? dropBlurRadius : 0)
        .animation(dropAnimation, value: isTorrentDropTargeted)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .dropDestination(for: TorrentWindowDropItem.self) { items, _ in
            isTorrentDropTargeted = false
            guard !TorrentInternalDragState.active else { return false }
            let urls = items.compactMap(\.url).filter {
                magnetLink(from: $0) != nil || $0.pathExtension.localizedCaseInsensitiveCompare("torrent") == .orderedSame
            }
            if !urls.isEmpty { openURLs(urls); return true }
            if let magnet = items.compactMap(\.text).compactMap({ normalizedMagnetLink(from: $0) }).first {
                presentMagnet(magnet)
                return true
            }
            return false
        } isTargeted: { isTorrentDropTargeted = $0 && !TorrentInternalDragState.active }
        .onPasteCommand(of: [.url, .plainText]) { providers in
            Task {
                for provider in providers {
                    if let magnet = await MagnetPaste.load(from: provider) {
                        presentMagnet(magnet)
                        break
                    }
                }
            }
        }
        .onDisappear { isTorrentDropTargeted = false }
        .overlay {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.primary.opacity(0.6), style: StrokeStyle(lineWidth: 3))
                Label(glassText("Drop to Add Torrent"), systemImage: "doc.badge.plus")
                    .font(.headline)
                    .padding(.horizontal, 18).padding(.vertical, 12)
                    .glassEffect(.regular, in: .capsule)
            }
            .padding(24)
            .opacity(isTorrentDropTargeted ? 1 : 0)
            .blur(radius: isTorrentDropTargeted ? 0 : 8)
            .animation(dropAnimation, value: isTorrentDropTargeted)
            .allowsHitTesting(false)
            .accessibilityHidden(!isTorrentDropTargeted)
        }
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .background(MainWindowChrome(widthChanged: updateInspectorWidth))
        .ignoresSafeArea(.container, edges: .top)
        .sheet(item: $activeSheet, onDismiss: {
            torrentImports.cancel()
            addDrafts.flush()
        }) { sheet in
            NavigationStack {
                switch sheet {
                case .newProfile:
                    ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: nil)
                case let .editProfile(profile):
                    ProfileEditorView(model: model, platformIntegration: platformIntegration, profile: profile)
                case let .addMagnet(magnet, draftID, restore):
                    AddMagnetView(model: model, platformIntegration: platformIntegration, magnet: magnet,
                        draftID: draftID, restore: restore,
                        capture: { addDrafts.capture($0) },
                        discardDraft: { addDrafts.discard(draftID) },
                        submit: submitTorrentFile, didFinishAdding: showAddedTorrent)
                case .loadingTorrentFiles, .addTorrentFiles:
                    torrentImportContent(sheet)
                }
            }
            .toolbarVisibility(sheet.isTorrentImport ? .hidden : .visible, for: .windowToolbar)
            .presentationSizing(.form)
            .presentationBackground(sheet.isTorrentImport ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.background))
        }
        .alert(glassText(activeAlertTitle), isPresented: activeAlertBinding, presenting: activeAlert) { alert in
            switch alert {
            case let .deleteProfile(profile):
                Button(glassText("Delete"), role: .destructive) {
                    model.deleteProfile(profile)
                }
                Button(glassText("Cancel"), role: .cancel) {}
            case .error:
                Button(glassText("OK")) {}
            }
        } message: { alert in
            switch alert {
            case let .deleteProfile(profile):
                Text("Remove \(profile.name) from Glass. Transmission data on the server is not changed.")
            case let .error(message):
                Text(message)
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.torrentFile],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                openURLs(urls)
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .onAppear {
            model.selectedTorrentGroup = .all
            persistSelectedSourceID()
            model.setApplicationActive(isTestWorkspace || scenePhase == .active)
            // Artwork previews resolve the file list for torrents whose name carries no media suffix.
            TorrentThumbnailService.shared.attach(model: model)
            if !isTestWorkspace, openURLRegistrationID == nil {
                openURLRegistrationID = GlassOpenURLRouter.shared.register { urls in
                    openURLs(urls)
                }
            }
        }
        .onDisappear {
            if let openURLRegistrationID {
                GlassOpenURLRouter.shared.unregister(openURLRegistrationID)
                self.openURLRegistrationID = nil
            }
        }
        .task { GlassBackgroundService.offerIfNeeded() }
        .task { await GlassBackgroundService.renameDownloadsWhileOpen() }
        .task(id: TorrentAutoRefreshInput(modelID: ObjectIdentifier(model), profiles: model.profiles, isActive: model.isApplicationActive)) {
            await model.runAutoRefresh()
        }
        .onChange(of: tuningPresentation.wrappedValue) { _, presented in
            if !presented { Task { await testSession.end() } }
        }
        .onChange(of: usesTestModel) { _, enabled in
            selectedTorrentID = nil
            presentation = TorrentListPresentationModel()
            model.setApplicationActive(scenePhase == .active)
            TorrentThumbnailService.shared.attach(model: model)
            if enabled { Task { await model.refreshAllSources() } }
        }
        .onChange(of: model.selectedProfileID) { _, _ in
            persistSelectedSourceID()
        }
        .onChange(of: scenePhase) { _, phase in
            model.setApplicationActive(isTestWorkspace || phase == .active)
        }
        .task(id: selectedTorrentID) {
            await loadSelectedTorrentDetails()
        }
        .glassTextStyle()
        .focusedSceneValue(\.glassTuningPresented, tuningPresentation)
        .focusedSceneValue(\.glassCommandActions, isTestWorkspace ? nil : commandActions)
    }

    @ViewBuilder private func torrentImportContent(_ sheet: ActiveSheet) -> some View {
        switch sheet {
        case .loadingTorrentFiles:
            DelayedTorrentLoadingView()
        case let .addTorrentFiles(session):
                    AddTorrentBatchView(
                        model: model,
                        platformIntegration: platformIntegration,
                        drafts: session.drafts,
                        pendingURLs: session.pendingURLs,
                        restore: session.restore,
                        draftID: session.id,
                        capture: { addDrafts.capture($0) },
                        discardDraft: { addDrafts.discard(session.id) },
                        submit: { draft, sourceID, name, downloadDirectory, fileSelection, namingPlan in
                            await submitTorrentFile(
                                draft,
                                sourceID: sourceID,
                                name: name,
                                downloadDirectory: downloadDirectory,
                                fileSelection: fileSelection,
                                namingPlan: namingPlan
                            )
                        },
                        didFinishAdding: showAddedTorrent
                    )
        default: EmptyView()
        }
    }

    private var selectedDraft: TorrentAddDraft? { addDrafts.draft(selectionID: selectedTorrentID) }

    private func discardDraft(_ draft: TorrentAddDraft) {
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            addDrafts.discard(draft.id)
            if selectedTorrentID == draft.listID { selectedTorrentID = nil }
        }
    }

    private var selectedRecord: TorrentRecord? {
        guard let selectedTorrentID else { return nil }
        return model.allTorrentRecords.first { $0.id == selectedTorrentID && !$0.isAdding }
    }

    private var selectedGroup: TorrentNameSequenceGroup? {
        presentation.rows.first { $0.id == selectedTorrentID }?.selectedGroup
    }

    private var selectedTorrent: TorrentSummary? { selectedRecord?.summary }

    private var commandActions: GlassCommandActions {
        GlassCommandActions(
            addServer: { activeSheet = .newProfile },
            addMagnet: {
                presentMagnet(NSPasteboard.general.string(forType: .string).flatMap(normalizedMagnetLink(from:)) ?? "")
            },
            addTorrentFile: { isFileImporterPresented = true },
            openMagnet: { presentMagnet($0) },
            toggleDownloadingFilter: toggleDownloadingFilter,
            isDownloadingFilterActive: model.selectedTorrentGroup == .downloading,
            canRemoveSelectedTorrent: (selectedDraft != nil || selectedRecord != nil || presentation.rows.contains { $0.id == selectedTorrentID && !$0.isTorrent }) && activeSheet == nil && activeAlert == nil,
            removeSelectedTorrent: removeSelectedTorrent
        )
    }

    private var activeAlertBinding: Binding<Bool> {
        Binding(
            get: { activeAlert != nil },
            set: { if !$0 { dismissActiveAlert() } }
        )
    }

    private var activeAlert: ActiveRootAlert? {
        if let pendingProfileDeletion {
            return .deleteProfile(pendingProfileDeletion)
        }
        if let errorMessage = model.errorMessage {
            return .error(errorMessage)
        }
        return nil
    }

    private var activeAlertTitle: String {
        switch activeAlert {
        case .deleteProfile:
            return "Delete Server?"
        case .error, nil:
            return "Glass"
        }
    }

    private func dismissActiveAlert() {
        switch activeAlert {
        case .deleteProfile:
            pendingProfileDeletion = nil
        case .error:
            model.errorMessage = nil
        case nil:
            break
        }
    }

    private func toggleDownloadingFilter() {
        model.selectedTorrentGroup = model.selectedTorrentGroup == .downloading ? .all : .downloading
    }

    private func submitRename(_ torrent: TorrentSummary, sourceID: UUID, newName proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != torrent.name else { return }

        let key = PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
        let pendingRename = PendingTorrentRename(
            key: key,
            oldName: torrent.name,
            newName: newName
        )
        withAnimation(motionAnimation(.snappy(duration: 0.22))) {
            pendingRenames[key] = pendingRename
        }

        Task {
            _ = await model.rename(torrent, to: newName, sourceID: sourceID)
            await MainActor.run {
                guard pendingRenames[key]?.id == pendingRename.id else { return }
                withAnimation(motionAnimation(.snappy(duration: 0.22))) {
                    pendingRenames[key] = nil
                }
            }
        }
    }

    private func persistSelectedSourceID() {
        guard !isTestWorkspace, !usesTestModel else { return }
        storedSelectedSourceID = model.selectedSourceID.uuidString
    }

    private func openURLs(_ urls: [URL]) {
        var torrentFileURLs: [URL] = []
        for url in urls {
            if let magnet = magnetLink(from: url) {
                presentMagnet(magnet)
                continue
            }
            guard url.pathExtension.lowercased() == "torrent" else { continue }
            torrentFileURLs.append(url)
        }

        guard !torrentFileURLs.isEmpty else { return }
        let session: TorrentAddSession
        if let open = activeSheet?.importSession {
            session = open
        } else {
            torrentImports.cancel()
            session = TorrentAddSession(id: UUID(), drafts: [], pendingURLs: [], restore: nil)
            activeSheet = .loadingTorrentFiles(session.id)
        }
        loadTorrentFiles(torrentFileURLs, session: session)
    }

    private func presentMagnet(_ magnet: String) {
        activeSheet = .addMagnet(magnet, draftID: UUID(), restore: nil)
    }

    /// Drafts are offered only when an Add modal went away without Cancel.
    private func restoreDraft(_ draft: TorrentAddDraft) {
        let items = draft.items.compactMap { TorrentFileAddDraft(restoring: $0) }
        let session = TorrentAddSession(id: draft.id, drafts: items, pendingURLs: draft.pendingURLs, restore: draft)
        if items.isEmpty, draft.pendingURLs.isEmpty, let magnet = draft.magnet {
            activeSheet = .addMagnet(magnet, draftID: draft.id, restore: draft)
            return
        }
        torrentImports.cancel()
        torrentImports.seed(items)
        activeSheet = items.isEmpty ? .loadingTorrentFiles(draft.id) : .addTorrentFiles(session)
        if !draft.pendingURLs.isEmpty {
            loadTorrentFiles(draft.pendingURLs, session: session)
        }
    }

    private func loadTorrentFiles(_ urls: [URL], session: TorrentAddSession) {
        torrentImports.enqueue(urls, load: prepareTorrentFile) { drafts, pendingURLs, finished in
            guard activeSheet?.isTorrentImport == true else { return }
            guard !drafts.isEmpty else {
                if finished {
                    activeSheet = nil
                    addDrafts.discard(session.id)
                }
                return
            }
            let updated = TorrentAddSession(
                id: session.id, drafts: drafts, pendingURLs: pendingURLs, restore: session.restore
            )
            activeSheet = .addTorrentFiles(updated)
            if addDrafts.draft(id: session.id) == nil {
                // The card's own autosave refines this record; guarantee it
                // exists before the card can appear.
                addDrafts.capture(intakeRecord(for: updated))
            }
        }
    }

    private func intakeRecord(for session: TorrentAddSession) -> TorrentAddDraft {
        TorrentAddDraft(
            id: session.id,
            sourceID: session.restore?.sourceID ?? model.selectedSourceID,
            downloadDirectory: session.restore?.downloadDirectory,
            pendingURLs: session.pendingURLs,
            items: session.drafts.map {
                TorrentAddDraftItem(id: $0.id, data: $0.data, sourceURL: $0.sourceURL, name: $0.preview.name)
            }
        )
    }

    private func prepareTorrentFile(at url: URL) async -> TorrentFileAddDraft? {
        do {
            return try await TorrentFileAddDraft.load(from: url)
        } catch is CancellationError {
            return nil
        } catch {
            model.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func submitTorrentFile(
        _ draft: TorrentFileAddDraft,
        sourceID: UUID,
        name: String,
        downloadDirectory: String?,
        fileSelection: TorrentAddFileSelection,
        namingPlan: TorrentAddNamingPlan?
    ) async -> TorrentFileAddSubmissionResult {
        let didAccess = draft.sourceURL?.startAccessingSecurityScopedResource() == true
        defer {
            if didAccess {
                draft.sourceURL?.stopAccessingSecurityScopedResource()
            }
        }
        var addedTorrent: TorrentAddResult?
        let succeeded = await model.addTorrentFile(
            draft.data,
            torrentName: name == draft.preview.name ? nil : name,
            downloadDirectory: downloadDirectory,
            fileSelection: fileSelection,
            namingPlan: namingPlan,
            sourceID: sourceID,
            sourceURL: draft.sourceURL,
            trashSourceOnSuccess: draft.sourceURL != nil,
            pendingAdditionID: draft.id,
            onSuccess: { addedTorrent = $0 }
        )
        return TorrentFileAddSubmissionResult(succeeded: succeeded, torrent: addedTorrent)
    }

    private func showAddedTorrent(sourceID: UUID, hashString: String?) {
        pendingTorrentReveal = PendingTorrentReveal(sourceID: sourceID, hashString: hashString)
        model.selectedTorrentGroup = .all

        model.selectedProfileID = sourceID
        Task { await refreshAndRevealPendingTorrent() }
    }

    private func refreshAndRevealPendingTorrent() async {
        guard let pendingTorrentReveal else { return }
        await model.refresh(sourceID: pendingTorrentReveal.sourceID)
        guard self.pendingTorrentReveal == pendingTorrentReveal else { return }
        if let hashString = pendingTorrentReveal.hashString {
            selectedTorrentID = TorrentRecord.identity(sourceID: pendingTorrentReveal.sourceID, hashString: hashString)
            torrentRevealToken = UUID()
        }
        self.pendingTorrentReveal = nil
    }

    private func loadSelectedTorrentDetails() async {
        guard let selectedTorrentID else {
            await model.loadDetails(for: nil)
            return
        }
        if let record = model.allTorrentRecords.first(where: { $0.id == selectedTorrentID && !$0.isAdding }) {
            await model.loadDetails(for: record.summary, sourceID: record.sourceID)
            return
        }
        guard let row = presentation.rows.first(where: { $0.id == selectedTorrentID }) else {
            await model.loadDetails(for: nil)
            return
        }
        await model.loadDetails(for: row.torrentRecord.flatMap { $0.isAdding ? nil : $0.summary }, sourceID: row.sourceID)
    }

    private func removeSelectedTorrent(deleteData: Bool) {
        if let draft = selectedDraft {
            discardDraft(draft)
            return
        }
        if let id = model.allTorrentRecords.first(where: { $0.id == selectedTorrentID })?.additionID {
            model.cancelTorrentAddition(id)
        } else if let record = selectedRecord {
            scheduleRemoval(record.summary, sourceID: record.sourceID, deleteData: deleteData)
        } else if let row = presentation.rows.first(where: { $0.id == selectedTorrentID }),
                  case let .group(records, _, _) = row.kind {
            selectedTorrentID = nil
            for record in records where !record.isAdding { scheduleRemoval(record.summary, sourceID: record.sourceID, deleteData: deleteData) }
        }
    }

    private func scheduleRemoval(_ torrent: TorrentSummary, sourceID: UUID, deleteData: Bool) {
        let key = PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            pendingRemovals.removeAll { $0.key == key }
            pendingRemovals.append(PendingTorrentRemoval(sourceID: sourceID, torrent: torrent, deleteData: deleteData))
            pendingRemovalResetToken = UUID()
        }
        if selectedTorrentID == TorrentRecord.identity(sourceID: sourceID, hashString: torrent.hashString) {
            selectedTorrentID = nil
        }
        pendingRemovalTask?.cancel()
        pendingRemovalTask = Task {
            do { try await Task.sleep(for: .seconds(pendingRemovalDuration)) }
            catch { return }
            commitPendingRemovals()
        }
    }

    private var pendingRemovalDuration: TimeInterval {
        12
    }

    private func cancelPendingRemovals() {
        let restoredSelection = pendingRemovals.last.map {
            TorrentRecord.identity(sourceID: $0.sourceID, hashString: $0.torrent.hashString)
        }

        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            pendingRemovals = []
            if selectedTorrentID == nil {
                selectedTorrentID = restoredSelection
            }
        }
    }

    private func dismissPendingRemovals() {
        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        commitPendingRemovals()
    }

    private func commitPendingRemovals() {
        let removals = pendingRemovals
        pendingRemovalTask?.cancel()
        pendingRemovalTask = nil
        guard !removals.isEmpty else { return }

        let keys = removals.map(\.key)
        withAnimation(motionAnimation(.snappy(duration: 0.28))) {
            committingRemovalKeys.formUnion(keys)
            pendingRemovals = []
        }

        Task {
            let removalsBySource = Dictionary(grouping: removals, by: \.sourceID)
            for (sourceID, sourceRemovals) in removalsBySource {
                let keepFiles = sourceRemovals.filter { !$0.deleteData }.map(\.torrent)
                let deleteData = sourceRemovals.filter(\.deleteData).map(\.torrent)

                if !keepFiles.isEmpty {
                    _ = await model.remove(keepFiles, deleteData: false, sourceID: sourceID)
                }
                if !deleteData.isEmpty {
                    _ = await model.remove(deleteData, deleteData: true, sourceID: sourceID)
                }
            }

            await MainActor.run {
                committingRemovalKeys.subtract(keys)
            }
        }
    }

    private var tuningPresentation: Binding<Bool> { externalTuningPresentation ?? $isTuningPresented }

    private var inspectorPresentation: Binding<Bool> {
        Binding(get: { isInspectorPresented || (GlassTuningMode.isEnabled && tuningPresentation.wrappedValue) },
            set: { visible in
                isInspectorPresented = visible
                if !visible { tuningPresentation.wrappedValue = false }
            })
    }

    private func updateInspectorWidth(_ width: CGFloat) {
        let visible = TorrentInspectorLayout.isVisible(width: width, wasVisible: isInspectorPresented)
        guard visible != isInspectorPresented else { return }
        withAnimation(motionAnimation(.easeInOut(duration: 0.25))) {
            isInspectorPresented = visible
        }
    }

    private var dropAnimation: Animation? {
        accessibilityReduceMotion ? nil : .timingCurve(1.0 / 3, 0, 2.0 / 3, 1,
            duration: isTorrentDropTargeted ? 0.25 : 0.30)
    }

    private func motionAnimation(_ animation: Animation) -> Animation? {
        accessibilityReduceMotion ? nil : animation
    }
}

private struct TorrentWorkspaceView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Binding var selection: String?
    let presentation: TorrentListPresentationModel
    let torrentRevealToken: UUID
    let pendingRenames: [PendingRemovalKey: PendingTorrentRename]
    let pendingRemovals: [PendingTorrentRemoval]
    let committingRemovalKeys: Set<PendingRemovalKey>
    let pendingRemovalResetToken: UUID
    let pendingRemovalDuration: TimeInterval
    let drafts: [TorrentAddDraft]
    let resumeDraft: (TorrentAddDraft) -> Void
    let discardDraft: (TorrentAddDraft) -> Void
    let commitRename: (TorrentSummary, UUID, String) -> Void
    let remove: (TorrentSummary, UUID, Bool) -> Void
    let removeSelected: (Bool) -> Void
    let undoRemovals: () -> Void
    let dismissRemovals: () -> Void

    var body: some View {
        TorrentListContent(
            model: model,
            platformIntegration: platformIntegration,
            selection: $selection,
            presentation: presentation,
            torrentRevealToken: torrentRevealToken,
            pendingRenames: pendingRenames,
            pendingRemovals: pendingRemovals,
            committingRemovalKeys: committingRemovalKeys,
            drafts: drafts,
            resumeDraft: resumeDraft,
            discardDraft: discardDraft,
            commitRename: commitRename,
            remove: remove,
            removeSelected: removeSelected
        )
        .frame(minWidth: 360, idealWidth: 480)
        .overlay(alignment: .bottom) {
            if !pendingRemovals.isEmpty {
                RemovalUndoToast(
                    removals: pendingRemovals,
                    resetToken: pendingRemovalResetToken,
                    duration: pendingRemovalDuration,
                    undo: undoRemovals,
                    dismiss: dismissRemovals
                )
                .padding(.horizontal, 16)
                .transition(
                    accessibilityReduceMotion
                        ? .opacity
                        : .move(edge: .bottom).combined(with: .opacity)
                )
            }
        }
    }

}

private struct TorrentListContent: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Binding var selection: String?
    let presentation: TorrentListPresentationModel
    let torrentRevealToken: UUID
    let pendingRenames: [PendingRemovalKey: PendingTorrentRename]
    let pendingRemovals: [PendingTorrentRemoval]
    let committingRemovalKeys: Set<PendingRemovalKey>
    let drafts: [TorrentAddDraft]
    let resumeDraft: (TorrentAddDraft) -> Void
    let discardDraft: (TorrentAddDraft) -> Void
    let commitRename: (TorrentSummary, UUID, String) -> Void
    let remove: (TorrentSummary, UUID, Bool) -> Void
    let removeSelected: (Bool) -> Void

    var body: some View {
        TorrentListView(
            model: model,
            platformIntegration: platformIntegration,
            records: visibleRecords,
            drafts: drafts,
            structureRevision: model.libraryStructureRevision,
            pendingRenameNames: pendingRenameNames,
            pendingRenameOldNames: pendingRenameOldNames,
            selection: $selection,
            presentation: presentation,
            revealSelectionToken: torrentRevealToken,
            resumeDraft: resumeDraft,
            discardDraft: discardDraft,
            commitRename: commitRename,
            remove: remove,
            removeSelected: removeSelected
        )
    }

    private var visibleRecords: [TorrentRecord] {
        let hiddenKeys = Set(pendingRemovals.map(\.key)).union(committingRemovalKeys)
        let available = model.allTorrentRecords.filter { record in
            !hiddenKeys.contains(PendingRemovalKey(sourceID: record.sourceID, hashString: record.hashString))
        }
        return TorrentLibraryFilter.records(available, group: model.selectedTorrentGroup, pendingRenameNames: pendingRenameNames)
    }

    private var pendingRenameNames: [String: String] {
        Dictionary(uniqueKeysWithValues: pendingRenames.values.compactMap { pendingRename in
            return (TorrentRecord.identity(sourceID: pendingRename.key.sourceID, hashString: pendingRename.key.hashString), pendingRename.newName)
        })
    }

    private var pendingRenameOldNames: [String: String] {
        Dictionary(uniqueKeysWithValues: pendingRenames.values.compactMap { pendingRename in
            return (TorrentRecord.identity(sourceID: pendingRename.key.sourceID, hashString: pendingRename.key.hashString), pendingRename.oldName)
        })
    }
}

private struct TorrentAutoRefreshInput: Equatable {
    let modelID: ObjectIdentifier
    let profiles: [RemoteProfile]
    let isActive: Bool
}

private struct TorrentSelectionInspector: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let selectedID: String?
    let presentation: TorrentListPresentationModel
    var isVisible = true

    var body: some View {
        let row = presentation.rows.first { $0.id == selectedID }
        TorrentInspectorView(
            model: model,
            platformIntegration: platformIntegration,
            sourceID: row?.sourceID ?? model.selectedSourceID,
            selectedTorrentHash: row?.torrentRecord?.hashString ?? row?.id,
            selectedTorrentGroup: row?.selectedGroup,
            isVisible: isVisible
        )
    }
}

private enum ActiveSheet: Identifiable {
    case newProfile
    case editProfile(RemoteProfile)
    case addMagnet(String, draftID: UUID, restore: TorrentAddDraft?)
    case loadingTorrentFiles(UUID)
    case addTorrentFiles(TorrentAddSession)

    var isTorrentImport: Bool {
        switch self {
        case .addMagnet, .loadingTorrentFiles, .addTorrentFiles: true
        default: false
        }
    }

    /// A Finder delivery joins the batch that is already on screen instead of
    /// replacing it. A loading placeholder can continue the same session.
    var importSession: TorrentAddSession? {
        switch self {
        case let .addTorrentFiles(session):
            return session
        case let .loadingTorrentFiles(id):
            return TorrentAddSession(id: id, drafts: [], pendingURLs: [], restore: nil)
        default:
            return nil
        }
    }

    var id: String {
        switch self {
        case .newProfile:
            return "new-profile"
        case let .editProfile(profile):
            return "edit-profile-\(profile.id.uuidString)"
        case let .addMagnet(_, draftID, _):
            return "add-magnet-\(draftID.uuidString)"
        case .loadingTorrentFiles, .addTorrentFiles:
            return "add-torrent-files"
        }
    }
}

private enum ActiveRootAlert {
    case deleteProfile(RemoteProfile)
    case error(String)
}

struct PendingRemovalKey: Hashable {
    let sourceID: UUID
    let hashString: String
}

private struct PendingTorrentReveal: Equatable {
    let sourceID: UUID
    let hashString: String?
}

struct PendingTorrentRename: Identifiable, Equatable {
    let id = UUID()
    let key: PendingRemovalKey
    let oldName: String
    let newName: String
}

struct PendingTorrentRemoval: Identifiable, Equatable {
    let sourceID: UUID
    let torrent: TorrentSummary
    let deleteData: Bool

    var key: PendingRemovalKey {
        PendingRemovalKey(sourceID: sourceID, hashString: torrent.hashString)
    }

    var id: String {
        "\(sourceID.uuidString)-\(torrent.hashString)-\(deleteData)"
    }
}

private extension UTType {
    static var torrentFile: UTType {
        UTType(filenameExtension: "torrent") ?? .data
    }
}

private extension TorrentSummary {
    func renamed(to name: String) -> TorrentSummary {
        TorrentSummary(
            id: id,
            hashString: hashString,
            name: name,
            status: status,
            percentDone: percentDone,
            metadataPercentComplete: metadataPercentComplete,
            rateDownload: rateDownload,
            rateUpload: rateUpload,
            sizeWhenDone: sizeWhenDone,
            leftUntilDone: leftUntilDone,
            eta: eta,
            uploadRatio: uploadRatio,
            peersConnected: peersConnected,
            downloadDir: downloadDir,
            bandwidthPriority: bandwidthPriority,
            queuePosition: queuePosition,
            fileCount: fileCount
        )
    }
}

/// One transferable destination avoids URL/text hover callbacks competing.
private struct TorrentWindowDropItem: Transferable, Sendable {
    let url: URL?
    let text: String?
    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (url: URL) in Self(url: url, text: nil) })
        ProxyRepresentation(importing: { (text: String) in Self(url: nil, text: text) })
    }
}

private struct DelayedTorrentLoadingView: View {
    @State private var showSpinner = false
    var body: some View {
        Color.clear.overlay { if showSpinner { ProgressView().controlSize(.small) } }
            .frame(width: GlassModalMetrics.addTorrent.width, height: GlassModalMetrics.addTorrent.height)
            .background(.background, in: RoundedRectangle(cornerRadius: GlassModalMetrics.cornerRadius))
            .task {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                showSpinner = true
            }
    }
}
