import AppKit
import Common
import CoreGraphics
import Darwin
import Foundation
import PrivateApi

private let builtInDisplayRecoveryHelperFlag = "--built-in-display-recovery-helper"
private let builtInDisplayLeaseFilename = "built-in-display-lease.json"
private let confirmationTimeout: TimeInterval = 15
/// How long the recovery helper tolerates a still-arming lease before deciding
/// the parent gave up mid-transition.
private let armingGracePeriod: TimeInterval = 30
/// How long a fully dark desktop must persist before the unconditional rescue
/// fires. Display reconfiguration transiently reports an empty active set.
private let blackoutRescueDebounce: TimeInterval = 0.75
/// Verifying a disable competes with WindowServer reconfiguration, which needs
/// more than the budget a plain state read does.
private let disableVerificationTimeout: TimeInterval = 2.5
/// How long after a wake or an unlock the controller waits before re-asserting
/// the disabled state. Display enumeration is still settling right after those,
/// and a disable issued mid-reconfiguration is the flakiest thing we can do.
private let reassertSettleDelay: TimeInterval = 2
/// Re-assertion budget. If something else keeps turning the panel back on,
/// stop fighting it rather than flapping the desktop for the rest of the login
/// session.
private let maxReassertAttempts = 3
private let reassertAttemptWindow: TimeInterval = 300
/// How long a re-asserted disable has to hold before the attempt budget is
/// refilled. The budget exists to catch a flapping fight, which cycles in
/// seconds; a disable that survives this long won its argument, and a machine
/// that sleeps often should not run out of attempts because of it.
private let reassertBudgetResetInterval: TimeInterval = 60
/// How long the helper requires the external list to stay empty before reading
/// it as a disconnect. Only applies while the parent is alive -- and while it
/// is, its own 0.75s blackout rescue already covers a genuinely dark desktop,
/// so this costs no safety and keeps the helper from restoring the panel during
/// the seconds a wake spends re-enumerating displays.
private let helperDisconnectDebounce: TimeInterval = 2.5
/// macOS synthesizes a placeholder framebuffer when the last real display is
/// detached, so the session survives with nothing physically attached. It
/// enumerates as an active, online, non-built-in display and would otherwise
/// make a blackout look like a healthy single-display desktop. It identifies
/// itself with vendor 'unkn' (kDisplayVendorIDUnknown) and model 'virt'.
private let virtualDisplayVendor: UInt32 = 0x756E_6B6E
private let virtualDisplayModel: UInt32 = 0x7669_7274

private var builtInDisplayLeaseUrl: URL {
    URL(filePath: "/tmp/")
        .appending(component: aeroSpaceAppId)
        .appending(component: builtInDisplayLeaseFilename)
}

enum BuiltInDisplayRequest: Sendable {
    case toggle
    case on
    case off
}

enum BuiltInDisplayActionResult: Equatable, Sendable {
    case changed(isEnabled: Bool)
    case noOp(isEnabled: Bool)
    case refused(String)
    case failed(String)

    var errorMessage: String? {
        switch self {
            case .changed, .noOp: nil
            case .refused(let message), .failed(let message): message
        }
    }
}

enum BuiltInDisplayMenuState: Equatable {
    case noBuiltInDisplay
    case unsupported
    case disabledByConfig
    case on(canTurnOff: Bool, externalCount: Int)
    case off(externalCount: Int)
    case transitioning
}

struct ManagedDisplayDescriptor: Equatable, Sendable {
    let id: CGDirectDisplayID
    let isBuiltIn: Bool
    let isActive: Bool
    let isOnline: Bool
    let isAsleep: Bool
    let isInMirrorSet: Bool
    let mirrorsDisplay: CGDirectDisplayID
    let isVirtual: Bool
    let stableFingerprint: String

    fileprivate init(id: CGDirectDisplayID) {
        self.id = id
        self.isBuiltIn = CGDisplayIsBuiltin(id) != 0
        self.isActive = CGDisplayIsActive(id) != 0
        self.isOnline = CGDisplayIsOnline(id) != 0
        self.isAsleep = CGDisplayIsAsleep(id) != 0
        self.isInMirrorSet = CGDisplayIsInMirrorSet(id) != 0
        self.mirrorsDisplay = CGDisplayMirrorsDisplay(id)
        self.isVirtual = CGDisplayVendorNumber(id) == virtualDisplayVendor
            && CGDisplayModelNumber(id) == virtualDisplayModel
        self.stableFingerprint = [
            CGDisplayVendorNumber(id),
            CGDisplayModelNumber(id),
            CGDisplaySerialNumber(id),
            CGDisplayUnitNumber(id),
        ].map(String.init).joined(separator: "-")
    }

