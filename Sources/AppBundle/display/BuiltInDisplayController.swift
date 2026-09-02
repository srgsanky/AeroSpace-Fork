import AppKit
import Common
import CoreGraphics
import Darwin
import Foundation
import PrivateApi

private let builtInDisplayRecoveryHelperFlag = "--built-in-display-recovery-helper"
private let builtInDisplayLeaseFilename = "built-in-display-lease.json"
private let confirmationTimeout: TimeInterval = 15

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
    let stableFingerprint: String

    fileprivate init(id: CGDirectDisplayID) {
        self.id = id
        self.isBuiltIn = CGDisplayIsBuiltin(id) != 0
        self.isActive = CGDisplayIsActive(id) != 0
        self.isOnline = CGDisplayIsOnline(id) != 0
        self.isAsleep = CGDisplayIsAsleep(id) != 0
        self.isInMirrorSet = CGDisplayIsInMirrorSet(id) != 0
        self.mirrorsDisplay = CGDisplayMirrorsDisplay(id)
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
        stableFingerprint: String = "test-display",
    ) {
        self.id = id
        self.isBuiltIn = isBuiltIn
        self.isActive = isActive
        self.isOnline = isOnline
        self.isAsleep = isAsleep
        self.isInMirrorSet = isInMirrorSet
        self.mirrorsDisplay = mirrorsDisplay
        self.stableFingerprint = stableFingerprint
    }
}

struct ManagedDisplaySnapshot: Equatable, Sendable {
    let displays: [ManagedDisplayDescriptor]

    var builtIn: ManagedDisplayDescriptor? { displays.first(where: \ManagedDisplayDescriptor.isBuiltIn) }
    var usableExternals: [ManagedDisplayDescriptor] {
        displays.filter { !$0.isBuiltIn && $0.isActive && $0.isOnline && !$0.isAsleep }
    }
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
    let confirmationDeadline: Date?
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

