import AmbulandoCore
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A QR code of exactly the text given, drawn crisp (no interpolation).
struct QRCodeView: View {
    let text: String
    var body: some View {
        if let image = Self.render(text) {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().scaledToFit()
                .padding(8).background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("QR code of the Lightning invoice")
        }
    }
    static func render(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

/// What NStack reports about one Lightning quote, with the exact invoice only when it is consistent and still payable. Presentation only:
/// nothing here decides that money arrived.
struct LightningQuoteCard: View {
    let quote: LightningQuote
    let invoice: PayableInvoice?
    let usdLabel: String
    let open: (URL) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            stateNotice
            if let invoice {
                LabeledContent("Amount", value: usdLabel)
                LabeledContent("Pay exactly", value: "\(invoice.sats.formatted()) sats")
                if let rate = quote.rate { LabeledContent("Rate", value: "\(rate.source), quoted \(Self.time(rate.quoted_at))") }
                LabeledContent("Invoice expires", value: invoice.expiry.formatted(date: .abbreviated, time: .standard))
                if Date() >= invoice.expiry {
                    Notice(tone: .warning, text: "The invoice's stated expiry has passed. Do not pay it. NStack has not confirmed it closed yet: check again, and it will say when it is.")
                } else {
                    QRCodeView(text: invoice.invoice.uppercased()).frame(maxWidth: 240).frame(maxWidth: .infinity)
                    Text(invoice.invoice).font(Amb.code).textSelection(.enabled).lineLimit(4).truncationMode(.middle)
                        .accessibilityIdentifier("lightning.invoice")
                    HStack {
                        Button(copied ? "Copied" : "Copy invoice") { Pasteboard.copy(invoice.invoice); copied = true }
                            .accessibilityIdentifier("lightning.copy")
                        Button("Open in wallet") { open(invoice.walletURL) }.accessibilityIdentifier("lightning.openWallet")
                    }
                }
            }
        }
    }

    @ViewBuilder private var stateNotice: some View {
        switch quote.state {
        case .open, .issuing: EmptyView()
        case .settled: Notice(tone: .success, text: "NStack reports this payment as verified.")
        case .expired, .cancelled: Notice(tone: .info, text: "NStack confirmed this invoice can no longer be paid.")
        case .latePayment, .mismatch, .unknown:
            Notice(tone: .warning, text: "NStack recorded a payment on this invoice that it did not credit automatically. Do not pay again. Contact support and quote this reference: \(quote.id).")
        }
    }

    static func time(_ text: String) -> String { NStackDateDisplay.format(text) }
}

enum NStackDateDisplay {
    static func format(_ text: String) -> String {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: text) ?? { f.formatOptions = [.withInternetDateTime]; return f.date(from: text) }()
        return date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? text
    }
}

/// Settings entry for manual account top-ups on the connected NStack.
struct TopupEntry: View {
    @Environment(AppModel.self) private var model
    var origin: String
    @State private var flow: TopupModel?
    @State private var error: String?

    var body: some View {
        Button("Add credit to your account…") {
            do { flow = try model.makeTopup(origin: origin); error = nil } catch { self.error = error.localizedDescription }
        }
        .disabled(!model.onboardingAvailable || origin.isEmpty)
        .accessibilityIdentifier("topup.start")
        if let error { Notice(tone: .error, text: error) }
        Color.clear.frame(height: 0).sheet(item: $flow) { flow in
            NavigationStack { TopupFlowView(topup: flow) }
        }
    }
}

extension TopupModel: Identifiable { nonisolated var id: String { "topup|\(origin.description)|\(signerNpub)" } }

