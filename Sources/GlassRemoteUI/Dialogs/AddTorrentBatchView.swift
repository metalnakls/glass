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
    ) async -> Bool

    @Environment(\.dismiss) private var dismiss

    @State private var items: [TorrentBatchItemState]
    @State private var groups: [TorrentBatchGroup]
    @State private var selectedGroupID: String
    @State private var sourceID: UUID
    @State private var destination: BatchDestination = .defaultLocation
    @State private var defaultDownloadDirectory: String?
    @State private var customDownloadDirectory = ""
    @State private var isAdding = false
    @State private var isChoosingDownloadDirectory = false
    @State private var addErrorMessage: String?

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
        ) async -> Bool
    ) {
        self.model = model
        self.platformIntegration = platformIntegration
        self.drafts = drafts
        self.submit = submit

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
                        isAdding: isAdding
                    )
                    .tabItem {
                        Label(
                            group.displayName,
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
                let didAdd = await submit(
                    item.draft,
                    sourceID,
                    item.normalizedName,
                    downloadDirectory(for: group),
                    item.fileSelection,
                    namingPlan(for: item, in: group, offset: offset)
                )
                if didAdd {
                    item.wasAdded = true
                } else {
                    failures.append("\(item.normalizedName): \(model.errorMessage ?? "Glass couldn’t add this torrent.")")
                    model.errorMessage = nil
                }
            }
        }

        if failures.isEmpty {
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
        return (base as NSString).appendingPathComponent(group.displayName)
    }

    private func namingPlan(
        for item: TorrentBatchItemState,
        in group: TorrentBatchGroup,
        offset: Int
    ) -> TorrentAddNamingPlan? {
        guard group.isSeasonGroup else { return item.namingPlan }
        let pathRenames = item.isAutoCleanEnabled ? (item.suggestion?.pathRenames ?? []) : []
        return TorrentAddNamingPlan(
            rootName: "Season \(group.seasons[offset])",
            pathRenames: pathRenames
        )
    }
}

private struct TorrentBatchGroupEditor: View {
    let group: TorrentBatchGroup
    let items: [TorrentBatchItemState]
    let isAdding: Bool

    var body: some View {
        Form {
            if group.isSeasonGroup {
                Section {
                    Label(
                        "\(group.itemIndices.count) separate season torrents will stay grouped as \(group.displayName).",
                        systemImage: "rectangle.stack"
                    )
                } footer: {
                    Text("Each season remains independently controllable and seedable inside one \(group.displayName) folder.")
                }
            }

            ForEach(group.itemIndices, id: \.self) { index in
                TorrentBatchItemEditor(item: items[index], isAdding: isAdding)
            }
        }
        .formStyle(.grouped)
    }
}

private struct TorrentBatchItemEditor: View {
    @Bindable var item: TorrentBatchItemState
    let isAdding: Bool

    var body: some View {
        Section {
            LabeledContent("Name") {
                TextField("Name", text: $item.name)
                    .multilineTextAlignment(.trailing)
            }

            if let suggestion = item.suggestion {
                LabeledContent(item.isAutoCleanEnabled ? "Applied" : "Suggestion") {
                    HStack(spacing: 8) {
                        Text(suggestion.rootName)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(item.isAutoCleanEnabled ? "Undo" : "Use Suggestion") {
                            item.toggleSuggestion()
                        }
                    }
                }
            }

            DisclosureGroup("Files — \(item.selectionSummary)") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.draft.preview.files.enumerated()), id: \.offset) { index, file in
                        Toggle(isOn: item.fileSelectionBinding(for: index)) {
                            TorrentFileRowLabel(file: file)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .padding(.top, 8)
            }
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
}

@MainActor
@Observable
private final class TorrentBatchItemState {
    let draft: TorrentFileAddDraft
    var name: String
    var selectedFileIndices: Set<Int>
    var isAutoCleanEnabled: Bool
    var nameBeforeAutoClean: String?
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
        self.isAutoCleanEnabled = suggestion != nil
        self.nameBeforeAutoClean = suggestion == nil ? nil : draft.preview.name
    }

    var normalizedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var canAdd: Bool { !normalizedName.isEmpty && !selectedFileIndices.isEmpty }

    var suggestion: TorrentAddNamingPlan? {
        TorrentNameCleaner.plan(
            rootName: draft.preview.name,
            files: draft.preview.files,
            selectedFileIndices: selectedFileIndices
        )
    }

    var namingPlan: TorrentAddNamingPlan? {
        guard isAutoCleanEnabled, let suggestion else { return nil }
        return TorrentAddNamingPlan(rootName: normalizedName, pathRenames: suggestion.pathRenames)
    }

    var fileSelection: TorrentAddFileSelection {
        let all = Set(draft.preview.files.indices)
        return TorrentAddFileSelection(
            filesWanted: selectedFileIndices.sorted(),
            filesUnwanted: all.subtracting(selectedFileIndices).sorted()
        )
    }

    var selectionSummary: String {
        let size = selectedFileIndices.reduce(UInt64.zero) { $0 + draft.preview.files[$1].length }
        return "\(selectedFileIndices.count) of \(draft.preview.files.count), \(formatBytes(size))"
    }

    func fileSelectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { self.selectedFileIndices.contains(index) },
            set: { selected in
                if selected {
                    self.selectedFileIndices.insert(index)
                } else {
                    self.selectedFileIndices.remove(index)
                }
            }
        )
    }

    func toggleSuggestion() {
        if isAutoCleanEnabled {
            name = nameBeforeAutoClean ?? draft.preview.name
            nameBeforeAutoClean = nil
            isAutoCleanEnabled = false
        } else if let suggestion {
            nameBeforeAutoClean = name
            name = suggestion.rootName
            isAutoCleanEnabled = true
        }
    }

    func applySeasonDisplayName(_ title: String, season: Int) {
        nameBeforeAutoClean = draft.preview.name
        name = "\(title) \(season)"
        isAutoCleanEnabled = true
    }
}

private enum BatchDestination: Hashable {
    case defaultLocation
    case directory(String)
    case other
}
