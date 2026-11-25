import AmbulandoCore
import Foundation
import Observation
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Invited onboarding for the unlocked identity (first slice: workspace-only, Stripe test mode). The wizard's durable state lives
/// in `OnboardingController`; this model only mirrors its snapshot for SwiftUI and runs the one platform step (opening checkout).
@MainActor @Observable
final class OnboardingModel {
    private(set) var snapshot: OnboardingSnapshot
    let origin: TowerOrigin
    let signerNpub: String
    @ObservationIgnored private let controller: OnboardingController
    @ObservationIgnored private let hostedBackup: HostedBackupSaver?

    init(origin: TowerOrigin, signerNpub: String, controller: OnboardingController, initial: OnboardingSnapshot, hostedBackup: HostedBackupSaver? = nil) {
        self.origin = origin; self.signerNpub = signerNpub; self.controller = controller; snapshot = initial; self.hostedBackup = hostedBackup
    }

    /// Saves the encrypted key on this NStack under a username, reads it back and checks it opens to this identity; only then does the
    /// gate move. Throws `HostedBackupFailure` (or `IdentityError`) for the view to show.
    func saveHostedBackup(username: String, password: String) async throws {
        guard let hostedBackup else { throw HostedBackupFailure(kind: .notEligible) }
        _ = try await hostedBackup.save(username: username, password: password)
        snapshot = await controller.refreshBackupGate()
    }
    var needsHostedBackup: Bool { snapshot.backupGate == .hostedBackupRequired }

    func load() async { snapshot = await controller.load() }
    func refresh() async { snapshot = await controller.refresh() }
    func provision() async { snapshot = await controller.provision() }
    func cancelSetup() async { snapshot = await controller.cancelSetup() }
    /// The user's explicit request to close an unpaid payment so another method can be chosen. Never called automatically.
    func releasePayment() async { snapshot = await controller.releasePayment() }
    func finish() async { snapshot = await controller.finish() }
    func editAgain() async { snapshot = await controller.reopenForEditing() }
    func paymentReturned(_ url: URL?) async { snapshot = await controller.paymentReturned(url) }
    /// Creates or resumes the intent and asks NStack for the Lightning invoice. Nothing is opened: the user chooses to copy, scan or open a wallet.
    func continueToLightning() async { snapshot = await controller.continueToLightning() }

    func review(name: String, fundingCents: Int, agentOfferId: String?, agentDailyCapCents: Int?, invite: OnboardingInviteCode?) async {
        _ = await controller.edit(name: name, fundingCents: fundingCents, agentOfferId: .some(agentOfferId),
                                  agentDailyCapCents: agentDailyCapCents.map { .some($0) }, invite: invite)
        snapshot = await controller.confirmReview()
    }

    /// Creates or resumes the intent, asks for checkout and opens the Stripe-hosted page in the system browser.
    func continueToPayment(open: (URL) -> Void) async {
        snapshot = await controller.continueToPayment()
        if let url = snapshot.checkoutURL { open(url) }
    }
}

/// Repeat account top-ups for the unlocked identity. Durable state lives in `TopupController`; this mirrors its snapshot for SwiftUI.
@MainActor @Observable
final class TopupModel {
    private(set) var snapshot: TopupSnapshot
    let origin: TowerOrigin
    let signerNpub: String
    @ObservationIgnored private let controller: TopupController

    init(origin: TowerOrigin, signerNpub: String, controller: TopupController, initial: TopupSnapshot) {
        self.origin = origin; self.signerNpub = signerNpub; self.controller = controller; snapshot = initial
    }
    func load() async { snapshot = await controller.load() }
    func refresh() async { snapshot = await controller.refresh() }
    func startCard(amountCents: Int, open: (URL) -> Void) async {
        snapshot = await controller.startCard(amountCents: amountCents)
        if let url = snapshot.checkoutURL { open(url) }
    }
    func reopenCheckout(open: (URL) -> Void) async {
        snapshot = await controller.reopenCheckout()
        if let url = snapshot.checkoutURL { open(url) }
    }
    func startLightning(amountCents: Int) async { snapshot = await controller.startLightning(amountCents: amountCents) }
    func resumeInvoice() async { snapshot = await controller.resumeInvoice() }
    func paymentReturned(_ url: URL?) async { snapshot = await controller.paymentReturned(url) }
}