    init(
        id: CGDirectDisplayID,
        isBuiltIn: Bool,
        isActive: Bool,
        isOnline: Bool = true,
        isAsleep: Bool = false,
        isInMirrorSet: Bool = false,
        mirrorsDisplay: CGDirectDisplayID = kCGNullDirectDisplay,
        isVirtual: Bool = false,
        stableFingerprint: String = "test-display",
    ) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.isActive = isActive
        self.isOnline = isOnline
        self.isAsleep = isAsleep
        self.isInMirrorSet = isInMirrorSet
        self.mirrorsDisplay = mirrorsDisplay
        self.isVirtual = isVirtual
        self.stableFingerprint = stableFingerprint
    }
}

struct ManagedDisplaySnapshot: Equatable, Sendable {
    let displays: [ManagedDisplayDescriptor]

    var builtIn: ManagedDisplayDescriptor? { displays.first(where: \ManagedDisplayDescriptor.isBuiltIn) }

    /// Externals that satisfy the precondition for turning the panel off:
    /// attached, awake, and drawable right now.
    var usableExternals: [ManagedDisplayDescriptor] {
        displays.filter { !$0.isBuiltIn && !$0.isVirtual && $0.isActive && $0.isOnline && !$0.isAsleep }
    }

    /// Externals that are still physically attached, including ones in display
    /// sleep. Recovery has to key on this rather than on ``usableExternals``:
    /// ordinary screen sleep is not a disconnect, and reading it as one
    /// re-enables the panel on an idle timer.
    var attachedExternals: [ManagedDisplayDescriptor] {
        displays.filter { !$0.isBuiltIn && !$0.isVirtual && $0.isOnline }
    }

    /// Whether anything at all could put pixels on screen once woken. A
    /// disabled panel reports offline, so an empty result is a real blackout
    /// rather than a sleeping desktop.
    var hasAttachedDisplay: Bool { displays.contains { $0.isOnline && !$0.isVirtual } }
}

enum BuiltInDisplayOffRefusal: Equatable, Sendable {
    case noBuiltInDisplay
    case noUsableExternalDisplay
    case mirroredConfiguration

    var message: String {
        switch self {
            case .noBuiltInDisplay:
                "This Mac has no built-in display"
            case .noUsableExternalDisplay:
                "Refusing to turn off the built-in display: no active external display is available"
            case .mirroredConfiguration:
                "Refusing to turn off the built-in display while display mirroring is active"
        }
    }
}

enum BuiltInDisplayPolicy {
    static func validateTurningOff(_ snapshot: ManagedDisplaySnapshot) -> BuiltInDisplayOffRefusal? {
        guard let builtIn = snapshot.builtIn else { return .noBuiltInDisplay }
        guard !snapshot.usableExternals.isEmpty else { return .noUsableExternalDisplay }
        if builtIn.isInMirrorSet || snapshot.usableExternals.contains(where: { $0.isInMirrorSet || $0.mirrorsDisplay != kCGNullDirectDisplay }) {
            return .mirroredConfiguration
        }
        return nil
    }
}

enum BuiltInDisplayReassertAction: Equatable, Sendable {
    /// Turn the panel back off: it is on, but the user asked for it to be off
    /// and the safety preconditions hold again.
    case reassert
    /// Leave it alone for now and look again on the next tick.
    case hold
    /// Give up on the intent. Something keeps re-enabling the panel and losing
    /// that argument quietly beats flapping the desktop.
    case abandon
}

/// Decides whether to re-apply a disabled built-in display that came back on
/// its own. macOS re-enables the panel across sleep, screen lock and login, so
/// the hardware state is not a reliable record of what the user asked for; the
/// intent is, and this is where it gets reconciled. Pure so the loop-avoidance
/// cases are testable without hardware.
enum BuiltInDisplayReassertPolicy {
    static func decide(
        wantsBuiltInOff: Bool,
        builtInIsActive: Bool,
        isScreenLocked: Bool,
        hasAttachedExternal: Bool,
        canTurnOff: Bool,
        hasSettled: Bool,
        recentAttempts: Int,
    ) -> BuiltInDisplayReassertAction {
        guard wantsBuiltInOff else { return .hold }
        // Already how the user wants it. Not an attempt, not a failure.
        guard builtInIsActive else { return .hold }
        guard recentAttempts < maxReassertAttempts else { return .abandon }
        // The lock screen owns the display configuration until the user is back,
        // and reconfiguring underneath it buys nothing they can see. Displays are
        // still re-enumerating for a second or two after a wake, so nothing below
        // this line should trust the inventory before it settles.
        guard !isScreenLocked, hasSettled else { return .hold }
        // Settled, unlocked, panel on, nothing external attached: the user is
        // working on the built-in display and the intent is spent. Keeping it
        // would blank the panel out from under them the moment they plug a
        // display back in, which is not something they asked for.
        guard hasAttachedExternal else { return .abandon }
        // An attached but sleeping or mirrored external fails the same
        // precondition the original turn-off had. Wait for it rather than
        // spending the intent on a state that is still resolving.
        guard canTurnOff else { return .hold }
        return .reassert
    }
}

enum BuiltInDisplayHelperAction: Equatable, Sendable {
    /// The panel is genuinely back. Drop the lease and exit.
    case retire
    /// Restore the built-in display now.
    case restore
    /// Keep holding the lease.
    case wait
}

