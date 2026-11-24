import AmbulandoCore
import Foundation
import Observation

/// Invited onboarding for the unlocked identity (first slice: workspace-only, Stripe test mode). The wizard's durable state lives
/// in `OnboardingController`; this model only mirrors its snapshot for SwiftUI and runs the one platform step (opening checkout).
@MainActor @Observable
final class OnboardingModel {
    private(set) var snapshot: OnboardingSnapshot
    let origin: TowerOrigin
    let signerNpub: String
    @ObservationIgnored private let controller: OnboardingController

    init(origin: TowerOrigin, signerNpub: String, controller: OnboardingController, initial: OnboardingSnapshot) {
        self.origin = origin; self.signerNpub = signerNpub; self.controller = controller; snapshot = initial
    }

    func load() async { snapshot = await controller.load() }
    func refresh() async { snapshot = await controller.refresh() }
    func provision() async { snapshot = await controller.provision() }
    func cancelSetup() async { snapshot = await controller.cancelSetup() }
    func finish() async { snapshot = await controller.finish() }
    func editAgain() async { snapshot = await controller.reopenForEditing() }
    func paymentReturned(_ url: URL?) async { snapshot = await controller.paymentReturned(url) }

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

extension AppModel {
    /// Not offered in Grandparent Chat, fixture/test runs, or while the identity is not unlocked.
    var onboardingAvailable: Bool { !Product.isGrandparentChat && fixture == nil && isUnlocked && signingSync != nil }

    /// The address Stripe returns to. It must be an exact member of the Tower's `HOSTING_STRIPE_RETURN_URLS`; the client cannot
    /// discover that list, so it is build configuration and checkout stays switched off when it is not set.
    static var onboardingReturnURL: URL? {
        guard let text = Bundle.main.object(forInfoDictionaryKey: "AmbulandoOnboardingReturnURL") as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }

    /// A wizard for `origin` and the currently unlocked identity only. The controller verifies the Tower's descriptor before it signs.
    func makeOnboarding(origin: String) async throws -> OnboardingModel {
        guard onboardingAvailable, case .unlocked(let npub) = identity, let sync = signingSync else { throw IdentityError.locked }
        let tower = try TowerOrigin(origin)
        let store = FileOnboardingDraftStore(directory: Self.dataDirectory.appendingPathComponent("Onboarding", isDirectory: true))
        let controller = OnboardingController(origin: tower, signerNpub: npub, signer: sync.identity, transport: sync.transport,
                                              store: store, returnURL: Self.onboardingReturnURL)
        return OnboardingModel(origin: tower, signerNpub: npub, controller: controller, initial: await controller.snapshot())
    }

    func openCheckout(_ url: URL) { browser.openInSystemBrowser(url) }
}
