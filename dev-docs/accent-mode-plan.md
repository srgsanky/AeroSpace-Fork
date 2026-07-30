# Accent Mode Implementation Plan

## Goal

Add a focused-window `accent` toggle to AeroSpace. An accented window floats over the tiled workspace in the top-center two-thirds of the usable monitor area.

The default binding will be:

```toml
[mode.main.binding]
alt-shift-space = 'accent'
```

`alt-shift-space` is free in AeroSpace's default config and is conceptually related to the common floating-window shortcut. The i3-like example already uses this binding for its existing floating toggle and should remain unchanged.

## Behavior

### Entering accent mode

Running `accent` on a non-accented focused window will:

1. Remove the window from the tiling tree.
2. Bind it to the workspace's floating-windows container.
3. Mark it as accented.
4. Keep it focused.
5. Position it in the top-center two-thirds of the workspace's usable monitor rectangle.

Removing the window from the tiling tree causes the remaining tiled windows to rebalance normally. For example, if there are two tiled windows, the remaining tiled window expands to fill the workspace behind the accented window.

### Leaving accent mode

Running `accent` again on the accented focused window will:

1. Clear its accent state.
2. Remove it from the floating-windows container.
3. Insert it into the tiling tree using AeroSpace's existing floating-to-tiling behavior.
4. Rebalance the tiled windows normally.

The exact former tree position and weight are not restored.

### State transitions

| Current state | Result of `accent` |
| --- | --- |
| Tiled | Become accented and floating |
| Ordinary floating | Become accented and floating |
| Accented | Clear accent and become tiled |
| macOS minimized, native fullscreen, hidden, popup, or unbound | Fail without changing state |

An ordinary floating window's former frame is not retained. After it becomes accented, toggling accent off sends it to tiling.

### Multiple accented windows

Accent state is per-window. Multiple windows may be accented simultaneously and may overlap. The command will not search for or alter other accented windows.

## Accent geometry

Use the workspace monitor's `visibleRectPaddedByOuterGaps` as the available rectangle. This respects the menu bar, Dock, and configured AeroSpace outer gaps.

For an available rectangle `area`, calculate:

```text
x      = area.minX + area.width / 6
y      = area.minY
width  = area.width * 2 / 3
height = area.height * 2 / 3
```

On the 1920x1080 test monitor with no outer gaps, the expected frame is:

```text
x      = 320
y      = 0
width  = 1280
height = 720
```

Keep this calculation in one pure helper, such as `accentFrame(in:)`, so command and layout behavior cannot develop different geometry.

## Implementation

### 1. Add per-window accent state

Update `Sources/AppBundle/tree/Window.swift`:

- Add `isAccent: Bool = false`.
- Do not store a former floating frame, tree parent, tree index, or weight.

In normal layout state, an accented window should belong to a `FloatingWindowsContainer`. Temporary macOS-native states may move it through the existing unconventional-window containers; returning through the existing floating path should preserve accent state.

### 2. Add accent layout behavior

Update `Sources/AppBundle/layout/layoutRecursive.swift`:

- At the beginning of `Window.layoutFloatingWindow`, check `isAccent`.
- For an accented window:
  - Calculate the frame from its workspace monitor.
  - Set `lastFloatingSize` to the calculated size.
  - Apply both position and size through `setAxFrame`.
  - Return without running ordinary floating relocation logic.

Reapplying the frame during layout makes accent a mode rather than a one-time move. It also keeps the proportions correct after workspace moves, monitor changes, gap changes, and display reconfiguration.

### 3. Centralize returning a floating window to tiling

Extract the existing floating-to-tiling behavior from `Sources/AppBundle/command/impl/LayoutCommand.swift` into a shared window helper. The helper should:

1. Capture the current AX size in `lastFloatingSize`, matching existing behavior.
2. Clear `isAccent`.
3. Call `relayoutWindow(on:..., forceTile: true)`.

Use this helper from both:

- `layout tiling`
- The accented-to-tiled branch of `accent`

This guarantees that explicitly running `layout tiling` on an accented window also clears accent state.

### 4. Add command arguments

Create `Sources/Common/cmdArgs/impl/AccentCmdArgs.swift` with:

- Command kind: `accent`
- Optional `--window-id <window-id>`
- No positional arguments
- No `on`, `off`, `toggle`, or `--fail-if-noop` options

The command always toggles when given a valid target.

Register the command in:

- `Sources/Common/cmdArgs/cmdArgsManifest.swift`
- `Sources/AppBundle/command/cmdManifest.swift`

Keep command lists alphabetically sorted according to existing repository conventions.

### 5. Implement `AccentCommand`

