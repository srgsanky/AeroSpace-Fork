# Built-in Display Persistence Across Sleep

Follow-up to `built-in-display-control-plan.md` and
`built-in-display-recovery-fixes.md`. The recovery work made the disabled state
safe. This makes it *survive*: before it, the panel came back on every time the
machine slept, which on a laptop that sleeps whenever the lid closes meant the
feature rarely lasted an hour.

## Symptom

Disable the built-in display with an external attached, let the Mac sleep, come
back and log in: both displays are on again. The panel was never disabled as far
as the desktop is concerned, and re-invoking `aerospace built-in-display off`
after every wake is the only way to keep it off.

## Root cause 1: sleep restored the panel by design

`BuiltInDisplayController.start()` registered the same restore handler for
sleep and wake that it used for termination:

```swift
for notification in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification] {
    ... BuiltInDisplayController.shared.restoreForLifecycleEvent()
}
```

`restoreForLifecycleEvent` calls `apply(.on)`. So the panel was re-enabled at
the moment the machine went to sleep, deliberately, and the wake handler ran the
same path again for good measure. This is plan §7 as written:

> On wake, safety takes priority over preserving the previous disabled state.
> AeroSpace must not automatically turn the display off again; the user may
> invoke the command after the external display is stable.

### Why the rule was wrong

The rule reads as conservative, but it protects nothing. The hazard the whole
feature guards against is a **blackout**: the panel is dark and nothing else can
draw. Sleep is not that hazard. An external display that was attached before a
sleep is still attached after it, and while the machine is asleep there is no
desktop to be unable to see.

The property that separates a recoverable desktop from a black one is
*attachment*, and `built-in-display-recovery-fixes.md` had already established
that — that is exactly why `attachedExternals` was split out from
`usableExternals`, so that display sleep would stop reading as a disconnect.
Restoring on system sleep is the same conflation of power state with attachment,
one level up, and it survived that pass because it lived in a lifecycle observer
rather than in the predicates being audited.

Meanwhile the layers that do key on attachment are indifferent to power state:
`rescueFromBlackoutIfNeeded` restores within 0.75 s of nothing being drawable,
and the recovery helper restores on disconnect, parent death and confirmation
timeout. Dropping the sleep restore leaves all of them in place.

## Root cause 2: the system re-enables the panel on its own

Removing the observer is necessary but not sufficient, and this is what makes
the fix a reconciliation loop rather than a deletion. macOS re-enables a
disabled built-in panel across sleep, screen lock and login on its own —
loginwindow reconfigures displays when it takes the session, and
`CGCompleteDisplayConfiguration` is called with `.forSession`, so nothing about
the disable is meant to outlive a session-level reconfiguration.

That defeats a purely passive fix in two ways:

1. The panel is on again after login regardless of what AeroSpace did or
   did not do at sleep.
2. Worse, `handleDisplayInventoryChange` reads the panel being active as *the
   user turned it back on*, and releases the lease:

   ```swift
   if snapshot.builtIn?.isActive == true {
       pendingRestore = false
       if ownsDisableLease { stopRecoveryLease() }
   ```

   So the disabled state was not merely undone, it was forgotten.

**Unverified on hardware.** How much of the observed symptom comes from cause 1
versus cause 2 was not measured; cause 1 alone is sufficient to produce it and
is certain from reading the code. The design assumes cause 2 is real because the
cost of being wrong is one no-op — if the system leaves the panel alone, the
re-assertion never fires — while the cost of assuming it away is the bug coming
back through login instead of sleep.

## The fix: intent outlives state

The controller now records what the user asked for separately from what the
hardware reports:

```swift
/// What the user asked for, as opposed to what the hardware currently reports.
private var wantsBuiltInDisplayOff = false
```

Set only once a disable is verified — a transition that never took hold must not
leave the controller trying to restore a state that was never reached — and
cleared on every path that deliberately turns the panel on, including rollback
and the blackout rescue. That last point is what stops a rescue and a
re-assertion from chasing each other: whoever turns the panel on owns the
intent, and turns it off.

The 1 s poller then reconciles. When it finds the panel active while the intent
says otherwise, `reassertDisabledStateIfNeeded` re-runs the full `turnOff` path
before the "user must have wanted it back" branch can release the lease.

### What gates a re-assertion

Turning a display off unprompted is exactly the operation the plan's safety
layers exist to constrain, so re-assertion is gated harder than the original
command, by a pure `BuiltInDisplayReassertPolicy.decide(...)`:

| Gate | Reason |
| --- | --- |
| Screen unlocked | loginwindow owns the display configuration until the user is back, and reconfiguring underneath it fixes nothing they can see |
| 2 s settle window after wake/unlock | display enumeration is still churning; a disable issued mid-reconfiguration is the flakiest thing available |
| `validateTurningOff` passes | same precondition as the original command: an active, awake, non-mirrored external |
| Confirmation skipped | the topology was confirmed when it was first disabled; a modal on every wake is its own bug |
| ≤ 3 attempts per 5 min | if something else keeps re-enabling the panel, losing the argument quietly beats flapping the desktop |

