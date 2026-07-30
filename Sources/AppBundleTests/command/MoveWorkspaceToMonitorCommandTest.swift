@testable import AppBundle
import Common
import XCTest

@MainActor
final class MoveWorkspaceToMonitorCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        assertEquals(parseMoveWorkspaceToMonitorTarget("move-workspace-to-monitor next"), .relative(.next))
        assertEquals(parseMoveWorkspaceToMonitorTarget("move-workspace-to-monitor main"), .patterns([.main]))
        XCTAssertTrue(parseMoveWorkspaceToMonitorArgs("move-workspace-to-monitor --swap next")?.swap == true)
    }

    func testParseDashDash() {
        assertEquals(parseMoveWorkspaceToMonitorTarget("move-workspace-to-monitor -- next"), .patterns([.pattern("next")!]))
        assertEquals(parseCommand("move-workspace-to-monitor --").errorOrNil, "ERROR: Argument \'(left|down|up|right|next|prev|<monitor-pattern>)\' is mandatory")
    }

    func testSwapIsNoopWithOneMonitor() async {
        let workspace = focus.workspace

        let result = await parseCommand("move-workspace-to-monitor --swap --wrap-around next").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        XCTAssertTrue(mainMonitor.activeWorkspace === workspace)
        XCTAssertTrue(focus.workspace === workspace)
    }

    func testSwapExchangesTwoVisibleWorkspacesAndPreservesFocus() async {
        let workspaces = setUpVisibleWorkspaces(["A", "B"])

        let result = await parseCommand("move-workspace-to-monitor --swap next").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(activeWorkspaceNames, ["B", "A"])
        XCTAssertTrue(focus.workspace === workspaces[0])
        assertEquals(workspaces[0].workspaceMonitor.monitorId_oneBased, 2)
    }

    func testSwapMovesFocusedWorkspaceAcrossThreeMonitors() async {
        let workspaces = setUpVisibleWorkspaces(["A", "B", "C"])

        let firstResult = await parseCommand("move-workspace-to-monitor --swap --wrap-around next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(firstResult.exitCode.rawValue, 0)
        assertEquals(activeWorkspaceNames, ["B", "A", "C"])
        XCTAssertTrue(focus.workspace === workspaces[0])

        let secondResult = await parseCommand("move-workspace-to-monitor --swap --wrap-around next").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertEquals(secondResult.exitCode.rawValue, 0)
        assertEquals(activeWorkspaceNames, ["B", "C", "A"])
        XCTAssertTrue(focus.workspace === workspaces[0])
    }

    func testSwapRejectsForceAssignedSourceWithoutMutation() async {
        _ = setUpVisibleWorkspaces(["A", "B"])
        config.workspaceToMonitorForceAssignment = ["A": [.sequenceNumber(1)]]

        let result = await parseCommand("move-workspace-to-monitor --swap next").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertNotEqual(result.exitCode.rawValue, 0)
        assertEquals(activeWorkspaceNames, ["A", "B"])
    }

    func testSwapRejectsForceAssignedTargetWithoutMutation() async {
        _ = setUpVisibleWorkspaces(["A", "B"])
        config.workspaceToMonitorForceAssignment = ["B": [.sequenceNumber(2)]]

        let result = await parseCommand("move-workspace-to-monitor --swap next").cmdOrDie.run(.defaultEnv, .emptyStdin)

        XCTAssertNotEqual(result.exitCode.rawValue, 0)
        assertEquals(activeWorkspaceNames, ["A", "B"])
    }

    func testMoveWithoutSwapRetainsExistingBehavior() async {
        let workspaces = setUpVisibleWorkspaces(["A", "B"])

        let result = await parseCommand("move-workspace-to-monitor next").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        XCTAssertTrue(sortedMonitors[1].activeWorkspace === workspaces[0])
        XCTAssertFalse(workspaces[1].isVisible)
        assertEquals(workspaces[1].workspaceMonitor.monitorId_oneBased, 2)
        XCTAssertFalse(sortedMonitors[0].activeWorkspace === workspaces[0])
        XCTAssertFalse(sortedMonitors[0].activeWorkspace === workspaces[1])
    }
}

@MainActor
private var activeWorkspaceNames: [String] {
    sortedMonitors.map(\.activeWorkspace.name)
}

@MainActor
private func setUpVisibleWorkspaces(_ names: [String]) -> [Workspace] {
    let monitorRects = names.indices.map {
        Rect(topLeftX: CGFloat($0 * 1920), topLeftY: 0, width: 1920, height: 1080)
    }
    setTestMonitorRects(monitorRects)
    gcMonitors()

    let workspaces = names.map(Workspace.get)
    for (monitor, workspace) in zip(sortedMonitors, workspaces) {
        check(monitor.setActiveWorkspace(workspace))
    }
    check(workspaces[0].focusWorkspace())
    return workspaces
}

@MainActor
private func parseMoveWorkspaceToMonitorArgs(_ raw: String) -> MoveWorkspaceToMonitorCmdArgs? {
    guard case .cmd(.cmd(let cmd)) = parseCommand(raw) else { return nil }
    return cmd.args as? MoveWorkspaceToMonitorCmdArgs
}

@MainActor
private func parseMoveWorkspaceToMonitorTarget(_ raw: String) -> MonitorTarget? {
    parseMoveWorkspaceToMonitorArgs(raw)?.target.val
}
