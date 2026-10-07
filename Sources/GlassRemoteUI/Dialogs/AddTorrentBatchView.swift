import AppKit
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct AddTorrentBatchView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let drafts: [TorrentFileAddDraft]
    let submit: @MainActor (
        TorrentFileAddDraft,
        UUID,
        String,
        String?,
        TorrentAddFileSelection,
        TorrentAddNamingPlan?
    ) async -> TorrentFileAddSubmissionResult
    let didFinishAdding: @MainActor (UUID, String?) -> Void

    @AppStorage("GlassList.showExtensions") private var showExtensions = false
    @Environment(\.dismiss) private var dismiss

    @State private var items: [TorrentBatchItemState]
    @State private var groups: [TorrentBatchGroup]
    @State private var selectedGroupID: String
    @State private var groupNamesByID: [String: String]
    @State private var smartNamesByGroupID: [String: Bool]
    @State private var sourceID: UUID
    @State private var downloadDirectory: String?
    @State private var defaultDownloadDirectory: String?
    @State private var optionHeld = false
    @State private var commandHeld = false
    @State private var fileSearchText = ""
    @State private var searchPresented = false
    @State private var namingReady = false
    @AppearanceStorage("GlassAdd.showIcon") private var showsTitleIcon = true
    @State private var disableSmartNamesForAdd = false
    @State private var isAdding = false
    @State private var addErrorMessage: String?
    @State private var lastAddedTorrentHash: String?

    init(
        model: RemoteAppModel,
        platformIntegration: any GlassPlatformIntegrating,
        drafts: [TorrentFileAddDraft],
        submit: @escaping @MainActor (
            TorrentFileAddDraft,
            UUID,
            String,
            String?,
            TorrentAddFileSelection,
            TorrentAddNamingPlan?
        ) async -> TorrentFileAddSubmissionResult,
        didFinishAdding: @escaping @MainActor (UUID, String?) -> Void
    ) {
        self.model = model
        self.platformIntegration = platformIntegration
        self.drafts = drafts
        self.submit = submit
        self.didFinishAdding = didFinishAdding

        let items = drafts.map { TorrentBatchItemState(draft: $0, defersNaming: true) }
        let groups = drafts.indices.map {
            TorrentBatchGroup(displayName: drafts[$0].preview.name, itemIndices: [$0])
        }
        _items = State(initialValue: items)
        _groups = State(initialValue: groups)
        _selectedGroupID = State(initialValue: groups.first?.id ?? "")
        _groupNamesByID = State(initialValue: Dictionary(
            uniqueKeysWithValues: groups.map { ($0.id, $0.displayName) }
        ))
        _smartNamesByGroupID = State(initialValue: Dictionary(
            uniqueKeysWithValues: groups.map { ($0.id, true) }
        ))
        _sourceID = State(initialValue: model.selectedSourceID)
    }

    var body: some View {
        VStack(spacing: 18) {
            if let group = groups.first(where: { $0.id == selectedGroupID }) {
                HStack(spacing: 14) {
                    if showsTitleIcon {
                        addTitleIcon(group)
                            .accessibilityHidden(true)
                    }
                    TextField(glassText("Torrent name"), text: titleBinding(for: group))
                        .font(.title.weight(.bold)).textFieldStyle(.plain)
                        .disabled(isAdding || optionHeld)
                    TorrentDownloadLocationPicker(model: model, platformIntegration: platformIntegration,
                        sourceID: $sourceID, directory: $downloadDirectory,
                        defaultDirectory: $defaultDownloadDirectory, errorMessage: $addErrorMessage,
                        isDisabled: isAdding)
                }
                TorrentBatchGroupEditor(group: group, items: items,
                    groupName: groupNameBinding(for: group),
                    smartNamesEnabled: Binding(get: { !optionHeld && (smartNamesByGroupID[group.id] ?? true) },
                        set: { smartNamesByGroupID[group.id] = $0 }),
                    isAdding: isAdding, fileSearchText: $fileSearchText)
                    .id(group.id)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)))
            }
            if let addErrorMessage {
                Label(addErrorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .padding(20)
        .padding(.bottom, 62)
        .background {
            if groups.count > 1 {
                ForEach(1...min(3, groups.count - 1), id: \.self) { depth in
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(.thinMaterial)
                        .rotationEffect(.degrees(Double(depth) * 1.5))
                        .offset(y: CGFloat(depth) * 7)
                        .padding(.horizontal, CGFloat(depth) * 6)
                }
            }
        }
        .animation(.smooth, value: selectedGroupID)
        .overlay(alignment: .bottom) {
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 10) {
                    if hasMultipleFiles {
                        GlassSearchPill(text: $fileSearchText, isPresented: $searchPresented, expandedWidth: 220)
                    }
                    Spacer(minLength: 12)
                    Button {
                        disableSmartNamesForAdd = NSEvent.modifierFlags.contains(.option)
                        commandHeld = NSEvent.modifierFlags.contains(.command)
                        Task { await addAll() }
                    } label: {
                        Text(glassText(commandHeld ? "Stall" : "Add"))
                            .id(commandHeld).transition(.blurReplace)
                            .modifier(InspectorGlassPill(interactive: true))
                    }.buttonStyle(.plain).keyboardShortcut(.defaultAction).disabled(!canAdd)
                }
            }
            .padding(20)
        }
        .background(ModifierKeyObserver { optionHeld = $0 })
        .background(AddCommandKeyObserver { held in withAnimation(.smooth) { commandHeld = held } })
        .onExitCommand { if searchPresented { searchPresented = false; fileSearchText = "" } else if !isAdding { dismiss() } }
        .task { await prepareNames() }
        .frame(width: 640, height: 500)
    }

    private func addTitleIcon(_ group: TorrentBatchGroup) -> some View {
        let files = group.itemIndices.flatMap { items[$0].draft.preview.files }
        let folder = group.isSeasonGroup || files.count > 1
        let type = folder ? UTType.folder : (UTType(filenameExtension: URL(fileURLWithPath: files.first?.name ?? "").pathExtension) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        return ZStack {
            if group.isSeasonGroup {
                NativeGlassIcon(image: image, size: 32, isFolder: true, rotation: -0.15).offset(x: -6)
                NativeGlassIcon(image: image, size: 32, isFolder: true, rotation: 0.15).offset(x: 6)
            } else {
                NativeGlassIcon(image: image, size: 34, isFolder: folder)
            }
        }.frame(width: group.isSeasonGroup ? 46 : 34, height: 36)
    }

    private var hasMultipleFiles: Bool {
        guard let group = groups.first(where: { $0.id == selectedGroupID }) else { return false }
        return group.itemIndices.reduce(0) { $0 + items[$1].draft.preview.files.count } > 1
    }

    private func prepareNames() async {
        let result = await AddNamingPreparation.prepare(drafts)
        guard !Task.isCancelled else { return }
        withAnimation(.smooth) {
            groups = result.groups
            selectedGroupID = groups.first?.id ?? ""
            let oldNames = groupNamesByID
            groupNamesByID = Dictionary(uniqueKeysWithValues: groups.map { group in
                let entered = oldNames[group.id]
                let original = group.itemIndices.first.map { items[$0].draft.preview.name }
                return (group.id, entered != nil && entered != original ? entered! : group.displayName)
            })
            smartNamesByGroupID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, true) })
            for (index, plan) in result.plans.enumerated() {
                items[index].cachedSuggestion = plan
                if items[index].name == items[index].draft.preview.name {
                    items[index].name = plan?.suggestedName ?? items[index].name
                }
            }
            for group in groups where group.isSeasonGroup {
                for (offset, index) in group.itemIndices.enumerated() {
                    if items[index].name == items[index].draft.preview.name || items[index].name == items[index].cachedSuggestion?.suggestedName {
                        items[index].applySeasonDisplayName(group.displayName, season: group.seasons[offset])
                    }
                }
            }
            namingReady = true
        }
    }

    private func titleBinding(for group: TorrentBatchGroup) -> Binding<String> {
        if optionHeld {
            return .constant(group.itemIndices.first.map { items[$0].presentedName(holdingOption: true, showExtensions: showExtensions) } ?? group.displayName)
        }
        if group.isSeasonGroup { return groupNameBinding(for: group) }
        guard let index = group.itemIndices.first else { return .constant("") }
        return Binding(get: { items[index].presentedName(holdingOption: false, showExtensions: showExtensions) }, set: { items[index].editPresentedName($0, showExtensions: showExtensions) })
    }

    private var canAdd: Bool {
        !isAdding && namingReady
            && (!groups.contains(where: needsSeriesDirectory) || resolvedBaseDownloadDirectory != nil)
            && (groups.first(where: { $0.id == selectedGroupID })?.itemIndices.allSatisfy { items[$0].canAdd } ?? false)
    }

    private func needsSeriesDirectory(_ group: TorrentBatchGroup) -> Bool {
        if optionHeld || disableSmartNamesForAdd { return false }
        return group.isSeasonGroup || ((smartNamesByGroupID[group.id] ?? true)
            && group.itemIndices.contains { items[$0].smartSeason != nil })
    }

    private func addAll() async {
        guard canAdd else { return }
        addErrorMessage = nil
        isAdding = true
        defer { isAdding = false }

        // Snapshot the submission before dismissing: modifier keys and modal state
        // cannot change the batch while the server processes its members.
        let activeGroups = groups.filter { $0.id == selectedGroupID }
        let jobs = activeGroups.flatMap { group in
            group.itemIndices.enumerated().compactMap { offset, index -> (TorrentBatchItemState, String, String?, TorrentAddNamingPlan?)? in
                let item = items[index]
                guard !item.wasAdded else { return nil }
                return (item, submissionName(for: item, in: group, offset: offset),
                        downloadDirectory(for: item, in: group),
                        namingPlan(for: item, in: group, offset: offset))
            }
        }
        let destinationSource = sourceID
        for (item, name, directory, plan) in jobs {
            model.prepareTorrentAddition(id: item.draft.id, sourceID: destinationSource,
                name: name, size: item.draft.preview.size, fileCount: item.draft.preview.files.count,
                downloadDirectory: directory,
                namingPlan: plan ?? (name == item.draft.preview.name ? nil : TorrentAddNamingPlan(rootName: name, pathRenames: [])),
                data: item.draft.data, fileSelection: item.fileSelection,
                sourceURL: item.draft.sourceURL, trashSourceOnSuccess: true,
                renameDuplicateRoot: plan == nil && name != item.draft.preview.name, startPaused: commandHeld)
        }
        model.selectedProfileID = destinationSource
        model.selectedTorrentGroup = .all
        let remaining = groups.filter { $0.id != selectedGroupID }
        if remaining.isEmpty { dismiss() }
        else {
            withAnimation(.smooth) { groups = remaining; selectedGroupID = remaining[0].id }
        }

        var failures: [String] = []
        var addedHash: String?
        for (item, name, directory, plan) in jobs {
            let result = await submit(item.draft, destinationSource, name, directory, item.fileSelection, plan)
            if result.succeeded {
                item.wasAdded = true
                if let hash = result.torrent?.hashString, !hash.isEmpty { addedHash = hash }
            } else {
                failures.append("\(item.normalizedName): \(model.errorMessage ?? "Glass couldn’t add this torrent.")")
                model.errorMessage = nil
            }
        }
        if let addedHash { didFinishAdding(destinationSource, addedHash) }
        if !failures.isEmpty { model.errorMessage = failures.joined(separator: "\n") }
    }

    private var resolvedBaseDownloadDirectory: String? {
        downloadDirectory ?? defaultDownloadDirectory
    }

    private func downloadDirectory(for item: TorrentBatchItemState, in group: TorrentBatchGroup) -> String? {
        guard !disableSmartNamesForAdd, let base = resolvedBaseDownloadDirectory else { return downloadDirectory }
        if group.isSeasonGroup {
            return TorrentSeasonStoragePlan.baseDirectory(base: base, title: resolvedGroupName(for: group))
        }
        guard smartNamesByGroupID[group.id] ?? true,
              let plan = item.seasonStoragePlan(baseDirectory: base) else {
            return downloadDirectory
        }
        return plan.downloadDirectory
    }

    private func namingPlan(
        for item: TorrentBatchItemState,
        in group: TorrentBatchGroup,
        offset: Int
    ) -> TorrentAddNamingPlan? {
        let smartNamesEnabled = !disableSmartNamesForAdd && (smartNamesByGroupID[group.id] ?? true)
        if disableSmartNamesForAdd { return nil }
        guard group.isSeasonGroup else {
            guard smartNamesEnabled else { return nil }
            return resolvedBaseDownloadDirectory.flatMap { item.seasonStoragePlan(baseDirectory: $0)?.namingPlan }
                ?? item.namingPlan()
        }
        let pathRenames = smartNamesEnabled
            ? (item.suggestion()?.pathRenames ?? [])
            : []
        return TorrentAddNamingPlan(
            rootName: resolvedGroupName(for: group),
            pathRenames: pathRenames,
            displayName: resolvedGroupName(for: group),
            season: TorrentSeasonDescriptor(title: resolvedGroupName(for: group), season: group.seasons[offset])
        )
    }

    private func submissionName(
        for item: TorrentBatchItemState,
        in group: TorrentBatchGroup,
        offset: Int
    ) -> String {
        if disableSmartNamesForAdd { return item.draft.preview.name }
        guard group.isSeasonGroup else { return item.normalizedName }
        return "\(resolvedGroupName(for: group)) \(group.seasons[offset])"
    }

    private func resolvedGroupName(for group: TorrentBatchGroup) -> String {
        let value = groupNamesByID[group.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? group.displayName : value
    }

    private func groupNameBinding(for group: TorrentBatchGroup) -> Binding<String> {
        Binding(
            get: { groupNamesByID[group.id] ?? group.displayName },
            set: { groupNamesByID[group.id] = $0 }
        )
    }

    private func smartNamesBinding(for group: TorrentBatchGroup) -> Binding<Bool> {
        Binding(
            get: { smartNamesByGroupID[group.id] ?? true },
            set: { smartNamesByGroupID[group.id] = $0 }
        )
    }
}

