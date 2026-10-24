import SwiftUI

/// Explicit identity import. The user pastes their own nsec; the app never searches for or reads
/// keys held by other apps or the browser. The scalar is sealed with the PIN + a device-only Keychain secret.
struct ImportIdentityView: View {
    @Environment(AppModel.self) private var model
    @State private var nsec = ""
    @State private var pin = ""
    @State private var confirm = ""
    @State private var working = false

    private var valid: Bool { nsec.hasPrefix("nsec1") && pin.count >= 4 && pin == confirm }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                BrandHeader(subtitle: "Solvitur ambulando — it is solved by walking.")
                    .padding(.top, 32)
                VStack(alignment: .leading, spacing: 12) {
                    Text("Import your identity").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
                    Text("Paste the nsec you use with Ambulando. It is encrypted on this iPhone with your PIN and a device-only Keychain secret, and never leaves this app.")
                        .font(.footnote).foregroundStyle(Amb.mutedForeground)
                    SecureField("nsec1…", text: $nsec)
                        .textContentType(.password).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .font(Amb.code).padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                    SecureField("PIN (4–12 digits)", text: $pin).keyboardType(.numberPad)
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                    SecureField("Confirm PIN", text: $confirm).keyboardType(.numberPad)
                        .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                    if let notice = model.notice { Notice(tone: .error, text: notice) }
                    Button {
                        working = true
                        Task {
                            await model.importIdentity(nsec: nsec, pin: pin)
                            nsec = ""; pin = ""; confirm = ""; working = false
                        }
                    } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Import and encrypt")) }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(!valid || working)
                }
                .ambCard()
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
    }
}

struct UnlockView: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    var embedded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !embedded { BrandHeader(subtitle: model.identity.npub.map(shortNpub)).padding(.top, 48) }
            VStack(alignment: .leading, spacing: 12) {
                Text("Unlock to sync").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
                Text("Your cached workspace stays readable while locked. Unlocking lets Ambulando sign requests to your Tower.")
                    .font(.footnote).foregroundStyle(Amb.mutedForeground)
                SecureField("PIN", text: $pin).keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                if let notice = model.notice { Notice(tone: .error, text: notice) }
                Button {
                    working = true
                    Task { await model.unlock(pin: pin); pin = ""; working = false }
                } label: { working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Unlock")) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(pin.count < 4 || working)
            }
            .ambCard()
            if !embedded { Spacer() }
        }
        .padding(20)
    }
}

func shortNpub(_ npub: String) -> String { npub.count > 20 ? "\(npub.prefix(12))…\(npub.suffix(6))" : npub }

/// Full-screen unlock shown whenever an existing identity is locked (relaunch after Lock now, a new device session,
/// or a disconnect). The PIN field is focused at once; a wrong PIN says so and keeps the field ready for another try.
/// The workspace behind it is not shown, and nothing is lost: selection, navigation, drafts and unsent messages
/// return when it opens. Once unlocked, the app stays unlocked on this iPhone until Lock now.
struct LockScreen: View {
    @Environment(AppModel.self) private var model
    @State private var pin = ""
    @State private var working = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                PassageMark(size: 88)
                Text("Ambulando").font(.system(.largeTitle, design: .serif).weight(.semibold)).foregroundStyle(Amb.foreground)
                Text("Locked").font(.headline).foregroundStyle(Amb.itemHeading).accessibilityIdentifier("lock.screen")
                if let npub = model.identity.npub {
                    Text(shortNpub(npub)).font(Amb.code).foregroundStyle(Amb.mutedForeground)
                }
            }
            VStack(spacing: 12) {
                SecureField("PIN", text: $pin)
                    .keyboardType(.numberPad).textContentType(.oneTimeCode)
                    .multilineTextAlignment(.center).font(.title3.monospacedDigit())
                    .padding(12).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                    .focused($focused)
                    .submitLabel(.go)
                    .onSubmit(unlock)
                    .accessibilityIdentifier("lock.pin")
                if let notice = model.notice { Notice(tone: .error, text: notice).accessibilityIdentifier("lock.error") }
                Button(action: unlock) {
                    working ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Unlock"))
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(pin.count < 4 || working)
                .accessibilityIdentifier("lock.unlock")
                Text("Enter your PIN to open your workspaces. Ambulando stays unlocked on this iPhone until you choose Lock now.")
                    .font(.footnote).foregroundStyle(Amb.mutedForeground).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Amb.background.ignoresSafeArea())
        .onAppear { focused = true }
    }

    private func unlock() {
        guard pin.count >= 4, !working else { return }
        working = true
        Task {
            await model.unlock(pin: pin)
            pin = ""
            working = false
            focused = true
        }
    }
}

/// The identity is on this iPhone but cannot be read right now: the app was started while the iPhone was locked (the
/// sealed vault and the session key open only after unlocking), or the vault file is damaged. Nothing is imported,
/// replaced or deleted from here; the app reads it again as soon as iOS allows.
struct IdentityUnavailableView: View {
    @Environment(AppModel.self) private var model
    @State private var checking = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                PassageMark(size: 88)
                Text("Ambulando").font(.system(.largeTitle, design: .serif).weight(.semibold)).foregroundStyle(Amb.foreground)
                Text("Your identity is on this iPhone").font(.headline).foregroundStyle(Amb.itemHeading)
                    .accessibilityIdentifier("identity.unavailable")
            }
            VStack(spacing: 12) {
                Text(model.vaultProblem == .damaged
                     ? "The identity file on this iPhone could not be opened: it looks damaged. It has been left exactly as it is, together with your Tower connection and saved work. Nothing was replaced."
                     : "It can't be opened right now. This happens when Ambulando was started while the iPhone was locked. Your key, Tower connection and saved work are kept; nothing needs to be imported again.")
                    .font(.callout).foregroundStyle(Amb.foreground).multilineTextAlignment(.center)
                    .accessibilityIdentifier(model.vaultProblem == .damaged ? "identity.damaged" : "identity.sealed")
                Button {
                    checking = true
                    Task { await model.refreshIdentityAvailability(); checking = false }
                } label: { checking ? AnyView(ProgressView().tint(Amb.primaryForeground)) : AnyView(Text("Try again")) }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(checking)
                .accessibilityIdentifier("identity.retry")
                Text("If this stays after unlocking your iPhone, the identity file may be damaged. Leave it in place and contact support; do not remove the app.")
                    .font(.footnote).foregroundStyle(Amb.mutedForeground).multilineTextAlignment(.center)
            }
            .frame(maxWidth: 360)
            Spacer()
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Amb.background.ignoresSafeArea())
    }
}
