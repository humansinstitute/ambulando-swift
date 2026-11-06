import AmbulandoCore
import SwiftUI

/// Account, connection, text size, lock, sign-out and the deliberate "change family chat". Nothing here deletes cached
/// messages or drafts; the destructive-looking actions say exactly what they keep.
struct FamilySettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FamilyTextSize.defaultsKey) private var textSize = FamilyTextSize.device.rawValue
    let binding: FamilyBinding?
    @State private var unsent = 0
    @State private var confirmChange = false
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                if let binding {
                    Section("Your family chat") {
                        LabeledContent("Space", value: binding.workspaceLabel)
                        LabeledContent("Channel", value: binding.channelName)
                        LabeledContent("Conversation", value: binding.conversationTitle)
                    }
                }
                Section("Account and connection") {
                    LabeledContent("Account", value: app.identity.npub.map(shortNpub) ?? "Not signed in")
                    LabeledContent("Tower", value: app.connection?.origin ?? "Not connected")
                    LabeledContent("Status", value: app.connectionStatus.label)
                    Button("Check the connection") { app.retryConnection() }.frame(minHeight: Amb.touchTarget)
                }
                Section("Text size") {
                    Picker("Text size", selection: $textSize) {
                        ForEach(FamilyTextSize.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline).labelsHidden()
                    Text("The quick brown fox jumps over the lazy dog.").font(.amb(.body))
                }
                Section {
                    Button("Lock Grandparent Chat") { Task { await app.lock(); dismiss() } }.frame(minHeight: Amb.touchTarget)
                    if binding != nil {
                        Button("Choose a different family chat") { confirmChange = true }.frame(minHeight: Amb.touchTarget)
                            .accessibilityIdentifier("family.settings.change")
                    }
                    Button("Sign out of this device", role: .destructive) { confirmSignOut = true }.frame(minHeight: Amb.touchTarget)
                        .accessibilityIdentifier("family.settings.signout")
                } footer: {
                    Text("Locking keeps everything and asks for your PIN next time. Choosing a different family chat only forgets which conversation is selected.")
                }
                Section("About") {
                    LabeledContent("Version", value: AppModel.versionLabel)
                }
            }
            .navigationTitle("Settings").inlineTitle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.font(.amb(.body).weight(.semibold)) } }
            .task { unsent = await app.unsentCount() }
            .confirmationDialog("Choose a different family chat?", isPresented: $confirmChange, titleVisibility: .visible) {
                if unsent == 0 { Button("Choose again") { Task { await family.forgetChoice(); dismiss() } } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(unsent == 0 ? "Messages and drafts already on this device stay where they are."
                     : "\(unsent) \(unsent == 1 ? "message is" : "messages are") still waiting to be sent to this family chat. Let them send (or discard them in the conversation) first.")
            }
            .confirmationDialog("Sign out of this device?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await app.removeIdentity(); dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(unsent == 0 ? "Your key is removed from this device. You will need your nsec to sign in again. Your family chat choice and saved messages stay on the device."
                     : "\(unsent) \(unsent == 1 ? "message has" : "messages have") not been sent yet and will wait until you sign in again. Your key is removed from this device; you will need your nsec to sign in again.")
            }
        }
    }
}
