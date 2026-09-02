# Built-in Display Control Design and Implementation Plan

## Goal

Allow a Mac laptop to remain open for use of its keyboard and trackpad while its built-in display is logically disabled and work continues on external displays.

The feature must be safety-biased:

- The built-in display can be turned off only while at least one usable external display is active.
- The built-in display is automatically restored when the last external display disconnects.
- Turning the built-in display on is always allowed.
- AeroSpace never turns the built-in display off merely because an external display was connected.
- A failed, interrupted, or unsupported transition must leave a usable display active.

A black overlay, zero brightness, or backlight control is not sufficient. Those approaches leave the built-in display in the macOS desktop, allowing windows and the pointer to disappear onto a panel the user cannot see. The feature must logically remove the built-in display from the active desktop.

## User interaction

### Keyboard interaction

Use a deliberate two-key sequence rather than a single global shortcut. In the current custom configuration, `d` can be added to service mode:

```toml
[mode.main.binding]
alt-shift-semicolon = 'mode service'

[mode.service.binding]
d = ['built-in-display', 'mode main']
```

The user presses and releases `Option-Shift-Semicolon`, then presses `D`.

A mode-based binding makes accidental activation less likely and avoids consuming another global shortcut. Existing user configuration files should not be rewritten automatically.

### Command interface

Follow the toggle/on/off convention used by other AeroSpace commands:

```bash
aerospace built-in-display       # Toggle
aerospace built-in-display on
aerospace built-in-display off
```

The no-argument form should:

- Turn the display off when it is active and a usable external display is available.
- Turn the display on when AeroSpace previously turned it off.

The explicit `on` and `off` forms are intended for scripts and menu actions. Menu actions should use the explicit forms rather than toggle so that a stale view cannot request the wrong transition.

### Menu-bar fallback

Add one display-control item to the AeroSpace menu:

| State | Menu item |
| --- | --- |
| Built-in active and external display usable | `Turn Off Built-in Display…` |
| Built-in disabled by AeroSpace | `Turn On Built-in Display` |
| Built-in is the only active display | Disabled `Built-in Display — only available display` |
| Mac has no built-in display | Omit the item |
| Display-control implementation is unavailable | Disabled item with an unsupported explanation |

The menu item provides discoverability and an explicit recovery path on the external display.

## Behavior contract

### Preconditions for turning off

A request to turn the built-in display off succeeds only when all of the following are true:

1. The Mac has an online built-in display.
2. The built-in display is currently active.
3. At least one non-built-in display is active, awake, and part of the current desktop.
4. The fallback external display is not merely a mirror whose source is the built-in display.
5. The display-control implementation is available on the running macOS version.
6. No other display transition is in progress.

A connected but inactive or sleeping external display does not satisfy the precondition. The guard applies only when turning the display off; a request to turn it on is never rejected because of monitor count.

When a precondition fails, do not mutate display state. Return a clear error, for example:

```text
Refusing to turn off Built-in Retina Display: no active external display is available
```

### State transitions

| Current state | External displays | Request/event | Result |
| --- | ---: | --- | --- |
| Built-in active | 0 | `off` or toggle | Refuse without mutation |
| Built-in active | 1 or more usable | `off` or toggle | Validate, then disable transactionally |
| Built-in active | Any | `on` | Successful no-op |
| Built-in disabled by AeroSpace | 1 or more usable | `on` or toggle | Enable built-in |
| Built-in disabled by AeroSpace | 1 or more usable | External removed, others remain | Keep built-in disabled |
| Built-in disabled by AeroSpace | 0 | Last external removed | Enable built-in immediately |
| Built-in disabled by another application | Any | Passive observation | Do not claim ownership or fight the other application |
| Any | Any | Transition failure | Roll back to built-in enabled |

If the built-in display is disabled by another application, an explicit `built-in-display on` may still attempt to enable it, but AeroSpace must not automatically manage that state until its own disable operation succeeds.

### Focus and workspace behavior

Before disabling the built-in display:

