import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct ProfileEditorView: View {
    let model: RemoteAppModel
    let platformIntegration: any GlassPlatformIntegrating
    @Environment(\.dismiss) private var dismiss

    @State private var profile: RemoteProfile
    @State private var urlText: String
    @State private var password: String
    @State private var isTesting = false
    @State private var testResult: Bool?
    @State private var mountedPath: String?
    @State private var mountedURL: URL?
    @State private var serverDownloadFolder: String
    @State private var linkError: String?
    @State private var isSaving = false

    init(model: RemoteAppModel, platformIntegration: any GlassPlatformIntegrating, profile: RemoteProfile?) {
        self.model = model
        self.platformIntegration = platformIntegration
        let profile = profile ?? RemoteProfile(
            name: "",
            rpcURL: URL(string: "http://localhost:9091/transmission/rpc")!,
            username: ""
        )
        _profile = State(initialValue: profile)
        _urlText = State(initialValue: profile.rpcURL.absoluteString)
        _password = State(initialValue: model.password(for: profile))
        let link = TorrentThumbnailService.shared.link(for: profile.id)
        _mountedPath = State(initialValue: link?.localPath)
        _serverDownloadFolder = State(initialValue: link?.remoteRoot ?? "")
    }

    var body: some View {
        Form {
            TextField(glassText("Name"), text: $profile.name)
            TextField(glassText("RPC URL"), text: $urlText)
            TextField(glassText("User"), text: $profile.username)
            SecureField(glassText("Password"), text: $password)

            Section(glassText("File Previews")) {
                if let mountedPath {
                    LabeledContent(glassText("Mounted Folder")) {
                        Text(mountedPath).lineLimit(1).truncationMode(.middle)
                        Button(glassText("Remove")) { self.mountedPath = nil; mountedURL = nil }
                    }
                    TextField(glassText("Server Folder"), text: $serverDownloadFolder)
                        .help("The server path that matches the mounted folder, such as /downloads.")
                }
                Button(glassText(mountedPath == nil ? "Link Mounted Folder…" : "Choose Another Folder…")) {
                    Task { await chooseMountedFolder() }
                }
                if let linkError { Text(linkError).foregroundStyle(.red) }
            }

            if let testResult {
                Label(
                    testResult ? "Connection succeeded" : "Connection failed",
                    systemImage: testResult ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(testResult ? .green : .secondary)
            }
        }
        .formStyle(.grouped)
        .disabled(isSaving)
        .navigationTitle(profile.name.isEmpty ? "New Server" : profile.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(glassText("Cancel")) {
                    dismiss()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button(glassText("Test")) {
                    Task { await testConnection() }
                }
                .disabled(!canSave || isTesting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(glassText("Save")) {
                    Task { await save() }
                }
                .disabled(!canSave || isSaving)
            }
        }
    }

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && URL(string: urlText) != nil
            && (mountedPath == nil || serverDownloadFolder.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/"))
    }

    private func updatedProfile() -> RemoteProfile? {
        guard let url = URL(string: urlText) else { return nil }
        return RemoteProfile(
            id: profile.id,
            name: profile.name.trimmingCharacters(in: .whitespacesAndNewlines),
            rpcURL: url,
            username: profile.username.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func chooseMountedFolder() async {
        do {
            guard let url = try await platformIntegration.chooseThumbnailDirectory() else { return }
            mountedURL = url
            mountedPath = url.path
            if serverDownloadFolder.isEmpty, model.profiles.contains(where: { $0.id == profile.id }) {
                serverDownloadFolder = await model.defaultDownloadDirectory(for: profile.id) ?? ""
            }
            linkError = nil
        } catch { linkError = error.localizedDescription }
    }

    private func save() async {
        guard let profile = updatedProfile() else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            let service = TorrentThumbnailService.shared
            let root = serverDownloadFolder.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mountedURL {
                try await service.setLink(sourceID: profile.id, remoteRoot: root, localURL: mountedURL)
            } else if mountedPath == nil, service.link(for: profile.id) != nil {
                try await service.setLink(sourceID: profile.id, remoteRoot: root, localURL: nil)
            } else if let previous = service.link(for: profile.id), previous.remoteRoot != root {
                try service.updateRemoteRoot(sourceID: profile.id, remoteRoot: root)
            }
        } catch { linkError = error.localizedDescription; return }
        model.saveProfile(profile, password: password)
        dismiss()
    }

    private func testConnection() async {
        guard let profile = updatedProfile() else { return }
        isTesting = true
        testResult = await model.testConnection(profile: profile, password: password)
        isTesting = false
    }
}
