# Native macOS Tabs with AeroSpace

## Summary

Applications that use native macOS tabs can appear to AeroSpace as multiple
windows even though macOS displays only one tab group. This can cause:

- invisible tabs to consume layout space;
- focus commands to cycle through tabs as though they were windows;
- the visible tab to jump between AeroSpace positions;
- `on-window-detected` callbacks to run once for each tab;
- grouped tabs to interact badly with workspace assignment.

This has been reproduced with Ghostty and Typora. It is the known upstream
[native-tabs issue #68](https://github.com/nikitabobko/AeroSpace/issues/68),
not an application-specific layout problem.

## Observed behavior

### Ghostty

With one Ghostty window open, AeroSpace initially tracked one window. After
creating a native tab with `Cmd-T`, the observations were:

| View of the application | Window count |
| --- | ---: |
| AeroSpace model | 2 |
| System Events accessibility view | 1 |
| On-screen CoreGraphics layer-0 windows | 1 |

AeroSpace retained the original window ID and registered a new ID for the
selected tab. It assigned the IDs different frames even though only the new ID
was visible.

### Typora

Opening two documents normally produced two real windows. With an AeroSpace
accordion layout, those windows overlap with the configured accordion offset;
this is expected and can look superficially like tabbing.

After using **Window -> Merge All Windows**, however, the observations became:

| View of the application | Window count |
| --- | ---: |
| AeroSpace model | 2 |
| System Events accessibility view | 1 |
| On-screen CoreGraphics layer-0 windows | 1 |

This is the same native-tab failure as Ghostty. Typora opening two documents is
not by itself the problem; the problem begins when those documents become a
native macOS tab group, whether through automatic tabbing, manual merging,
full-screen behavior, or restored window state.

## Root cause

Ghostty deliberately uses native macOS tabs. Typora also exposes the native
macOS window-tab commands. Native tabs do not have a stable one-to-one mapping
to independently visible windows in the public macOS Accessibility APIs.

For applications such as Ghostty, selecting another tab changes the focused
window ID. The previous tab's Accessibility object can remain valid and retain
a non-null containing window ID even though it is no longer listed in the
application's `AXWindows` collection or represented by an on-screen
CoreGraphics window.

AeroSpace currently preserves cached AX windows while
`containingWindowId()` remains non-null:

- `Sources/AppBundle/tree/MacApp.swift`,
  `refreshAndGetAliveWindowIds(frontmostAppBundleId:)`;
- `Sources/AppBundle/tree/MacWindow.swift`, `getOrRegister(windowId:macApp:)`;
- `Sources/AppBundle/layout/refresh.swift`, `refresh()`.

The relevant flow is:

1. Keep previously tracked AX window IDs whose objects still have a containing
   window ID.
2. Register each new ID returned by `AXWindows` or `AXFocusedWindow`.
3. Give every registered ID its own `MacWindow` and tree position.
4. Lay out and focus those tree nodes independently.

This leaves the inactive tab in the AeroSpace tree. Focusing that tree node can
make AppKit select the associated tab, which explains why directional focus
appears to switch tabs or move the visible window unexpectedly.

AeroSpace cannot simply discard everything absent from `AXWindows` because
macOS also omits windows located on inactive native Spaces. The fix therefore
needs to distinguish a native-tab replacement from a valid window on another
Space.

## Recommended workaround

The most reliable workaround is to avoid native macOS tabs and let AeroSpace
manage real windows. AeroSpace's accordion layout can provide tab-like window
stacking without confusing physical windows and native tabs.

### Ghostty

Use `Cmd-N` to create a real window instead of `Cmd-T`.

To retain the `Cmd-T` habit, add this to `~/.config/ghostty/config`:

```ini
keybind = super+t=new_window
```

This was verified to produce two AeroSpace windows, two Accessibility windows,
and two on-screen CoreGraphics windows.

Other alternatives:

- use Ghostty splits (`Cmd-D` and `Cmd-Shift-D` by default);
- map `Cmd-T` to a split, for example `keybind = super+t=new_split:right`;
- use tmux or zellij inside one terminal window;
- use a terminal such as WezTerm or iTerm2 that implements its own tabs;
- set `window-decoration = none` in Ghostty, which disables native tabs on
  macOS but also removes window decorations.

Ghostty documents its use of native tabs in
[ghostty#1840](https://github.com/ghostty-org/ghostty/issues/1840) and
[ghostty#2006](https://github.com/ghostty-org/ghostty/issues/2006).

### Typora

1. Set **System Settings -> Desktop & Dock -> Prefer tabs when opening
   documents -> Never**.
2. Convert an existing tab group back to real windows with **Window -> Move Tab
   to New Window**.
3. If tab groups return at launch, disable session/window restoration or split
   the tabs before quitting Typora.

The equivalent global preference is commonly set from the command line with:

```bash
defaults write -g AppleWindowTabbingMode -string manual
```

Prefer the System Settings control when available, since the underlying
preference is not a stable public interface. Quit and reopen affected
applications after changing it.

### AeroSpace floating workaround

If native tabs must remain enabled, floating the affected applications prevents
phantom tab nodes from consuming tiled space:

```toml
[[on-window-detected]]
if.app-id = 'com.mitchellh.ghostty'
run = 'layout floating'

[[on-window-detected]]
if.app-id = 'abnerworks.Typora'
run = 'layout floating'
```

Apply the change with:

```bash
aerospace reload-config
```

This is only a partial workaround. AeroSpace may still include inactive tabs in
focus navigation, and every real window from those applications will also
float.

## Recovering a confused layout

After separating or closing native tabs:

1. Quit and reopen the affected application, or restart AeroSpace, to clear
   stale window IDs.
2. Run `aerospace flatten-workspace-tree` if the workspace tree still has an
   undesirable shape.
3. Confirm that the number of AeroSpace windows now matches the number of real
   application windows:

```bash
aerospace list-windows --all \
  --format '%{window-id}\t%{app-bundle-id}\t%{window-title}\t%{workspace}' \
  | grep -E 'com\.mitchellh\.ghostty|abnerworks\.Typora'
```

## Proper fix

A proper fix must recognize that a newly focused native-tab window ID replaces
the previously focused ID in the same physical tab group. It should retire the
old ID and splice the new `MacWindow` into the old tree slot instead of adding a
second leaf. Retired IDs also need to remain suppressed during subsequent
refreshes so that stale AX objects are not resurrected.

The project tracks native-tab support in
[issue #68](https://github.com/nikitabobko/AeroSpace/issues/68).
[PR #2225](https://github.com/nikitabobko/AeroSpace/pull/2225), **Insert
replaced native-tab windows into their old tree slot**, proposes this approach.
Consult the issue and pull request for current availability and limitations.