/// Decision logic for the out-of-process recovery helper, kept pure so the
/// blackout-critical cases are testable without hardware.
enum BuiltInDisplayHelperPolicy {
    static func decide(
        builtInIsActive: Bool,
        isArmed: Bool,
        parentIsAlive: Bool,
        armingElapsed: TimeInterval,
        confirmationExpired: Bool,
        externalMissingElapsed: TimeInterval,
    ) -> BuiltInDisplayHelperAction {
        // A lease with no armedAt is still arming: the parent wrote it but has
        // not yet verified the panel went dark. The helper reaches its first
        // check within milliseconds -- long before CGCompleteDisplayConfiguration
        // returns -- so treating "built-in still active" as a completed recovery
        // here retires the lease before it ever protects anything.
        let isArming = !isArmed && parentIsAlive && armingElapsed < armingGracePeriod
        if builtInIsActive { return isArming ? .wait : .retire }
        // While arming, a momentarily asleep or re-enumerating external must not
        // read as a disconnect: that would fight the transition the parent runs.
        // The same holds after a wake, which is why the disconnect needs to
        // persist rather than being believed on its first poll.
        let isDisconnected = externalMissingElapsed >= helperDisconnectDebounce && !isArming
        if !parentIsAlive || confirmationExpired || isDisconnected { return .restore }
        return .wait
    }
}

private enum CoreGraphicsDisplayError: Error, CustomStringConvertible {
    case inventory(CGError)
    case begin(CGError)
    case configure(CGError)
    case complete(CGError)

    var description: String {
        switch self {
            case .inventory(let error): "Unable to read display inventory (CGError \(error.rawValue))"
            case .begin(let error): "Unable to begin display configuration (CGError \(error.rawValue))"
            case .configure(let error): "Unable to change built-in display state (CGError \(error.rawValue))"
            case .complete(let error): "Unable to apply display configuration (CGError \(error.rawValue))"
        }
    }
}

@MainActor
private final class CoreGraphicsBuiltInDisplayAdapter {
    var isAvailable: Bool { AeroPrivateDisplayControlIsAvailable() }

    func snapshot() throws -> ManagedDisplaySnapshot {
        let ids = try allDisplayIds()
        return ManagedDisplaySnapshot(displays: ids.map(ManagedDisplayDescriptor.init(id:)))
    }

    func setEnabled(_ enabled: Bool, displayId: CGDirectDisplayID) throws {
        var configRef: CGDisplayConfigRef?
        let beginResult = unsafe CGBeginDisplayConfiguration(&configRef)
        guard beginResult == .success else { throw CoreGraphicsDisplayError.begin(beginResult) }

        let configureResult = unsafe AeroPrivateConfigureDisplayEnabled(configRef, displayId, enabled)
        guard configureResult == .success else {
            unsafe CGCancelDisplayConfiguration(configRef)
            throw CoreGraphicsDisplayError.configure(configureResult)
        }

        let completeResult = unsafe CGCompleteDisplayConfiguration(configRef, .forSession)
        guard completeResult == .success else { throw CoreGraphicsDisplayError.complete(completeResult) }
    }

    private func allDisplayIds() throws -> [CGDirectDisplayID] {
        guard isAvailable else { return try onlineDisplayIds() }
        var count: UInt32 = 0
        let countResult = unsafe AeroPrivateGetDisplayList(0, nil, &count)
        guard countResult == .success else { throw CoreGraphicsDisplayError.inventory(countResult) }
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = unsafe AeroPrivateGetDisplayList(count, &ids, &count)
        guard listResult == .success else { throw CoreGraphicsDisplayError.inventory(listResult) }
        return Array(ids.prefix(Int(count)))
    }

    private func onlineDisplayIds() throws -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        let countResult = unsafe CGGetOnlineDisplayList(0, nil, &count)
        guard countResult == .success else { throw CoreGraphicsDisplayError.inventory(countResult) }
        guard count > 0 else { return [] }

        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let listResult = unsafe CGGetOnlineDisplayList(count, &ids, &count)
        guard listResult == .success else { throw CoreGraphicsDisplayError.inventory(listResult) }
        return Array(ids.prefix(Int(count)))
    }
}

private struct BuiltInDisplayRecoveryLease: Codable {
    let parentPid: Int32
    let builtInDisplayId: CGDirectDisplayID
    /// Identifies the generation of the lease. Re-assertion retires one lease
    /// and starts another, and the outgoing helper can outlive the terminate()
    /// that retired it; without this it would delete its successor's file and
    /// leave the next disable unguarded.
    let token: String?
    let confirmationDeadline: Date?
    /// When the parent verified the panel actually went dark. While this is nil
    /// the lease is still arming, and the helper must not retire it merely
    /// because the built-in display still looks active.
    let armedAt: Date?
}

private let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { _, flags, _ in
    if flags.contains(.beginConfigurationFlag) { return }
    Task.startUnstructured { @MainActor in
        BuiltInDisplayController.shared.handleDisplayInventoryChange()
    }
}