struct TopupFlowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let topup: TopupModel
    @State private var choice = OnboardingFunding.presetsCents[0]
    @State private var custom = false
    @State private var customDollars = ""
    @State private var busy = false

    private var snap: TopupSnapshot { topup.snapshot }
    private var amountCents: Int? { custom ? snap.limits.cents(fromDollars: customDollars) : (snap.limits.valid(choice) ? choice : nil) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let failure = snap.failure { Notice(tone: .error, text: failure.localizedDescription) }
                if let notice = snap.notice { Notice(tone: .info, text: notice) }
                content.ambCard()
                if !snap.needsSupport.isEmpty { support }
                credited
            }
            .padding(20)
        }
        .navigationTitle("Add credit").inlineTitle()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await topup.load(); seed() }
        .onChange(of: scenePhase) { _, phase in if phase == .active, snap.phase == .ready { Task { await topup.refresh() } } }
        .onOpenURL { url in Task { await topup.paymentReturned(url) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Signed in as \(shortNpub(topup.signerNpub))").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Text(topup.origin.description).font(Amb.code).foregroundStyle(Amb.mutedForeground)
            if let account = snap.overview?.account {
                LabeledContent("Balance", value: "US$\(account.balance_usd)")
                LabeledContent("Paid credit", value: "US$\(account.paid_usd)")
                if account.promo_usd != "0.00" { LabeledContent("Promotional credit", value: "US$\(account.promo_usd)") }
            }
            if snap.overview?.funding?.hasDebt == true {
                Notice(tone: .warning, text: "A refund or dispute left a shortfall on this account. NStack applies any top-up to that first.")
            } else if let open = snap.overview?.funding?.open_cents, open > 0 {
                Notice(tone: .info, text: "A refund or dispute of \(OnboardingFunding.label(cents: open)) is still open at NStack.")
            }
            if let state = snap.overview?.lifecycle, state.state == "read_only", let ro = state.read_only {
                Notice(tone: .warning, text: "This account is read-only with \(ro.days_remaining) day\(ro.days_remaining == 1 ? "" : "s") left before removal becomes due. A top-up resumes charging from then on, with no back-charge. Nothing is deleted automatically.")
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch snap.phase {
        case .checking: ProgressView("Checking this NStack…")
        case .unavailable(let why): unavailable(why)
        case .ready: if snap.attempt != nil { attempt } else { chooser }
        }
    }

    private func unavailable(_ why: TopupUnavailability) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not available here").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text(Self.explanation(why)).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Button("Check again") { run { await topup.load() } }.disabled(busy)
        }
    }

    private static func explanation(_ why: TopupUnavailability) -> String {
        switch why {
        case .originRejected(let m): "This address did not check out as the NStack it claims to be (\(m)). No signed request was sent to it."
        case .backendMissing: "This NStack does not offer account top-ups."
        case .rolloutDisabled: "Top-ups are currently unavailable on this NStack. Nothing was sent or charged."
        case .notProvisioned: "Top-ups open once your first workspace has been created on this NStack."
        case .signerRefused: "NStack did not accept this identity's signature."
        case .signerMismatch: "The unlocked identity is not the one this top-up belongs to. No request was signed or sent for it."
        case .identityLocked: "Unlock your identity to continue."
        case .loadFailed: "NStack could not be read just now. Nothing was sent. Check again."
        case .draftUnreadable: "A saved payment attempt on this device could not be read. Nothing was sent and no new payment can be started until it is understood; contact support."
        }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add credit").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text("One payment, added to your account balance. No fee, no subscription, no automatic top-up; it does not create a workspace.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Picker("Amount", selection: Binding(get: { custom ? -1 : choice }, set: { v in if v == -1 { custom = true } else { custom = false; choice = v } })) {
                ForEach(snap.limits.presetsCents, id: \.self) { Text(OnboardingFunding.label(cents: $0)).tag($0) }
                Text("Custom").tag(-1)
            }.pickerStyle(.segmented)
            if custom {
                TextField("US$ amount, at least \(snap.limits.minCents / 100)", text: $customDollars).decimalEntry()
                    .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                if amountCents == nil {
                    Text("Enter an amount from \(OnboardingFunding.label(cents: snap.limits.minCents)) to \(OnboardingFunding.label(cents: snap.limits.maxCents)), whole or two decimals.")
                        .font(.amb(.caption)).foregroundStyle(Amb.destructive)
                }
            }
            if !snap.cardAvailable { Text("Card payments are unavailable on this NStack right now.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
            else { Text("Card payments run in Stripe test mode: no real money moves.").font(.amb(.caption)).foregroundStyle(Amb.warning) }
            if !snap.lightningAvailable { Text("Lightning is unavailable on this NStack right now.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
            Text("Starting a payment opens one at a time. The next can begin once NStack confirms this one is closed.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            HStack {
                Button("Pay by card") { if let cents = amountCents { run { await topup.startCard(amountCents: cents) { app.openCheckout($0) } } } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy || !snap.cardAvailable || amountCents == nil).accessibilityIdentifier("topup.card")
                Button("Pay with Lightning") { if let cents = amountCents { run { await topup.startLightning(amountCents: cents) } } }
                    .buttonStyle(PrimaryButtonStyle()).disabled(busy || !snap.lightningAvailable || amountCents == nil).accessibilityIdentifier("topup.lightning")
            }
        }
    }

    @ViewBuilder private var attempt: some View {
        if let attempt = snap.attempt {
            VStack(alignment: .leading, spacing: 10) {
                Text(attempt.method == .card ? "Waiting for your card payment" : "Pay with Lightning").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
                LabeledContent("Top-up", value: OnboardingFunding.label(cents: attempt.amountCents))
                if attempt.method == .lightning {
                    if let quote = snap.quote {
                        LightningQuoteCard(quote: quote, invoice: snap.invoice, usdLabel: OnboardingFunding.label(cents: quote.amount_cents), open: { app.openWallet($0) })
                    } else {
                        Text("The invoice has not been received yet. Asking again reuses the same request, so it never creates a second invoice.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                        Button("Get the invoice") { run { await topup.resumeInvoice() } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    }
                } else {
                    Text("Finish the test payment in your browser, then come back. Credit is added only when NStack has verified the payment; coming back or a browser message is not enough.")
                        .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                    Button("Reopen payment page") { run { await topup.reopenCheckout { app.openCheckout($0) } } }.disabled(busy)
                }
                Button("Check payment now") { run { await topup.refresh() } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("topup.check")
                Text("This payment stays open until NStack reports it paid, expired or closed. It cannot be cleared here, so a second payment is never started by mistake.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            }
        }
    }

    private var support: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snap.needsSupport) { quote in
                Notice(tone: .warning, text: "A Lightning payment of \(OnboardingFunding.label(cents: quote.amount_cents)) is recorded as \(quote.state.replacingOccurrences(of: "_", with: " ")) and was not credited automatically. Do not pay again. Contact support with reference \(quote.quote_id).")
            }
        }
    }

    @ViewBuilder private var credited: some View {
        if let list = snap.list, !list.credited.isEmpty || !list.pending_checkout.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !list.credited.isEmpty {
                    Text("Credited top-ups").font(.amb(.subheadline).weight(.semibold))
                    ForEach(list.credited) { credit in
                        LabeledContent("\(OnboardingFunding.label(cents: credit.amount_cents)) · \(credit.method)", value: credit.settled_at.map(NStackDateDisplay.format) ?? "")
                            .font(.amb(.footnote))
                    }
                }
                if !list.pending_checkout.isEmpty {
                    Text("\(list.pending_checkout.count) card payment\(list.pending_checkout.count == 1 ? " is" : "s are") still open at NStack and not yet credited.")
                        .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
                }
            }.ambCard()
        }
    }

    private func seed() {
        if !snap.limits.valid(choice) { choice = snap.limits.presetsCents.first ?? snap.limits.minCents }
    }
    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false; seed() }
    }
}
