import Foundation

/// Sends and withdraws registrations. The concrete one signs with the unlocked identity (so a locked identity can never
/// upload a token); tests inject a fake.
public protocol PushRegistrar: Sendable {
    /// Registers `token` for one workspace and returns the lease expiry Tower granted.
    func register(_ registration: PushRegistration, token: PushDeviceToken, origin: TowerOrigin, signerNpub: String) async throws -> PushAcknowledgement
    /// HTTP status of the revocation, or nil when it never reached Tower or could not be signed.
    func revoke(_ revocation: PendingPushRevocation) async -> Int?
}

/// What the coordinator needs to know about the app right now.
public struct PushContext: Sendable, Equatable {
    /// Nil when there is no Tower connection or no workspace.
    public var binding: PushBinding?
    /// The npub that can sign right now (nil while locked or with no identity).
    public var unlockedSigner: String?

    public init(binding: PushBinding?, unlockedSigner: String?) {
        self.binding = binding
        self.unlockedSigner = unlockedSigner
    }
}

/// What Settings shows. Wording lives in the UI; this is only the truth.
public struct PushStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case off
        case needsPermission          // enabled, the person has not answered the system prompt
        case denied                   // the OS refuses alerts; only system Settings can change that
        case waitingForToken          // permission granted, no device token yet
        case waitingForUnlock         // token held; registration needs the identity unlocked
        case notRegistered            // token held and unlocked, but nothing acknowledged yet
        case active(until: Date)
        /// Tower accepted the registration but says it cannot send yet (`provider_not_configured`, `environment_not_enabled`,
        /// `permission_denied`). Never shown as "on".
        case registeredNotDelivering(reason: String?)
        case providerUnavailable      // Tower answered that it cannot deliver alerts
        case failed(String)
    }

    public var phase: Phase
    public var permission: PushPermission
    public var environment: PushEnvironment
    public var enrolledWorkspaces: Int
    public var pendingRevocations: Int
}

