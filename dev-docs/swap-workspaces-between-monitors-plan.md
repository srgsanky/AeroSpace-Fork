# Swap Workspaces Between Monitors Implementation Plan

## Goal

Change the default `alt-shift-tab` workflow to enter a one-shot `move-workspace` binding mode. Directional `h`, `j`, `k`, and `l` bindings swap the focused workspace with the active workspace on the monitor in that direction, regardless of the number of connected monitors.

Preserve the existing `move-workspace-to-monitor` behavior for scripts and existing configurations by keeping swap behavior opt-in with `--swap`. The new default bindings are:

```toml
[mode.main.binding]
    alt-shift-tab = 'mode move-workspace'

[mode.move-workspace.binding]
    h = ['move-workspace-to-monitor --swap left', 'mode main']
    j = ['move-workspace-to-monitor --swap down', 'mode main']
    k = ['move-workspace-to-monitor --swap up', 'mode main']
    l = ['move-workspace-to-monitor --swap right', 'mode main']
    esc = 'mode main'
```

Existing user configuration files are not rewritten automatically.

## Behavior

Given two monitors with active workspaces:

```text
1[A] 2[B]
```

With workspace `A` focused, the invocation produces:

```text
1[B] 2[A]
```

Workspace `A` remains focused.

Additional behavior:

- With one monitor, `--wrap-around next` resolves to the same monitor and succeeds without changing state.
- With two monitors, the active workspaces exchange monitors.
- Directional `left`, `down`, `up`, and `right` targets exchange the two selected monitors' active workspaces with any monitor count.
- With more than two monitors, non-directional `next`, `prev`, and monitor-pattern targets retain the existing move-and-replace-with-stub behavior to avoid relying on monitor order for a series of swaps.
- `left`, `down`, `up`, `right`, `next`, `prev`, and monitor-pattern targets all accept `--swap`.
- When an exchange is performed, `--workspace <workspace>` swaps the selected workspace rather than necessarily the focused workspace; the selected workspace must currently be visible.
- Focus behavior remains unchanged: if the moved workspace was focused, focus follows it to the target monitor.
- Without `--swap`, `move-workspace-to-monitor` retains its current move-and-replace-with-stub behavior.

## Force-assignment behavior

A swap has two assignments: the selected workspace to the target monitor and the target monitor's active workspace to the source monitor.

Before changing either monitor, validate both assignments against `workspace-to-monitor-force-assignment`.

- If both assignments are valid, perform the exchange.
- If either assignment is invalid, fail without changing either monitor.
- A same-monitor no-op succeeds even if the workspace is force-assigned.

This preflight is required to avoid a partially completed swap.

## Implementation

### 1. Add the command flag

Update `Sources/Common/cmdArgs/impl/MoveWorkpsaceToMonitorCmdArgs.swift`:

- Parse `--swap` as a boolean flag.
- Keep it compatible with `--workspace` and `--wrap-around`.
- Keep the existing restriction that `--wrap-around` cannot be combined with monitor patterns.

### 2. Add an atomic workspace-swap model operation

Update `Sources/AppBundle/tree/Workspace.swift` with a monitor helper that swaps two active workspaces.

The helper should:

1. Treat monitors with the same top-left point as a successful no-op.
2. Capture both active workspaces before mutation.
3. Validate both destination assignments using the same force-assignment rule as `setActiveWorkspace`.
4. Return `false` without mutation if either validation fails.
5. Set each workspace active on the opposite monitor.
6. Assert that the two post-validation assignments succeed.

Keeping this transaction in the workspace/monitor model prevents command code from exposing an intermediate state or duplicating assignment rules.

### 3. Use swap mode in the command

Update `Sources/AppBundle/command/impl/MoveWorkspaceToMonitorCommand.swift`:

- Resolve the source workspace and target monitor exactly as today.
- Preserve the existing same-monitor success path.
- Require a selected `--workspace` source to be visible when performing a swap, because an invisible workspace is not the active workspace that can be exchanged with another monitor.
- When `--swap` is present and either exactly two monitors are connected or the target is directional, call the atomic monitor helper.
- On invalid force assignment, return a clear error naming both workspaces.
- When `--swap` is absent, or its target and monitor count do not meet the exchange conditions, retain the existing target activation and source stub selection logic.

### 4. Add multi-monitor test support

The test runtime currently hard-codes one monitor. Update `Sources/AppBundle/model/Monitor.swift` with a test-only monitor override:

- Production continues to derive monitors from `NSScreen.screens`.
- Unit tests can install deterministic monitor rectangles.
- Resetting the override restores the existing 1920x1080 test monitor.

Update `setUpWorkspacesForTests()` to restore the default monitor list and reconcile visible workspaces before each test. This prevents multi-monitor state from leaking between tests.

### 5. Add tests

Expand `Sources/AppBundleTests/command/MoveWorkspaceToMonitorCommandTest.swift` to cover:

1. `--swap` parses successfully.
2. Existing parsing and non-swap behavior remain intact.
3. One monitor plus `--wrap-around next` is a successful no-op.
4. Two monitors exchange active workspaces and preserve focus on the selected workspace.
5. A non-directional swap target with three monitors retains the existing move-and-replace-with-stub behavior.
6. A directional swap target with three monitors exchanges only the source and resolved target workspaces.
7. A force-assigned source workspace rejects the swap without mutation.
8. A force-assigned target workspace rejects the swap without mutation.
9. Plain `move-workspace-to-monitor` still leaves the displaced target workspace assigned to its original monitor and installs a stub on the source monitor.

### 6. Change the shipped default binding

Update `docs/config-examples/default-config.toml` so `alt-shift-tab` enters the `move-workspace` mode and that mode maps `h`, `j`, `k`, and `l` to one-shot directional swaps. Include an `esc` binding that returns to `main` mode without moving.

This changes newly copied/default configurations only. Document that existing users must update their own bindings.

### 7. Update command documentation and grammar

Update `docs/aerospace-move-workspace-to-monitor.adoc`:

- Add `--swap` to each synopsis.
- Describe exchanging with the target monitor's active workspace.
- Document that directional targets swap with any monitor count while non-directional targets swap only in two-monitor setups.
- Document all-or-nothing force-assignment validation.
- Include the default binding-mode example.

Update `grammar/commands-bnf-grammar.txt` so generated/reference grammar accepts `--swap` and `--workspace` consistently.

Regenerate command help after changing the AsciiDoc synopsis.

## Verification

Run:

```bash
./generate.sh
./format.sh
./swift-test.sh
./lint.sh
./build-docs.sh
./build-shell-completion.sh
```

Manual QA with two and three monitors:

1. Verify `alt-shift-tab` enters `move-workspace` mode.
2. With two monitors, verify `h`, `j`, `k`, and `l` exchange the focused workspace with the monitor in that direction when one exists.
3. With more than two monitors, verify directional bindings exchange only the source and resolved target workspaces.
4. Verify each directional binding returns to `main` mode and `esc` cancels without moving.
5. Verify focus and focused window are preserved.
6. Verify workspaces constrained by `workspace-to-monitor-force-assignment` cannot produce a partial swap.
7. Verify non-directional `--swap` targets retain the existing behavior outside two-monitor setups.
8. Verify invoking the command without `--swap` retains the old move behavior.

## Non-goals

- Changing the semantics of `move-workspace-to-monitor` when `--swap` is absent.
- Rewriting existing users' configuration files.
- Swapping invisible workspaces other than the selected `--workspace` source.
- Changing non-directional swap behavior outside two-monitor setups.
- Rotating all monitor workspaces in one invocation.
- Changing macOS Spaces or display ordering behavior.
