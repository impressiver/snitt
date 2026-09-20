# An agent drives Snitt's own editor

**Status:** built. Product-owner direction 2026-09-19.

## Why

An agent cannot produce a demo of Snitt. It can record, trim, crop, caption and
export, all through the CLI, but it cannot show any of that happening: the
editor is where the work is visible, and nothing an agent can do reaches it.

## This depends on a bugfix that is now its own spec

`2026-09-19-one-writer-for-a-recording-design.md` covers the data-loss bug
underneath this: an agent's edit to a document open in the editor is silently
overwritten. That is a bug and this is a feature, so they were split. This spec
assumes that one has landed and that an agent's edit to an open document
survives. It survives by ROUTING through the window (W7), which is what makes
a document verb visible rather than merely safe.

Three findings from that spec bind here, because this surface makes agent edits
land in a window a person is watching:

- The window lookup exists (`existing(for:)`). The apply path did not:
  `applyAndSave` is private, so W7 added `applyFromAgent` and its two sidecar
  twins, which this surface reuses rather than rebuilds.
- `AutomationHost` is off the main actor; `EditorWindowController` is
  `@MainActor`. Undo bracketing must enclose the synchronous mutation, not the
  enqueued `pendingSaveTask`.
- A refused edit raises a modal with no channel back to the caller, which
  would hang an unattended agent. W7's `lastSaveError` is that channel.

## What gets new verbs, and what deliberately does not

Only view state, because it is not in the document:

| verb | why it cannot be a document operation |
|---|---|
| `editor open <bundle>` | replaces `open -a Snitt`, which works and is undiscoverable |
| `editor play <bundle>` / `editor pause <bundle>` | playback position is not persisted |
| `editor seek <bundle> --to <seconds>` | same |
| `editor select <bundle> --from <s> --to <s>` | selection is "UI state only, never written into `edl`, never persisted" |

Each names its bundle, like every other verb, so a command is unambiguous when
more than one document is open. A verb whose target is "whatever is frontmost"
would make an agent's result depend on window order.

Everything that changes the recording (`trim`, `auto-deep-trim`, `crop`,
`narrate`, deleting words) is unchanged and simply becomes visible when the
document is open. No new verbs, no new scope.

That sentence is true because of W7, and was briefly false: W4 shipped
REFUSING an edit to an open document, which would have made every document verb
fail rather than show. W7 routes instead, which is what this surface needs.

That split is what keeps the §4.8 amendment narrow. The new claim is not that
Snitt drives a GUI. It is that Snitt can be told where to put its own playhead.

## §4.8 and D49

§4.8 says "Scope is record-only. It does not click, type, or navigate, and it
does not upload." D49 splits the work: the agent drives the UI with its own
tools, Snitt supplies what those tools cannot.

That sentence is about FOREIGN UI, and the split is about not duplicating the
agent's own automation. Neither speaks to Snitt acting on its own document at an
agent's request, which is the app doing what its own API already says.

**That answers only half of D49, and the other half needs answering too.** D49
gave two reasons: posting synthetic events needs an Accessibility grant, "the
most powerful TCC permission on the machine", AND "it would mean a
prompt-injected agent could drive the Mac rather than only film it."

**D71 is the decision this proposal actually sits beside**, and the spec did not
cite it. D71 is OPEN, and already reopened D49 on a fact: Accessibility is true
of `CGEvent.post` "and not true of every way to move a window's content, so the
premise is narrower than the ruling built on it". Its argument is a permission
taxonomy, and on that axis this proposal is **cheaper than D71's own**: driving
Snitt's own editor is in-process, needing neither Accessibility nor Apple
Events nor any new TCC grant.

The blast-radius half still applies, in D71's own words: "every new capability
on this surface widens what a prompt-injected agent can reach". What these four
verbs add is bounded to bundles the agent can already reach through the existing
document API. They cannot drive another application and cannot exfiltrate.

**One of them is not bounded, and needs a rule.** `editor open` puts a
recording ON SCREEN, so a prompt-injected agent could display a recording its
owner never meant shown, while they are screen-sharing or watched. The
precedent is exact: `screenshotForAgent` refuses to photograph a session the
agent did not start, because "a screenshot of someone else's screen is the most
obviously sensitive thing this surface could hand out, and §5's posture makes
that Snitt's problem rather than the caller's." The same rule applies here: an
agent may open only a recording it made.

The amendment is recorded as **D109** rather than left to be re-derived. Its
boundary: Snitt operates its own editor and nothing else. Record-only continues
to mean Snitt never drives another application.

## Legibility

A person must be able to tell their editor is being driven. Required here, not
filed separately, because this surface is what creates the need.

Today the only "an agent is active" signal is `RecordingState`, which is
`idle` or `recording(startedAt:)` and is driven solely by an agent starting or
stopping a RECORDING. Every verb here, and every document verb, works with no
recording session at all, so nothing would show. Undo grouping is post-hoc: it
tells a person what happened once they open the Edit menu, not while their
playhead is moving.