1. Choose a usable external fallback deterministically, preferring the focused external monitor and then the main external monitor.
2. If focus is on the built-in display, focus the fallback external monitor's active workspace.
3. Preserve the fallback monitor's currently visible workspace.
4. Allow the built-in monitor's visible workspace to become invisible without moving or closing its windows.

After the display inventory stabilizes, reconcile workspaces and layout once. Do not repeatedly refresh against transient `NSScreen.screens` snapshots during the CoreGraphics transition.

When the built-in display is restored, normal monitor reconciliation may make an appropriate workspace visible there. Restoring an exact prior workspace-to-display arrangement can be considered later; it is not required for the first implementation.

## Confirmation experience

The first successful disable for a previously unseen external-display topology must show a confirmation HUD on the fallback external display:

```text
Built-in display is off

Keep this display configuration?
Reverting in 15 seconds

[Keep]  [Restore]
```

If the user cannot see or interact with the HUD, the timeout restores the built-in display. Selecting `Keep` commits the disable lease; selecting `Restore` enables the built-in display immediately.

A trusted topology is identified using stable display UUIDs rather than transient `CGDirectDisplayID` values. Trust should be invalidated when:

- The set of external display UUIDs changes.
- The macOS build changes.
- Display-control capability probing changes.

After a topology is trusted, the normal keyboard interaction may disable immediately. A brief notification with an Undo action is sufficient for trusted topologies.

The confirmation timeout and recovery watchdog must not depend on the HUD or the main actor continuing to render.

## Blackout prevention

No single check is sufficient. The implementation must use independent recovery layers.

### 1. Transactional preflight

Before changing display state:

1. Take a low-level display inventory snapshot.
2. Identify the built-in display using the platform's built-in-display property, not its localized name.
3. Select and validate a fallback external display.
4. Record the recovery lease and built-in display identity atomically.
5. Begin one display configuration transaction.

Do not infer the built-in display from names such as `Built-in Retina Display`, and do not use `NSScreen.screens.count` as the safety decision.

### 2. Immediate postcondition verification

After committing the transition, query CoreGraphics again and verify:

- The built-in display is inactive.
- At least one non-built-in display remains active and awake.
- The selected fallback display is still part of the desktop.

If any postcondition fails, enable the built-in display immediately and report the failed transition.

### 3. Confirmation rollback timer

For an untrusted topology, begin the independent 15-second rollback timer before committing the disable transaction. Cancel it only after the user confirms and postconditions remain valid.

### 4. Display reconfiguration watcher

Register a CoreGraphics display-reconfiguration callback. While AeroSpace owns a disable lease:

- Recompute the active external display count after each completed reconfiguration.
- Enable the built-in display when the count reaches zero.
- Keep it disabled when one external display disconnects but another usable external remains.
- Clear the lease if another process re-enables the built-in display.

Do not issue a nested display configuration from inside a begin-configuration callback. Schedule recovery on the display-control module's serialized executor after the system transition completes.

### 5. Polling watchdog

Callbacks can be delayed or missed during driver and sleep/wake transitions. While the built-in display is disabled, also poll the low-level inventory at a short interval. Polling is a fallback, not the primary event mechanism.

The watcher and poller must use CoreGraphics inventory rather than `NSScreen.screens`, which can be transiently empty during display reconfiguration.

### 6. Process-death recovery

Treat the disabled state as a lease owned by the current AeroSpace process. Before disabling, launch a small recovery helper that knows:

- The parent AeroSpace process identifier.
- The built-in display's recoverable identity.
- The recovery deadline while confirmation is pending.
- Whether at least one usable external display remains.

The helper enables the built-in display if:

- AeroSpace exits or crashes while holding the lease.
- Confirmation times out.
- The last external display disappears.

Once the built-in display is active, the helper clears the recovery marker and exits. Store the marker atomically so the next AeroSpace launch can repair stale state if both processes terminate unexpectedly.

### 7. Lifecycle restoration

Enable the built-in display before or during:

