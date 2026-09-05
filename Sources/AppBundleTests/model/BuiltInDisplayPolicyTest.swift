@testable import AppBundle
import XCTest

final class BuiltInDisplayPolicyTest: XCTestCase {
    func testRefusesToTurnOffWithoutBuiltInDisplay() {
        let snapshot = ManagedDisplaySnapshot(displays: [externalDisplay()])
        assertEquals(BuiltInDisplayPolicy.validateTurningOff(snapshot), .noBuiltInDisplay)
    }

    func testRefusesToTurnOffWithoutUsableExternalDisplay() {
        let snapshot = ManagedDisplaySnapshot(displays: [builtInDisplay()])
        assertEquals(BuiltInDisplayPolicy.validateTurningOff(snapshot), .noUsableExternalDisplay)
    }

    func testRefusesSleepingExternalDisplay() {
        let snapshot = ManagedDisplaySnapshot(displays: [builtInDisplay(), externalDisplay(isAsleep: true)])
        assertEquals(BuiltInDisplayPolicy.validateTurningOff(snapshot), .noUsableExternalDisplay)
    }

    func testRefusesMirroredConfiguration() {
        let snapshot = ManagedDisplaySnapshot(displays: [
            builtInDisplay(isInMirrorSet: true),
            externalDisplay(isInMirrorSet: true),
        ])
        assertEquals(BuiltInDisplayPolicy.validateTurningOff(snapshot), .mirroredConfiguration)
    }

    func testAllowsActiveExtendedExternalDisplay() {
        let snapshot = ManagedDisplaySnapshot(displays: [builtInDisplay(), externalDisplay()])
        assertNil(BuiltInDisplayPolicy.validateTurningOff(snapshot))
    }

    /// Display sleep must not read as a disconnect. An asleep external fails the
    /// turn-off precondition but is still attached, so recovery leaves the panel
    /// alone instead of re-enabling it on an idle timer.
    func testSleepingExternalIsUnusableButStillAttached() {
        let snapshot = ManagedDisplaySnapshot(displays: [builtInDisplay(), externalDisplay(isAsleep: true)])
        assertEquals(snapshot.usableExternals.count, 0)
        assertEquals(snapshot.attachedExternals.count, 1)
        assertTrue(snapshot.hasAttachedDisplay)
    }

    /// A disabled panel reports offline, so a detached external leaves nothing
    /// attached at all -- the real blackout the rescue exists for.
    func testDisabledPanelWithNoExternalHasNothingAttached() {
        let snapshot = ManagedDisplaySnapshot(displays: [disabledBuiltInDisplay()])
        assertEquals(snapshot.attachedExternals.count, 0)
        assertFalse(snapshot.hasAttachedDisplay)
    }

    /// A sleeping desktop is not a blackout: waking the external recovers it.
    func testSleepingDesktopIsNotABlackout() {
        let snapshot = ManagedDisplaySnapshot(displays: [
            disabledBuiltInDisplay(),
            externalDisplay(isAsleep: true),
        ])
        assertTrue(snapshot.hasAttachedDisplay)
    }

    /// macOS synthesizes this when the last real display is detached. It reports
    /// as active, online and non-built-in, so before it was recognised it made a
    /// blackout look like a healthy desktop and defeated every recovery layer.
    func testVirtualDisplayIsNotAUsableExternal() {
        let snapshot = ManagedDisplaySnapshot(displays: [builtInDisplay(), virtualDisplay()])
        assertEquals(BuiltInDisplayPolicy.validateTurningOff(snapshot), .noUsableExternalDisplay)
    }

    func testVirtualDisplayIsNotAttached() {
        let snapshot = ManagedDisplaySnapshot(displays: [disabledBuiltInDisplay(), virtualDisplay()])
        assertEquals(snapshot.attachedExternals.count, 0)
        assertFalse(snapshot.hasAttachedDisplay)
    }

    /// The exact inventory observed on hardware while the panel was dark: the
    /// built-in display is gone from the list and only the phantom remains.
    func testPhantomOnlyInventoryIsABlackout() {
        let snapshot = ManagedDisplaySnapshot(displays: [virtualDisplay()])
        assertNil(snapshot.builtIn)
        assertFalse(snapshot.hasAttachedDisplay)
        assertEquals(snapshot.attachedExternals.count, 0)
    }

    private func virtualDisplay() -> ManagedDisplayDescriptor {
        ManagedDisplayDescriptor(
            id: 12,
            isBuiltIn: false,
            isActive: true,
            isOnline: true,
            isVirtual: true,
            stableFingerprint: "virtual",
        )
    }

    private func disabledBuiltInDisplay() -> ManagedDisplayDescriptor {
        // CoreGraphics reports a disabled built-in panel as offline.
        ManagedDisplayDescriptor(
            id: 1,
            isBuiltIn: true,
            isActive: false,
            isOnline: false,
            stableFingerprint: "built-in",
        )
    }

    private func builtInDisplay(isInMirrorSet: Bool = false) -> ManagedDisplayDescriptor {
        ManagedDisplayDescriptor(
            id: 1,
            isBuiltIn: true,
            isActive: true,
            isInMirrorSet: isInMirrorSet,
            stableFingerprint: "built-in",
        )
    }

    private func externalDisplay(isAsleep: Bool = false, isInMirrorSet: Bool = false) -> ManagedDisplayDescriptor {
        ManagedDisplayDescriptor(
            id: 2,
            isBuiltIn: false,
            // CoreGraphics reports a display in power save as inactive but online.
            isActive: !isAsleep,
            isAsleep: isAsleep,
            isInMirrorSet: isInMirrorSet,
            stableFingerprint: "external",
        )
    }
}
