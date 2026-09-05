# Built-in Display Recovery Fixes

Follow-up to `built-in-display-control-plan.md`. The plan specified eight
independent blackout-prevention layers. The first implementation shipped all
eight, but seven defects meant that in the case they exist for -- the last
external display being unplugged -- none of them fired.

Four defects disarmed the recovery lease and its watchdogs (causes 1-4 below);
a fifth made ordinary display sleep look like a disconnect; and two more, found
only by instrumenting real hardware, defeated detection and actuation
independently of all the rest.

## Symptom

With the built-in display disabled and a single external display attached,
disconnecting the external display left the machine with nothing visible. The
panel was not restored, by either the in-process watcher or the recovery helper.
Recovery required reattaching the external display and invoking
`aerospace built-in-display on` by hand.

The wording matters. Throughout the outage CoreGraphics reported one active,
online display, so "no active display" was never true and any check written
against that idea could not work. See the phantom-display section.

## Root causes

### 1. The recovery helper retired its own lease before the disable happened

`turnOff` wrote the lease and spawned the helper *before* calling
`adapter.setEnabled(false, ...)`:

```swift
try startRecoveryLease(displayId: currentBuiltIn.id, confirmationDeadline: deadline)
try adapter.setEnabled(false, displayId: currentBuiltIn.id)
```

The helper's first loop iteration read "built-in display is active", concluded
there was nothing left to guard, deleted the lease file and exited:

```swift
if snapshot?.builtIn?.isActive == true {
    try? FileManager.default.removeItem(at: builtInDisplayLeaseUrl)
    return true
}
```

This is not a narrow race. `initAppBundle()` runs inside `AeroSpaceApp.init()`,
which SwiftUI calls before AppKit boots, so the helper reaches that check in
about 10 ms, while `CGCompleteDisplayConfiguration` is still applying the
transition. The helper effectively always won.

Losing the helper removed plan layers 3 (confirmation rollback timer), 6
(process-death recovery) and 7 (stale-marker repair on restart) for the entire
time the panel was off.

### 2. Every remaining recovery path was gated on in-memory ownership

`handleDisplayInventoryChange` returned early unless `ownsDisableLease` was set,
and that flag lives only in the process. `recoverStaleLeaseIfNeeded` repaired
state on startup only when the lease *file* existed — which cause 1 had already
deleted. Nothing anywhere expressed the actual safety invariant: *if no display
is active, turn the built-in display on.*

### 3. A failed rollback disarmed the watchdogs while the panel stayed dark

```swift
} else {
    try? adapter.setEnabled(true, displayId: currentBuiltIn.id)
    stopRecoveryLease()
    return .failed("The display transition could not be verified and was rolled back")
}
```

The rollback's failure was swallowed by `try?`, but `stopRecoveryLease()` ran
unconditionally: it cleared `ownsDisableLease`, deleted the lease file and
terminated the helper. A rollback that did not actually restore the panel
therefore produced exactly the observed end state — panel off, no lease, no
helper, no owner.

### 4. The disable postcondition was flaky

```swift
guard waitForPostcondition({ snapshot in
    snapshot.builtIn?.isActive == false && !snapshot.usableExternals.isEmpty
})
```

Two problems. The budget was a fixed 20 x 50 ms = 1 s, which competes with
WindowServer reconfiguration. And requiring a *specific external* to be active
and awake at that instant re-checks a precondition in the middle of the
reconfiguration that invalidates it, so an ordinary enumeration blip tripped the
rollback in cause 3.

## Evidence

Collected on macOS (Darwin 25.5) with the panel disabled:

- `CGSConfigureDisplayEnabled` and `CGSGetDisplayList` both resolve, so the
  private-API seam was healthy.
- A disabled built-in display enumerates as `builtin=1 active=0 online=0`, so
  `CGDisplayIsBuiltin` remains usable for identification while the panel is off
  and the display-ID lookup was not at fault.
- `/tmp/bobko.aerospace/` existed but was empty, and no helper process was
  running, while the panel was disabled — the fingerprint of cause 1 or 3.
- Helper cold start to exit measured at 0.00-0.01 s over three runs.
- Spawning the helper with a valid lease while the built-in display was active
  deleted the lease and exited immediately, reproducing cause 1 directly.

## Fixes

### 1. Lease arming