§5.3 already gives recording a visible indicator. Editing deserves the same.
The minimum is a cue on the window being driven; reusing the menu-bar indicator
is the cheaper option and says less about which window.

**Settled (E13): a routed edit CLEARS the selection.** It names OUTPUT
seconds, and any cut shifts output time, so a selection kept across an edit
silently points at different footage than the one the caller chose — and
`auto-deep-trim` can remove exactly the selected range, leaving it pointing at
seconds the timeline no longer has. Remapping through the edit is the other
defensible answer and is a larger piece of work; clearing is the one that
cannot be subtly wrong, and an agent that wants a selection afterwards can set
one.

## Undo

Agent edits are undoable, grouped explicitly, one group per agent command.

`UndoManager.groupsByEvent` is on by default and collapses registrations made in
one run-loop pass. The rev-5 spec records that rev 4 shipped a test which passed
against both the correct and the incorrect implementation for exactly this
reason. An agent applying twenty cuts would therefore collapse into one undo
entry, or twenty, decided by the run loop rather than by anyone.

So the group boundary is set explicitly, and it is the thing a person
recognises: `auto-deep-trim` is one undo entry however many cuts it made.
Registration follows its neighbours at `EditorWindowController.swift:672, 714,
732, 805, 886`.

## Testing

The house rule applies: every test names a plausible wrong implementation and is
verified to fail against it.

- One agent command is one undo entry, whatever it did. Fails against relying on
  `groupsByEvent`, which is the trap above.
- View verbs move view state and do not touch `edit.json`. Fails against
  implementing selection as a document field.
- A driven edit raises the visible cue; a person-driven one does not. Fails
  against wiring the cue to `RecordingState`, which no verb here sets.
- A selection spanning a range a later `auto-deep-trim` removes ends in the
  state chosen above. Fails against leaving a selection pointing at seconds the
  timeline no longer has.
- `editor open` refuses a bundle the agent did not record. Fails against
  treating a readable path as an openable one.

The one-writer spec carries the tests for the bug itself, including the
closed-document control and `laterTrimIsNotOverwrittenByAnEarlierSave`.

`SnittAppTests` cannot run in CI, so these merge on a local
`Scripts/run-tests.sh`.

## Out of scope

- Driving any application other than Snitt. §4.8 stands.
- Multiple windows on one bundle. Today nothing opens the same bundle twice;
  #196 is where that stops being avoided by luck.
- Anything that makes the editor a general remote-control surface. The four
  verbs above are the whole of it, and adding a fifth is a decision, not a
  detail.

## Decision log

Slug: `agent-drives-the-editor`.

E1-E4 moved to the one-writer spec as W1-W4, with the bugfix they belong to.

| # | Decision | Rationale | Rests on | Status |
|---|---|---|---|---|
| E5 | Only view state gets new verbs; document operations are unchanged | Keeps the scope amendment to "Snitt can be told where to put its own playhead" | Product owner | Decided |
| E6 | Amend §4.8 narrowly as D109 | Record-only is about FOREIGN UI and D49's split; Snitt acting on its own document is a different claim, and leaving it unrecorded makes the next reader re-derive it | Product owner, 2026-09-19 | Decided |
| E7 | Agent edits are undoable, grouped explicitly, one group per command | `groupsByEvent` collapses by run-loop pass, so twenty cuts could be one entry or twenty, decided by the run loop rather than by anyone | rev5 spec constraint 7 | Decided |
| E8 | Every verb names its bundle | A verb targeting "whatever is frontmost" makes an agent's result depend on window order | Self-review | Decided |
| E9 | Split: the bugfix is its own spec | A data-loss bug should not need a feature's justification | Red team + Pragmatist independently; product owner | Decided |
| E10 | Legibility is required here, not filed separately | This surface creates the need; `RecordingState` is recording-only so nothing would show | Operator + Product/UX independently; product owner | Decided |
| E11 | `editor open` may only open a recording the agent made | `screenshotForAgent` sets the precedent: "a screenshot of someone else's screen is the most obviously sensitive thing this surface could hand out" | `RecordingCoordinator.swift:354` | Decided |
| E13 | A routed edit clears the selection rather than remapping it | Output time shifts under any cut, so a kept selection points at different footage; clearing cannot be subtly wrong | E10's open item | Decided |
| E14 | A closed document is `target_not_found`, not a silent success | An agent cannot watch the window, so a cheerful no-op is indistinguishable from a seek that worked (§8) | §8 | Decided |
| E15 | `editor open` tests `initiator`, not the session id | Ownership elsewhere is per-session and a bundle is opened after its session ended; `initiator` is the only ownership fact that survives in the bundle. Grants "made by an agent", not "by THIS agent", and refuses every human recording | `RecordingMetadata.initiator` | Decided |
| E12 | D109 must answer D49's blast-radius half, and cite D71 | The FOREIGN-UI rebuttal answers only the Accessibility half; D71 is OPEN on adjacent ground and was uncited | D49, D71 | Decided |