@MainActor
final class BuiltInDisplayController: NSObject {
    static let shared = BuiltInDisplayController()

    private let adapter = CoreGraphicsBuiltInDisplayAdapter()
    private var ownsDisableLease = false
    private var isTransitioning = false
    /// Set when a restore was requested but could not be verified. The poller
    /// keeps retrying until the panel is actually back.
    private var pendingRestore = false
    private var zeroActiveDisplaysSince: Date?
    /// The panel's display ID captured when AeroSpace disabled it. CoreGraphics
    /// stops enumerating a disabled built-in display once the last real display
    /// is detached, but CGSConfigureDisplayEnabled still accepts the remembered
    /// ID -- verified on hardware.
    private var disabledBuiltInDisplayId: CGDirectDisplayID?
    /// What the user asked for, as opposed to what the hardware currently
    /// reports. macOS re-enables a disabled panel across system sleep, screen
    /// lock and login, so the intent has to outlive the state and be re-applied.
    private var wantsBuiltInDisplayOff = false
    /// Timestamps of recent re-assertions, used to bound the fight.
    private var reassertAttempts: [Date] = []
    /// Since when the panel has stayed dark while the intent says it should be.
    private var disabledStateHoldingSince: Date?
    /// Set on wake and unlock: re-assertion waits for display enumeration to
    /// settle rather than racing WindowServer.
    private var reassertNotBefore: Date?
    private var leaseToken: String?
    private var recoveryHelper: Process?
    private var observerTokens: [NSObjectProtocol] = []
    private var isStarted = false

    override private init() {
        super.init()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true

        recoverStaleLeaseIfNeeded()
        unsafe CGDisplayRegisterReconfigurationCallback(displayReconfigurationCallback, nil)

        let appNotifications = NotificationCenter.default
        observerTokens.append(appNotifications.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main,
        ) { _ in
            Task.startUnstructured { @MainActor in BuiltInDisplayController.shared.handleDisplayInventoryChange() }
        })

