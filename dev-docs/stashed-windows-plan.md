# Stashed Windows Design and Implementation Plan

## Goal

Add AeroSpace-managed, per-window hiding without using macOS minimize or application hide.

A user should be able to:

1. Stash the focused window with a key binding.
2. Keep the window open while removing it from tiling and focus navigation.
3. Restore one of several stashed windows through an AeroSpace HUD.
4. Restore the selected window to normal tiling without Dock entries or macOS minimize/hide animations.

Example bindings, subject to choosing conflict-free defaults:

```toml
[mode.main.binding]
ctrl-alt-shift-h = 'stash'
ctrl-alt-h = 'stash-picker'
```

## Terminology

Use **stashed** rather than **hidden** as the canonical term.

"Hidden" is already overloaded in AeroSpace and macOS:

- macOS hides an entire application.
- AeroSpace hides windows belonging to invisible workspaces by moving them to a screen corner.
- AeroSpace has a container for windows of macOS-hidden applications.

A **stashed window** is an open window that:

- Remains owned by its AeroSpace workspace.
- Is excluded from the tiling tree and focus navigation.
- Is parked off-screen by AeroSpace.
- Can be previewed or restored through explicit stash commands.

A **previewed window** is temporarily shown by the stash picker while remaining logically stashed and excluded from tiling.

A **restored window** has left the stash and has been inserted into normal tiling.

## User experience

### Stashing the focused window

Running `stash` will:

1. Resolve the focused window or an explicit `--window-id` target.
2. Remove the window from the tiling or floating tree.
3. Add it to the owning workspace's stash.
4. Park it off-screen immediately, without a macOS animation.
5. Rebalance the remaining tiled windows normally.
6. Focus the most recently focused visible window in the same workspace.
7. Keep the current workspace active even when all its windows are stashed.

The stash does not leave a placeholder in the tiling tree. Stashed windows consume no layout space.

If no visible window remains, AeroSpace keeps logical focus on the workspace and does not automatically switch workspaces or monitors.

### Eligible windows

| Current state | Result of `stash` |
| --- | --- |
| Tiled | Become stashed |
| Ordinary floating | Become stashed |
| Accented | Clear accent presentation and become stashed |
| Already stashed | Succeed without changing state, or fail with `--fail-if-noop` |
| macOS minimized | Fail without changing state |
| macOS native fullscreen | Fail without changing state |
| Window of a macOS-hidden app | Fail without changing state |
| Popup or unbound window | Fail without changing state |

Regardless of whether a regular window was tiled, floating, or accented before being stashed, restoring it makes it tiled. The stash does not retain a former floating frame, accent state, tiling parent, index, or weight.

The transition must be atomic. If AeroSpace cannot park an eligible window, the command must leave the window in its previous state and report an error.

## Stash picker HUD

Running `stash-picker` opens an AeroSpace-owned HUD on the focused workspace's monitor:

```text
Stashed windows — workspace 2

> Safari       GitHub – Pull Request #182
  Terminal     development server
  Preview      AeroSpace documentation

j/↓ next    k/↑ previous    space preview    enter restore    esc cancel
```

Each row should display, when available:

- Application icon.
- Application name.
- Window title.
- Workspace name when showing windows from more than one workspace.

Candidates are ordered from most recently stashed to least recently stashed. Opening the picker selects the most recently stashed candidate.

If the focused workspace has no stashed windows, AeroSpace briefly shows `No stashed windows on workspace <name>` and does not enter picker input mode.

### Picker scope

The default scope is the focused workspace. This keeps restoration behavior local and predictable.

A future or optional `--all` flag may include stashed windows from all workspaces:

```bash
aerospace stash-picker --all
```

Restoring a candidate from another workspace first activates that window's owning workspace on its assigned monitor, then restores and focuses the window there. It does not move the window into the workspace from which the picker was opened.

### Keyboard navigation

The HUD supports Vim keys in addition to arrow keys:

| Key | Action |
| --- | --- |
| `j` or Down Arrow | Select the next row |
| `k` or Up Arrow | Select the previous row |
| Enter | Restore and focus the selected window |
| Escape | Close the HUD without restoring anything |
| Space | Toggle an optional live preview of the selected window |

Selection wraps at both ends. `j` on the final row selects the first row, and `k` on the first row selects the final row.

Changing selection does not change stash recency. Only a new `stash` operation changes the recency order.

