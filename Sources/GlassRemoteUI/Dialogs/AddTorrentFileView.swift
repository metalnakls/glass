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

    @State private var name: String
    @State private var selectedFileIndices: Set<Int>
    @State private var sourceID: UUID
    @State private var destination: Destination = .defaultLocation
    @State private var defaultDownloadDirectory: String?
    @State private var customDownloadDirectory = ""
    @State private var isAdding = false
    @State private var isChoosingDownloadDirectory = false
    @State private var isAutoCleanEnabled = false
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
        _name = State(initialValue: draft.preview.name)
        _selectedFileIndices = State(initialValue: Set(draft.preview.files.indices))
        _sourceID = State(initialValue: model.selectedSourceID)
    }

    var body: some View {
        Form {
            if let addErrorMessage {
                Section {
                    Label(addErrorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                } header: {
                    Text("Couldn’t Add Torrent")
                }
            }

            Section {
                LabeledContent("Name") {
                    StemSelectingTextField(text: $name, initialSelection: initialNameSelection)
                }

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

            if autoCleanSuggestion != nil {
                Section {
                    Toggle("Auto Clean Names", isOn: $isAutoCleanEnabled)

                    if isAutoCleanEnabled, let plan = resolvedAutoCleanPlan {
                        namingPreview("Torrent", from: draft.preview.name, to: plan.rootName)
                        ForEach(plan.pathRenames.prefix(5)) { rename in
                            namingPreview("File", from: rename.path, to: rename.name)
                        }
                        if plan.pathRenames.count > 5 {
                            Text("\(plan.pathRenames.count - 5) more file names")
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Names")
                } footer: {
                    Text("Suggested. Nothing changes until you enable Auto Clean and add the torrent.")
                }
            }

            Section {
                ForEach(Array(draft.preview.files.enumerated()), id: \.offset) { index, file in
                    Toggle(isOn: fileSelectionBinding(for: index)) {
                        HStack(spacing: 12) {
                            Text(file.name)
                                .lineLimit(1)
                                .truncationMode(.middle)

                            Spacer(minLength: 12)

                            Text(formatBytes(file.length))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .toggleStyle(.checkbox)
                    .disabled(isAdding)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Files")

                    Text(selectionSummary)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Button("All") {
                        selectedFileIndices = Set(draft.preview.files.indices)
                    }
                    .disabled(selectedFileIndices.count == draft.preview.files.count || isAdding)

                    Button("None") {
                        selectedFileIndices.removeAll()
                    }
                    .disabled(selectedFileIndices.isEmpty || isAdding)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Add Torrent")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isAdding)
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    requestAdd()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canAdd)
            }
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 500, idealHeight: 560)
        .containerBackground(.thinMaterial, for: .window)
        .alert("Change File Extension?", isPresented: $isExtensionWarningPresented) {
            Button("Keep .\(originalExtension)", role: .cancel) {}
            Button(newExtension.isEmpty ? "Use Without Extension" : "Use .\(newExtension)") {
                Task { await add() }
            }
        } message: {
            Text("If you change or remove the extension, the file may open in a different application.")
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
        .onChange(of: isAutoCleanEnabled) { _, isEnabled in
            if isEnabled, let suggestion = autoCleanSuggestion {
                name = suggestion.rootName
            }
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
                Section("Favorites") {
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
                Section("Recent") {
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
                Button("Choose…", systemImage: "folder") {
                    Task { await chooseDownloadDirectory() }
                }
                .disabled(isChoosingDownloadDirectory || isAdding)
            } else {
                Button("Other Path…", systemImage: "folder.badge.plus") {
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
        return TorrentAddNamingPlan(rootName: normalizedName, pathRenames: suggestion.pathRenames)
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
        let didAdd = await submit(
            sourceID,
            normalizedName,
            resolvedDownloadDirectory,
            fileSelection,
            resolvedAutoCleanPlan
        )
        isAdding = false
        if didAdd {
            dismiss()
        } else {
            addErrorMessage = model.errorMessage ?? "Glass couldn’t add this torrent."
            model.errorMessage = nil
        }
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
}

struct TorrentFileAddDraft: Identifiable, Sendable {
    let id = UUID()
    let data: Data
    let preview: TorrentFilePreview
    let sourceURL: URL
}

private enum Destination: Hashable {
    case defaultLocation
    case directory(String)
    case other
}