extension AppModel {
    /// Top-ups need the same unlocked identity and signing path as onboarding, and are never offered in Grandparent Chat or fixture runs.
    func makeTopup(origin: String) throws -> TopupModel {
        guard onboardingAvailable, case .unlocked(let npub) = identity, let sync = signingSync else { throw IdentityError.locked }
        let tower = try TowerOrigin(origin)
        let store = FileTopupDraftStore(directory: Self.dataDirectory.appendingPathComponent("Topups", isDirectory: true))
        let identityService = sync.identity
        let controller = TopupController(origin: tower, signerNpub: npub, signer: identityService, transport: sync.transport, store: store,
                                         backupGate: { await identityService.paymentBackupGate(origin: tower) })
        return TopupModel(origin: tower, signerNpub: npub, controller: controller, initial: .init())
    }

    /// Not offered in Grandparent Chat, fixture/test runs, or while the identity is not unlocked.
    var onboardingAvailable: Bool { !Product.isGrandparentChat && fixture == nil && isUnlocked && signingSync != nil }

    /// Legacy deployment fallback. Current NStack deployments publish their exact approved URLs through signed config reads;
    /// the server still validates the selected URL when creating checkout.
    static var onboardingReturnURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "AmbulandoOnboardingReturnURL") as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    /// A wizard for `origin` and the currently unlocked identity only. The controller verifies the Tower's descriptor before it signs.
    func makeOnboarding(origin: String) async throws -> OnboardingModel {
        guard onboardingAvailable, case .unlocked(let npub) = identity, let sync = signingSync else { throw IdentityError.locked }
        let tower = try TowerOrigin(origin)
        let store = FileOnboardingDraftStore(directory: Self.dataDirectory.appendingPathComponent("Onboarding", isDirectory: true))
        let identityService = sync.identity
        let controller = OnboardingController(origin: tower, signerNpub: npub, signer: identityService, transport: sync.transport,
                                              store: store, returnURL: Self.onboardingReturnURL,
                                              backupGate: { await identityService.paymentBackupGate(origin: tower) },
                                              declaresNewIdentity: { await identityService.backupRecord()?.origin == .created })
        let hosted = HostedBackupSaver(origin: tower, transport: sync.transport, identity: identityService)
        return OnboardingModel(origin: tower, signerNpub: npub, controller: controller, initial: await controller.snapshot(), hostedBackup: hosted)
    }

    func openCheckout(_ url: URL) { browser.openInSystemBrowser(url) }

    /// Hands a Lightning invoice to the system's wallet handler. Only the exact `lightning:` address built from the shown invoice is opened.
    func openWallet(_ url: URL) {
        guard url.scheme == "lightning" else { return }
        #if os(iOS)
        UIApplication.shared.open(url)
        #else
        NSWorkspace.shared.open(url)
        #endif
    }

    /// Connects to the Tower that just provisioned `workspaceId` through the same path as a discovered Tower, then opens that workspace
    /// if (and only if) discovery returns exactly that id for this signer. Existing connections are kept; the connection record is an
    /// upsert for (origin, signer). If the Tower has not listed the workspace yet, the normal Tower workspace picker stays open and
    /// nothing is guessed. Returns a message only when something needs the user's attention.
    func openProvisionedWorkspace(origin: String, signerNpub: String, workspaceId: String) async -> String? {
        guard isUnlocked, case .unlocked(let npub) = identity, npub == signerNpub else { return "Unlock the identity this workspace was created for to open it." }
        guard let canonical = try? TowerOrigin(origin).description else { return "The workspace address is not valid." }
        await connectDiscoveredTower(canonical)
        if let problem = notice, pendingTowerWorkspaceChoice == nil { return problem }
        for attempt in 0..<6 {
            guard case .unlocked(let current) = identity, current == signerNpub else { return "The identity changed, so nothing was opened." }
            if let entry = workspaceEntries.first(where: { $0.connection.origin == canonical && $0.connection.signerNpub == signerNpub && $0.workspace.id == workspaceId }) {
                choosePendingWorkspace(entry)
                return nil
            }
            if attempt < 5 { try? await Task.sleep(for: .seconds(1)); await refreshPendingTowerWorkspaces() }
        }
        return "The NStack has not listed the new workspace for your identity yet. It is not guessed: pick it on the Connect screen once it appears."
    }
}
