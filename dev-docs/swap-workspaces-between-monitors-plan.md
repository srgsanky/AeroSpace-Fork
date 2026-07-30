# Swap Workspaces Between Monitors Implementation Plan

## Goal

Change the default `alt-shift-tab` workflow to swap the current workspace with the other monitor's active workspace when exactly two monitors are connected. Keep the existing move behavior for other monitor counts.

Preserve the existing `move-workspace-to-monitor` behavior for scripts and existing configurations by adding an opt-in `--swap` flag. The new default binding will be:

```toml
alt-shift-tab = 'move-workspace-to-monitor --swap --wrap-around next'
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
- With more than two monitors, `--swap` uses the existing move-and-replace-with-stub behavior to avoid relying on monitor order for a series of swaps.
- `left`, `down`, `up`, `right`, `next`, `prev`, and monitor-pattern targets all support `--swap`.
- With exactly two monitors, `--workspace <workspace>` swaps the selected workspace rather than necessarily the focused workspace; the selected workspace must currently be visible.
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
- Require a selected `--workspace` source to be visible when swapping on a two-monitor setup, because an invisible workspace is not the active workspace that can be exchanged with another monitor.
- When `--swap` is present and exactly two monitors are connected, call the atomic monitor helper.
- On invalid force assignment, return a clear error naming both workspaces.
- When `--swap` is absent or the monitor count is not two, retain the existing target activation and source stub selection logic.

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
5. Three monitors retain the existing move-and-replace-with-stub behavior.
6. A force-assigned source workspace rejects the swap without mutation.
7. A force-assigned target workspace rejects the swap without mutation.
8. Plain `move-workspace-to-monitor` still leaves the displaced target workspace assigned to its original monitor and installs a stub on the source monitor.

### 6. Change the shipped default binding

Update `docs/config-examples/default-config.toml`:

```toml
alt-shift-tab = 'move-workspace-to-monitor --swap --wrap-around next'
```

This changes newly copied/default configurations only. Document that existing users must update their own binding.

### 7. Update command documentation and grammar

Update `docs/aerospace-move-workspace-to-monitor.adoc`:

- Add `--swap` to each synopsis.
- Describe exchanging with the target monitor's active workspace.
- Document all-or-nothing force-assignment validation.
- Include the default-binding example.

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

1. With two monitors, verify `alt-shift-tab` exchanges the focused workspace with the other monitor's workspace.
2. With more than two monitors, verify `alt-shift-tab` retains the existing move-and-replace-with-stub behavior.
3. Verify focus and focused window are preserved.
4. Verify a single-monitor setup does nothing and reports no error.
5. Verify workspaces constrained by `workspace-to-monitor-force-assignment` cannot produce a partial swap.
6. Verify invoking the command without `--swap` retains the old move behavior.

## Non-goals

- Changing the semantics of `move-workspace-to-monitor` when `--swap` is absent.
- Rewriting existing users' configuration files.
- Swapping invisible workspaces other than the selected `--workspace` source.
- Rotating all monitor workspaces in one invocation.
- Changing macOS Spaces or display ordering behavior.