- Normal AeroSpace termination.
- AeroSpace's `enable off` transition.
- Application restart when a stale recovery marker exists.
- System wake, before relying on a post-wake external inventory.

On wake, safety takes priority over preserving the previous disabled state. AeroSpace must not automatically turn the display off again; the user may invoke the command after the external display is stable.

### 8. Emergency recovery

Keep `aerospace built-in-display on` available whenever the display backend can run, including when AeroSpace window management is disabled. The menu-bar action must call the same underlying operation.

A future hard-wired rescue shortcut may always request `on`, but it should supplement rather than replace process-death and disconnect recovery.

## Module design

Place the display-state complexity behind a deep `BuiltInDisplayController` module. Commands, the menu, lifecycle observers, and tests should all use the same interface rather than performing CoreGraphics checks independently.

A possible interface is:

```swift
enum BuiltInDisplayRequest {
    case toggle
    case on
    case off
}

enum BuiltInDisplayResult {
    case changed(BuiltInDisplayState)
    case noOp(BuiltInDisplayState)
    case refused(BuiltInDisplayRefusal)
}

protocol BuiltInDisplayControlling {
    func apply(_ request: BuiltInDisplayRequest) async -> BuiltInDisplayResult
    func handleDisplayInventoryChange() async
    func restoreForLifecycleEvent() async
}
```

The exact Swift types may change, but the interface should preserve these properties:

- One operation owns validation, mutation, verification, and rollback.
- Callers request intent rather than manipulating display IDs.
- Refusals are expected domain outcomes, not crashes.
- Lifecycle and display-change recovery cross the same seam as commands.
- CoreGraphics identifiers, private symbols, timers, persistence, and helper communication remain implementation details.

The module should serialize transitions so command execution, menu interaction, callbacks, polling, sleep/wake, and termination cannot concurrently mutate display state.

### Internal inventory model

Represent enough information to make safety decisions without exposing CoreGraphics details to callers:

```swift
struct DisplaySnapshot {
    let builtIn: DisplayDescriptor?
    let activeExternals: [DisplayDescriptor]
    let transitionInProgress: Bool
}
```

Each descriptor should carry a transient display ID for the current operation and a stable UUID for persistence. Inventory classification should distinguish at least:

- Online versus active.
- Built-in versus external.
- Awake versus asleep.
- Extended versus mirrored.

### Ownership model

Persist only state AeroSpace needs to recover its own operation:

- AeroSpace owns the current disable lease.
- Stable built-in display identity.
- External topology fingerprint.
- Pending confirmation deadline, if any.
- Running macOS build and backend capability version.

Do not treat every inactive built-in display as AeroSpace-owned. This prevents conflict with BetterDisplay, Lunar, system clamshell behavior, or another display-management process.

## Platform feasibility and experimental gating

macOS does not expose a supported public interface for logically disconnecting only the built-in display while leaving the lid open. A true implementation therefore requires either:

1. A version-gated private CoreGraphics display function, or
2. An adapter to an external display utility that already provides logical disconnect/reconnect behavior.

Brightness control and black overlays are explicitly rejected because they do not remove the screen from the desktop.

Direct private-interface support conflicts with AeroSpace's preference to minimize private APIs. If implemented in-process, the feature must be opt-in and experimental, for example:

```toml
enable-experimental-built-in-display-control = true
```

The implementation must:

- Resolve private symbols dynamically so an absent symbol does not prevent AeroSpace from launching.
- Probe capability before presenting an enabled menu item or accepting `off`.
- Fail closed when the running macOS version or display state is unknown.
- Require neither disabled SIP nor permanent boot configuration.
- Record enough version information to invalidate trusted topologies after an OS update.

If this cannot meet AeroSpace's maintenance and private-interface standards, keep the command/interface design but implement the display seam through a separately installed display utility.

## Integration points

Expected code areas include:

