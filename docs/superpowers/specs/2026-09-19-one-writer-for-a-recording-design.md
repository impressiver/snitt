# One writer for a recording

**Status:** design, W4 settled. Split out of the agent-drives-the-editor spec on
2026-09-19, because this is a data-loss bug and that is a feature.

## The bug

An agent's edit to a document open in the editor is silently destroyed.

`EditorWindowController.applyAndSave` (line 2004) takes `self.edl` and calls
`controller.apply(edl:events:)`; `applyAndSaveEvents` (1032) does the same with
`self.events`. Neither re-reads, neither detects a conflict, and nothing in
`SnittApp` watches the bundle: no `DispatchSource`, no `NSFilePresenter`. So the
window's next save overwrites whatever a `snitt trim`, `crop`, `narrate` or
`auto-deep-trim` wrote.

This is D60's failure class in the other direction. D60 fixed `snitt trim`
deleting the GUI's cuts because "§4.8 and §6 hold that the CLI and GUI are one
model, not two; a CLI that silently deletes the GUI's edits is two." The GUI
deleting the CLI's edits is the same two models.

No §4.8 amendment is needed. This changes write ordering, not scope.

## Two fixes, and the cheap one is not obviously wrong

**Refuse.** When a bundle is open in a window, an agent's edit fails with a
named error saying so. Silent loss becomes loud refusal. Tiny: the lookup
already exists, and `AutomationHost` already reports failures.

**Route.** Apply the edit through the open window, so it lands and is visible.

Route was chosen first, on the belief that it reused the window's existing edit
path. **It does not**, and that is a significant enough change to reopen the
choice:

- `applyAndSave` and `applyAndSaveEvents` are both `private`, so
  `AutomationHost`, in another file, cannot call either. Assigning `edl`
  without them does nothing: no rebuild, no persist, no undo. Route needs NEW
  internal surface on a class whose privacy currently keeps mutation scoped to
  its own gesture handlers.
- `AutomationHost` is off the main actor by design; `EditorWindowController` is
  `@MainActor`. Route needs a hop that is precedented for the coordinator and
  not for the editor.
- A refused edit reaches `presentEditRejection`, whose only non-UI escape is
  `onEditRejectedForTesting`, documented "`nil` in production, where the alert
  is the whole point". Route therefore needs a non-UI result path FIRST, or an
  unattended agent hits a modal nobody dismisses.

**Settled: Refuse.** Product owner, 2026-09-19. It ends the data loss today,
needs none of the three preconditions, and does not block Route later if the
editor-control work wants edits to land visibly instead.

## What Refuse means

A document verb whose bundle is open in a window fails, before it writes
anything:

```
snitt trim main.snitt --auto

error: bundle_open_in_editor
  main-1b5f7d9.snitt is open in Snitt's editor.
  Close the window, or edit it there.

exit 4
```

Four things that are not optional:

- **The check runs before the write, not after.** A verb that writes and then
  reports a conflict has already lost the data it was meant to protect.
- **It is a new error code, not `internal_error`.** The agent-API audit's
  finding 2 is that `internal_error` already spans "fix your request", "do not
  retry" and "wait and retry"; this is squarely the first, and the hint tells
  the caller exactly what to do about it.
- **It raises no alert.** `presentEditRejection` is a modal, and an unattended
  agent would hang on it. Refusal travels as an `AutomationError`.
- **A closed bundle is untouched.** Every headless use — which is most of them —
  takes the same path it takes today.

## What is already built

`EditorWindowController.existing(for:)` (line 2727) finds an open window by
normalised bundle URL, and the normalisation already handles the symlink and
trailing-slash cases that make two URLs for one bundle compare unequal. Both
fixes need this lookup and neither needs to build it.

## Testing

Every test names a plausible wrong implementation and is verified to fail
against it.

- An agent edit to an open document is not lost. Fails against today's blind
  overwrite, which is the bug.
- An agent edit to a CLOSED document still writes the file, unchanged. The
  control; without it, a change that routed or refused everything would pass
  the first test and break every headless use.
- `EditorPersistenceTests.laterTrimIsNotOverwrittenByAnEarlierSave` (line 274)
  keeps passing. It walks into the save-ordering inversion deliberately.
- A refused agent edit returns `bundle_open_in_editor` and raises no alert.
  Fails against reusing `presentEditRejection`, which is the hang.
- A refused agent edit leaves `edit.json` byte-identical. Fails against
  checking after the write instead of before it, which still loses the data.

`SnittAppTests` cannot run in CI, so this merges on a local
`Scripts/run-tests.sh`.

## Decision log

| # | Decision | Rationale | Rests on | Status |
|---|---|---|---|---|
| W1 | Split from the control-surface spec | A data-loss bug should not need a feature's justification, nor inherit its review | Red team and Pragmatist, independently; product owner 2026-09-19 | Decided |
| W2 | No §4.8 amendment here | Write ordering is not scope | §4.8 | Decided |
| W3 | ~~Route reuses the window's existing edit path~~ | Refuted: both save methods are `private`, the host is off-MainActor, and rejection is a modal with no caller channel | W4 | Superseded |
| W4 | Refuse, not Route | Ends the data loss today, needs none of Route's three preconditions, and does not block Route later | Product owner, 2026-09-19 | Decided |
| W5 | `bundle_open_in_editor` is its own code, not `internal_error` | The audit's finding 2: `internal_error` already spans three unrelated classes; this one is "fix your request" and its hint says how | Agent-API audit, finding 2 | Decided |
| W6 | The check runs before the write | A verb that writes and then reports the conflict has already lost the data | W4 | Decided |
