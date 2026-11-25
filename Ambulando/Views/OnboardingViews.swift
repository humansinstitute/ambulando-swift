import AmbulandoCore
import SwiftUI

/// Entry shown wherever a new workspace can be started: needs an unlocked identity and a Tower address the user confirms.
struct OnboardingEntry: View {
    @Environment(AppModel.self) private var model
    var origin: String
    @State private var flow: OnboardingModel?
    @State private var error: String?

    var body: some View {
        Button("Start a new workspace with an invitation") {
            Task {
                do { flow = try await model.makeOnboarding(origin: origin); error = nil }
                catch { self.error = error.localizedDescription }
            }
        }
        .disabled(!model.onboardingAvailable || origin.isEmpty)
        .accessibilityIdentifier("onboarding.start")
        if let error { Notice(tone: .error, text: error) }
        Text(model.onboardingAvailable
             ? "Uses the NStack address above. Setup is in test mode: no real money moves."
             : "Unlock your identity to start a new workspace.")
            .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
        Color.clear.frame(height: 0).sheet(item: $flow) { flow in
            NavigationStack { OnboardingFlowView(onboarding: flow) }
        }
    }
}

extension OnboardingModel: Identifiable { nonisolated var id: String { "\(origin.description)|\(signerNpub)" } }

struct OnboardingFlowView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let onboarding: OnboardingModel
    @State private var name = ""
    @State private var inviteText = ""
    @State private var fundingChoice = OnboardingFunding.presetsCents[0]
    @State private var custom = false
    @State private var customDollars = ""
    @State private var agentId: String?
    @State private var agentCap = ""
    @State private var seeded = false
    @State private var inviteNote: String?
    @State private var busy = false
    @State private var openProblem: String?

    private var snap: OnboardingSnapshot { onboarding.snapshot }
    private var fundingCents: Int? { custom ? OnboardingFunding.cents(fromDollars: customDollars) : fundingChoice }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let failure = snap.failure { Notice(tone: .error, text: failure.localizedDescription) }
                if let notice = snap.notice { Notice(tone: .info, text: notice) }
                switch snap.backupGate {
                case .allowed: EmptyView()
                case .localBackupRequired:
                    Notice(tone: .warning, text: OnboardingFailure(kind: .backupRequired).localizedDescription).accessibilityIdentifier("onboarding.backupGate")
                case .hostedBackupRequired:
                    Notice(tone: .warning, text: OnboardingFailure(kind: .hostedBackupRequired).localizedDescription).accessibilityIdentifier("onboarding.backupGate")
                }
                if onboarding.needsHostedBackup { HostedBackupSection(onboarding: onboarding).ambCard() }
                phaseBody.ambCard()
                if case .form = snap.phase {} else { backendFootnote }
            }
            .padding(20)
        }
        .navigationTitle("New workspace").inlineTitle()
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        .task { await onboarding.load(); seed() }
        .onChange(of: scenePhase) { _, phase in if phase == .active, snap.intent != nil { Task { await onboarding.refresh() } } }
        .onOpenURL { url in Task { await onboarding.paymentReturned(url) } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Signed in as \(shortNpub(onboarding.signerNpub))").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Text(onboarding.origin.description).font(Amb.code).foregroundStyle(Amb.mutedForeground)
            Label("Test mode — payment uses Stripe test cards; no real money moves.", systemImage: "testtube.2")
                .font(.amb(.footnote)).foregroundStyle(Amb.warning)
        }
    }

    @ViewBuilder private var phaseBody: some View {
        switch snap.phase {
        case .checking: ProgressView("Checking this NStack…")
        case .unavailable(let why): unavailable(why)
        case .form: form
        case .review: review
        case .awaitingPayment: awaiting
        case .readyToProvision: ready
        case .provisioning: provisioning
        case .provisioned: done
        case .cancelled: cancelled
        }
    }

    private func unavailable(_ why: OnboardingUnavailability) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not available here").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text(Self.explanation(why)).font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Button("Check again") { run { await onboarding.load() } }.disabled(busy)
        }
    }

    private static func explanation(_ why: OnboardingUnavailability) -> String {
        switch why {
        case .originRejected(let m): "This address did not check out as the NStack it claims to be (\(m)). No signed request was sent to it."
        case .backendMissing: "This NStack does not have invited onboarding. Your existing connections are unchanged."
        case .rolloutDisabled: "Invited onboarding is currently unavailable on this NStack. Your progress is kept on this device and on NStack. Check the status again; a payment you already made is not affected by this message."
        case .offline: "NStack could not be reached. Your progress is saved."
        case .signerRefused: "NStack did not accept this identity's signature."
        case .identityLocked: "Unlock your identity to continue. Your progress is kept."
        case .signerMismatch: "The unlocked identity is not the one this setup belongs to. No request was signed or sent for it."
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Set up your workspace").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            if snap.draft.intentId == nil {
                Text("Invitation").font(.amb(.subheadline).weight(.semibold))
                SecureField("Invitation code", text: $inviteText).noCapitalization().autocorrectionDisabled()
                    .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                    .accessibilityIdentifier("onboarding.invite")
                if let inviteNote { Notice(tone: .warning, text: inviteNote) }
            } else {
                Notice(tone: .info, text: "An earlier setup was found on the NStack and resumed. Review it again before paying.")
            }
            Text("Workspace name").font(.amb(.subheadline).weight(.semibold))
            TextField("Studio", text: $name)
                .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                .accessibilityIdentifier("onboarding.name")
            Text("Funding").font(.amb(.subheadline).weight(.semibold))
            Picker("Funding", selection: Binding(get: { custom ? -1 : fundingChoice }, set: { v in if v == -1 { custom = true } else { custom = false; fundingChoice = v } })) {
                ForEach(OnboardingFunding.presetsCents, id: \.self) { Text(OnboardingFunding.label(cents: $0)).tag($0) }
                Text("Custom").tag(-1)
            }.pickerStyle(.segmented)
            if custom {
                TextField("US$ amount, at least 21", text: $customDollars).decimalEntry()
                    .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                if fundingCents == nil { Text("Enter a whole or two-decimal amount from US$21 up.").font(.amb(.caption)).foregroundStyle(Amb.destructive) }
            }
            agentSection
            Button("Review") {
                var invite: OnboardingInviteCode?
                if snap.draft.intentId == nil {
                    guard let parsed = OnboardingInviteInput.parse(inviteText) else { inviteNote = "That is not an invitation code."; return }
                    if let suggested = parsed.suggestedOrigin, suggested != onboarding.origin {
                        inviteNote = "That link points at a different NStack (\(suggested.description)). No request was sent to it. Start from that NStack's address if you trust it."; return
                    }
                    invite = parsed.code; inviteNote = nil
                }
                guard let cents = fundingCents else { return }
                run { await onboarding.review(name: name, fundingCents: cents, agentOfferId: agentId, agentDailyCapCents: agentId == nil ? nil : Int(agentCap), invite: invite) }
            }
            .buttonStyle(PrimaryButtonStyle()).disabled(busy || fundingCents == nil || OnboardingName.normalized(name) == nil)
            .accessibilityIdentifier("onboarding.review")
        }
    }

    @ViewBuilder private var agentSection: some View {
        Text("Agent (optional)").font(.amb(.subheadline).weight(.semibold))
        if snap.offers.isEmpty {
            Text("No agents are on offer from this NStack yet, so none can be chosen.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
        } else {
            Picker("Agent", selection: $agentId) {
                Text("No agent").tag(String?.none)
                ForEach(snap.offers) { Text("\($0.template) · \($0.model_ref)").tag(String?.some($0.id)) }
            }
            if let offer = snap.offers.first(where: { $0.id == agentId }) {
                TextField("Daily cap in cents (default \(offer.default_daily_cap_cents), max \(offer.max_daily_cap_cents))", text: $agentCap).numberPadEntry()
                    .padding(10).background(Amb.muted, in: RoundedRectangle(cornerRadius: Amb.radiusControl))
                Text("Choosing an agent reserves the choice only. It does not start running, and it never sends a request for you.").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            }
        }
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review before paying").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            LabeledContent("Workspace", value: snap.draft.workspaceName)
            LabeledContent("Funding", value: OnboardingFunding.label(cents: snap.draft.fundingCents))
            LabeledContent("Agent", value: snap.offers.first { $0.id == snap.draft.agentOfferId }.map { "\($0.template) (not running yet)" } ?? "None")
            if snap.draft.agentOfferId != nil, let cap = snap.draft.agentDailyCapCents { LabeledContent("Agent daily cap", value: OnboardingFunding.label(cents: cap)) }
            LabeledContent("Identity", value: shortNpub(onboarding.signerNpub))
            Text("Payment method").font(.amb(.subheadline).weight(.semibold))
            ForEach(snap.paymentOptions, id: \.method) { option in
                VStack(alignment: .leading, spacing: 2) {
                    Label(option.label, systemImage: option.method == .lightning ? (option.available ? "bolt" : "nosign") : (option.available ? "creditcard" : "nosign"))
                        .foregroundStyle(option.available ? Amb.foreground : Amb.mutedForeground)
                    if let reason = option.unavailableReason { Text(reason).font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
                }
            }
            Text("Choosing a method starts one payment for this setup. Another method opens only after NStack confirms the first is closed.")
                .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
            Button("Edit") { run { await onboarding.editAgain() } }.disabled(busy)
            HStack {
                Button("Pay by card") { run { await onboarding.continueToPayment { app.openCheckout($0) } } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || !snap.paymentOptions.contains { $0.method == .card && $0.available })
                    .accessibilityIdentifier("onboarding.pay")
                Button("Pay with Lightning") { run { await onboarding.continueToLightning() } }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || !snap.paymentOptions.contains { $0.method == .lightning && $0.available })
                    .accessibilityIdentifier("onboarding.payLightning")
            }
        }
    }

    @ViewBuilder private var awaiting: some View {
        if snap.draft.paymentMethod == "lightning" || snap.draft.lightningKey != nil { awaitingLightning } else { awaitingCard }
    }

    private var awaitingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for payment confirmation").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text("Finish the test payment in your browser, then come back. Setup only continues once the NStack itself confirms the payment; coming back or a browser message is not enough.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Button("Check payment now") { run { await onboarding.refresh() } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
            Button("Reopen payment page") { run { await onboarding.continueToPayment { app.openCheckout($0) } } }.disabled(busy)
            Button("Cancel this setup", role: .destructive) { run { await onboarding.cancelSetup() } }.disabled(busy)
        }
    }

    private var awaitingLightning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pay with Lightning").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            if let quote = snap.lightning {
                LightningQuoteCard(quote: quote, invoice: snap.lightningInvoice, usdLabel: OnboardingFunding.label(cents: quote.amount_cents), open: { app.openWallet($0) })
            } else {
                Text("The invoice has not been received yet. Asking again reuses the same request, so it never creates a second invoice.")
                    .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                Button("Get the invoice") { run { await onboarding.continueToLightning() } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                    .accessibilityIdentifier("onboarding.getInvoice")
            }
            Text("Setup only continues once the NStack itself confirms the payment. A wallet saying \"paid\", coming back to the app or time passing is not confirmation.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Button("Check payment now") { run { await onboarding.refresh() } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("onboarding.checkLightning")
            if snap.lightning == nil || snap.lightning?.state.verifiedClosedUnpaid == true {
                Button("Get a new invoice") { run { await onboarding.continueToLightning() } }.disabled(busy)
            }
            Button("Cancel this setup", role: .destructive) { run { await onboarding.cancelSetup() } }.disabled(busy)
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Payment confirmed by the NStack", systemImage: "checkmark.seal").foregroundStyle(Amb.success)
            Text("Create \(snap.intent?.workspace_name ?? "your workspace") now. If it stops part-way, your payment and finished steps are kept and you can retry.")
                .font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Button("Create workspace") { run { await onboarding.provision() } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
                .accessibilityIdentifier("onboarding.provision")
        }
    }

    private var provisioning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setting up…").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            if let error = snap.intent?.last_error { Text("Last step reported: \(error)").font(.amb(.caption)).foregroundStyle(Amb.mutedForeground) }
            Button("Continue setup") { run { await onboarding.provision() } }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Workspace created", systemImage: "checkmark.circle").font(Amb.editorial).foregroundStyle(Amb.success)
            if let landing = snap.landing {
                Text(landing.generalReady ? "General is ready." : "General is not set up yet: the NStack has not recorded it.").font(.amb(.footnote))
                if let agent = landing.agentName {
                    Text(landing.agentRunning ? "Your \(agent) agent is ready." : "Your \(agent) agent is chosen but not running yet. When it is, you decide the first request.")
                        .font(.amb(.footnote))
                }
            }
            if let workspaceId = snap.landing?.workspaceId {
                Text("Open it now: this connects to \(onboarding.origin.description) as \(shortNpub(onboarding.signerNpub)) and keeps your other connections.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
                Button("Open workspace") {
                    busy = true
                    Task {
                        openProblem = await app.openProvisionedWorkspace(origin: onboarding.origin.description, signerNpub: onboarding.signerNpub, workspaceId: workspaceId)
                        busy = false
                        if openProblem == nil { await onboarding.finish(); dismiss() }
                    }
                }.buttonStyle(PrimaryButtonStyle()).disabled(busy).accessibilityIdentifier("onboarding.openWorkspace")
                if let openProblem { Notice(tone: .warning, text: openProblem) }
            } else {
                Text("The NStack did not report a workspace id. Connect from the Connect screen to see it in your workspace list.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            }
            Button("Done") { run { await onboarding.finish() }; dismiss() }.disabled(busy)
        }
    }

    private var cancelled: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Setup cancelled").font(Amb.editorial).foregroundStyle(Amb.itemHeading)
            Text("This setup is cancelled. Any payment already confirmed stays as credit on your account; check your account status if you are unsure.").font(.amb(.footnote)).foregroundStyle(Amb.mutedForeground)
            Button("Start over") { run { await onboarding.finish(); seeded = false; seed() } }.disabled(busy)
        }
    }

    private var backendFootnote: some View {
        Text("Hosted username backup and agent provisioning are still being built; this slice creates the workspace only.")
            .font(.amb(.caption)).foregroundStyle(Amb.mutedForeground)
    }

    private func seed() {
        guard !seeded else { return }
        seeded = true
        let d = snap.draft
        name = d.workspaceName
        if OnboardingFunding.presetsCents.contains(d.fundingCents) { fundingChoice = d.fundingCents; custom = false }
        else { custom = true; customDollars = String(format: "%.2f", Double(d.fundingCents) / 100) }
        agentId = d.agentOfferId
        agentCap = d.agentDailyCapCents.map(String.init) ?? ""
    }

    private func run(_ work: @escaping () async -> Void) {
        busy = true
        Task { await work(); busy = false }
    }
}