`BuiltInDisplayRecoveryLease` gained `armedAt: Date?`. `startRecoveryLease`
writes it as `nil`; `turnOff` sets it only after the disable is verified. The
helper treats a lease with no `armedAt` as still arming and will not retire it,
bounded by `armingGracePeriod` (30 s) and released early if the parent dies
mid-transition. Missing keys decode to `nil` through the synthesized
`decodeIfPresent`, so leases written by the previous build still load.

While arming, a transiently empty external list is also ignored, so the helper
cannot fight the transition its parent is running.

### 2. Unconditional blackout rescue

`rescueFromBlackoutIfNeeded` runs in `handleDisplayInventoryChange` before the
ownership guard. If no *real* display is attached, the built-in display is
restored regardless of which process disabled it. Both qualifiers were learned
the hard way: the display-sleep section explains why attachment rather than
activity is the test, and the phantom-display section explains why "real" has to
exclude the placeholder macOS synthesizes. It is debounced by
`blackoutRescueDebounce` (0.75 s) because reconfiguration transiently reports an
empty set, so a real blackout recovers in roughly one to two seconds.

Ownership tracking still exists to avoid fighting BetterDisplay, Lunar or
clamshell behaviour, but it no longer gates the last-display-standing rescue.

### 3. Rollback that verifies before releasing

`rollBackToBuiltInEnabled` replaces both open-coded rollback sites. It releases
the lease only once the panel is verified active again; otherwise it sets the
new `pendingRestore` flag and keeps ownership so the poller retries.
`ownsDisableLease` is now set *before* `setEnabled(false)` rather than after
verification, so no failure path between the two can leave the panel off with
the watchdogs disarmed.

### 4. Postconditions split and given a real budget

`waitForPostcondition` takes a `timeout` (default 1 s, `disableVerificationTimeout`
= 2.5 s for the disable). The external-display clause is gone from the
verification; the invariant that actually matters, that *something* remained
drawable, is checked as a separate postcondition.

## Related defect: display sleep read as a disconnect

`ManagedDisplaySnapshot.usableExternals` was doing two incompatible jobs. As a
*precondition* it is right: refusing to disable the panel when the only external
is asleep or inactive is what the plan mandates. As a *recovery trigger* it is
wrong. A display in power save is expected to report as asleep and inactive,
which drops it out of `usableExternals`, so once the idle timer elapsed both the
poller and the helper would conclude the last external had disappeared and
restore the panel -- the feature undoing itself on a timer, with no disconnect
involved.

Unlike the phantom-display defect below, this one was **not reproduced on
hardware**; it was found by reading the predicate. The split is worth making
regardless of whether power save is what trips it, because recovery must key on
whether a display is attached, never on whether it is usable right now.

The two meanings are now separate:

| Property | Predicate | Used by |
| --- | --- | --- |
| `usableExternals` | real, active, online, awake | `validateTurningOff`, fallback focus, topology fingerprint, menu state |
| `attachedExternals` | real and online | disconnect watcher, helper `hasAttachedExternal` |
| `hasAttachedDisplay` | any real display online | blackout rescue, post-disable verification |

"Real" excludes the synthesized placeholder described in the next section.

`isOnline` is the correct attachment test: `CGGetOnlineDisplayList` documents
online as including sleeping displays, a detached display leaves the list
entirely, and a disabled built-in panel reports offline (confirmed above). So an
empty `hasAttachedDisplay` is a genuine blackout, while a sleeping desktop is
not — waking the external recovers it without touching the panel.

This also corrects the blackout rescue added in fix 2, which would otherwise
have fired on every screen sleep for the same reason.

## The phantom display

The fixes above were necessary but not sufficient. On hardware the panel still
did not come back, and an independent observer process recorded why. For the
entire 54 seconds the external display was detached:

```
n=1 [{id=11 bi=0 act=1 onl=1 slp=0}]  cgOnline=1 cgActive=1
```

macOS synthesizes a placeholder framebuffer when the last real display is
detached, so the login session survives with nothing physically attached. It
enumerates as an **active, online, non-built-in display**, and at the same time
the disabled built-in panel **disappears from the display list entirely**. The
panel is still enumerated while disabled as long as a real display is attached;
it is the combination of disabled *and* detached that removes it.

Every layer was defeated at once, and no single one of the earlier fixes could
have helped:

