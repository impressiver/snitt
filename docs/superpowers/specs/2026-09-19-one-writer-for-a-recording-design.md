# One writer for a recording

**Status:** built (Route). W4 superseded by W7. Split out of the agent-drives-the-editor spec on
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

**Settled first as Refuse, now as Route.** Refuse shipped (#200) and was
superseded within the day (W7).

Refuse was the right call against the question as posed: it ended the data loss
for almost nothing. What it could not do is let an agent SHOW its work, and
that turned out to be load-bearing. With Refuse, `snitt trim` on a document
open in the editor returns `bundle_open_in_editor` and nothing happens on
screen, so the README demo's central beat — the transcript cut landing while
the editor is being filmed — cannot be produced at all.

The costing also changed. Route's three preconditions were what made it
expensive, and the control surface pays for two of them regardless:

| precondition | still Route-only? |
|---|---|
| new internal surface on the editor's document state | no, the view verbs need it |
| actor hop from the off-MainActor host | no, same |
| a non-UI rejection path instead of `NSAlert` | yes |

That is the new evidence, and it is why this is a supersede rather than a
reversal of an unsound decision.

## What Refuse means

A document verb whose bundle is open in a window fails, before it writes
anything:

```
snitt trim main.snitt --auto

error: bundle_open_in_editor
  main-1b5f7d9.snitt is open in Snitt's editor.
  Close the window, or make this edit in the editor.

exit 20
```

Four things that are not optional:

- **The check runs before the write, not after.** A verb that writes and then
  reports a conflict has already lost the data it was meant to protect.
- **It is a new error code, not `internal_error`.** `bundle_open_in_editor`,
  exit 20 — appended, because §15 makes these a public interface and the codes
  that shipped keep the numbers they shipped. The agent-API audit's
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
- An agent edit to an open document routes, and the host writes no file
  itself. Fails against today's blind write, where the file really does say
  what the agent asked for right up until the window's next save.
- The transform is applied to the WINDOW's document, not the file's. The window
  carries a cut `edit.json` does not; building on the file drops it.
- Every mutating verb routes, `narrate` included. Fails against routing only
  the verb the bug was noticed through.

`SnittAppTests` cannot run in CI, so this merges on a local
`Scripts/run-tests.sh`.

## Decision log

| # | Decision | Rationale | Rests on | Status |
|---|---|---|---|---|
| W1 | Split from the control-surface spec | A data-loss bug should not need a feature's justification, nor inherit its review | Red team and Pragmatist, independently; product owner 2026-09-19 | Decided |
| W2 | No §4.8 amendment here | Write ordering is not scope | §4.8 | Decided |
| W3 | ~~Route reuses the window's existing edit path~~ | Refuted: both save methods are `private`, the host is off-MainActor, and rejection is a modal with no caller channel | W4 | Superseded |
| W4 | ~~Refuse, not Route~~ | Superseded by W7 the same day: Refuse cannot let an agent show its work, and the control surface pays for two of Route's three preconditions | W7 | Superseded |
| W5 | ~~`bundle_open_in_editor` is its own code~~ | Nothing produces it under Route. Retained in the enum rather than removed: it shipped on `main` and the lenient decoder makes an unused code harmless, where removing one is a wire change for no gain | W7 | Superseded |
| W6 | ~~The check runs before the write~~ | There is no check under Route; the window is simply the writer | W7 | Superseded |
| W7 | Route, not Refuse | Refuse left the demo's central beat unfilmable, and two of Route's three preconditions are paid for by the control surface either way | Product owner, 2026-09-19 | Decided |
| W8 | The host hands over a transform, not a finished EDL | A window holds applied-but-unpersisted edits; computing from disk and handing back the result reintroduces the divergence by a longer route | `applyAndSave` takes `self.edl` | Decided |
| W9 | All three sidecars route, not just `edit.json` | `transcript.json` and `events.json` are held as published state and written whole too; `narrate` is a different file with the identical bug | `applyAndSaveTranscript`, `applyAndSaveEvents` | Decided |
