import AppKit
import GlassRemoteCore
import GlassRemoteServices
import Observation
import SwiftUI

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

        let items = drafts.map(TorrentBatchItemState.init)
        let groups = TorrentNameCleaner.batchGroups(for: drafts.map {
            TorrentBatchNamingInput(rootName: $0.preview.name, files: $0.preview.files)
        })
        for group in groups where group.isSeasonGroup {
            for (offset, itemIndex) in group.itemIndices.enumerated() {
                items[itemIndex].applySeasonDisplayName(group.displayName, season: group.seasons[offset])
            }
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
        VStack(spacing: 16) {
            if let group = groups.first(where: { $0.id == selectedGroupID }) {
                TextField("Torrent name", text: titleBinding(for: group))
                    .font(.largeTitle.weight(.bold)).textFieldStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading).disabled(isAdding)
            }
            Form {
                TorrentDownloadLocationPicker(
                    model: model,
                    platformIntegration: platformIntegration,
                    sourceID: $sourceID,
                    directory: $downloadDirectory,
                    defaultDirectory: $defaultDownloadDirectory,
                    errorMessage: $addErrorMessage,
                    isDisabled: isAdding
                )

                if groups.count > 1 {
                    Picker("Torrent", selection: $selectedGroupID) {
                        ForEach(groups) { group in
                            Text(groupNamesByID[group.id] ?? group.displayName).tag(group.id)
                        }
                    }
                    .disabled(isAdding)
                }
            }
            .formStyle(.columns)
            .fixedSize(horizontal: false, vertical: true)

            if let group = groups.first(where: { $0.id == selectedGroupID }) {
                TorrentBatchGroupEditor(
                    group: group,
                    items: items,
                    groupName: groupNameBinding(for: group),
                    smartNamesEnabled: Binding(get: { !optionHeld && (smartNamesByGroupID[group.id] ?? true) }, set: { smartNamesByGroupID[group.id] = $0 }),
                    isAdding: isAdding
                )
                .id(group.id)
            }

            if let addErrorMessage {
                Label(addErrorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .background(ModifierKeyObserver { optionHeld = $0 })
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isAdding)
                Spacer()
                Button(drafts.count == 1 ? "Add" : "Add All") {
                    disableSmartNamesForAdd = NSEvent.modifierFlags.contains(.option)
                    Task { await addAll() }
                }
                .keyboardShortcut(.defaultAction).disabled(!canAdd)
            }
            .controlSize(.large).padding(12)
            .background(.ultraThinMaterial)
        }
        .frame(width: 540, height: 460)
    }

    private func titleBinding(for group: TorrentBatchGroup) -> Binding<String> {
        if group.isSeasonGroup { return groupNameBinding(for: group) }
        guard let index = group.itemIndices.first else { return .constant("") }
        return Binding(get: { optionHeld ? items[index].draft.preview.name : items[index].name }, set: { items[index].name = $0 })
    }

    private var canAdd: Bool {
        !isAdding
            && (!groups.contains(where: needsSeriesDirectory) || resolvedBaseDownloadDirectory != nil)
            && items.filter({ !$0.wasAdded }).allSatisfy(\.canAdd)
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

        var failures: [String] = []
        for group in groups {
            for (offset, itemIndex) in group.itemIndices.enumerated() {
                let item = items[itemIndex]
                guard !item.wasAdded else { continue }
                let result = await submit(
                    item.draft,
                    sourceID,
                    submissionName(for: item, in: group, offset: offset),
                    downloadDirectory(for: item, in: group),
                    item.fileSelection,
                    namingPlan(for: item, in: group, offset: offset)
                )
                if result.succeeded {
                    item.wasAdded = true
                    if let hashString = result.torrent?.hashString, !hashString.isEmpty {
                        lastAddedTorrentHash = hashString
                    }
                } else {
                    failures.append("\(item.normalizedName): \(model.errorMessage ?? "Glass couldn’t add this torrent.")")
                    model.errorMessage = nil
                }
            }
        }

        if failures.isEmpty {
            didFinishAdding(sourceID, lastAddedTorrentHash)
            dismiss()
        } else {
            addErrorMessage = failures.joined(separator: "\n")
        }
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
            displayName: submissionName(for: item, in: group, offset: offset)
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
    @State private var fileSearchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Toggle("Select all files", isOn: Binding(get: {
                    group.itemIndices.allSatisfy { items[$0].selectedFileIndices.count == items[$0].draft.preview.files.count }
                }, set: { value in
                    for index in group.itemIndices where !items[index].wasAdded { items[index].setAllFilesWanted(value) }
                })).labelsHidden().toggleStyle(.checkbox)
                TextField("Search Files", text: $fileSearchText).textFieldStyle(.roundedBorder).controlSize(.small)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
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
                            showsControls: false, isCompact: true
                        )
                        .disabled(item.wasAdded)
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
        let suggestion = smartNamesEnabled ? item.suggestion() : nil
        let renamedFiles = Dictionary(
            uniqueKeysWithValues: (suggestion?.pathRenames ?? []).map { ($0.path, $0.name) }
        )
        return item.draft.preview.files.enumerated().map { index, file in
            TorrentFileBrowserEntry(
                index: index,
                file: file,
                rootName: item.draft.preview.name,
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
        TextField("Name", text: $item.name)
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

    init(draft: TorrentFileAddDraft) {
        self.draft = draft
        let selected = Set(draft.preview.files.indices)
        let suggestion = TorrentNameCleaner.plan(
            rootName: draft.preview.name,
            files: draft.preview.files,
            selectedFileIndices: selected
        )
        self.name = suggestion?.rootName ?? draft.preview.name
        self.selectedFileIndices = selected
    }

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canAdd: Bool { !normalizedName.isEmpty && !selectedFileIndices.isEmpty }

    func suggestion() -> TorrentAddNamingPlan? {
        TorrentNameCleaner.plan(
            rootName: draft.preview.name,
            files: draft.preview.files,
            selectedFileIndices: selectedFileIndices
        )
    }

    func namingPlan() -> TorrentAddNamingPlan? {
        guard let suggestion = suggestion() else { return nil }
        return TorrentAddNamingPlan(rootName: normalizedName, pathRenames: suggestion.pathRenames)
    }

    var smartSeason: TorrentSeasonDescriptor? {
        guard let season = TorrentNameCleaner.seasonDescriptor(for: TorrentBatchNamingInput(
            rootName: draft.preview.name, files: draft.preview.files
        )), normalizedName == "\(season.title) \(season.season)" else { return nil }
        return season
    }

    func seasonStoragePlan(baseDirectory: String) -> TorrentSeasonStoragePlan? {
        guard let season = smartSeason else { return nil }
        return TorrentSeasonStoragePlan(
            downloadDirectory: TorrentSeasonStoragePlan.baseDirectory(base: baseDirectory, title: season.title),
            namingPlan: TorrentAddNamingPlan(
                rootName: season.title, pathRenames: suggestion()?.pathRenames ?? [], displayName: normalizedName
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
            name = suggestion.rootName
        }
    }

    func restoreOriginalName() {
        name = draft.preview.name
    }

    func applySeasonDisplayName(_ title: String, season: Int) {
        name = "\(title) \(season)"
    }
}
