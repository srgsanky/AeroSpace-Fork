@testable import AppBundle
import XCTest

final class BuiltInDisplayReassertPolicyTest: XCTestCase {
    /// The bug this policy exists for: the machine sleeps, macOS lights the
    /// panel back up, and the user logs in to two displays again.
    func testReassertsAfterTheSystemTurnsThePanelBackOn() {
        assertEquals(decide(), .reassert)
    }

    func testHoldsWhenTheUserNeverAskedForThePanelOff() {
        assertEquals(decide(wantsBuiltInOff: false), .hold)
    }

    func testHoldsWhilePanelIsAlreadyOff() {
        assertEquals(decide(builtInIsActive: false), .hold)
    }

    /// loginwindow owns the display configuration until the user is back, and
    /// nothing they can see is fixed by reconfiguring underneath it.
    func testHoldsWhileScreenIsLocked() {
        assertEquals(decide(isScreenLocked: true), .hold)
    }

    /// Displays are still re-enumerating for a couple of seconds after a wake.
    func testHoldsUntilDisplaysHaveSettled() {
        assertEquals(decide(hasSettled: false), .hold)
    }

    /// Attached but asleep or mirrored: the same precondition the original
    /// turn-off had, so wait for it instead of spending the intent.
    func testHoldsForASleepingExternal() {
        assertEquals(decide(canTurnOff: false), .hold)
    }

    /// With no external left, the user is on the built-in display. Keeping the
    /// intent would blank the panel the next time they plug something in.
    func testAbandonsIntentOnceTheExternalIsGone() {
        assertEquals(decide(hasAttachedExternal: false, canTurnOff: false), .abandon)
    }

    /// ...but not before displays have finished re-enumerating after a wake.
    func testDoesNotAbandonOnAnUnsettledEmptyInventory() {
        assertEquals(decide(hasAttachedExternal: false, canTurnOff: false, hasSettled: false), .hold)
    }

    /// Losing the argument quietly beats flapping the desktop for the rest of
    /// the session.
    func testAbandonsIntentAfterRepeatedAttempts() {
        assertEquals(decide(recentAttempts: 3), .abandon)
    }

    /// Abandoning wins over every hold, so an exhausted budget cannot be parked
    /// behind a locked screen and resume flapping at unlock.
    func testAbandonsEvenWhenItWouldOtherwiseHold() {
        assertEquals(decide(isScreenLocked: true, recentAttempts: 3), .abandon)
    }

    private func decide(
        wantsBuiltInOff: Bool = true,
        builtInIsActive: Bool = true,
        isScreenLocked: Bool = false,
        hasAttachedExternal: Bool = true,
        canTurnOff: Bool = true,
        hasSettled: Bool = true,
        recentAttempts: Int = 0,
    ) -> BuiltInDisplayReassertAction {
        BuiltInDisplayReassertPolicy.decide(
            wantsBuiltInOff: wantsBuiltInOff,
            builtInIsActive: builtInIsActive,
            isScreenLocked: isScreenLocked,
            hasAttachedExternal: hasAttachedExternal,
            canTurnOff: canTurnOff,
            hasSettled: hasSettled,
            recentAttempts: recentAttempts,
        )
    }
}