### Preview behavior

Preview is optional for the first implementation; the text-and-icon picker is sufficient for selecting and restoring windows.

If live preview is implemented:

1. The selected window is temporarily moved to the same top-center frame used by accent mode.
2. It remains logically stashed and does not consume tiling space.
3. Selecting another row re-parks the previous preview before showing the new one.
4. Escape re-parks the preview and restores the window that was focused before the picker opened.
5. Enter promotes the previewed window directly into tiling.
6. Closing the previewed window selects the next candidate or dismisses the picker when none remain.

Preview must not change stash ordering or run `on-window-detected`.

### Mouse and accessibility behavior

The HUD may support single-click selection and double-click restoration, but keyboard operation is the primary interface.

Rows and controls must have native accessibility labels so VoiceOver can announce the application, title, workspace, selection, and available actions.

## Restoring a window

The picker restores its selected window through the same underlying operation exposed for scripts:

```bash
aerospace unstash --window-id <window-id>
```

Restoration will:

1. Re-park any temporary preview before changing logical ownership.
2. Remove the window from its workspace's stash.
3. Insert it into the workspace's tiling tree using AeroSpace's normal new-tiling-window insertion behavior.
4. Rebalance the workspace.
5. Focus the restored window.

If a tiled window was focused when restoration began, the restored window is inserted after that window according to existing MRU insertion behavior. If there is no tiled insertion target, it is appended to the workspace root.

The exact former tree position and weight are intentionally not restored. This matches accent mode and avoids placeholders or references to containers that may have since disappeared.

Restoration must be atomic. The window remains stashed if it cannot be rebound and made visible.

## Window lifecycle behavior

Normal window lifecycle events must not alter unrelated stashed windows.

| Event | Visible layout behavior | Stash behavior |
| --- | --- | --- |
| A new window opens | Detect, run `on-window-detected`, and insert normally | Existing stashed windows and their order are unchanged |
| A new window opens from the same app as a stashed window | Handle it as an independent new window | Do not inherit stashed state |
| A visible window closes | Rebalance remaining visible windows | Stashed windows are unchanged |
| A stashed window closes | Do not relayout visible windows solely because of the close | Remove only that stash entry |
| A stashed window is selected in the picker and closes | Keep the visible layout unchanged | Select the next candidate, or dismiss when empty |
| An application quits | Remove its visible windows normally | Remove that application's stash entries without changing the others |
| A stashed window's title changes | No layout effect | Update its HUD label without reordering |
| A layout or configuration refresh occurs | Relayout visible windows normally | Keep every stashed window parked and stashed |
| A stashed window is restored | Insert and rebalance once | Remove only the restored entry |

Restoring is not new-window detection. It must not rerun `on-window-detected` callbacks.

If an app closes a stashed window and later creates a replacement with a new window ID, AeroSpace treats the replacement as a new, visible window. Stash state is not inherited by app identity or title.

Normal focus, move, resize, layout, swap, flatten, accent, and close-all commands must ignore stashed windows unless their documentation explicitly says otherwise. Commands with an explicit `--window-id` may either support stashed windows deliberately or fail with a clear state-specific error.

## Workspace behavior

A stashed window belongs to a workspace, not directly to a monitor.

A workspace containing only stashed windows is:

- **Visually empty:** it has no windows participating in visible layout.
- **Occupied:** it must not be garbage-collected or reused as an empty stub workspace.

This distinction requires separate workspace queries rather than using one `isEffectivelyEmpty` concept for both layout and lifetime decisions.

Switching away from and back to a workspace does not restore its stashed windows. They remain parked until an explicit `unstash` action.

Moving, closing, or opening visible windows in the workspace does not alter stash ordering, membership, or restoration state.

## Monitor behavior

### Moving a workspace to another monitor

When `move-workspace-to-monitor`, workspace swapping, or monitor reassignment moves a workspace:

1. Every stashed window remains associated with that workspace.
2. No stashed window becomes tiled or visible.
3. AeroSpace recalculates a safe parking corner using the current monitor topology.
4. Restoring a window tiles it on the workspace's current monitor, not the monitor where it was originally stashed.
5. If the picker is open for that workspace, the HUD follows the workspace to the destination monitor.
6. A live preview, if active, recomputes its accent frame using the destination monitor's usable rectangle.

### Display connection, disconnection, and geometry changes