/// Owns alert enrolment: the permission request (only on explicit action), the device token, the per-workspace
/// registrations with their leases, and their withdrawal. It never signs on its own: every upload goes through the
/// registrar, which needs the unlocked identity, and a revocation that cannot be sent is kept until it can be or the
/// lease has ended on Tower's side.
public actor PushCoordinator {
    public static let unavailableRetry: TimeInterval = 3600

    private let platform: PushPlatform
    private let registrar: PushRegistrar
    private let persistence: PushPersistence
    private let bundleId: String
    private let environment: PushEnvironment
    private let leaseSeconds: Int
    private let platformName: String
    private let appVersion: String?
    private let now: @Sendable () -> Date
    private var state: PushInstallationState
    private var loaded = false
    private var busy = false
    private var rerun: PushContext?

    public init(platform: PushPlatform, registrar: PushRegistrar, persistence: PushPersistence, bundleId: String,
                environment: PushEnvironment, leaseSeconds: Int = PushRegistration.defaultLeaseSeconds,
                platformName: String = "ios", appVersion: String? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.platform = platform
        self.registrar = registrar
        self.persistence = persistence
        self.bundleId = bundleId
        self.environment = environment
        self.leaseSeconds = leaseSeconds
        self.platformName = platformName
        self.appVersion = appVersion
        self.now = now
        state = PushInstallationState()
    }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        if let saved = await persistence.load() { state = saved } else { await persistence.save(state) }
    }

    public var installationId: String { get async { await load(); return state.installationId } }

    public func status() async -> PushStatus {
        await load()
        return await makeStatus()
    }

    private func makeStatus() async -> PushStatus {
        let permission = await platform.permission()
        let phase: PushStatus.Phase
        if !state.enabled { phase = .off }
        else if permission == .notDetermined { phase = .needsPermission }
        else if permission == .denied { phase = .denied }
        else if let until = state.enrolled.values.min(), state.binding != nil, !state.enrolled.isEmpty, until > now() {
            phase = state.deliveryReady == false ? .registeredNotDelivering(reason: state.deliveryReason) : .active(until: until)
        }
        else if let problem = state.lastProblem { phase = .failed(problem) }
        else if let at = state.providerUnavailableAt, now().timeIntervalSince(at) < Self.unavailableRetry { phase = .providerUnavailable }
        else if state.tokenHex == nil { phase = .waitingForToken }
        else { phase = state.binding == nil ? .waitingForUnlock : .notRegistered }
        return PushStatus(phase: phase, permission: permission, environment: environment,
                          enrolledWorkspaces: state.enrolled.count, pendingRevocations: state.pendingRevocations.count)
    }

    // MARK: Explicit actions

    /// "Enable Notifications". Prompts only when the OS has not been asked yet; a refusal is reported, not retried.
    /// Registration continues through `reconcile` once a token exists.
    @discardableResult
    public func enable(context: PushContext) async -> PushStatus {
        await load()
        var permission = await platform.permission()
        if permission == .notDetermined { permission = await platform.requestPermission() }
        guard permission == .authorized else {
            state.enabled = false
            await persistence.save(state)
            return await makeStatus()
        }
        state.enabled = true
        state.lastProblem = nil
        state.providerUnavailableAt = nil
        await persistence.save(state)
        await platform.registerForRemoteNotifications()
        await reconcile(context: context, force: true)
        return await makeStatus()
    }

    /// "Disable": withdraws registrations (queued if they cannot be sent now) and drops the token.
    public func disable(context: PushContext) async {
        await load()
        state.enabled = false
        await unbindLocked(context: context)
        state.tokenHex = nil
        state.tokenEnvironment = nil
        state.lastProblem = nil
        await persistence.save(state)
        await platform.unregisterForRemoteNotifications()
    }

    /// Sign-out paths (Disconnect, Remove identity, signer or workspace change): withdraw first, forget after. Call it
    /// before the connection or identity is removed so the signer is still available when it can be.
    public func unbind(context: PushContext) async {
        await load()
        await unbindLocked(context: context)
        await persistence.save(state)
    }

    // MARK: OS callbacks

    public func tokenReceived(_ data: Data, context: PushContext) async {
        await load()
        guard let token = try? PushDeviceToken(data: data) else {
            state.lastProblem = "The system returned an unusable device token."
            await persistence.save(state)
            return
        }
        guard state.enabled else { return }
        if state.tokenHex != token.hex || state.tokenEnvironment != environment {
            // A new token is a new registration body for every workspace; the installation row is replaced, not duplicated.
            state.enrolled = [:]
        }
        state.tokenHex = token.hex
        state.tokenEnvironment = environment
        state.lastProblem = nil
        await persistence.save(state)
        await reconcile(context: context, force: false)
    }

    public func registrationFailed(_ error: Error) async {
        await load()
        state.lastProblem = "The system could not register this device for notifications: \(Self.describe(error))"
        await persistence.save(state)
    }

    // MARK: Reconcile

    /// Brings Tower in line with the app: uploads when unlocked and due, withdraws what no longer matches, and retries
    /// owed revocations. Trigger-driven (launch, unlock, foreground, workspace change); it has no timer of its own.
    public func reconcile(context: PushContext, force: Bool = false) async {
        await load()
        if busy { rerun = context; return }
        busy = true
        var next: PushContext? = context
        var forced = force
        while let current = next {
            rerun = nil
            await reconcileOnce(context: current, force: forced)
            next = rerun
            forced = false
        }
        busy = false
    }

    private func reconcileOnce(context: PushContext, force: Bool) async {
        // 1. Withdraw anything that no longer matches the binding (signer, Tower or a removed workspace).
        if let bound = state.binding {
            let gone: [String]
            var sameOwner = false
            if let want = context.binding, want.origin == bound.origin, want.signerNpub == bound.signerNpub {
                gone = state.enrolled.keys.filter { !want.workspaceIds.contains($0) }
                sameOwner = true
            } else { gone = Array(state.enrolled.keys) }
            if !gone.isEmpty { queueRevocations(for: gone, binding: bound) }
            if !sameOwner { state.installationId = UUID().uuidString.lowercased(); state.binding = nil }
        }
        // 2. Drop pending revocations Tower no longer cares about, send the ones whose signer is available.
        await drainRevocations(signer: context.unlockedSigner)

        guard state.enabled, let want = context.binding else { await persistence.save(state); return }
        let permission = await platform.permission()
        if permission != .authorized {
            // Alerts were turned off in system Settings: tell Tower rather than leave a dead registration.
            if !state.enrolled.isEmpty, let bound = state.binding { queueRevocations(for: Array(state.enrolled.keys), binding: bound) }
            await drainRevocations(signer: context.unlockedSigner)
            await persistence.save(state)
            return
        }
        if state.tokenHex == nil, !force { await platform.registerForRemoteNotifications() }   // no token yet: ask again (enable already asked once)
        guard let hex = state.tokenHex, let token = try? PushDeviceToken(hex: hex) else { await persistence.save(state); return }
        guard context.unlockedSigner == want.signerNpub else { await persistence.save(state); return }   // never sign while locked
        if let at = state.providerUnavailableAt, !force, now().timeIntervalSince(at) < Self.unavailableRetry { await persistence.save(state); return }
        guard let origin = try? TowerOrigin(want.origin) else { return }

        state.binding = want
        let renewBefore = now().addingTimeInterval(TimeInterval(leaseSeconds) / 2)
        for workspace in want.workspaceIds {
            if let lease = state.enrolled[workspace], lease > renewBefore, !force { continue }
            do {
                let registration = try PushRegistration(workspaceId: workspace, appNpub: want.appNpubs[workspace] ?? "", installationId: state.installationId,
                                                        environment: environment, bundleId: bundleId, leaseSeconds: leaseSeconds,
                                                        platform: platformName, appVersion: appVersion)
                let ack = try await registrar.register(registration, token: token, origin: origin, signerNpub: want.signerNpub)
                state.enrolled[workspace] = ack.leaseExpiresAt
                state.deliveryReady = ack.deliveryReady
                state.deliveryReason = ack.deliveryReason
                state.lastProblem = nil
                state.providerUnavailableAt = nil
            } catch let error as TowerError {
                if case .http(let status, let code, _) = error {
                    if status == 404 || status == 501 { state.providerUnavailableAt = now(); state.lastProblem = nil; break }
                    if code == "transport_owned" { state.lastProblem = "This device is already registered to another account on this Tower."; break }
                    if code == "installation_owned" { state.installationId = UUID().uuidString.lowercased(); state.lastProblem = "Registration will retry with a new device id."; break }
                    if code == "workspace_membership_required" { state.lastProblem = "You are not an active member of that workspace."; continue }
                }
                state.lastProblem = Self.describe(error)
            } catch IdentityError.locked {
                break
            } catch {
                state.lastProblem = Self.describe(error)   // transport trouble: the next trigger tries again
            }
        }
        await persistence.save(state)
    }

    // MARK: Revocation

    private func unbindLocked(context: PushContext) async {
        if let bound = state.binding, !state.enrolled.isEmpty { queueRevocations(for: Array(state.enrolled.keys), binding: bound) }
        state.enrolled = [:]
        state.binding = nil
        state.deliveryReady = nil
        state.deliveryReason = nil
        state.installationId = UUID().uuidString.lowercased()   // see PushInstallationState.installationId
        await drainRevocations(signer: context.unlockedSigner)
    }

    private func queueRevocations(for workspaces: [String], binding: PushBinding) {
        guard let origin = try? TowerOrigin(binding.origin) else { return }
        for workspace in workspaces {
            let lease = state.enrolled[workspace] ?? now()
            state.enrolled[workspace] = nil
            guard !state.pendingRevocations.contains(where: { $0.workspaceId == workspace && $0.signerNpub == binding.signerNpub && $0.origin == binding.origin }) else { continue }
            state.pendingRevocations.append(PendingPushRevocation(origin: origin, workspaceId: workspace, appNpub: binding.appNpubs[workspace] ?? "",
                                                                 installationId: state.installationId, signerNpub: binding.signerNpub,
                                                                 leaseExpiresAt: lease, now: now()))
        }
    }

    private func drainRevocations(signer: String?) async {
        var kept: [PendingPushRevocation] = []
        for var item in state.pendingRevocations {
            if now() >= item.leaseExpiresAt { continue }           // Tower stops delivering to an unrenewed lease by itself
            guard item.signerNpub == signer, now() >= item.nextAttemptAt else { kept.append(item); continue }
            let status = await registrar.revoke(item)
            switch item.record(status: status, now: now()) {
            case .done, .leaseExpired: break
            case .retry: kept.append(item)
            }
        }
        state.pendingRevocations = kept
    }

    private static func describe(_ error: Error) -> String {
        if let tower = error as? TowerError { return tower.localizedDescription }
        return (error as NSError).localizedDescription
    }
}