struct TorrentFileAddSubmissionResult: Sendable, Hashable {
    let succeeded: Bool
    let torrent: TorrentAddResult?
}

struct TorrentSeasonStoragePlan {
    let downloadDirectory: String
    let namingPlan: TorrentAddNamingPlan

    static func baseDirectory(base: String, title: String) -> String {
        let baseURL = URL(fileURLWithPath: base).standardizedFileURL
        if baseURL.lastPathComponent == title { return baseURL.deletingLastPathComponent().path }
        return baseURL.path
    }
}

private struct TorrentBatchGroupEditor: View {
    let group: TorrentBatchGroup
    let items: [TorrentBatchItemState]
    @Binding var groupName: String
    @Binding var smartNamesEnabled: Bool
    let isAdding: Bool
    @Binding var fileSearchText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if fileCount == 1, let index = group.itemIndices.first, let file = items[index].draft.preview.files.first {
                TorrentSingleFilePreview(name: file.name, size: file.length)
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(group.itemIndices.enumerated()), id: \.element) { offset, index in
                        let item = items[index]
                        if group.isSeasonGroup {
                            Text("Season \(group.seasons[offset])").font(.subheadline.weight(.semibold))
                        }
                        TorrentFilesBrowser(
                            entries: fileEntries(for: item), searchText: $fileSearchText,
                            onSetWanted: { item.setFileWanted($0, $1) },
                            onSetPriority: { item.filePriorities[$0] = $1 },
                            onSetAllWanted: { item.setAllFilesWanted($0) },
                            showsControls: false, isCompact: true, showsActionBar: false
                        )
                        .disabled(item.wasAdded)
                    }
                }
            }
        }
            }
        .disabled(isAdding)

    }

    private var fileCount: Int {
        group.itemIndices.reduce(0) { $0 + items[$1].draft.preview.files.count }
    }

    private var selectionSummary: String {
        let selected = group.itemIndices.reduce(0) { $0 + items[$1].selectedFileIndices.count }
        let size = group.itemIndices.reduce(UInt64.zero) { total, index in
            total + items[index].selectedFileIndices.reduce(UInt64.zero) {
                $0 + items[index].draft.preview.files[$1].length
            }
        }
        return "\(selected) of \(fileCount) · \(formatBytes(size))"
    }

    private func fileEntries(for item: TorrentBatchItemState) -> [TorrentFileBrowserEntry] {
        let suggestion = smartNamesEnabled ? item.cachedSuggestion : nil
        let renamedFiles = Dictionary(
            uniqueKeysWithValues: (suggestion?.pathRenames ?? []).map { ($0.path, $0.name) }
        )
        let rootName = TorrentFileBrowserEntry.commonRoot(paths: item.draft.preview.files.map(\.name)) ?? item.draft.preview.name
        return item.draft.preview.files.enumerated().map { index, file in
            TorrentFileBrowserEntry(
                index: index,
                file: file,
                rootName: rootName,
                displayName: renamedFiles[file.name],
                isWanted: item.selectedFileIndices.contains(index),
                priority: item.filePriorities[index] ?? 0
            )
        }
    }

    private func setAllFilesWanted(_ wanted: Bool) {
        for index in group.itemIndices where !items[index].wasAdded {
            items[index].setAllFilesWanted(wanted)
        }
    }
}

