@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) async {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // A stashed window can still be raised through macOS APIs by context switchers such as
        // Contexts. Treat that native focus change as an explicit request to restore the window.
        // The ID check is important: while stashing the currently focused window, macOS can keep
        // reporting its stale native focus until AeroSpace focuses the next visible window.
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
        if let nativeFocused, nativeFocused.isStashed {
            try? await StashedWindows.restore(nativeFocused)
        } else {
            _ = nativeFocused?.focusWindow()
        }
    }
    (nativeFocused as? MacWindow)?.macApp.lastNativeFocusedWindowId = nativeFocused?.windowId
}