        let workspaceNotifications = NSWorkspace.shared.notificationCenter
        for notification in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
            observerTokens.append(workspaceNotifications.addObserver(forName: notification, object: nil, queue: .main) { _ in
                Task.startUnstructured { @MainActor in BuiltInDisplayController.shared.restoreForLifecycleEvent() }
            })
        }

        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            Task.startUnstructured { @MainActor in BuiltInDisplayController.shared.handleDisplayInventoryChange() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshMenuState()
    }

    func configDidReload() {
        if !config.enableExperimentalBuiltInDisplayControl, ownsDisableLease {
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
        guard let builtIn = initialSnapshot.builtIn else { return .refused(BuiltInDisplayOffRefusal.noBuiltInDisplay.message) }

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
        guard ownsDisableLease else {
            refreshMenuState()
            return
        }

        guard let snapshot = try? adapter.snapshot() else { return }
        if snapshot.builtIn?.isActive == true {
            stopRecoveryLease()
        } else if snapshot.usableExternals.isEmpty {
            _ = apply(.on)
            return
        }
        refreshMenuState(using: snapshot)
    }

    func restoreForLifecycleEvent() {
        guard ownsDisableLease || FileManager.default.fileExists(atPath: builtInDisplayLeaseUrl.path) else {
            refreshMenuState()
            return
        }
        _ = apply(.on)
    }

    private func turnOff(
        initialSnapshot: ManagedDisplaySnapshot,
        builtIn: ManagedDisplayDescriptor,
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
        let requiresConfirmation = !trustedTopologies.contains(topologyFingerprint)
        let deadline = requiresConfirmation ? Date().addingTimeInterval(confirmationTimeout) : nil

        isTransitioning = true
        refreshMenuState()
        defer {
            isTransitioning = false
            refreshMenuState()
        }

        do {
            try startRecoveryLease(displayId: currentBuiltIn.id, confirmationDeadline: deadline)
            try adapter.setEnabled(false, displayId: currentBuiltIn.id)
            guard waitForPostcondition({ snapshot in
                snapshot.builtIn?.isActive == false && !snapshot.usableExternals.isEmpty
            }) else {
                try? adapter.setEnabled(true, displayId: currentBuiltIn.id)
                stopRecoveryLease()
                return .failed("The display transition could not be verified and was rolled back")
            }
            ownsDisableLease = true

            if requiresConfirmation {
                guard confirmDisplayConfiguration() else {
                    _ = turnOnWithoutTransitionGuard(displayId: currentBuiltIn.id)
                    return .refused("The display configuration was not confirmed and has been restored")
                }
                guard waitForPostcondition({ snapshot in
                    snapshot.builtIn?.isActive == false && !snapshot.usableExternals.isEmpty
                }) else {
                    _ = turnOnWithoutTransitionGuard(displayId: currentBuiltIn.id)
                    return .failed("The external display became unavailable, so the built-in display was restored")
                }
                trustedTopologies.insert(topologyFingerprint)
                persistTrustedTopologies()
                try updateRecoveryLease(displayId: currentBuiltIn.id, confirmationDeadline: nil)
            }
            return .changed(isEnabled: false)
        } catch {
            try? adapter.setEnabled(true, displayId: currentBuiltIn.id)
            stopRecoveryLease()
            return .failed(String(describing: error))
        }
    }

    private func turnOn(builtIn: ManagedDisplayDescriptor) -> BuiltInDisplayActionResult {
        if builtIn.isActive {
            stopRecoveryLease()
            refreshMenuState()
            return .noOp(isEnabled: true)
        }
        guard adapter.isAvailable else {
            return .refused("Built-in display control is unavailable on this macOS version")
        }

        isTransitioning = true
        refreshMenuState()
        defer {
            isTransitioning = false
            refreshMenuState()
        }
        return turnOnWithoutTransitionGuard(displayId: builtIn.id)
    }

    private func turnOnWithoutTransitionGuard(displayId: CGDirectDisplayID) -> BuiltInDisplayActionResult {
        do {
            try adapter.setEnabled(true, displayId: displayId)
            guard waitForPostcondition({ $0.builtIn?.isActive == true }) else {
                return .failed("The built-in display did not become active after the restore request")
            }
            stopRecoveryLease()
            return .changed(isEnabled: true)
        } catch {
            return .failed(String(describing: error))
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

    private func waitForPostcondition(_ predicate: (ManagedDisplaySnapshot) -> Bool) -> Bool {
        for _ in 0 ..< 20 {
            if let snapshot = try? adapter.snapshot(), predicate(snapshot) { return true }
            Thread.sleep(forTimeInterval: 0.05)
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
        try updateRecoveryLease(displayId: displayId, confirmationDeadline: confirmationDeadline)

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

    private func updateRecoveryLease(displayId: CGDirectDisplayID, confirmationDeadline: Date?) throws {
        let lease = BuiltInDisplayRecoveryLease(
            parentPid: ProcessInfo.processInfo.processIdentifier,
            builtInDisplayId: displayId,
            confirmationDeadline: confirmationDeadline,
        )
        let directory = builtInDisplayLeaseUrl.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(lease).write(to: builtInDisplayLeaseUrl, options: .atomic)
    }

    private func stopRecoveryLease() {
        ownsDisableLease = false
        try? FileManager.default.removeItem(at: builtInDisplayLeaseUrl)
        if recoveryHelper?.isRunning == true { recoveryHelper?.terminate() }
        recoveryHelper = nil
    }

    private func recoverStaleLeaseIfNeeded() {
        guard FileManager.default.fileExists(atPath: builtInDisplayLeaseUrl.path) else { return }
        ownsDisableLease = true
        guard let snapshot = try? adapter.snapshot(), let builtIn = snapshot.builtIn else { return }
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

    let adapter = CoreGraphicsBuiltInDisplayAdapter()
    while FileManager.default.fileExists(atPath: builtInDisplayLeaseUrl.path) {
        let lease: BuiltInDisplayRecoveryLease? = {
            guard let data = try? Data(contentsOf: builtInDisplayLeaseUrl) else { return nil }
            return try? JSONDecoder().decode(BuiltInDisplayRecoveryLease.self, from: data)
        }()
        let leaseParentPid = lease?.parentPid ?? parentPid
        let parentIsAlive = kill(leaseParentPid, 0) == 0 || errno == EPERM
        let snapshot = try? adapter.snapshot()
        if snapshot?.builtIn?.isActive == true {
            try? FileManager.default.removeItem(at: builtInDisplayLeaseUrl)
            return true
        }

        let confirmationExpired = lease?.confirmationDeadline.map { $0 <= Date() } == true
        let lostLastExternal = snapshot?.usableExternals.isEmpty == true
        if !parentIsAlive || confirmationExpired || lostLastExternal {
            try? adapter.setEnabled(true, displayId: lease?.builtInDisplayId ?? displayId)
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
    return true
}