| Layer | Predicate | Observed | Result |
| --- | --- | --- | --- |
| Blackout rescue | `hasAttachedDisplay` | true, the phantom is online | never fires |
| Disconnect watcher | `attachedExternals.isEmpty` | false, phantom counts as external | never fires |
| Helper | `hasAttachedExternal` | true | waits forever |
| All of them | `guard let builtIn` | nil, panel not enumerated | would bail regardless |

So there were two independent defects: **detection**, because the phantom makes
a blackout indistinguishable from a healthy desktop, and **actuation**, because
the panel's identity is gone and there is no ID left to re-enable.

### Identifying the phantom

The placeholder identifies itself, and the values decode as FourCC:

```
vendor = 1970170734 = 0x756E6B6E = 'unkn'   (kDisplayVendorIDUnknown)
model  = 1986622068 = 0x76697274 = 'virt'
serial = 0   unit = 0
```

Its `CGDirectDisplayID` differs between occurrences (11, then 12 on the next
disconnect), so ID matching is not an option; the vendor/model pair is.
`ManagedDisplayDescriptor.isVirtual` tests it, and all three snapshot predicates
now exclude virtual displays.

This also closes a latent hazard that predates the disconnect bug: with only a
phantom present, `validateTurningOff` counted it as a usable external and would
have allowed disabling the panel straight into a blackout.

### Actuation without enumeration

The observer then tested whether the panel can be re-enabled while it is absent
from the inventory:

```
ATTEMPT[session id=1] begin=ok configure=ok complete -> CGError 0 *** OK ***
```

`CGSConfigureDisplayEnabled` accepts the remembered `CGDirectDisplayID` and the
panel lights up, even though `CGSGetDisplayList` no longer reports it. The
controller therefore records `disabledBuiltInDisplayId` when it disables the
panel, `recoverStaleLeaseIfNeeded` reloads it from the lease file on startup,
and `apply(.on)` and the rescue fall back to it whenever `snapshot.builtIn` is
nil. The helper already actuated through `lease.builtInDisplayId`, so once the
phantom stopped counting as an external it recovers on its own.

## Testing

The helper's decision logic was extracted into a pure
`BuiltInDisplayHelperPolicy.decide(...)` returning `retire` / `restore` / `wait`,
so the blackout-critical cases are testable without hardware.
`BuiltInDisplayHelperPolicyTest` covers plan test-matrix items 7, 8 and 9, plus
the cause-1 regression directly:
`testArmingLeaseIsNotRetiredWhileBuiltInStillLooksActive`.

`BuiltInDisplayPolicyTest` covers the snapshot predicates, including
`testPhantomOnlyInventoryIsABlackout`, which is built from the inventory
actually recorded on hardware while the panel was dark.

Two things remain hardware-only and are not covered by tests: that
`CGSConfigureDisplayEnabled` accepts an unenumerated display ID, and the
phantom's vendor/model values. Both are recorded above so a future OS change
that breaks them can be recognised.

## Known gaps

- `waitForPostcondition` still blocks the main thread with `Thread.sleep`; the
  disable path can now block for 2.5 s in the failure case. Making it async
  requires threading `apply()` through `Command.run`.
- `stableFingerprint` uses vendor/model/serial/unit numbers rather than the
  display UUID the plan calls for. `CGDisplaySerialNumber` is 0 on many panels,
  so two identical monitors can fingerprint identically; both panels on the
  development machine report non-zero serials, so the collision is latent rather
  than active. `CGDisplayUnitNumber` can shift with attach order, which fails
  safe by asking for confirmation again. Worst case either way is a skipped or
  repeated confirmation, never a blackout.
- Ownership is still not persisted beyond the lease file, but this matters less
  than it first appeared. Fix 1 keeps the lease alive for as long as the panel is
  dark, so a force-killed AeroSpace is recovered by the helper, and a restart
  repairs through `recoverStaleLeaseIfNeeded`, which now also reloads the
  panel's display ID from the lease. `CGCompleteDisplayConfiguration` is called
  with `.forSession`, so logout reverts the disable regardless.
- The one genuinely unrecovered case is losing both processes *and* the lease
  file inside a single login session. With no lease there is no remembered
  display ID, and if the external is then detached the panel is not enumerated
  either, so `rescueFromBlackoutIfNeeded` has no ID to act on and correctly does
  nothing. With the external still attached this is one `built-in-display on`
  away; with it detached, reattaching or logging out is the way back. Persisting
  the panel's identity outside the lease would close it.
