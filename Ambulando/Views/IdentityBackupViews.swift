import AmbulandoCore
import SwiftUI
import UniformTypeIdentifiers

/// An `ncryptsec` text file. Only ever written by an explicit user save; the app keeps no copy.
struct EncryptedBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws { text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self) }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data((text + "\n").utf8)) }
}

private let backupPasswordMinimum = 16

private struct BackupSavePanel: View {
    let backup: String
    var onExported: () -> Void
    @State private var saving = false
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(backup).font(Amb.code).textSelection(.enabled).padding(10)
                .background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                .accessibilityIdentifier("backup.text")
            Button("Copy backup") { Pasteboard.copy(backup); note = "Copied. Paste it somewhere safe; other apps can read the clipboard."; onExported() }
                .accessibilityIdentifier("backup.copy")
            Button("Save backup as a file…") { saving = true }.accessibilityIdentifier("backup.save")
            if let note { Text(note).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
        }
        .fileExporter(isPresented: $saving, document: EncryptedBackupFile(text: backup), contentType: .plainText, defaultFilename: "ambulando-key-backup") { result in
            switch result {
            case .success: note = "Saved."; onExported()
            case .failure(let error): note = "Not saved: \(error.localizedDescription)"
            }
        }
    }
}

/// Create a new identity: password → encrypted backup → save it → prove the password → PIN. The key reaches the vault only at
/// the last step, and only after the backup was saved and decrypted back to the same key.
struct NewIdentityView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private enum Step { case password, save, verify, pin }
    @State private var step = Step.password
    @State private var npub: String?
    @State private var password = ""
    @State private var confirm = ""
    @State private var backup: String?
    @State private var exported = false
    @State private var understood = false
    @State private var verifyPassword = ""
    @State private var pin = ""
    @State private var pinConfirm = ""
    @State private var working = false
    @State private var error: String?
    @State private var created = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let npub { Text("New public key: \(shortNpub(npub))").font(Amb.code).foregroundStyle(Amb.mutedForeground) }
                    switch step {
                    case .password: passwordStep
                    case .save: saveStep
                    case .verify: verifyStep
                    case .pin: pinStep
                    }
                    if let error { Notice(tone: .error, text: error) }
                    if let notice = model.notice { Notice(tone: .error, text: notice) }
                    Notice(tone: .warning, text: HostedBackup.requirementNotice)
                }
                .ambCard().padding(20)
            }
            .navigationTitle("New identity").inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task { await begin() }
            .onDisappear { password = ""; confirm = ""; verifyPassword = ""; pin = ""; pinConfirm = ""; backup = nil; if !created { Task { await model.discardNewIdentity() } } }
        }
    }

    private var passwordStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a backup password").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text("Your new key is made on this \(Device.name). Before it is used, it is encrypted with a password you choose into a backup (NIP-49 “ncryptsec”). No one can recover that password or the key for you.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            SecureField("Backup password (at least \(backupPasswordMinimum) characters)", text: $password).noCapitalization()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("newid.password")
            SecureField("Confirm backup password", text: $confirm).noCapitalization()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            Button { Task { await makeBackup() } } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Create encrypted backup")) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(npub == nil || password.count < backupPasswordMinimum || password != confirm || working)
                .accessibilityIdentifier("newid.makeBackup")
        }
    }

    private var saveStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save your backup").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text("Copy it or save it as a file somewhere you control, for example a password manager. Anyone with this backup and your password can use your identity; without both, nobody can restore it. \(Product.name) does not keep a copy.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            if let backup { BackupSavePanel(backup: backup) { exported = true; Task { await model.notePendingBackupExported() } } }
            Button("I saved it — continue") { step = .verify; error = nil }.buttonStyle(PrimaryButtonStyle()).disabled(!exported)
                .accessibilityIdentifier("newid.saved")
            if !exported { Text("Copy or save the backup first.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
        }
    }

    private var verifyStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Prove you can open it").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text("Type the backup password again. The app decrypts your backup and checks that it opens to this same identity.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            SecureField("Backup password", text: $verifyPassword).noCapitalization()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("newid.verify")
            Toggle("I stored the backup and its password where I can find them later. I understand nobody, including NStack, can recover them for me.", isOn: $understood)
                .font(.amb(.footnote)).accessibilityIdentifier("newid.understood")
            Button { Task { await verify() } } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Check backup")) }
                .buttonStyle(PrimaryButtonStyle()).disabled(!understood || verifyPassword.isEmpty || working)
                .accessibilityIdentifier("newid.check")
        }
    }

    private var pinStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose a PIN for this \(Device.name)").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text("The backup is confirmed. The PIN (with a device-only Keychain secret) unlocks the key on this \(Device.name) day to day.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            SecureField("PIN (4–12 digits)", text: $pin).numberPadEntry()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("newid.pin")
            SecureField("Confirm PIN", text: $pinConfirm).numberPadEntry()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
            Button { Task { await commit() } } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Create identity")) }
                .buttonStyle(PrimaryButtonStyle()).disabled(pin.count < 4 || pin != pinConfirm || working)
                .accessibilityIdentifier("newid.create")
        }
    }

    private func begin() async {
        guard npub == nil else { return }
        do { npub = try await model.beginNewIdentity() } catch { self.error = error.localizedDescription }
    }

    private func makeBackup() async {
        working = true; error = nil
        defer { working = false }
        do { backup = try await model.createPendingBackup(password: password); exported = false; step = .save }
        catch { self.error = error.localizedDescription }
    }

    private func verify() async {
        working = true; error = nil
        defer { working = false }
        do { try await model.acknowledgePendingBackup(password: verifyPassword); verifyPassword = ""; step = .pin }
        catch { self.error = error.localizedDescription }
    }

    private func commit() async {
        working = true; error = nil
        defer { working = false }
        if await model.commitNewIdentity(pin: pin) { created = true; pin = ""; pinConfirm = ""; dismiss() }
    }
}

