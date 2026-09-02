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
            isActive: true,
            isAsleep: isAsleep,
            isInMirrorSet: isInMirrorSet,
            stableFingerprint: "external",
        )
    }
}