        // Sleep and wake deliberately do not restore the panel: an attached
        // external is still attached across a sleep, and turning the built-in
        // display back on every time the machine naps defeats the whole point of
        // having turned it off. Safety keeps riding on attachment instead --
        // rescueFromBlackoutIfNeeded and the recovery helper both restore the
        // moment nothing else is drawable, whether the machine is asleep or not.
        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            observerTokens.append(workspaceNotifications.addObserver(forName: notification, object: nil, queue: .main) { _ in
                Task.startUnstructured { @MainActor in BuiltInDisplayController.shared.deferReassertion() }
            })
        }

        // Unlocking reconfigures the displays again, so it restarts the settle
        // window. The lock *state* is read from the session rather than tracked
        // from these notifications: a missed unlock would otherwise wedge
        // re-assertion off for the rest of the session.
        let distributedNotifications = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            observerTokens.append(distributedNotifications.addObserver(
                forName: Notification.Name(name),
                object: nil,
                queue: .main,
            ) { _ in
                Task.startUnstructured { @MainActor in BuiltInDisplayController.shared.deferReassertion() }
            })
        }

        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task.startUnstructured { @MainActor in BuiltInDisplayController.shared.handleDisplayInventoryChange() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshMenuState()
    }

    /// Wake and unlock both land while the display list is still churning.
    /// Hold re-assertion until it settles.
    func deferReassertion() {
        reassertNotBefore = Date().addingTimeInterval(reassertSettleDelay)
    }

    /// Whether the login window is currently covering the session. Read live so
    /// a dropped lock/unlock notification cannot leave the controller believing
    /// the screen is still locked.
    private var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    func configDidReload() {
        if !config.enableExperimentalBuiltInDisplayControl, ownsDisableLease || wantsBuiltInDisplayOff {
            _ = apply(.on)
        } else {
            refreshMenuState()
        }
    }

    func apply(_ request: BuiltInDisplayRequest) -> BuiltInDisplayActionResult {
        guard !isTransitioning else { return .refused("A display transition is already in progress") }

        let initialSnapshot: ManagedDisplaySnapshot
        do {
            initialSnapshot = try adapter.snapshot()
        } catch {
            return .failed(String(describing: error))
        }
        guard let builtIn = initialSnapshot.builtIn else {
            // Disabled panel plus no real display attached: CoreGraphics drops it
            // from the inventory entirely. Turning it back on still works through
            // the remembered ID, and that is exactly when it matters most.
            guard let remembered = disabledBuiltInDisplayId, request != .off else {
                return .refused(BuiltInDisplayOffRefusal.noBuiltInDisplay.message)
            }
            return turnOnRemembered(displayId: remembered)
        }

        let resolvedRequest: BuiltInDisplayRequest = switch request {
            case .toggle: builtIn.isActive ? .off : .on
            case .on: .on
            case .off: .off
        }

        switch resolvedRequest {
            case .toggle:
                die("Toggle request must be resolved before applying display state")
            case .on:
                return turnOn(builtIn: builtIn)
            case .off:
                return turnOff(initialSnapshot: initialSnapshot, builtIn: builtIn)
        }
    }

    func handleDisplayInventoryChange() {
        guard isStarted, !isTransitioning else { return }
        guard let snapshot = try? adapter.snapshot() else { return }

        if rescueFromBlackoutIfNeeded(snapshot) { return }

        if snapshot.builtIn?.isActive == true {
            pendingRestore = false
            disabledStateHoldingSince = nil
            if reassertDisabledStateIfNeeded(snapshot) { return }
            if ownsDisableLease { stopRecoveryLease() }
            refreshMenuState(using: snapshot)
            return
        }
        // Below here the panel is dark or gone. If that is what was asked for and
        // it has held, the fight is over and the attempt budget can be refilled.
        noteDisabledStateHolding()
        if pendingRestore {
            _ = apply(.on)
            return
        }
        guard ownsDisableLease else {
            refreshMenuState(using: snapshot)
            return
        }
        if snapshot.attachedExternals.isEmpty {
            // Right after a wake or an unlock an empty external list is usually
            // re-enumeration rather than a disconnect, and believing it here
            // restores the panel -- the exact behavior this design set out to
            // stop. Nothing is risked by waiting: with the panel dark and no
            // external attached the desktop is black, and rescueFromBlackout-
            // IfNeeded above restores it within 0.75s regardless of this window.
            if Date() < (reassertNotBefore ?? .distantPast) {
                refreshMenuState(using: snapshot)
                return
            }
            _ = apply(.on)
            return
        }
        refreshMenuState(using: snapshot)
    }

    /// Last-resort rescue. When nothing is drawable the desktop is black, and no
    /// ownership question is worth preserving that: restore the panel whoever
    /// turned it off. Deliberately not gated on ``ownsDisableLease`` — that flag
    /// lives only in memory and is cleared by several failure paths that leave
    /// the panel dark.
    private func rescueFromBlackoutIfNeeded(_ snapshot: ManagedDisplaySnapshot) -> Bool {
        guard let displayId = snapshot.builtIn?.id ?? disabledBuiltInDisplayId,
              !snapshot.hasAttachedDisplay
        else {
            zeroActiveDisplaysSince = nil
            return false
        }
        let since = zeroActiveDisplaysSince ?? Date()
        zeroActiveDisplaysSince = since
        guard Date().timeIntervalSince(since) >= blackoutRescueDebounce else { return false }
        zeroActiveDisplaysSince = nil
        _ = turnOnRemembered(displayId: displayId)
        return true
    }

    private func noteDisabledStateHolding() {
        guard wantsBuiltInDisplayOff else {
            disabledStateHoldingSince = nil
            return
        }
        let since = disabledStateHoldingSince ?? Date()
        disabledStateHoldingSince = since
        if Date().timeIntervalSince(since) >= reassertBudgetResetInterval { reassertAttempts = [] }
    }

    /// Re-applies a disable that the system undid. Returns true when it acted,
    /// so the caller does not go on to interpret the panel being on as the user
    /// having asked for it back and drop the lease.
    private func reassertDisabledStateIfNeeded(_ snapshot: ManagedDisplaySnapshot) -> Bool {
        let now = Date()
        reassertAttempts.removeAll { now.timeIntervalSince($0) > reassertAttemptWindow }
        let action = BuiltInDisplayReassertPolicy.decide(
            wantsBuiltInOff: wantsBuiltInDisplayOff,
            builtInIsActive: snapshot.builtIn?.isActive == true,
            isScreenLocked: isScreenLocked,
            hasAttachedExternal: !snapshot.attachedExternals.isEmpty,
            canTurnOff: config.enableExperimentalBuiltInDisplayControl
                && adapter.isAvailable
                && BuiltInDisplayPolicy.validateTurningOff(snapshot) == nil,
            hasSettled: now >= (reassertNotBefore ?? .distantPast),
            recentAttempts: reassertAttempts.count,
        )
        switch action {
            case .hold:
                return false
            case .abandon:
                wantsBuiltInDisplayOff = false
                reassertAttempts = []
                return false
            case .reassert:
                guard let builtIn = snapshot.builtIn else { return false }
                reassertAttempts.append(now)
                // The lease and helper from the original turn-off are stale: they
                // are watching a panel that is currently on, and a second helper
                // racing the first over one lease file ends with the survivor
                // deleting it. Retire that generation and let turnOff arm a fresh
                // one for the transition it is about to run.
                if ownsDisableLease { stopRecoveryLease() }
                // Never prompt here. The user already confirmed this topology;
                // a modal every time the machine wakes is its own bug.
                _ = turnOff(initialSnapshot: snapshot, builtIn: builtIn, skipConfirmation: true)
                return true
        }
    }

    func restoreForLifecycleEvent() {
        wantsBuiltInDisplayOff = false
        guard ownsDisableLease || FileManager.default.fileExists(atPath: builtInDisplayLeaseUrl.path) else {
            refreshMenuState()
            return
        }
        _ = apply(.on)
    }

    private func turnOff(
        initialSnapshot: ManagedDisplaySnapshot,
        builtIn: ManagedDisplayDescriptor,
        skipConfirmation: Bool = false,
    ) -> BuiltInDisplayActionResult {
        guard config.enableExperimentalBuiltInDisplayControl else {
            return .refused(
                "Built-in display control is experimental. Set enable-experimental-built-in-display-control = true and reload the config",
            )
        }
        guard adapter.isAvailable else {
            return .refused("Built-in display control is unavailable on this macOS version")
        }
        if !builtIn.isActive { return .noOp(isEnabled: false) }
        if let refusal = BuiltInDisplayPolicy.validateTurningOff(initialSnapshot) { return .refused(refusal.message) }

        focusExternalFallback(from: initialSnapshot)

        let snapshot: ManagedDisplaySnapshot
        do {
            snapshot = try adapter.snapshot()
        } catch {
            return .failed(String(describing: error))
        }
        if let refusal = BuiltInDisplayPolicy.validateTurningOff(snapshot) { return .refused(refusal.message) }
        guard let currentBuiltIn = snapshot.builtIn, currentBuiltIn.isActive else { return .noOp(isEnabled: false) }

        let topologyFingerprint = trustedTopologyFingerprint(snapshot.usableExternals)
        let requiresConfirmation = !skipConfirmation && !trustedTopologies.contains(topologyFingerprint)
        let deadline = requiresConfirmation ? Date().addingTimeInterval(confirmationTimeout) : nil

        isTransitioning = true
        refreshMenuState()
        defer {
            isTransitioning = false
            refreshMenuState()
        }

        do {
            try startRecoveryLease(displayId: currentBuiltIn.id, confirmationDeadline: deadline)
            // Ownership starts the moment the panel may go dark, not once the
            // transition is verified. Every failure path below has to leave a
            // watchdog armed.
            ownsDisableLease = true
            disabledBuiltInDisplayId = currentBuiltIn.id
            try adapter.setEnabled(false, displayId: currentBuiltIn.id)
            guard waitForPostcondition(timeout: disableVerificationTimeout, { $0.builtIn?.isActive == false }) else {
                rollBackToBuiltInEnabled(displayId: currentBuiltIn.id)
                return .failed("The display transition could not be verified and was rolled back")
            }
            // The real safety invariant is that something stayed drawable. Asking
            // for a specific external to be awake mid-reconfiguration is flaky.
            guard waitForPostcondition(timeout: disableVerificationTimeout, { $0.hasAttachedDisplay }) else {
                rollBackToBuiltInEnabled(displayId: currentBuiltIn.id)
                return .failed("No display remained active, so the built-in display was restored")
            }
            // Arm the helper only now. Until the panel is verified dark it would
            // read the pre-transition state as a completed recovery and retire.
            try updateRecoveryLease(displayId: currentBuiltIn.id, confirmationDeadline: deadline, armedAt: Date())

            if requiresConfirmation {
                guard confirmDisplayConfiguration() else {
                    _ = turnOnWithoutTransitionGuard(displayId: currentBuiltIn.id)
                    return .refused("The display configuration was not confirmed and has been restored")
                }
                guard waitForPostcondition({ snapshot in
                    snapshot.builtIn?.isActive == false && !snapshot.attachedExternals.isEmpty
                }) else {
                    _ = turnOnWithoutTransitionGuard(displayId: currentBuiltIn.id)
                    return .failed("The external display became unavailable, so the built-in display was restored")
                }
                trustedTopologies.insert(topologyFingerprint)
                persistTrustedTopologies()
                try updateRecoveryLease(displayId: currentBuiltIn.id, confirmationDeadline: nil, armedAt: Date())
            }
            // Record the intent only once the panel is verified dark, so a
            // transition that never took hold cannot leave the controller trying
            // to restore a state that was never reached.
            wantsBuiltInDisplayOff = true
            return .changed(isEnabled: false)
        } catch {
            rollBackToBuiltInEnabled(displayId: currentBuiltIn.id)
            return .failed(String(describing: error))
        }
    }

    private func turnOn(builtIn: ManagedDisplayDescriptor) -> BuiltInDisplayActionResult {
        if builtIn.isActive {
            wantsBuiltInDisplayOff = false
            stopRecoveryLease()
            refreshMenuState()
            return .noOp(isEnabled: true)
        }
        guard adapter.isAvailable else {
            return .refused("Built-in display control is unavailable on this macOS version")
        }

        return turnOnRemembered(displayId: builtIn.id)
    }

    private func turnOnRemembered(displayId: CGDirectDisplayID) -> BuiltInDisplayActionResult {
        guard adapter.isAvailable else {
            return .refused("Built-in display control is unavailable on this macOS version")
        }
        isTransitioning = true
        refreshMenuState()
        defer {
            isTransitioning = false
            refreshMenuState()
        }
        return turnOnWithoutTransitionGuard(displayId: displayId)
    }

    private func turnOnWithoutTransitionGuard(displayId: CGDirectDisplayID) -> BuiltInDisplayActionResult {
        // Every path that reaches here -- an explicit request, a rescue, a
        // stale-lease repair -- wants the panel on. Drop the intent first, or
        // the poller re-asserts the disable a second later and undoes it.
        wantsBuiltInDisplayOff = false
        do {
            try adapter.setEnabled(true, displayId: displayId)
            guard waitForPostcondition({ $0.builtIn?.isActive == true }) else {
                pendingRestore = true
                return .failed("The built-in display did not become active after the restore request")
            }
            pendingRestore = false
            stopRecoveryLease()
            return .changed(isEnabled: true)
        } catch {
            pendingRestore = true
            return .failed(String(describing: error))
        }
    }

    /// Restores the panel after a failed transition. The lease is released only
    /// once the built-in display is verified active again: a swallowed rollback
    /// failure must never disarm the watchdogs while the panel is still dark.
    private func rollBackToBuiltInEnabled(displayId: CGDirectDisplayID) {
        wantsBuiltInDisplayOff = false
        try? adapter.setEnabled(true, displayId: displayId)
        if waitForPostcondition({ $0.builtIn?.isActive == true }) {
            pendingRestore = false
            stopRecoveryLease()
        } else {
            pendingRestore = true
            ownsDisableLease = true
        }
    }

    private func focusExternalFallback(from snapshot: ManagedDisplaySnapshot) {
        let externalIds = snapshot.usableExternals.map(\.id).toSet()
        let externalMonitors = monitors.filter { monitor in
            monitor.displayId.map(externalIds.contains) == true
        }
        guard let fallback = externalMonitors.first(where: { $0.activeWorkspace == focus.workspace })
            ?? externalMonitors.first(where: \Monitor.isMain)
            ?? externalMonitors.first
        else { return }
        if !externalIds.contains(focus.workspace.workspaceMonitor.displayId ?? kCGNullDirectDisplay) {
            _ = fallback.activeWorkspace.focusWorkspace()
        }
    }

    private func waitForPostcondition(
        timeout: TimeInterval = 1,
        _ predicate: (ManagedDisplaySnapshot) -> Bool,
    ) -> Bool {
        let interval: TimeInterval = 0.05
        for _ in 0 ..< max(1, Int((timeout / interval).rounded())) {
            if let snapshot = try? adapter.snapshot(), predicate(snapshot) { return true }
            Thread.sleep(forTimeInterval: interval)
        }
        return false
    }

    private func confirmDisplayConfiguration() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Built-in display is off"
        alert.informativeText = "Keep this display configuration? It will be restored automatically in 15 seconds."
        alert.addButton(withTitle: "Keep")
        alert.addButton(withTitle: "Restore")

        let timeoutTimer = Timer(
            timeInterval: confirmationTimeout,
            target: self,
            selector: #selector(abortDisplayConfirmation(_:)),
            userInfo: nil,
            repeats: false,
        )
        RunLoop.main.add(timeoutTimer, forMode: .common)
        defer { timeoutTimer.invalidate() }

        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func abortDisplayConfirmation(_: Timer) {
        NSApp.abortModal()
    }

    private func trustedTopologyFingerprint(_ displays: [ManagedDisplayDescriptor]) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return ([os] + displays.map(\.stableFingerprint).sorted()).joined(separator: "|")
    }

    private var trustedTopologies: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "trustedBuiltInDisplayTopologies") ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: "trustedBuiltInDisplayTopologies") }
    }

    private func persistTrustedTopologies() {
        UserDefaults.standard.synchronize()
    }

    private func startRecoveryLease(displayId: CGDirectDisplayID, confirmationDeadline: Date?) throws {
        let token = UUID().uuidString
        leaseToken = token
        try updateRecoveryLease(displayId: displayId, confirmationDeadline: confirmationDeadline, armedAt: nil)

        guard let executable = Bundle.main.executableURL ?? CommandLine.arguments.first.map({ URL(filePath: $0) }) else {
            try? FileManager.default.removeItem(at: builtInDisplayLeaseUrl)
            throw CocoaError(.executableNotLoadable)
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            builtInDisplayRecoveryHelperFlag,
            String(ProcessInfo.processInfo.processIdentifier),
            String(displayId),
            token,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            recoveryHelper = process
        } catch {
            try? FileManager.default.removeItem(at: builtInDisplayLeaseUrl)
            throw error
        }
    }

    private func updateRecoveryLease(displayId: CGDirectDisplayID, confirmationDeadline: Date?, armedAt: Date?) throws {
        let lease = BuiltInDisplayRecoveryLease(
            parentPid: ProcessInfo.processInfo.processIdentifier,
            builtInDisplayId: displayId,
            token: leaseToken,
            confirmationDeadline: confirmationDeadline,
            armedAt: armedAt,
        )
        let directory = builtInDisplayLeaseUrl.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(lease).write(to: builtInDisplayLeaseUrl, options: .atomic)
    }

    private func stopRecoveryLease() {
        ownsDisableLease = false
        disabledBuiltInDisplayId = nil
        leaseToken = nil
        try? FileManager.default.removeItem(at: builtInDisplayLeaseUrl)
        if recoveryHelper?.isRunning == true { recoveryHelper?.terminate() }
        recoveryHelper = nil
    }

    private func recoverStaleLeaseIfNeeded() {
        guard FileManager.default.fileExists(atPath: builtInDisplayLeaseUrl.path) else { return }
        ownsDisableLease = true
        let lease: BuiltInDisplayRecoveryLease? = {
            guard let data = try? Data(contentsOf: builtInDisplayLeaseUrl) else { return nil }
            return try? JSONDecoder().decode(BuiltInDisplayRecoveryLease.self, from: data)
        }()
        disabledBuiltInDisplayId = lease?.builtInDisplayId
        guard let snapshot = try? adapter.snapshot() else { return }
        guard let builtIn = snapshot.builtIn else {
            // Panel not enumerated: recover through the id recorded in the lease.
            if let remembered = disabledBuiltInDisplayId, adapter.isAvailable {
                _ = turnOnWithoutTransitionGuard(displayId: remembered)
            }
            return
        }
        if builtIn.isActive {
            stopRecoveryLease()
        } else if adapter.isAvailable {
            _ = turnOnWithoutTransitionGuard(displayId: builtIn.id)
        }
    }

    private func refreshMenuState(using suppliedSnapshot: ManagedDisplaySnapshot? = nil) {
        if isTransitioning {
            TrayMenuModel.shared.builtInDisplayState = .transitioning
            return
        }
        let snapshot = suppliedSnapshot ?? (try? adapter.snapshot())
        guard let snapshot, let builtIn = snapshot.builtIn else {
            TrayMenuModel.shared.builtInDisplayState = .noBuiltInDisplay
            return
        }
        if !builtIn.isActive {
            TrayMenuModel.shared.builtInDisplayState = .off(externalCount: snapshot.usableExternals.count)
        } else if !adapter.isAvailable {
            TrayMenuModel.shared.builtInDisplayState = .unsupported
        } else if !config.enableExperimentalBuiltInDisplayControl {
            TrayMenuModel.shared.builtInDisplayState = .disabledByConfig
        } else {
            TrayMenuModel.shared.builtInDisplayState = .on(
                canTurnOff: BuiltInDisplayPolicy.validateTurningOff(snapshot) == nil,
                externalCount: snapshot.usableExternals.count,
            )
        }
    }
}

