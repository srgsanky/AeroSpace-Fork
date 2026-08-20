@testable import AppBundle
import XCTest

@MainActor
final class WorkspaceMonitorReconfigurationTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testActiveWorkspaceSurvivesTransientZeroMonitorState() {
        let previousWorkspace = mainMonitor.activeWorkspace

        setTestMonitorRects([])
        gcMonitors()

        XCTAssertTrue(mainMonitor.activeWorkspace === previousWorkspace)
    }

    func testActiveWorkspaceSurvivesStaleDisconnectedMonitor() {
        let firstRect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        let secondRect = Rect(topLeftX: 1920, topLeftY: 0, width: 1920, height: 1080)
        setTestMonitorRects([firstRect, secondRect])
        gcMonitors()
        let disconnectedMonitor = sortedMonitors[1]

        setTestMonitorRects([firstRect])
        gcMonitors()

        XCTAssertTrue(disconnectedMonitor.activeWorkspace === mainMonitor.activeWorkspace)
    }

    func testActiveWorkspaceWorksAfterMonitorSnapshotRecovers() {
        let rect = Rect(topLeftX: 0, topLeftY: 0, width: 1920, height: 1080)
        setTestMonitorRects([])
        gcMonitors()
        setTestMonitorRects([rect])
        gcMonitors()

        _ = mainMonitor.activeWorkspace
    }
}