/// Hosted backup step shown inside the onboarding wizard for an identity created in this app.
struct HostedBackupSection: View {
    let onboarding: OnboardingModel
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Save your hosted backup").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text(HostedBackup.requirementNotice).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Text(HostedBackup.residualRisk).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            TextField("Username (3–32: a–z, 0–9, - _)", text: $username).noCapitalization().autocorrectionDisabled()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("hosted.username")
            SecureField("Long, unique backup password (at least 16 characters)", text: $password).noCapitalization()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("hosted.password")
            SecureField("Confirm backup password", text: $confirmPassword).noCapitalization()
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("hosted.password.confirm")
            Button {
                working = true; error = nil
                Task {
                    do { try await onboarding.saveHostedBackup(username: username, password: password); password = ""; confirmPassword = "" }
                    catch { self.error = error.localizedDescription }
                    working = false
                }
            } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Save hosted backup")) }
                .buttonStyle(PrimaryButtonStyle()).disabled(username.count < 3 || password.count < backupPasswordMinimum || password != confirmPassword || working).accessibilityIdentifier("hosted.save")
            if let error { Notice(tone: .error, text: error) }
        }
        .onDisappear { password = ""; confirmPassword = "" }
    }
}

/// Restore an identity from an `ncryptsec` and its password.
struct ImportBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var password = ""
    @State private var pin = ""
    @State private var pinConfirm = ""
    @State private var working = false
    @State private var hostedOrigin = ""
    @State private var hostedName = ""
    @State private var fetchError: String?

    private var valid: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ncryptsec1") && !password.isEmpty && pin.count >= 4 && pin == pinConfirm }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Import an encrypted backup").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
                    Text("Paste the ncryptsec1… backup and its password. It is decrypted on this \(Device.name) only, then sealed with the PIN you choose. A wrong password or a changed backup imports nothing.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    DisclosureGroup("Fetch it from your NStack by username") {
                        TextField("https://your-tower.example", text: $hostedOrigin).urlEntry().autocorrectionDisabled()
                            .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                        TextField("Username", text: $hostedName).noCapitalization().autocorrectionDisabled()
                            .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                        Button("Fetch encrypted backup") {
                            Task {
                                do { text = try await model.fetchHostedBackup(origin: hostedOrigin, username: HostedBackupUsername.normalized(hostedName) ?? hostedName); fetchError = nil }
                                catch { fetchError = error.localizedDescription }
                            }
                        }.disabled(hostedOrigin.isEmpty || hostedName.isEmpty)
                        if let fetchError { Notice(tone: .error, text: fetchError) }
                        Text("Only the encrypted copy is downloaded. It opens with your backup password, here on this \(Device.name).").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                    }.font(.amb(.footnote))
                    TextField("ncryptsec1…", text: $text).noCapitalization().autocorrectionDisabled().font(Amb.code)
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("importbackup.text")
                    SecureField("Backup password", text: $password).noCapitalization()
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("importbackup.password")
                    SecureField("PIN for this \(Device.name) (4–12 digits)", text: $pin).numberPadEntry()
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                    SecureField("Confirm PIN", text: $pinConfirm).numberPadEntry()
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                    if let notice = model.notice { Notice(tone: .error, text: notice) }
                    Button {
                        working = true
                        Task {
                            let done = await model.importIdentityBackup(ncryptsec: text, password: password, pin: pin)
                            password = ""; pin = ""; pinConfirm = ""; working = false
                            if done { text = ""; dismiss() }
                        }
                    } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Decrypt and import")) }
                        .buttonStyle(PrimaryButtonStyle()).disabled(!valid || working).accessibilityIdentifier("importbackup.go")
                }
                .ambCard().padding(20)
            }
            .navigationTitle("Import backup").inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .onDisappear { password = ""; pin = ""; pinConfirm = "" }
        }
    }
}

/// Settings: an explicit, password-protected export of the unlocked identity. Nothing is copied or saved until the user chooses to.
struct ExportBackupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirm = ""
    @State private var backup: String?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Encrypted identity backup").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
                    Text("Creates a backup of your key (NIP-49 “ncryptsec”) under a password you choose. Anyone with the backup and password can use your identity. \(Product.name) keeps no copy and cannot recover either.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    if let backup {
                        BackupSavePanel(backup: backup) {}
                    } else {
                        SecureField("Backup password (at least \(backupPasswordMinimum) characters)", text: $password).noCapitalization()
                            .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl)).accessibilityIdentifier("exportbackup.password")
                        SecureField("Confirm backup password", text: $confirm).noCapitalization()
                            .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                        Button {
                            working = true; error = nil
                            Task {
                                do { backup = try await model.exportIdentityBackup(password: password); password = ""; confirm = "" }
                                catch { self.error = error.localizedDescription }
                                working = false
                            }
                        } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Create backup")) }
                            .buttonStyle(PrimaryButtonStyle()).disabled(password.count < backupPasswordMinimum || password != confirm || working)
                            .accessibilityIdentifier("exportbackup.go")
                    }
                    if let error { Notice(tone: .error, text: error) }
                    Text(HostedBackup.requirementNotice).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
                .ambCard().padding(20)
            }
            .navigationTitle("Identity backup").inlineTitle()
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .onDisappear { password = ""; confirm = ""; backup = nil }
        }
    }
}
