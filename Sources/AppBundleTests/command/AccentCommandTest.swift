@testable import AppBundle
import AppKit
import Common
import XCTest

@MainActor
final class AccentCommandTest: XCTestCase {
    override func setUp() async throws { setUpWorkspacesForTests() }

    func testParse() {
        testParseSingleCommandSucc("accent", AccentCmdArgs(rawArgs: []))
        testParseSingleCommandSucc(
            "accent --window-id 2",
            AccentCmdArgs(rawArgs: []).copy(\.windowId, 2),
        )
        testParseCommandFail("accent unexpected", msg: "ERROR: Unknown argument 'unexpected'", exitCode: 2)
    }

    func testAccentTiledWindow() async {
        let workspace = Workspace.get(byName: name)
        let root = workspace.rootTilingContainer
        let accented = TestWindow.new(id: 1, parent: root)
        assertEquals(accented.focusWindow(), true)
        TestWindow.new(id: 2, parent: root)

        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertTrue(accented.parent === workspace.floatingWindowsContainer)
        assertTrue(accented.isAccent)
        assertEquals(root.layoutDescription, .h_tiles([.window(2)]))
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testLayoutAppliesAccentFrame() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)

        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)
        try await workspace.layoutWorkspace()

        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.topLeftX, 320)
        assertEquals(rect?.topLeftY, 0)
        assertEquals(rect?.width, 1280)
        assertEquals(rect?.height, 720)
        assertEquals(window.lastFloatingSize?.width, 1280)
        assertEquals(window.lastFloatingSize?.height, 720)
    }

    func testToggleAccentBackToTiling() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)

        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertFalse(window.isAccent)
        assertEquals(workspace.floatingWindows, [])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testOrdinaryFloatingWindowBecomesAccentThenTiled() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(
            id: 1,
            parent: workspace.floatingWindowsContainer,
            rect: Rect(topLeftX: 100, topLeftY: 100, width: 500, height: 400),
        )
        assertEquals(window.focusWindow(), true)

        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertTrue(window.isAccent)
        assertTrue(window.parent === workspace.floatingWindowsContainer)

        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)
        assertFalse(window.isAccent)
        assertEquals(workspace.floatingWindows, [])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    func testMultipleWindowsCanBeAccented() async {
        let workspace = Workspace.get(byName: name)
        let first = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(first.focusWindow(), true)
        let second = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("accent --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertTrue(first.isAccent)
        assertTrue(second.isAccent)
        assertEquals(workspace.floatingWindows.map(\.windowId), [1, 2])
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testLayoutTilingClearsAccent() async {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)

        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)
        await parseCommand("layout tiling").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertFalse(window.isAccent)
        assertEquals(workspace.floatingWindows, [])
        assertEquals(workspace.rootTilingContainer.layoutDescription, .h_tiles([.window(1)]))
    }

    func testWindowIdAccentsNonFocusedWindowWithoutChangingFocus() async {
        let workspace = Workspace.get(byName: name)
        let focused = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(focused.focusWindow(), true)
        let target = TestWindow.new(id: 2, parent: workspace.rootTilingContainer)

        await parseCommand("accent --window-id 2").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertTrue(target.isAccent)
        assertTrue(target.parent === workspace.floatingWindowsContainer)
        assertEquals(focus.windowOrNil?.windowId, 1)
    }

    func testEmptyWorkspaceFails() async {
        let workspace = Workspace.get(byName: name)

        let result = await parseCommand("accent").cmdOrDie
            .run(.defaultEnv.withWorkspaceName(workspace.name), .emptyStdin)

        assertEquals(result.exitCode.rawValue, 2)
        assertEquals(result.stderr, [noWindowIsFocused])
        assertTrue(workspace.isEffectivelyEmpty)
    }

    func testUnconventionalWindowFailsWithoutChangingStateOrParent() async {
        let workspace = Workspace.get(byName: name)
        let container = workspace.macOsNativeFullscreenWindowsContainer
        let window = TestWindow.new(id: 1, parent: container)
        window.isMacosFullscreenForTest = true
        assertEquals(window.focusWindow(), true)

        let result = await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)

        assertEquals(result.exitCode.rawValue, 2)
        assertFalse(window.isAccent)
        assertTrue(window.parent === container)
    }

    func testLaterLayoutRestoresAccentFrame() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(id: 1, parent: workspace.rootTilingContainer)
        assertEquals(window.focusWindow(), true)
        await parseCommand("accent").cmdOrDie.run(.defaultEnv, .emptyStdin)

        window.setAxFrame(CGPoint(x: 10, y: 20), CGSize(width: 300, height: 200))
        try await workspace.layoutWorkspace()

        let rect = try await window.getAxRect(.nonCancellable)
        assertEquals(rect?.topLeftX, 320)
        assertEquals(rect?.topLeftY, 0)
        assertEquals(rect?.width, 1280)
        assertEquals(rect?.height, 720)
    }

    func testOrdinaryFloatingLayoutIsUnchanged() async throws {
        let workspace = Workspace.get(byName: name)
        let window = TestWindow.new(
            id: 1,
            parent: workspace.floatingWindowsContainer,
            rect: Rect(topLeftX: 100, topLeftY: 120, width: 500, height: 400),
        )

        try await workspace.layoutWorkspace()

        let rect = try await window.getAxRect(.nonCancellable)
        assertFalse(window.isAccent)
        assertEquals(rect?.topLeftX, 100)
        assertEquals(rect?.topLeftY, 120)
        assertEquals(rect?.width, 500)
        assertEquals(rect?.height, 400)
    }
}
