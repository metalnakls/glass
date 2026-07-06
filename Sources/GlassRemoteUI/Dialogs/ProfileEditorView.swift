import GlassRemoteCore
import GlassRemoteServices
import SwiftUI

struct ProfileEditorView: View {
    @ObservedObject var model: RemoteAppModel
    @Environment(\.dismiss) private var dismiss

    @State private var profile: RemoteProfile
    @State private var urlText: String
    @State private var password: String
    @State private var isTesting = false
    @State private var testResult: Bool?

    init(model: RemoteAppModel, profile: RemoteProfile?) {
        self.model = model
        let profile = profile ?? RemoteProfile(
            name: "",
            rpcURL: URL(string: "http://localhost:9091/transmission/rpc")!,
            username: ""
        )
        _profile = State(initialValue: profile)
        _urlText = State(initialValue: profile.rpcURL.absoluteString)
        _password = State(initialValue: model.password(for: profile))
    }

    var body: some View {
        Form {
            TextField("Name", text: $profile.name)
            TextField("RPC URL", text: $urlText)
            TextField("User", text: $profile.username)
            SecureField("Password", text: $password)

            if let testResult {
                Label(
                    testResult ? "Connection succeeded" : "Connection failed",
                    systemImage: testResult ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(testResult ? .green : .secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 440)
        .navigationTitle(profile.name.isEmpty ? "New Server" : profile.name)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Test") {
                    Task { await testConnection() }
                }
                .disabled(!canSave || isTesting)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    save()
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
    }

    private var canSave: Bool {
        !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && URL(string: urlText) != nil
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

    private func save() {
        guard let profile = updatedProfile() else { return }
        model.saveProfile(profile, password: password)
    }

    private func testConnection() async {
        guard let profile = updatedProfile() else { return }
        isTesting = true
        testResult = await model.testConnection(profile: profile, password: password)
        isTesting = false
    }
}
