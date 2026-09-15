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
    @State private var cleanupWordsByGroupID: [String: String]
    @State private var sourceID: UUID
    @State private var destination: BatchDestination = .defaultLocation
    @State private var defaultDownloadDirectory: String?
    @State private var customDownloadDirectory = ""
    @State private var isAdding = false
    @State private var isChoosingDownloadDirectory = false
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
        _cleanupWordsByGroupID = State(initialValue: Dictionary(
            uniqueKeysWithValues: groups.map { ($0.id, "") }
        ))
        _sourceID = State(initialValue: model.selectedSourceID)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let addErrorMessage {
                    Section("Couldn’t Add Torrents") {
                        Label(addErrorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }

                Section {
                    Picker("Add To", selection: $sourceID) {
                        Label(model.localSourceName, systemImage: model.localSourceSystemImage)
                            .tag(model.localSourceID)
                        ForEach(model.profiles) { profile in
                            Label(profile.name, systemImage: "server.rack")
                                .tag(profile.id)
                        }
                    }

                    LabeledContent("Download Location") {
                        downloadLocationMenu
                    }

                    if destination == .other {
                        TextField("Path", text: $customDownloadDirectory)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(height: addErrorMessage == nil ? 128 : 205)

            Divider()

            TabView(selection: $selectedGroupID) {
                ForEach(groups) { group in
                    TorrentBatchGroupEditor(
                        group: group,
                        items: items,
                        groupName: groupNameBinding(for: group),
                        smartNamesEnabled: smartNamesBinding(for: group),
                        cleanupWords: cleanupWordsBinding(for: group),
                        isAdding: isAdding
                    )
                    .tabItem {
                        Label(
                            groupNamesByID[group.id] ?? group.displayName,
                            systemImage: group.isSeasonGroup ? "rectangle.stack" : "film"
                        )
                    }
                    .tag(group.id)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
        .navigationTitle(drafts.count == 1 ? "Add Torrent" : "Add \(drafts.count) Torrents")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isAdding)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(drafts.count == 1 ? "Add" : "Add All") {
                    Task { await addAll() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 650)
        .containerBackground(.thinMaterial, for: .window)
        .task(id: sourceID) {
            defaultDownloadDirectory = nil
            let directory = await model.defaultDownloadDirectory(for: sourceID)
            guard !Task.isCancelled else { return }
            defaultDownloadDirectory = directory
        }
        .onChange(of: sourceID) { _, _ in
            destination = .defaultLocation
            customDownloadDirectory = ""
        }
    }

    private var canAdd: Bool {
        !isAdding
            && resolvedDownloadDirectoryIsValid
            && (!groups.contains(where: \.isSeasonGroup) || resolvedBaseDownloadDirectory != nil)
            && items.filter({ !$0.wasAdded }).allSatisfy(\.canAdd)
    }

    private var resolvedDownloadDirectoryIsValid: Bool {
        destination != .other || !customDownloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var downloadLocationMenu: some View {
        Menu {
            Button {
                destination = .defaultLocation
            } label: {
                Label(defaultLocationLabel, systemImage: destination == .defaultLocation ? "checkmark" : "folder")
            }

            ForEach(availableDirectories, id: \.self) { directory in
                Button {
                    destination = .directory(directory)
                } label: {
                    Label(
                        displayName(for: directory),
                        systemImage: destination == .directory(directory) ? "checkmark" : "folder"
                    )
                }
            }

            Divider()
            if sourceID == model.localSourceID {
                Button("Choose…", systemImage: "folder") {
                    Task { await chooseDownloadDirectory() }
                }
                .disabled(isChoosingDownloadDirectory || isAdding)
            } else {
                Button("Other Path…", systemImage: "folder.badge.plus") {
                    destination = .other
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedLocationLabel).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .help(resolvedDownloadDirectory ?? defaultDownloadDirectory ?? "Use the host’s default download location")
    }

    private var availableDirectories: [String] {
        var result: [String] = []
        for directory in model.favoriteDownloadDirectories(for: sourceID) + model.downloadDirectories(for: sourceID) {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed != defaultDownloadDirectory, !result.contains(trimmed) else { continue }
            result.append(trimmed)
        }
        return result
    }

    private var defaultLocationLabel: String {
        guard let defaultDownloadDirectory, !defaultDownloadDirectory.isEmpty else { return "Default" }
        return "Default — \(displayName(for: defaultDownloadDirectory))"
    }

    private var selectedLocationLabel: String {
        switch destination {
        case .defaultLocation:
            return defaultLocationLabel
        case let .directory(directory):
            return displayName(for: directory)
        case .other:
            let trimmed = customDownloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Other Path" : displayName(for: trimmed)
        }
    }

    private var resolvedDownloadDirectory: String? {
        switch destination {
        case .defaultLocation:
            return nil
        case let .directory(directory):
            return directory
        case .other:
            let value = customDownloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }
    }

    private func displayName(for directory: String) -> String {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private func chooseDownloadDirectory() async {
        isChoosingDownloadDirectory = true
        defer { isChoosingDownloadDirectory = false }
        do {
            if let path = try await platformIntegration.chooseLocalDownloadDirectory(
                startingAt: resolvedDownloadDirectory ?? defaultDownloadDirectory
            ) {
                destination = .directory(path)
            }
        } catch {
            addErrorMessage = error.localizedDescription
        }
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
                    downloadDirectory(for: group),
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
        resolvedDownloadDirectory ?? defaultDownloadDirectory
    }

    private func downloadDirectory(for group: TorrentBatchGroup) -> String? {
        guard group.isSeasonGroup, let base = resolvedBaseDownloadDirectory else {
            return resolvedDownloadDirectory
        }
        return (base as NSString).appendingPathComponent(resolvedGroupName(for: group))
    }

    private func namingPlan(
        for item: TorrentBatchItemState,
        in group: TorrentBatchGroup,
        offset: Int
    ) -> TorrentAddNamingPlan? {
        let removingTokens = cleanupTokens(from: cleanupWordsByGroupID[group.id] ?? "")
        let smartNamesEnabled = smartNamesByGroupID[group.id] ?? true
        guard group.isSeasonGroup else {
            return smartNamesEnabled ? item.namingPlan(removingTokens: removingTokens) : nil
        }
        let pathRenames = smartNamesEnabled
            ? (item.suggestion(removingTokens: removingTokens)?.pathRenames ?? [])
            : []
        return TorrentAddNamingPlan(
            rootName: "Season \(group.seasons[offset])",
            pathRenames: pathRenames
        )
    }

    private func submissionName(
        for item: TorrentBatchItemState,
        in group: TorrentBatchGroup,
        offset: Int
    ) -> String {
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

    private func cleanupWordsBinding(for group: TorrentBatchGroup) -> Binding<String> {
        Binding(
            get: { cleanupWordsByGroupID[group.id] ?? "" },
            set: { cleanupWordsByGroupID[group.id] = $0 }
        )
    }
}

struct TorrentFileAddSubmissionResult: Sendable, Hashable {
    let succeeded: Bool
    let torrent: TorrentAddResult?
}

private struct TorrentBatchGroupEditor: View {
    let group: TorrentBatchGroup
    let items: [TorrentBatchItemState]
    @Binding var groupName: String
    @Binding var smartNamesEnabled: Bool
    @Binding var cleanupWords: String
    let isAdding: Bool
    @State private var fileSearchText = ""

    private var removingTokens: [String] { cleanupTokens(from: cleanupWords) }

    var body: some View {
        Form {
            if group.isSeasonGroup {
                Section {
                    TextField("Series Name", text: $groupName)
                } footer: {
                    Text("Glass creates one shared folder and keeps each season as a separate torrent.")
                }
            }

            Section {
                Toggle("Smart Names", isOn: $smartNamesEnabled)

                if smartNamesEnabled {
                    LabeledContent("Remove Extra Tags") {
                        TextField("Optional", text: $cleanupWords, prompt: Text("PURPLECAT, release group"))
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Naming")
            } footer: {
                Text(smartNamesEnabled
                    ? "Glass cleans release tags and episode names. Add comma-separated tags only when the preview still contains one."
                    : "Original torrent and file names will be kept.")
            }

            Section {
                TorrentFilesBrowserControls(
                    searchText: $fileSearchText,
                    onSetAllWanted: setAllFilesWanted
                )
            } header: {
                Text("Files")
            } footer: {
                Text("Click a column heading to sort. Files start sorted by name.")
            }

            ForEach(Array(group.itemIndices.enumerated()), id: \.element) { offset, index in
                TorrentBatchItemEditor(
                    item: items[index],
                    season: group.isSeasonGroup ? group.seasons[offset] : nil,
                    smartNamesEnabled: smartNamesEnabled,
                    removingTokens: removingTokens,
                    fileSearchText: $fileSearchText,
                    isAdding: isAdding
                )
            }
        }
        .formStyle(.grouped)
        .onChange(of: smartNamesEnabled) { _, enabled in
            updateStandaloneNames(enabled: enabled)
        }
        .onChange(of: cleanupWords) { _, _ in
            guard smartNamesEnabled else { return }
            updateStandaloneNames(enabled: true)
        }
    }

    private func updateStandaloneNames(enabled: Bool) {
        guard !group.isSeasonGroup else { return }
        for index in group.itemIndices {
            if enabled {
                items[index].applySmartName(removingTokens: removingTokens)
            } else {
                items[index].restoreOriginalName()
            }
        }
    }

    private func setAllFilesWanted(_ wanted: Bool) {
        for index in group.itemIndices {
            items[index].setAllFilesWanted(wanted)
        }
    }
}

private struct TorrentBatchItemEditor: View {
    @Bindable var item: TorrentBatchItemState
    let season: Int?
    let smartNamesEnabled: Bool
    let removingTokens: [String]
    @Binding var fileSearchText: String
    let isAdding: Bool

    var body: some View {
        Section {
            if let season {
                LabeledContent("Torrent") {
                    Text("Season \(season)")
                }
            } else {
                LabeledContent("Name") {
                    TextField("Name", text: $item.name)
                        .multilineTextAlignment(.trailing)
                }
            }

            if smartNamesEnabled, let suggestion = item.suggestion(removingTokens: removingTokens) {
                TorrentRenamePreview(
                    originalName: item.draft.preview.name,
                    resultName: season.map { "Season \($0)" } ?? item.normalizedName,
                    renames: suggestion.pathRenames
                )
            }

            LabeledContent("Picked", value: item.selectionSummary)

            TorrentFilesBrowser(
                entries: fileEntries,
                searchText: $fileSearchText,
                onSetWanted: item.setFileWanted,
                onSetPriority: item.setFilePriority,
                onSetAllWanted: item.setAllFilesWanted,
                showsControls: false
            )
        } header: {
            HStack {
                Text(item.draft.preview.name)
                Spacer()
                if item.wasAdded {
                    Label("Added", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
        }
        .disabled(isAdding || item.wasAdded)
    }

    private var fileEntries: [TorrentFileBrowserEntry] {
        let suggestion = smartNamesEnabled ? item.suggestion(removingTokens: removingTokens) : nil
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
}

@MainActor
@Observable
private final class TorrentBatchItemState {
    let draft: TorrentFileAddDraft
    var name: String
    var selectedFileIndices: Set<Int>
    var filePriorities: [Int: Int]
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
        self.filePriorities = Dictionary(
            uniqueKeysWithValues: draft.preview.files.indices.map { ($0, 0) }
        )
    }

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canAdd: Bool { !normalizedName.isEmpty && !selectedFileIndices.isEmpty }

    func suggestion(removingTokens: [String] = []) -> TorrentAddNamingPlan? {
        TorrentNameCleaner.plan(
            rootName: draft.preview.name,
            files: draft.preview.files,
            selectedFileIndices: selectedFileIndices,
            removingTokens: removingTokens
        )
    }

    func namingPlan(removingTokens: [String]) -> TorrentAddNamingPlan? {
        guard let suggestion = suggestion(removingTokens: removingTokens) else { return nil }
        return TorrentAddNamingPlan(rootName: normalizedName, pathRenames: suggestion.pathRenames)
    }

    var fileSelection: TorrentAddFileSelection {
        let all = Set(draft.preview.files.indices)
        return TorrentAddFileSelection(
            filesWanted: selectedFileIndices.sorted(),
            filesUnwanted: all.subtracting(selectedFileIndices).sorted(),
            priorityHigh: priorityIndices(1),
            priorityNormal: priorityIndices(0),
            priorityLow: priorityIndices(-1)
        )
    }

    var selectionSummary: String {
        let size = selectedFileIndices.reduce(UInt64.zero) { $0 + draft.preview.files[$1].length }
        return "\(selectedFileIndices.count) of \(draft.preview.files.count), \(formatBytes(size))"
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

    func setFilePriority(_ index: Int, _ priority: Int) {
        filePriorities[index] = priority
    }

    private func priorityIndices(_ priority: Int) -> [Int] {
        draft.preview.files.indices.filter { filePriorities[$0] == priority }
    }

    func applySmartName(removingTokens: [String]) {
        if let suggestion = suggestion(removingTokens: removingTokens) {
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

private struct TorrentRenamePreview: View {
    let originalName: String
    let resultName: String
    let renames: [TorrentPathRename]

    var body: some View {
        DisclosureGroup("Review Name Changes") {
            VStack(alignment: .leading, spacing: 8) {
                if originalName != resultName {
                    changeRow(from: originalName, to: resultName)
                }

                ForEach(renames.prefix(6)) { rename in
                    changeRow(
                        from: URL(fileURLWithPath: rename.path).lastPathComponent,
                        to: rename.name
                    )
                }

                if renames.count > 6 {
                    Text("\(renames.count - 6) more file changes")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        }
    }

    private func changeRow(from original: String, to result: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(original)
                .foregroundStyle(.secondary)
                .strikethrough()
            Text(result)
        }
        .font(.callout)
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(original), changes to \(result)")
    }
}

private func cleanupTokens(from text: String) -> [String] {
    text.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

private enum BatchDestination: Hashable {
    case defaultLocation
    case directory(String)
    case other
}