When monitor topology changes:

1. Reassign workspaces using existing AeroSpace behavior.
2. Re-park stashed windows before laying out visible windows, minimizing transient exposure.
3. Reposition an open picker HUD on the owning workspace's current monitor.
4. Preserve stash membership and ordering.

If the monitor hosting an all-workspaces picker disappears and there is no unambiguous owning workspace for the HUD, move the HUD to the newly focused monitor. If no monitor is available, dismiss the picker and keep all windows stashed.

If an application tries to move or resize a stashed window onto a visible monitor, the next AeroSpace reconciliation reparks it. Application-driven focus requests do not implicitly restore a stashed window.

## State model

```text
 tiled ───────┐
 floating ────┼── stash ──▶ stashed ── restore ──▶ tiled
 accented ────┘                │
                               ├── preview ──▶ previewed-but-still-stashed
                               │                    │
                               │                    └── cancel ──▶ stashed
                               └── close ─────▶ gone
```

Core invariants:

1. A stashed window belongs to exactly one workspace stash.
2. It does not belong to a tiling or floating container.
3. It is not a focus-navigation candidate.
4. It does not participate in layout size calculations.
5. A normal layout pass cannot accidentally restore it.
6. Only explicit restoration or window closure removes it from the stash.
7. Its physical parking location is derived from current monitor topology and is not its logical state.

## Command interface

Proposed commands:

```text
stash [--window-id <window-id>] [--fail-if-noop]
stash-picker [--workspace <workspace>|--all]
unstash --window-id <window-id>
```

Extend window inspection with a state-aware filter and interpolation:

```bash
aerospace list-windows --all --stashed yes
aerospace list-windows --all --format '%{window-id} %{window-state} %{app-name} %{window-title}'
```

`%{window-state}` should distinguish at least:

```text
tiled
floating
accented
stashed
macos_native_minimized
macos_native_fullscreen
macos_native_window_of_hidden_app
popup
```

The picker is an interface over the same stash operations used by CLI commands; it must not maintain an independent source of truth.

## Native HUD implementation

Implement the HUD entirely in Swift using native macOS frameworks. No browser view, Electron process, or external picker process is needed.

Recommended shape:

- An AppKit `NSPanel` based on the existing `NSPanelHud` class.
- A SwiftUI view hosted in the panel through `NSHostingView`.
- An `ObservableObject` picker model containing candidates, selection, scope, and preview state.
- Native application icons and accessibility metadata.

The existing `NSPanelHud` is already borderless, floating, non-activating, available on all Spaces, and able to appear alongside fullscreen windows. Reusing it gives the picker native placement and appearance while avoiding a Dock icon or normal application window.

### Keyboard input

Prefer an internal modal hotkey layer built on AeroSpace's existing hotkey machinery rather than making the HUD activate AeroSpace and steal focus from the user's application.

While the picker is open, the internal layer captures:

```text
j, k, down, up, enter, esc, space
```

It must remember the previously active user mode and restore that mode when the picker exits for any reason, including:

- Enter or Escape.
- Closing the final stashed window.
- AeroSpace being disabled.
- Configuration reload.
- Display removal.
- An internal error.

This approach keeps the panel non-activating and makes `j`/`k` behave exactly like the arrow keys. It also means Secure Input has the same limitation as normal AeroSpace shortcuts; the existing Secure Input warning behavior should remain applicable.

Direct AppKit key handling is a fallback if the modal hotkey layer proves unsuitable. In that design, a panel subclass would become key temporarily and route `keyDown` events to the same picker model, but it risks changing application activation and focus and is therefore not preferred.

## Internal module shape

Put logical stash behavior behind one deep module rather than distributing state checks across commands and layout code.

A conceptual interface is:

```text
stash(window)
restore(window)
candidates(scope)
removeClosedWindows(aliveWindowIds)
reconcileParking(monitorTopology)
```

The module owns:

- Workspace stash membership.
- Stash recency.
- Atomic stash and restore transitions.
- Physical parking and unparking.
- Picker candidate snapshots.
- Cleanup after close, app exit, disable, and display changes.

Commands, the HUD, lifecycle reconciliation, and tests should cross this same seam.

### Tree representation

Add one dedicated `StashedWindowsContainer` per workspace, analogous to AeroSpace's unconventional-window containers.

