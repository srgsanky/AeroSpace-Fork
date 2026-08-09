import Common
import Foundation

/// The single logical seam for stash membership, ordering, parking, and restoration.
///
/// A window is stashed if and only if its parent is a `StashedWindowsContainer`. `stashOrder`
/// records only recency; it is not a second source of truth for membership.
@MainActor
enum StashedWindows {
    private static var nextOrder: UInt64 = 0

    @discardableResult
    static func stash(_ window: Window, failIfNoop: Bool = false) async throws -> Bool {
        if window.isStashed {
            if failIfNoop { throw StashOperationError.alreadyStashed(window.windowId) }
            return false
        }

        let workspace = try eligibleWorkspace(for: window)
        try await validateNativeState(window)

        // Parking happens before the tree mutation. A parking failure therefore leaves layout,
        // accent state, recency, and focus untouched.
        try await window.parkForStash(in: optimalHideCorner(for: workspace.workspaceMonitor))

        let wasFocused = focus.windowOrNil == window
        window.isAccent = false
        window.isFullscreen = false
        nextOrder &+= 1
        window.stashOrder = nextOrder
        window.bind(to: workspace.stashedWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)

        if wasFocused {
            _ = workspace.focusWorkspace()
        }
        return true
    }

    static func restore(_ window: Window, focus shouldFocus: Bool = true) async throws {
        guard case .stashedWindowsContainer(let container) = window.windowParentCases,
              let workspace = container.nodeWorkspace
        else {
            throw StashOperationError.notStashed(window.windowId)
        }
        try await restore(window, on: workspace, focus: shouldFocus, validateState: true)
    }

    static func restoreAllForDisable() async {
        let windows = candidates(.all)
        for window in windows.reversed() {
            guard let workspace = window.nodeWorkspace else { continue }
            try? await restore(window, on: workspace, focus: false, validateState: false)
        }
    }

    static func candidates(_ scope: StashScope) -> [Window] {
        let windows: [Window] = switch scope {
            case .workspace(let workspace): workspace.stashedWindows
            case .all: Workspace.all.flatMap(\.stashedWindows)
        }
        return windows.sorted { ($0.stashOrder ?? 0) > ($1.stashOrder ?? 0) }
    }

    static func reconcileParking() async {
        for window in candidates(.all) {
            guard let workspace = window.nodeWorkspace else { continue }
            try? await window.parkForStash(in: optimalHideCorner(for: workspace.workspaceMonitor))
        }
    }

    /// Used only by frozen-world restoration after a transient loss of Accessibility data.
    static func restoreFrozenMembership(_ window: Window, workspace: Workspace, order: UInt64) {
        window.isAccent = false
        window.stashOrder = order
        nextOrder = max(nextOrder, order)
        window.bind(to: workspace.stashedWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
    }

    private static func eligibleWorkspace(for window: Window) throws -> Workspace {
        switch window.windowParentCases {
            case .tilingContainer, .floatingWindowsContainer:
                return try window.nodeWorkspace.orThrow(StashOperationError.notManaged(window.windowId))
            case .stashedWindowsContainer:
                throw StashOperationError.alreadyStashed(window.windowId)
            case .macosMinimizedWindowsContainer:
                throw StashOperationError.macosMinimized(window.windowId)
            case .macosFullscreenWindowsContainer:
                throw StashOperationError.macosFullscreen(window.windowId)
            case .macosHiddenAppsWindowsContainer:
                throw StashOperationError.macosHiddenApp(window.windowId)
            case .macosPopupWindowsContainer:
                throw StashOperationError.popup(window.windowId)
            case .unbound:
                throw StashOperationError.notManaged(window.windowId)
        }
    }

    private static func validateNativeState(_ window: Window) async throws {
        if window is MacWindow, try await window.getAxRect(.nonCancellable) == nil {
            throw StashOperationError.cannotAccess(window.windowId)
        }
        if try await window.isMacosMinimized(.nonCancellable) {
            throw StashOperationError.macosMinimized(window.windowId)
        }
        if try await window.isMacosFullscreen(.nonCancellable) {
            throw StashOperationError.macosFullscreen(window.windowId)
        }
        if window.isWindowOfMacosHiddenApp() {
            throw StashOperationError.macosHiddenApp(window.windowId)
        }
    }

    private static func restore(
        _ window: Window,
        on workspace: Workspace,
        focus shouldFocus: Bool,
        validateState: Bool,
    ) async throws {
        if validateState { try await validateNativeState(window) }
        let oldOrder = window.stashOrder
        window.clearCornerParkingForRestore()
        window.stashOrder = nil
        do {
            try await window.returnToTiling(on: workspace, .nonCancellable)
        } catch {
            window.stashOrder = oldOrder
            window.bind(to: workspace.stashedWindowsContainer, adaptiveWeight: WEIGHT_DOESNT_MATTER, index: INDEX_BIND_LAST)
            try? await window.parkForStash(in: optimalHideCorner(for: workspace.workspaceMonitor))
            throw error
        }
        if shouldFocus { _ = window.focusWindow() }
    }
}

enum StashScope {
    case workspace(Workspace)
    case all
}

enum StashOperationError: Error, LocalizedError, Equatable {
    case alreadyStashed(UInt32)
    case notStashed(UInt32)
    case notManaged(UInt32)
    case macosMinimized(UInt32)
    case macosFullscreen(UInt32)
    case macosHiddenApp(UInt32)
    case popup(UInt32)
    case cannotAccess(UInt32)
    case cannotPark(UInt32)

    var errorDescription: String? {
        switch self {
            case .alreadyStashed(let id): "Window \(id) is already stashed"
            case .notStashed(let id): "Window \(id) is not stashed"
            case .notManaged(let id): "Window \(id) is unbound or isn't managed by a workspace"
            case .macosMinimized(let id): "Can't stash or restore macOS minimized window \(id)"
            case .macosFullscreen(let id): "Can't stash or restore macOS native fullscreen window \(id)"
            case .macosHiddenApp(let id): "Can't stash or restore window \(id) because its application is hidden"
            case .popup(let id): "Can't stash popup window \(id)"
            case .cannotAccess(let id): "Can't access window \(id)"
            case .cannotPark(let id): "Can't park window \(id) off-screen"
        }
    }
}

func stashedWindowCommandError(_ window: Window) -> String {
    "Window \(window.windowId) is stashed; run 'unstash --window-id \(window.windowId)' first"
}

enum WindowState: String {
    case tiled
    case floating
    case accented
    case stashed
    case macosNativeMinimized = "macos_native_minimized"
    case macosNativeFullscreen = "macos_native_fullscreen"
    case macosNativeWindowOfHiddenApp = "macos_native_window_of_hidden_app"
    case popup
    case unbound
}

extension Window {
    var windowState: WindowState {
        switch windowParentCases {
            case .tilingContainer: .tiled
            case .floatingWindowsContainer: isAccent ? .accented : .floating
            case .stashedWindowsContainer: .stashed
            case .macosMinimizedWindowsContainer: .macosNativeMinimized
            case .macosFullscreenWindowsContainer: .macosNativeFullscreen
            case .macosHiddenAppsWindowsContainer: .macosNativeWindowOfHiddenApp
            case .macosPopupWindowsContainer: .popup
            case .unbound: .unbound
        }
    }
}

extension Optional {
    fileprivate func orThrow(_ error: @autoclosure () -> any Error) throws -> Wrapped {
        guard let value = self else { throw error() }
        return value
    }
}