private struct TorrentBatchNameField: View {
    @Bindable var item: TorrentBatchItemState

    var body: some View {
        TextField(glassText("Name"), text: $item.name)
            .disabled(item.wasAdded)
    }
}

@MainActor
@Observable
final class TorrentBatchItemState {
    let draft: TorrentFileAddDraft
    var name: String
    var selectedFileIndices: Set<Int>
    var filePriorities: [Int: Int] = [:]
    var wasAdded = false
    var cachedSuggestion: TorrentAddNamingPlan?

    init(draft: TorrentFileAddDraft, defersNaming: Bool = false) {
        self.draft = draft
        let selected = Set(draft.preview.files.indices)
        let suggestion = defersNaming ? nil : TorrentNameCleaner.plan(rootName: draft.preview.name,
            files: draft.preview.files, selectedFileIndices: selected)
        self.cachedSuggestion = suggestion
        self.name = suggestion?.suggestedName ?? draft.preview.name
        self.selectedFileIndices = selected
    }

    func presentedName(holdingOption: Bool, showExtensions: Bool = false) -> String {
        let title = holdingOption ? draft.preview.name : name
        return TorrentExtensionPolicy.name(title, hiding: showExtensions ? nil : hiddenTitleExtension)
    }
    private var hiddenTitleExtension: String? {
        TorrentExtensionPolicy.hiddenExtension(paths: draft.preview.files.map(\.name))
    }
    func editPresentedName(_ title: String, showExtensions: Bool = false) {
        name = TorrentExtensionPolicy.editedName(title, original: name, hiding: showExtensions ? nil : hiddenTitleExtension)
    }

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canAdd: Bool { !normalizedName.isEmpty  }

