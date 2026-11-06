import AmbulandoCore
import SwiftUI

/// Account, connection, text size, sign-out and the deliberate "change family chat". Sign out only locks: the key, the
/// family chat choice and every saved message stay on the device. Removing the key is a separate, hidden, confirmed step.
struct FamilySettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(FamilyChatModel.self) private var family
    @Environment(\.dismiss) private var dismiss
    @AppStorage(FamilyTextSize.defaultsKey) private var textSize = FamilyTextSize.device.rawValue
    let binding: FamilyBinding?
    @State private var unsent = 0
    @State private var confirmChange = false
    @State private var confirmRemoveKey = false
    @State private var showAdvanced = false

    private var accountName: String {
        if let name = app.me.value?.person.name, !name.isEmpty { return name }
        return app.identity.npub.map(shortNpub) ?? "Not signed in"
    }

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
                    HStack(spacing: 12) {
                        if let person = app.me.value?.person { PersonAvatar(person: person) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(accountName).font(.amb(.headline))
                            if let npub = app.identity.npub { Text(shortNpub(npub)).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
                        }
                    }
                    LabeledContent("NStack", value: app.connection?.origin ?? "Not connected")
                    LabeledContent("Connection", value: app.connectionStatus.label)
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
                    Button("Sign out") { Task { await app.lock(); dismiss() } }.frame(minHeight: Amb.touchTarget)
                        .accessibilityIdentifier("family.settings.signout")
                    if binding != nil {
                        Button("Choose a different family chat") { confirmChange = true }.frame(minHeight: Amb.touchTarget)
                            .accessibilityIdentifier("family.settings.change")
                    }
                } footer: {
                    Text("Signing out keeps your key, your family chat and your saved messages on this device; you only need your PIN to come back. Choosing a different family chat only forgets which conversation is selected.")
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        Button("Remove my key from this device", role: .destructive) { confirmRemoveKey = true }.frame(minHeight: Amb.touchTarget)
                            .accessibilityIdentifier("family.settings.removekey")
                        Text("You will need your sign-in key (nsec1…) to sign in again. Saved messages and your family chat choice stay on the device.")
                            .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    }
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
                     : "\(unsent) \(unsent == 1 ? "message is" : "messages are") still waiting to be sent to this family chat. Let \(unsent == 1 ? "it" : "them") send first, or discard \(unsent == 1 ? "it" : "them") in the conversation.")
            }
            .confirmationDialog("Remove your key from this device?", isPresented: $confirmRemoveKey, titleVisibility: .visible) {
                Button("Remove my key", role: .destructive) { Task { await app.removeIdentity(); dismiss() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(unsent == 0 ? "You will need your sign-in key (nsec1…) to sign in again."
                     : "\(unsent) \(unsent == 1 ? "message has" : "messages have") not been sent yet and will wait on this device until you sign in again. You will need your sign-in key (nsec1…) to do that.")
            }
        }
    }
}
