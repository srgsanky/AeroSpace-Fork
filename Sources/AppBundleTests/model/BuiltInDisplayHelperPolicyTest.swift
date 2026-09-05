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
        assertEquals(decide(isArmed: true, hasAttachedExternal: false), .restore)
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
        assertEquals(decide(isArmed: false, armingElapsed: 0.2, hasAttachedExternal: false), .wait)
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
        hasAttachedExternal: Bool = true,
    ) -> BuiltInDisplayHelperAction {
        BuiltInDisplayHelperPolicy.decide(
            builtInIsActive: builtInIsActive,
            isArmed: isArmed,
            parentIsAlive: parentIsAlive,
            armingElapsed: armingElapsed,
            confirmationExpired: confirmationExpired,
            hasAttachedExternal: hasAttachedExternal,
        )
    }
}