    func suggestion() -> TorrentAddNamingPlan? {
        if selectedFileIndices.count == draft.preview.files.count, let cachedSuggestion { return cachedSuggestion }
        return TorrentNameCleaner.plan(
            rootName: draft.preview.name,
            files: draft.preview.files,
            selectedFileIndices: selectedFileIndices
        )
    }

    func namingPlan() -> TorrentAddNamingPlan? {
        guard let suggestion = suggestion() else { return nil }
        return suggestion.withDisplayName(normalizedName)
    }

    var smartSeason: TorrentSeasonDescriptor? {
        guard let season = TorrentNameCleaner.seasonDescriptor(for: TorrentBatchNamingInput(
            rootName: draft.preview.name, files: draft.preview.files
        )), normalizedName == season.title else { return nil }
        return season
    }

    func seasonStoragePlan(baseDirectory: String) -> TorrentSeasonStoragePlan? {
        guard let season = smartSeason else { return nil }
        return TorrentSeasonStoragePlan(
            downloadDirectory: TorrentSeasonStoragePlan.baseDirectory(base: baseDirectory, title: season.title),
            namingPlan: TorrentAddNamingPlan(
                rootName: season.title, pathRenames: suggestion()?.pathRenames ?? [], displayName: normalizedName, season: season
            )
        )
    }

