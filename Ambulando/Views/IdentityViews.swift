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
