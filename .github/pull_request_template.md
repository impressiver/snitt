<!--
Small fix or a typo? Delete all of this and just say what it does.
The sections below earn their keep on changes that touch behaviour.
-->

## What this changes

<!-- One or two sentences. The reader has not seen the issue. -->

## Why

<!--
Link the issue if there is one. If a `docs/superpowers/specs/` decision says
otherwise, say so here and argue it. Decisions are sticky, not frozen, and
reversing one silently leaves the next reader with a premise that is no longer
true.
-->

## How it was verified

<!--
Not "tests pass". WHICH tests, and what wrong implementation would they catch?

`swift test` EXITS 0 WHEN THE TEST BUNDLE SEGFAULTS. Only the
`Test run with N tests ... passed` line means anything, and piping to grep
returns grep's status rather than the suite's.

CI runs five of seven targets: SnittExportTests and SnittAppTests hang on a
headless runner. If this touches export, composition, the editor or the
timeline, run the full unfiltered `swift test` locally and paste the summary
line. Green CI does not cover those.
-->

## Checklist

- [ ] Every new test names a plausible wrong implementation and was verified to fail against it
- [ ] Full `swift test` run locally if this touches export, composition, the editor or the timeline
- [ ] UI change? Rebuilt with `Scripts/make-app.sh` and actually looked at it. Tests passing is not the same as pixels changing
- [ ] New Swift files carry the MPL Exhibit A header (`LicenseHeaderTests` enforces this)
- [ ] I have read and agree to [`CLA.md`](../CLA.md)
