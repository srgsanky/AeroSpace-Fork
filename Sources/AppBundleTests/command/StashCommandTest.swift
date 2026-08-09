@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class StashCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("stash", StashCmdArgs(rawArgs: []))
        testParseSingleCommandSucc(
            "stash --window-id 2 --fail-if-noop",
            StashCmdArgs(rawArgs: []).copy(\.windowId, 2).copy(\.failIfNoop, true),
        )
        assertNil(parseCommand("stash-picker").errorOrNil)
        assertNil(parseCommand("stash-picker --workspace dev").errorOrNil)
        assertNil(parseCommand("stash-picker --all").errorOrNil)
        testParseCommandFail(
            "stash-picker --all --workspace dev",
            msg: "ERROR: Conflicting options: --all, --workspace",
            exitCode: 2,
        )
        assertNil(parseCommand("unstash --window-id 2").errorOrNil)
        testParseCommandFail(
            "unstash",
            msg: "Mandatory option is not specified (--window-id)",
            exitCode: 2,
        )
    }

    func testStashTiledWindowRemovesItFromLayoutAndTransfersFocus() async {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let stashed = TestWindow.new(id: 1, parent: root)
        assertTrue(stashed.focusWindow())
        TestWindow.new(id: 2, parent: root)

        let result = await parseCommand("stash").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertTrue(stashed.isStashed)
        assertTrue(stashed.parent === workspace.stashedWindowsContainer)
        assertEquals(root.layoutDescription, .h_tiles([.window(2)]))
        assertEquals(focus.windowOrNil?.windowId, 2)
        assertEquals(workspace.visibleLeafWindowsRecursive.map(\.windowId), [2])
    }

    func testStashingFinalWindowLeavesWorkspaceVisuallyEmptyButOccupied() async {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertTrue(window.focusWindow())

        await parseCommand("stash").cmdOrDie.run(.defaultEnv, .emptyStdin)
        Workspace.garbageCollectUnusedWorkspaces()

        assertTrue(workspace.isEffectivelyEmpty)
        assertTrue(workspace.isOccupied)
        assertNil(focus.windowOrNil)
        assertTrue(focus.workspace === workspace)
        assertTrue(Workspace.all.contains(workspace))
    }

    func testRestoreUsesNormalMruTilingInsertionAndFocusesWindow() async {
        let workspace = focus.workspace
        let root = workspace.rootTilingContainer
        let stashed = TestWindow.new(id: 1, parent: root)
        assertTrue(stashed.focusWindow())
        TestWindow.new(id: 2, parent: root)
        await parseCommand("stash").cmdOrDie.run(.defaultEnv, .emptyStdin)

        let result = await parseCommand("unstash --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertFalse(stashed.isStashed)
        assertNil(stashed.stashOrder)
        assertEquals(root.layoutDescription, .h_tiles([.window(2), .window(1)]))
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testFloatingAndAccentedWindowsRestoreAsTiled() async {
        let workspace = focus.workspace
        let floating = TestWindow.new(id: 1, parent: workspace.floatingWindowsContainer)
        let accented = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        accented.isAccent = true

        await parseCommand("stash --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("stash --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("unstash --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("unstash --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertFalse(floating.isFloating)
        assertFalse(accented.isFloating)
        assertFalse(accented.isAccent)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1, 2])
    }

    func testAlreadyStashedIsNoopUnlessRequestedToFail() async {
        let window = TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        await parseCommand("stash --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let order = window.stashOrder

        let noop = await parseCommand("stash --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)
        let failure = await parseCommand("stash --window-id 1 --fail-if-noop").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(noop.exitCode.rawValue, 0)
        assertEquals(failure.exitCode.rawValue, 2)
        assertEquals(window.stashOrder, order)
        assertTrue(window.isStashed)
    }

    func testIneligibleNativeWindowFailsWithoutChangingParent() async {
        let workspace = focus.workspace
        let parent = workspace.macOsNativeFullscreenWindowsContainer
        let window = TestWindow.new(id: 1, parent: parent)
        window.isMacosFullscreenForTest = true

        let result = await parseCommand("stash --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 2)
        assertTrue(window.parent === parent)
        assertNil(window.stashOrder)
    }

    func testWorkspaceStashesHaveIndependentRecency() async throws {
        let firstWorkspace = focus.workspace
        let secondWorkspace = Workspace.get(byName: "other")
        let first = TestWindow.new(id: 1, parent: firstWorkspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: firstWorkspace.rootTilingContainer)
        let other = TestWindow.new(id: 3, parent: secondWorkspace.rootTilingContainer)

        try await StashedWindows.stash(first)
        try await StashedWindows.stash(other)
        try await StashedWindows.stash(second)

        assertEquals(StashedWindows.candidates(.workspace(firstWorkspace)).map(\.windowId), [2, 1])
        assertEquals(StashedWindows.candidates(.workspace(secondWorkspace)).map(\.windowId), [3])
        assertEquals(StashedWindows.candidates(.all).map(\.windowId), [2, 3, 1])
    }

    func testListWindowsFiltersAndFormatsStashedState() async {
        let workspace = focus.workspace
        TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        await parseCommand("stash --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)

        let result = await parseCommand("list-windows --all --stashed yes --format '%{window-id} %{window-state}'")
            .cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 0)
        assertEquals(result.stdout, ["2 stashed"])
    }

    func testNormalCommandsRejectExplicitStashedWindow() async {
        TestWindow.new(id: 1, parent: focus.workspace.rootTilingContainer)
        await parseCommand("stash --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)

        let result = await parseCommand("fullscreen --window-id 1").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, ["Window 1 is stashed; run 'unstash --window-id 1' first"])
    }

    func testVisibleWindowLifecycleDoesNotChangeStashOrder() async throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await StashedWindows.stash(first)
        try await StashedWindows.stash(second)
        let originalOrder = StashedWindows.candidates(.workspace(workspace)).map(\.windowId)

        let visible = TestWindow.new(id: 3, parent: workspace.rootTilingContainer)
        assertEquals(StashedWindows.candidates(.workspace(workspace)).map(\.windowId), originalOrder)
        visible.unbindFromParent()
        assertEquals(StashedWindows.candidates(.workspace(workspace)).map(\.windowId), originalOrder)
    }

    func testClosingStashedWindowRemovesOnlyThatEntry() async throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)
        try await StashedWindows.stash(first)
        try await StashedWindows.stash(second)

        second.closeAxWindow()

        assertEquals(StashedWindows.candidates(.workspace(workspace)).map(\.windowId), [1])
        assertTrue(first.isStashed)
    }

    func testRestoreAllForDisableLeavesNoWindowParkedInStash() async throws {
        let workspace = focus.workspace
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        let second = TestWindow.new(id: 2, parent: workspace.floatingWindowsContainer)
        try await StashedWindows.stash(first)
        try await StashedWindows.stash(second)

        await StashedWindows.restoreAllForDisable()

        assertTrue(workspace.stashedWindows.isEmpty)
        assertEquals(workspace.rootTilingContainer.allLeafWindowsRecursive.map(\.windowId), [1, 2])
    }

    func testLayoutPassKeepsWindowLogicallyStashed() async throws {
        let workspace = focus.workspace
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        try await StashedWindows.stash(window)

        try await workspace.layoutWorkspace()

        assertTrue(window.isStashed)
        assertTrue(window.parent === workspace.stashedWindowsContainer)
        assertTrue(workspace.rootTilingContainer.allLeafWindowsRecursive.isEmpty)
    }

    func testPickerSelectionWrapsInBothDirections() {
        let model = StashPickerModel()
        model.replaceCandidates([
            StashPickerCandidate(windowId: 1, appName: "One", title: "", workspaceName: "1", icon: nil),
            StashPickerCandidate(windowId: 2, appName: "Two", title: "", workspaceName: "1", icon: nil),
        ])

        assertEquals(model.selectedWindowId, 1)
        model.selectPrevious()
        assertEquals(model.selectedWindowId, 2)
        model.selectNext()
        assertEquals(model.selectedWindowId, 1)
        model.selectNext()
        assertEquals(model.selectedWindowId, 2)
    }
}
