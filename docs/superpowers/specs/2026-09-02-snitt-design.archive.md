# Decision log archive — Snitt design spec

Full text of decisions collapsed to stubs in the live log. Nothing here was
deleted; the stub in the spec keeps the D-number so every cross-reference still
resolves (enforced by `SpecConformanceTests`), and the reasoning is preserved
here because a rejected option's *rationale* is what stops it being re-pitched.

Compacted 2026-09-07. Only fully-superseded entries move here — a `Decided`
entry describing live content never does.

## D30 — superseded by D33

**Original claim:** Target selection moves to `SCContentSharingPicker`; makes the grant one-time

**Why it was overturned:** — the picker cannot serve non-interactive capture (V12), so it makes the grant one-time only for manual record-button use | macOS 15 shows a recurring MONTHLY re-consent prompt to apps that bypass the system picker — its wording is literally "requesting to bypass the system private window picker". Enumerating our own targets would nag every user forever, defeating the one-time-grant promise. The picker also gives window scoping for free, so D29 and D30 are one change | §4.6 (which already cited the picker), §5.2 | **Superseded** → D33 | permission-recurs-not-persists |

## D31 — superseded by D34

**Original claim:** Agent target grants per application bundle identifier, persisted until revoked

**Why it was overturned:** — a stored grant cannot become an `SCContentFilter` (V12), so it removed a Snitt dialog while the OS prompt fired anyway | Agents have no human to drive `SCContentSharingPicker`, which would strand automation on the bypass path and its monthly nag (§5.2). Per-window grants are impossible because `SCWindow.windowID` is a per-session integer that changes on relaunch, so the grant would silently stop matching; the bundle identifier is the stable key. Displays stay excluded — a display grant is exactly what window scoping exists to prevent giving away casually | §5.2, §5.4; `SCWindow.windowID` semantics | **Superseded** → D34 | unstable-identity-as-permission-key |

## D32 — superseded by D35

**Original claim:** An *ungranted* agent request returns `consent_required`

**Why it was overturned:** — the mechanism survives, its trigger changes: there are no grants to lack | An automation run parked behind a modal no human can see is worse than a clean failure — the agent cannot report it, cannot time out meaningfully, and cannot ask for help. Failing fast lets the agent relay the blockage to its human, which is the only path to resolution | §5.4, §11 | **Superseded** → D35 | invisible-modal-blocks-automation |

## D36 — superseded by D42

**Original claim:** §4.11 uses a cached last-approved target for the hotkey

**Why it was overturned:** — real use rejected silent target reuse, and presenting the picker every time also removes the monthly prompt for human recording | A monthly prompt costs once a month; a picker on every hotkey press costs once per recording, forever. For "record this repro now", per-use cost dominates | V12; §1, §5.2 | **Superseded** → D42 | per-use-cost-beats-periodic-cost |
