import AppKit
import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct AddTorrentFileView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    let draft: TorrentFileAddDraft
    let submit: @MainActor (UUID, String, String?, TorrentAddFileSelection, TorrentAddNamingPlan?) async -> Bool

    @Environment(\.dismiss) private var dismiss

    @AppStorage("GlassList.showExtensions") private var showExtensions = false
    @State private var name: String
    @State private var selectedFileIndices: Set<Int>
    @State private var sourceID: UUID
    @State private var destination: Destination = .defaultLocation
    @State private var defaultDownloadDirectory: String?
    @State private var customDownloadDirectory = ""
    @State private var isAdding = false
    @State private var isChoosingDownloadDirectory = false
    @State private var isAutoCleanEnabled: Bool
    @State private var nameBeforeAutoClean: String?
    @State private var addErrorMessage: String?
    @State private var isExtensionWarningPresented = false

    init(
        model: RemoteAppModel,
        platformIntegration: any GlassPlatformIntegrating,
        draft: TorrentFileAddDraft,
        submit: @escaping @MainActor (UUID, String, String?, TorrentAddFileSelection, TorrentAddNamingPlan?) async -> Bool
    ) {
        self.model = model
        self.platformIntegration = platformIntegration
        self.draft = draft
        self.submit = submit
        let selectedFileIndices = Set(draft.preview.files.indices)
        let suggestion = TorrentNameCleaner.plan(
            rootName: draft.preview.name,
            files: draft.preview.files,
            selectedFileIndices: selectedFileIndices
        )
        _name = State(initialValue: suggestion?.suggestedName ?? draft.preview.name)
        _selectedFileIndices = State(initialValue: selectedFileIndices)
        _sourceID = State(initialValue: model.selectedSourceID)
        _isAutoCleanEnabled = State(initialValue: suggestion != nil)
        _nameBeforeAutoClean = State(initialValue: suggestion == nil ? nil : draft.preview.name)
    }

    var body: some View {
        Form {
            if let addErrorMessage {
                Section {
                    Label(addErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: {
                    Text(glassText("Couldn’t Add Torrent"))
                }
            }

            Section {
                LabeledContent(glassText("Name")) {
                    StemSelectingTextField(text: titleBinding, initialSelection: initialNameSelection)
                }

                if let suggestion = autoCleanSuggestion {
                    LabeledContent(isAutoCleanEnabled ? "Applied" : "Suggestion") {
                        HStack(spacing: 8) {
                            Text(TorrentExtensionPolicy.name(suggestion.suggestedName, hiding: showExtensions ? nil : TorrentExtensionPolicy.hiddenExtension(paths: draft.preview.files.map(\.name))))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Button(glassText(isAutoCleanEnabled ? "Undo" : "Use Suggestion")) {
                                toggleAutoCleanSuggestion(suggestion)
                            }
                        }
                    }
                }

                Picker(glassText("Add To"), selection: $sourceID) {
                    Label(model.localSourceName, systemImage: model.localSourceSystemImage)
                        .tag(model.localSourceID)

                    ForEach(model.profiles) { profile in
                        Label(profile.name, systemImage: "server.rack")
                            .tag(profile.id)
                    }
                }

                LabeledContent(glassText("Download Location")) {
                    downloadLocationMenu
                }

                if destination == .other {
                    TextField(glassText("Path"), text: $customDownloadDirectory)
                }
            }

            if isAutoCleanEnabled, autoCleanSuggestion != nil {
                Section {
                    if let plan = resolvedAutoCleanPlan {
                        ForEach(plan.pathRenames.prefix(5)) { rename in
                            namingPreview("File", from: rename.path, to: rename.name)
                        }
                        if plan.pathRenames.count > 5 {
                            Text("\(plan.pathRenames.count - 5) more file names")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(glassText("File Name Suggestions"))
                } footer: {
                    Text(glassText("Suggested file names are applied only when you add the torrent. Choose Undo to restore the name you entered."))
                }
            }

            Section {
                ForEach(Array(draft.preview.files.enumerated()), id: \.offset) { index, file in
                    Toggle(isOn: fileSelectionBinding(for: index)) {
                        TorrentFileRowLabel(file: file)
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isAdding)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text(glassText("Files"))

                    Text(selectionSummary)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button(glassText("All")) {
                        selectedFileIndices = Set(draft.preview.files.indices)
                    }
                    .disabled(selectedFileIndices.count == draft.preview.files.count || isAdding)

                    Button(glassText("None")) {
                        selectedFileIndices.removeAll()
                    }
                    .disabled(selectedFileIndices.isEmpty || isAdding)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(glassText("Add Torrent"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(glassText("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isAdding)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(glassText("Add")) {
                    requestAdd()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 500, idealHeight: 560)
        .containerBackground(.thinMaterial, for: .window)
        .alert(glassText("Change File Extension?"), isPresented: $isExtensionWarningPresented) {
            Button("Keep .\(originalExtension)", role: .cancel) {}
            Button(glassText(newExtension.isEmpty ? "Use Without Extension" : "Use .\(newExtension)")) {
                Task { await add() }
            }
        } message: {
            Text(glassText("If you change or remove the extension, the file may open in a different application."))
        }
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

    private var downloadLocationMenu: some View {
        Menu {
            Button {
                destination = .defaultLocation
            } label: {
                locationMenuLabel(defaultLocationLabel, selected: destination == .defaultLocation)
            }

            if !favoriteDirectories.isEmpty {
                Section(glassText("Favorites")) {
                    ForEach(favoriteDirectories, id: \.self) { directory in
                        Button {
                            destination = .directory(directory)
                        } label: {
                            locationMenuLabel(displayName(for: directory), selected: destination == .directory(directory))
                        }
                        .help(directory)
                    }
                }
            }

            if !recentDirectories.isEmpty {
                Section(glassText("Recent")) {
                    ForEach(recentDirectories, id: \.self) { directory in
                        Button {
                            destination = .directory(directory)
                        } label: {
                            locationMenuLabel(displayName(for: directory), selected: destination == .directory(directory))
                        }
                        .help(directory)
                    }
                }
            }

            Divider()

            if isLocalDestination {
                Button(glassText("Choose…"), systemImage: "folder") {
                    Task { await chooseDownloadDirectory() }
                }
                .disabled(isChoosingDownloadDirectory || isAdding)
            } else {
                Button(glassText("Other Path…"), systemImage: "folder.badge.plus") {
                    destination = .other
                }
            }

            if resolvedDownloadDirectory != nil {
                Divider()
                Button(
                    isCurrentDownloadDirectoryFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isCurrentDownloadDirectoryFavorite ? "star.slash" : "star"
                ) {
                    toggleFavoriteDownloadDirectory()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selectedLocationLabel)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.borderlessButton)
        .help(selectedLocationHelp)
    }

    private func locationMenuLabel(_ title: String, selected: Bool) -> some View {
        Label(title, systemImage: selected ? "checkmark" : "folder")
    }

    private var normalizedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canAdd: Bool {
        !normalizedName.isEmpty
            && !selectedFileIndices.isEmpty
            && resolvedDownloadDirectoryIsValid
            && !isAdding
    }

    private var originalExtension: String {
        guard draft.preview.files.count == 1 else { return "" }
        return URL(fileURLWithPath: draft.preview.name).pathExtension
    }

    private var titleBinding: Binding<String> {
        let suffix = showExtensions ? nil : TorrentExtensionPolicy.hiddenExtension(paths: draft.preview.files.map(\.name))
        return Binding(get: { TorrentExtensionPolicy.name(name, hiding: suffix) },
                       set: { name = TorrentExtensionPolicy.editedName($0, original: name, hiding: suffix) })
    }

    private var initialNameSelection: NSRange {
        let fullLength = (draft.preview.name as NSString).length
        guard !originalExtension.isEmpty else { return NSRange(location: 0, length: fullLength) }
        return NSRange(
            location: 0,
            length: max(0, fullLength - (originalExtension as NSString).length - 1)
        )
    }

    private var newExtension: String {
        URL(fileURLWithPath: normalizedName).pathExtension
    }

    private var changesExtension: Bool {
        !originalExtension.isEmpty && originalExtension.caseInsensitiveCompare(newExtension) != .orderedSame
    }

    private var resolvedDownloadDirectoryIsValid: Bool {
        if destination == .other {
            return !customDownloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private var favoriteDirectories: [String] {
        model.favoriteDownloadDirectories(for: sourceID)
    }

    private var recentDirectories: [String] {
        var directories: [String] = []
        for directory in model.downloadDirectories(for: sourceID) {
            let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                !trimmed.isEmpty,
                trimmed != defaultDownloadDirectory,
                !favoriteDirectories.contains(trimmed),
                !directories.contains(trimmed)
            else {
                continue
            }
            directories.append(trimmed)
        }
        return directories
    }

    private var defaultLocationLabel: String {
        guard let defaultDownloadDirectory, !defaultDownloadDirectory.isEmpty else {
            return "Default"
        }
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

    private var selectedLocationHelp: String {
        resolvedDownloadDirectory ?? defaultDownloadDirectory ?? "Use the host’s default download location"
    }

    private func displayName(for directory: String) -> String {
        let name = URL(fileURLWithPath: directory).lastPathComponent
        return name.isEmpty ? directory : name
    }

    private var resolvedDownloadDirectory: String? {
        switch destination {
        case .defaultLocation:
            return nil
        case let .directory(directory):
            return directory
        case .other:
            let directory = customDownloadDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            return directory.isEmpty ? nil : directory
        }
    }

    private var isLocalDestination: Bool {
        sourceID == model.localSourceID
    }

    private var isCurrentDownloadDirectoryFavorite: Bool {
        guard let directory = resolvedDownloadDirectory else { return false }
        return favoriteDirectories.contains(directory)
    }

    private var fileSelection: TorrentAddFileSelection {
        let allIndices = Set(draft.preview.files.indices)
        return TorrentAddFileSelection(
            filesWanted: selectedFileIndices.sorted(),
            filesUnwanted: allIndices.subtracting(selectedFileIndices).sorted()
        )
    }

    private var autoCleanSuggestion: TorrentAddNamingPlan? {
        TorrentNameCleaner.plan(
            rootName: draft.preview.name,
            files: draft.preview.files,
            selectedFileIndices: selectedFileIndices
        )
    }

    private var resolvedAutoCleanPlan: TorrentAddNamingPlan? {
        guard isAutoCleanEnabled, let suggestion = autoCleanSuggestion else { return nil }
        return suggestion.withDisplayName(normalizedName)
    }

    private func namingPreview(_ kind: String, from oldName: String, to newName: String) -> some View {
        LabeledContent(kind) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(oldName)
                    .foregroundStyle(.secondary)
                    .strikethrough()
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(newName)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    private var selectionSummary: String {
        let selectedSize = selectedFileIndices.reduce(UInt64.zero) { partialResult, index in
            partialResult + draft.preview.files[index].length
        }
        return "\(selectedFileIndices.count) of \(draft.preview.files.count), \(formatBytes(selectedSize))"
    }

    private func fileSelectionBinding(for index: Int) -> Binding<Bool> {
        Binding(
            get: { selectedFileIndices.contains(index) },
            set: { isSelected in
                if isSelected {
                    selectedFileIndices.insert(index)
                } else {
                    selectedFileIndices.remove(index)
                }
            }
        )
    }

    private func add() async {
        guard canAdd else { return }
        addErrorMessage = nil
        isAdding = true
        let destinationSource = sourceID
        model.prepareTorrentAddition(id: draft.id, sourceID: destinationSource, name: normalizedName,
            size: draft.preview.size, fileCount: draft.preview.files.count,
            downloadDirectory: resolvedDownloadDirectory,
            namingPlan: resolvedAutoCleanPlan ?? (normalizedName == draft.preview.name ? nil : TorrentAddNamingPlan(rootName: normalizedName, pathRenames: [])),
            data: draft.data, fileSelection: fileSelection, sourceURL: draft.sourceURL, trashSourceOnSuccess: true,
            renameDuplicateRoot: resolvedAutoCleanPlan == nil && normalizedName != draft.preview.name)
        model.selectedProfileID = destinationSource
        model.selectedTorrentGroup = .all
        dismiss()
        _ = await submit(destinationSource, normalizedName, resolvedDownloadDirectory, fileSelection, resolvedAutoCleanPlan)

    }

    private func requestAdd() {
        guard canAdd else { return }
        if changesExtension {
            isExtensionWarningPresented = true
        } else {
            Task { await add() }
        }
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

    private func toggleFavoriteDownloadDirectory() {
        guard let directory = resolvedDownloadDirectory else { return }
        model.setDownloadDirectory(
            directory,
            isFavorite: !isCurrentDownloadDirectoryFavorite,
            for: sourceID
        )
    }

    private func toggleAutoCleanSuggestion(_ suggestion: TorrentAddNamingPlan) {
        if isAutoCleanEnabled {
            name = nameBeforeAutoClean ?? draft.preview.name
            nameBeforeAutoClean = nil
            isAutoCleanEnabled = false
        } else {
            nameBeforeAutoClean = name
            name = suggestion.suggestedName
            isAutoCleanEnabled = true
        }
    }
}

struct TorrentFileAddDraft: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    let preview: TorrentFilePreview
    let sourceURL: URL

    @concurrent
    static func load(from url: URL) async throws -> Self {
        try Task.checkCancellation()
        let didAccess = url.startAccessingSecurityScopedResource()
        defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let preview = TorrentFilePreview(data: data, fallbackURL: url)
        try Task.checkCancellation()
        return Self(data: data, preview: preview, sourceURL: url)
    }
}

private enum Destination: Hashable {
    case defaultLocation
    case directory(String)
    case other
}