Create `Sources/AppBundle/command/impl/AccentCommand.swift`.

The command should:

1. Resolve `--window-id`, callback context, or focused window through `resolveTargetOrReportError`.
2. Return `No window is focused` when the target is an empty workspace.
3. Reject unconventional window parents without mutating state.
4. If `window.isAccent`:
   - Use the shared floating-to-tiling helper.
5. Otherwise:
   - Bind the window to `target.workspace.floatingWindowsContainer` if it is not already floating.
   - Set `window.isAccent = true`.
6. Leave focus unchanged.

Set `shouldResetClosedWindowsCache` to `true` because both branches can change the tree.

The command only mutates the model. AeroSpace's normal post-command layout pass applies the accent frame, matching how other layout-state commands work.

### 6. Add the default binding

Update `docs/config-examples/default-config.toml`:

```toml
# See: https://nikitabobko.github.io/AeroSpace/commands#accent
alt-shift-space = 'accent'
```

Place it near the existing layout bindings. Do not alter:

- `alt-shift-h/j/k/l`, which move tiled windows.
- The i3-like config's `alt-shift-space` floating toggle.

### 7. Update the test window adapter

Update `Sources/AppBundleTests/tree/TestWindow.swift` so its `setAxFrame` override records the requested position and size in `_rect`.

The adapter should support:

- Position and size supplied together.
- Position-only and size-only updates when an existing rectangle is available.

This makes frame behavior testable through the same `Window` interface used in production.

### 8. Add command and layout tests

Create `Sources/AppBundleTests/command/AccentCommandTest.swift`.

Cover the following cases:

1. `accent` parses successfully.
2. `accent --window-id 2` parses successfully.
3. Unknown positional arguments fail parsing.
4. With two tiled windows, accenting the focused window:
   - Moves it to the floating container.
   - Sets `isAccent`.
   - Leaves the other window as the sole tiled window.
   - Preserves focus.
5. A layout pass applies the expected 1920x1080 accent frame.
6. Toggling the same window again:
   - Clears `isAccent`.
   - Removes it from the floating container.
   - Returns it to the tiling tree.
7. An ordinary floating window becomes accented, then becomes tiled on the next toggle.
8. Two windows can be accented simultaneously without either being automatically restored.
9. `layout tiling` clears accent state.
10. `--window-id` can accent a non-focused window without changing focus.
11. An empty workspace reports `No window is focused`.
12. Unconventional windows fail without changing their state or parent.
13. A later layout pass restores an accented window that was moved away from its accent frame.
14. Ordinary non-accented floating windows retain existing layout behavior.

Do not assert an exact tree index after returning to tiling; normal AeroSpace MRU insertion behavior owns that decision.

### 9. Add command documentation

Create `docs/aerospace-accent.adoc` containing:

- Synopsis:

  ```text
  aerospace accent [-h|--help] [--window-id <window-id>]
  ```

- Toggle semantics.
- Exact geometry.
- The fact that remaining tiled windows rebalance.
- Ordinary floating windows return to tiling after the second toggle.
- Multiple accented windows may overlap.
- Exact prior tiling placement is not restored.
- The `alt-shift-space` configuration example.

Add the command to `docs/commands.adoc` in alphabetical order.

Update `grammar/commands-bnf-grammar.txt`:

```text
accent [--window-id <window_id>]
```

### 10. Regenerate derived files

Run the repository generators so the new command appears in:

- `Sources/Common/cmdHelpGenerated.swift`
- `Sources/Cli/subcommandDescriptionsGenerated.swift`
- The generated Xcode project
- Shell completions

## Verification

Run:

```bash
./generate.sh
./format.sh
./test.sh
./lint.sh
./build-docs.sh
./build-shell-completion.sh
```

Perform manual QA with the default binding:

```toml
alt-shift-space = 'accent'
```

Manual scenarios:

1. Accent one of two tiled windows and verify the other fills the workspace behind it.
2. Toggle the accented window back to tiling.
3. Accent an ordinary floating window and verify the second toggle tiles it.
4. Accent two windows and verify they can overlap.
5. Move an accented window to a workspace on another monitor and verify its proportional frame is recomputed.
6. Change outer gaps and reload config; verify the accent frame uses the new usable rectangle.
7. Verify apps with minimum-size constraints fail gracefully or use their nearest supported size.

## Non-goals

- Restoring a previous floating frame.
- Restoring the exact previous tiling parent, index, or weight.
- Enforcing one accented window per workspace.
- Preventing accented windows from overlapping.
- Adding visual borders, glow, shadows, or always-on-top behavior.
- Adding wildcard keybindings.
- Changing the i3-like configuration example.