Lock state is read live from `CGSessionCopyCurrentDictionary()`
(`CGSSessionScreenIsLocked`) rather than tracked from `com.apple.screenIsLocked`
notifications, so a dropped notification cannot wedge re-assertion off for the
rest of the session; the notifications only restart the settle window.

The attempt budget refills once a disable has held for 60 s. Without that, a
budget meant to catch a flapping fight — which cycles in seconds — would instead
be spent by a machine that legitimately sleeps four times in an afternoon.

When the budget *is* exhausted, or when the external is gone entirely, the
intent is abandoned rather than parked. An abandoned intent matters: keeping it
alive would blank the panel out from under a user who has since unplugged and is
now working on the built-in display, the moment they plug a display back in.
Turning the panel off is still something they ask for, once per topology.

## Two races that re-assertion opened

Re-asserting means running a *second* disable transition in a session that
already ran one, and both of the following are only reachable because of that.

### A retired helper deleting its successor's lease

`reassertDisabledStateIfNeeded` calls `stopRecoveryLease()` before `turnOff`,
because the existing lease and helper are watching a panel that is currently on:
left running, the old helper reads "built-in is active" with an armed lease,
concludes recovery is complete and deletes the lease file. `stopRecoveryLease`
terminates it — but `Process.terminate()` is a signal, not a join, so the old
helper can survive long enough to delete the *new* lease file written
milliseconds later, leaving the fresh disable unguarded and the panel dark with
no watchdog.

The lease now carries a generation token:

```swift
let token: String?
```

The helper receives its own token in `argv[4]` and exits without touching the
file when the lease on disk carries a different one. Missing keys decode to nil,
so a lease from the previous build still loads and still behaves as before.

### Wake re-enumeration read as a disconnect

Both the poller and the helper treat an empty external list as "the last
external was unplugged, restore the panel". A wake takes seconds to re-enumerate
displays over DisplayPort or Thunderbolt, so with the sleep restore gone that
path became the *new* route to the same bug: the panel would be restored a
second after wake, and the restore would clear the intent, so no re-assertion
would follow.

Both sides now require the condition to persist:

- The poller suppresses the disconnect restore inside the same settle window it
  uses for re-assertion.
- `BuiltInDisplayHelperPolicy.decide` takes `externalMissingElapsed` in place of
  `hasAttachedExternal` and requires 2.5 s.

Neither weakens the blackout guarantee, and this is the load-bearing argument
for both: with the panel dark and no external attached, *nothing is drawable*,
so `rescueFromBlackoutIfNeeded` fires on its own 0.75 s debounce regardless of
either delay. The helper's debounce is bypassed entirely when the parent is
dead, which is the case where the helper is the only thing left. What is delayed
is only the redundant path, in the one situation where it is usually wrong.

## Safety layers after this change

| Layer | Trigger | Affected by this change |
| --- | --- | --- |
| Blackout rescue | nothing drawable, 0.75 s | no |
| Disconnect watcher (poller) | `attachedExternals` empty | suppressed during the 2 s settle window |
| Recovery helper: disconnect | `attachedExternals` empty | requires 2.5 s, parent alive only |
| Recovery helper: parent death | `kill(pid, 0)` fails | no |
| Recovery helper: confirmation timeout | deadline passed | no |
| Stale-lease repair on restart | lease file present | no |
| Termination / `enable off` / config reload | lifecycle | no, and each clears the intent |
| System sleep / wake | — | **removed**; replaced by re-assertion |

## Testing

`BuiltInDisplayReassertPolicy.decide(...)` returns `reassert` / `hold` /
`abandon` and is pure, so every gate above is covered without hardware in
`BuiltInDisplayReassertPolicyTest`, including the loop-avoidance cases that
cannot be exercised safely on a real desktop: abandoning an exhausted budget
even when another gate would hold it, and *not* abandoning on an empty inventory
that has not settled yet.

`BuiltInDisplayHelperPolicyTest` gains
`testWaitsOutATransientlyEmptyExternalListWhileParentIsAlive` and
`testRestoresImmediatelyWhenParentIsDeadAndExternalIsMissing`, which pin the
asymmetry the debounce depends on.

Hardware-only, and not covered: whether the system re-enables the panel across
lock and login (cause 2), how long re-enumeration actually takes after wake on a
given machine — the 2 s and 2.5 s constants are estimates — and whether the
disable is even permitted while the login window is up, which the lock gate
sidesteps rather than answers.

## Known gaps

- The intent is in-memory only. A crash while the panel is disabled is recovered
  by the helper and the panel comes back on, which is correct, but the intent
  does not survive to re-apply it after a restart. Persisting it in the lease
  would close this, at the cost of a stale intent outliving the reason for it.
- `reassertAttempts` is per-topology-blind: three re-assertions in five minutes
  abandon the intent even if they were against three different external
  displays. In practice each disconnect clears the intent first.
- A user who turns the panel back on through System Settings or another display
  tool, rather than through AeroSpace, is seen only as "the panel is active" —
  indistinguishable from the system doing it. AeroSpace will re-assert, up to
  the budget, and then give up. This is the intended failure mode, but it is a
  worse experience than noticing the first time.