/// Runs before normal AeroSpace initialization in a child copy of the app.
/// The helper restores the built-in display if the parent dies, confirmation
/// expires, or the last external display disappears.
@MainActor
public func runBuiltInDisplayRecoveryHelperIfRequested() -> Bool {
    let args = CommandLine.arguments
    guard args.getOrNil(atIndex: 1) == builtInDisplayRecoveryHelperFlag else { return false }
    guard let parentPidString = args.getOrNil(atIndex: 2),
          let parentPid = Int32(parentPidString),
          let displayIdString = args.getOrNil(atIndex: 3),
          let displayId = CGDirectDisplayID(displayIdString)
    else { return true }
    let token = args.getOrNil(atIndex: 4)

    let adapter = CoreGraphicsBuiltInDisplayAdapter()
    let startedAt = Date()
    var externalMissingSince: Date?
    while FileManager.default.fileExists(atPath: builtInDisplayLeaseUrl.path) {
        let lease: BuiltInDisplayRecoveryLease? = {
            guard let data = try? Data(contentsOf: builtInDisplayLeaseUrl) else { return nil }
            return try? JSONDecoder().decode(BuiltInDisplayRecoveryLease.self, from: data)
        }()
        // A newer generation of the lease means this helper was retired and the
        // file on disk belongs to its successor. Leave without touching it.
        if let token, let leaseToken = lease?.token, leaseToken != token { return true }
        let leaseParentPid = lease?.parentPid ?? parentPid
        let parentIsAlive = kill(leaseParentPid, 0) == 0 || errno == EPERM
        let snapshot = try? adapter.snapshot()
        // A failed snapshot must not read as a disconnect.
        let hasAttachedExternal = snapshot.map { !$0.attachedExternals.isEmpty } ?? true
        externalMissingSince = hasAttachedExternal ? nil : (externalMissingSince ?? Date())
        let action = BuiltInDisplayHelperPolicy.decide(
            builtInIsActive: snapshot?.builtIn?.isActive == true,
            isArmed: lease?.armedAt != nil,
            parentIsAlive: parentIsAlive,
            armingElapsed: Date().timeIntervalSince(startedAt),
            confirmationExpired: lease?.confirmationDeadline.map { $0 <= Date() } == true,
            externalMissingElapsed: externalMissingSince.map { Date().timeIntervalSince($0) } ?? 0,
        )
        switch action {
            case .retire:
                try? FileManager.default.removeItem(at: builtInDisplayLeaseUrl)
                return true
            case .restore:
                try? adapter.setEnabled(true, displayId: lease?.builtInDisplayId ?? displayId)
            case .wait:
                break
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return true
}