Do not represent stashed state only as a boolean on a floating window. A dedicated container makes workspace ownership and layout exclusion structural and prevents ordinary floating logic from moving the window onscreen.

The tree and traversal helpers will need to distinguish:

- All managed windows, including stashed windows.
- Visible layout windows.
- Tiled windows.
- Floating windows.
- Stashed windows.

Avoid relying on `allLeafWindowsRecursive` where the caller actually means visible windows. In particular, the visible-workspace path that currently calls `unhideFromCorner()` for all leaf windows must not unpark stashed windows.

### Parking implementation

macOS does not expose true per-window hiding through the Accessibility interface. Implement stashing by reusing or extracting AeroSpace's existing corner-parking behavior for invisible workspaces.

Parking must be:

- Idempotent.
- Derived from current monitor topology.
- Separate from logical stash membership.
- Reapplied when an app tries to reposition a stashed window.
- Removed before restoring the window to tiling.

The implementation may still leave a one-pixel edge because of macOS window-positioning constraints, and the window may remain discoverable through Mission Control or application window menus. It will not create a minimized Dock item or use minimize/hide animations.

Do not reuse one undifferentiated `isHiddenInCorner` flag for both invisible workspaces and stashed windows. The implementation must know why a window is parked so making a workspace visible cannot unpark its stashed windows.

## Disable, restart, crash, and lock behavior

Stash state is session state and is not persisted across AeroSpace process restarts.

On graceful disable or termination, AeroSpace should restore stashed windows to tiling before surrendering control. On a crash, the normal startup reconciliation should treat previously parked windows as ordinary detected windows and bring them back into visible layout. This avoids permanently stranding windows off-screen.

A transient loss of Accessibility data, such as locking the screen, must not be treated as a real close. Stash membership should participate in the existing closed-window/frozen-world protection so unlocking does not unexpectedly restore or forget stashed windows.

Reloading configuration does not clear the stash.

## Testing

Cover at least these scenarios:

1. Stashing one of two tiled windows removes it from tiling and expands the other.
2. Stashing transfers focus to a visible window in the same workspace.
3. Stashing the final visible window keeps the workspace alive and visually empty.
4. Restoring inserts the window through normal MRU tiling behavior and focuses it.
5. Former floating and accented windows restore as tiled.
6. Ineligible native states fail atomically.
7. Multiple workspaces maintain independent stash membership and ordering.
8. A new visible window does not alter existing stashed windows.
9. Closing a visible window does not alter existing stashed windows.
10. Closing one stashed window removes only that entry and does not relayout visible windows.
11. App exit removes only that app's entries.
12. `on-window-detected` does not run during restoration.
13. The picker opens with the newest candidate selected.
14. `j` and Down select the same next candidate and wrap identically.
15. `k` and Up select the same previous candidate and wrap identically.
16. Enter restores exactly one selected candidate.
17. Escape closes the HUD without changing stash state.
18. Picker exit restores the previously active AeroSpace mode on every exit path.
19. Workspace movement leaves windows stashed and reparks them for the destination topology.
20. Display disconnection preserves stash membership and does not flash a window onscreen.
21. A later layout pass cannot unpark or tile a stashed window.
22. Lock and unlock preserve stash state.
23. Graceful disable restores stashed windows so none remain stranded off-screen.

## Manual QA

1. Stash and restore windows from several applications without observing Dock entries or minimize animations.
2. Stash several windows and navigate the HUD using only `j`, `k`, Enter, and Escape.
3. Repeat navigation using Up and Down and verify identical behavior.
4. Open and close visible windows while several others remain stashed.
5. Close a stashed window through its application and verify the HUD updates.
6. Move a workspace containing stashed windows between monitors.
7. Disconnect the workspace's monitor and restore a window after reassignment.
8. Disable and restart AeroSpace and verify no window is stranded off-screen.
9. Exercise apps with minimum-size or restricted-position windows and verify atomic failure.
10. Verify VoiceOver announces picker rows and selection changes.

## Non-goals

- Using macOS minimize.
- Using macOS application hide.
- Guaranteeing complete invisibility in Mission Control or application window menus.
- Restoring the exact former tiling parent, index, or weight.
- Restoring a former floating frame or accent state.
- Persisting stash state across AeroSpace process restarts.
- Reserving empty placeholders in the tiling tree.
- Taking window screenshots or requiring Screen Recording permission for the first HUD implementation.