- `Sources/Common/cmdArgs`: command kind, parser, generated help inputs, and `on`/`off` arguments.
- `Sources/AppBundle/command`: `BuiltInDisplayCommand` delegating to the controller.
- `Sources/AppBundle/ui/MenuBar.swift`: explicit on/off menu actions and disabled-state explanation.
- `Sources/AppBundle/ui/TrayMenuModel.swift`: published display-control state.
- `Sources/AppBundle/GlobalObserver.swift`: sleep/wake and display-change integration, or forwarding to a dedicated observer owned by the controller.
- `Sources/AppBundle/initAppBundle.swift`: capability probing and stale-lease recovery before normal monitor layout.
- `Sources/AppBundle/model/Monitor.swift`: retain `NSScreen` adaptation for window layout, but do not use it as the safety inventory.
- `Sources/AppBundle/tree/Workspace.swift`: coalesce monitor reconciliation after the display snapshot stabilizes.
- `Sources/PrivateApi`: private symbol declaration or dynamic-loading bridge if the in-process adapter is selected.
- `docs/config-examples/default-config.toml`: optional service-mode binding example.
- `docs`: command reference, configuration warning, recovery behavior, and private-interface limitations.

Display changes must be coordinated with complete refresh sessions so a transient empty AppKit screen list does not cause recursive reconfiguration or destroy the last coherent workspace mapping.

## Testing

### Pure state-machine tests

Use a fake display adapter and deterministic clock to cover:

1. `off` is refused with no active external display.
2. `off` succeeds with one usable external display.
3. A sleeping, inactive, or mirror-only external does not satisfy the safety guard.
4. `on` succeeds regardless of external display count.
5. `toggle` selects the correct explicit transition.
6. Failed postcondition verification rolls back to built-in enabled.
7. Removing one of two external displays keeps the built-in disabled.
8. Removing the last external display enables the built-in.
9. Confirmation timeout enables the built-in.
10. Confirming a topology cancels its rollback timer.
11. A topology or macOS build change requires confirmation again.
12. A display state changed by another application is not claimed by AeroSpace.
13. Concurrent requests are serialized and cannot leave a partial lease.
14. A stale recovery marker is repaired on startup.
15. Normal termination and `enable off` restore the built-in display.

### Command and menu tests

Cover:

- Parsing toggle, `on`, and `off` forms.
- Clear refusal and unsupported-platform messages.
- Nonzero exit status for refused or failed changes.
- Explicit menu actions invoking the intended state rather than toggle.
- Menu visibility and labels for active, disabled, only-display, unsupported, and no-built-in states.

### Manual hardware QA

Test on every supported macOS major version and at least these configurations:

1. One built-in display only: disabling is refused.
2. One extended external display: disable, confirm, and restore manually.
3. Disconnect the sole external display while disabled: built-in restores.
4. Two external displays: disconnect one, then disconnect the last.
5. Built-in configured as main display before disabling.
6. External configured as main display before disabling.
7. Mirrored displays: refuse or safely handle without losing the mirror source.
8. External display asleep or powered off at invocation.
9. USB-C or Thunderbolt dock disconnect.
10. DisplayPort/HDMI cable disconnect without dock removal.
11. System sleep and wake while the built-in display is disabled.
12. AeroSpace normal quit while disabled.
13. Force-kill AeroSpace while disabled and verify helper recovery.
14. Force-kill both AeroSpace and the helper, then verify startup-marker recovery.
15. Another display utility enabling or disabling the built-in display.
16. Rapid repeated toggle requests during display reconfiguration.

For every case, verify that at least one display remains usable, focus ends on a visible workspace, and AeroSpace performs only one stable workspace reconciliation after the transition.

## Non-goals

- Automatically turning the built-in display off whenever an external display connects.
- Powering off arbitrary external displays.
- Replacing a full display arrangement or resolution utility.
- Treating zero brightness or a black overlay as disabled.
- Persistently changing firmware, boot arguments, SIP, or system security settings.
- Guaranteeing recovery from an operating-system or display-driver failure that prevents all display configuration calls.
- Restoring the exact prior workspace-to-monitor arrangement in the first implementation.
