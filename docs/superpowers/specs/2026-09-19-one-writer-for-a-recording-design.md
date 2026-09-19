# One writer for a recording

**Status:** design, not built. Split out of the agent-drives-the-editor spec on
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

**Open question for the product owner.** Refuse ends the data loss today and
costs almost nothing. Route ends it and makes agent edits visible, which is
what the editor-control work wants, at three preconditions. Refuse does not
block Route later; Route makes Refuse unnecessary.

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
- If Route: a refused agent edit returns an error and raises no alert. Fails
  against reusing `presentEditRejection`, which is the hang.

`SnittAppTests` cannot run in CI, so this merges on a local
`Scripts/run-tests.sh`.

## Decision log

| # | Decision | Rationale | Rests on | Status |
|---|---|---|---|---|
| W1 | Split from the control-surface spec | A data-loss bug should not need a feature's justification, nor inherit its review | Red team and Pragmatist, independently; product owner 2026-09-19 | Decided |
| W2 | No §4.8 amendment here | Write ordering is not scope | §4.8 | Decided |
| W3 | ~~Route reuses the window's existing edit path~~ | Refuted: both save methods are `private`, the host is off-MainActor, and rejection is a modal with no caller channel | W4 | Superseded |
| W4 | Refuse-versus-Route is reopened, product owner to settle | W3's premise was the reason Route looked cheap, and it was false | `EditorWindowController.swift:1032,2004,2669,2958` | Open |
