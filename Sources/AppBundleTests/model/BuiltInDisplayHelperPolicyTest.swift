@testable import AppBundle
import XCTest

final class BuiltInDisplayHelperPolicyTest: XCTestCase {
    /// Regression: the helper starts in ~10ms, long before the disable it is
    /// meant to guard has been applied. It used to see the still-active panel,
    /// delete its own lease and exit, disarming confirmation timeout, process
    /// death recovery and stale-marker repair for the whole session.
    func testArmingLeaseIsNotRetiredWhileBuiltInStillLooksActive() {
        assertEquals(decide(builtInIsActive: true, isArmed: false, armingElapsed: 0.01), .wait)
    }

    func testArmedLeaseIsRetiredOncePanelIsBack() {
        assertEquals(decide(builtInIsActive: true, isArmed: true), .retire)
    }

    func testArmingLeaseIsRetiredAfterGracePeriodExpires() {
        assertEquals(decide(builtInIsActive: true, isArmed: false, armingElapsed: 120), .retire)
    }

    func testArmingLeaseIsRetiredWhenParentDiesBeforeDisabling() {
        assertEquals(decide(builtInIsActive: true, isArmed: false, parentIsAlive: false), .retire)
    }

    func testRestoresWhenLastExternalIsDetached() {
        assertEquals(decide(isArmed: true, externalMissingElapsed: 10), .restore)
    }

    /// A wake re-enumerates displays over several seconds. Reading the first
    /// empty poll as a disconnect restored the panel on every wake; while the
    /// parent is alive its own blackout rescue covers a real dark desktop.
    func testWaitsOutATransientlyEmptyExternalListWhileParentIsAlive() {
        assertEquals(decide(isArmed: true, externalMissingElapsed: 1), .wait)
    }

    func testRestoresImmediatelyWhenParentIsDeadAndExternalIsMissing() {
        assertEquals(decide(isArmed: true, parentIsAlive: false, externalMissingElapsed: 0.5), .restore)
    }

    func testRestoresWhenParentDiesWhilePanelIsDark() {
        assertEquals(decide(isArmed: true, parentIsAlive: false), .restore)
    }

    func testRestoresWhenConfirmationExpires() {
        assertEquals(decide(isArmed: true, confirmationExpired: true), .restore)
    }

    /// A transiently empty external list during the parent's own transition is
    /// not a disconnect; restoring there would fight the parent.
    func testArmingIgnoresTransientlyMissingExternal() {
        assertEquals(decide(isArmed: false, armingElapsed: 0.2, externalMissingElapsed: 10), .wait)
    }

    func testHoldsWhilePanelIsDarkAndSetupIsHealthy() {
        assertEquals(decide(isArmed: true), .wait)
    }

    private func decide(
        builtInIsActive: Bool = false,
        isArmed: Bool,
        parentIsAlive: Bool = true,
        armingElapsed: TimeInterval = 0.1,
        confirmationExpired: Bool = false,
        externalMissingElapsed: TimeInterval = 0,
    ) -> BuiltInDisplayHelperAction {
        BuiltInDisplayHelperPolicy.decide(
            builtInIsActive: builtInIsActive,
            isArmed: isArmed,
            parentIsAlive: parentIsAlive,
            armingElapsed: armingElapsed,
            confirmationExpired: confirmationExpired,
            externalMissingElapsed: externalMissingElapsed,
        )
    }
}