    var fileSelection: TorrentAddFileSelection {
        let all = Set(draft.preview.files.indices)
        return TorrentAddFileSelection(
            filesWanted: selectedFileIndices.sorted(),
            filesUnwanted: all.subtracting(selectedFileIndices).sorted(),
            priorityHigh: draft.preview.files.indices.filter { filePriorities[$0] == 1 },
            priorityNormal: draft.preview.files.indices.filter { (filePriorities[$0] ?? 0) == 0 },
            priorityLow: draft.preview.files.indices.filter { filePriorities[$0] == -1 }
        )
    }

    func setFileWanted(_ index: Int, _ wanted: Bool) {
        if wanted {
            selectedFileIndices.insert(index)
        } else {
            selectedFileIndices.remove(index)
        }
    }

    func setAllFilesWanted(_ wanted: Bool) {
        selectedFileIndices = wanted ? Set(draft.preview.files.indices) : []
    }

    func applySmartName() {
        if let suggestion = suggestion() {
            name = suggestion.suggestedName
        }
    }

    func restoreOriginalName() {
        name = draft.preview.name
    }

    func applySeasonDisplayName(_ title: String, season: Int) {
        name = "\(title) \(season)"
    }
}

private enum AddNamingPreparation {
    struct Result: Sendable {
        let groups: [TorrentBatchGroup]
        let plans: [TorrentAddNamingPlan?]
    }
    @concurrent static func prepare(_ drafts: [TorrentFileAddDraft]) async -> Result {
        let start = ContinuousClock.now
        let groups = TorrentNameCleaner.batchGroups(for: drafts.map {
            TorrentBatchNamingInput(rootName: $0.preview.name, files: $0.preview.files)
        })
        var plans: [TorrentAddNamingPlan?] = []
        for draft in drafts {
            if Task.isCancelled { break }
            plans.append(TorrentNameCleaner.plan(rootName: draft.preview.name,
                files: draft.preview.files, selectedFileIndices: Set(draft.preview.files.indices)))
        }
        #if DEBUG
        print("Smart Rename: \(drafts.count) drafts, \(drafts.reduce(0) { $0 + $1.preview.files.count }) files, \(start.duration(to: .now))")
        #endif
        return Result(groups: groups, plans: plans)
    }
}

private struct AddCommandKeyObserver: NSViewRepresentable {
    let changed: (Bool) -> Void
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) { view.changed = changed }
    final class Anchor: NSView {
        var changed: ((Bool) -> Void)?
        private var monitor: Any?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
            guard window != nil else { return }
            changed?(NSEvent.modifierFlags.contains(.command))
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.changed?(event.modifierFlags.contains(.command)); return event
            }
        }
        isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
