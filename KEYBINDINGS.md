# Keybindings

The active custom bindings are configured in `~/.config/aerospace/aerospace.toml` under `[mode.main.binding]`.

## Monitors

To swap the focused workspace with the active workspace on another monitor, press and release <kbd>⌃ Control</kbd> + <kbd>⇧ Shift</kbd> + <kbd>Tab</kbd>, then press a direction key:

| Key | Direction |
| --- | --- |
| <kbd>H</kbd> | Left |
| <kbd>J</kbd> | Down |
| <kbd>K</kbd> | Up |
| <kbd>L</kbd> | Right |

This uses **Control**, not Command. Press <kbd>Esc</kbd> after the initial shortcut to cancel without swapping.

## Stashed windows

AeroSpace calls per-window hiding **stashing**. This is distinct from macOS hiding an entire application.

| Keybinding | Command | Action |
| --- | --- | --- |
| <kbd>⌘ Cmd</kbd> + <kbd>H</kbd> | `stash` | Stash the focused window. |
| <kbd>⌘ Cmd</kbd> + <kbd>⌥ Option</kbd> + <kbd>H</kbd> | `stash-picker` | Open the stashed-window picker for the current workspace. |

In the picker, use <kbd>J</kbd>/<kbd>↓</kbd> and <kbd>K</kbd>/<kbd>↑</kbd> to select a window, <kbd>Enter</kbd> to restore it, or <kbd>Esc</kbd> to cancel.
