# Contributing to Snitt

## Licence

Snitt is licensed under the **Mozilla Public License 2.0** (see `LICENSE`).

MPL is *file-level* copyleft: changes to Snitt's own files must be published
under the MPL, while a larger work that merely uses Snitt may carry its own
terms. That boundary only holds if every file declares itself covered, so
**every Swift file must begin with the Exhibit A notice**:

```swift
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//
// Copyright © 2026 Ian White.
```

`LicenseHeaderTests` fails the build if a file is missing it — that is a
correctness check, not a style one. A file without the notice is arguably not
Covered Software, which silently removes it from the protection the licence
exists to provide.

## Contributor Licence Agreement

Contributions require agreeing to [`CLA.md`](CLA.md). It is short, and it is not
a copyright assignment — you keep your copyright. It exists so the project can
relicense in future (a Mac App Store build, or a commercial licence beside the
free one), which is impossible once contributions arrive under terms that cannot
be changed without unanimous permission.

## Before you open a pull request

Read [`docs/DEVELOPING.md`](docs/DEVELOPING.md) for environment setup, building
and running locally.

### Tests

Every test must name a plausible wrong implementation and be **verified to fail
against it**. A test that passes whether or not the code is correct is worse
than no test, because it reads as coverage. This project has found twenty-six
tests that asserted a property *adjacent* to the one that mattered.

Two project-specific traps:

- **`swift test` exits 0 when the test bundle segfaults.** Only the
  `Test run with N tests ... passed` line is trustworthy. Piping to `grep`
  returns grep's exit status, not the suite's.
- **CI runs five of seven targets.** `SnittExportTests` and `SnittAppTests` hang
  on a headless GitHub runner — they build AVFoundation compositions, encode
  movies, or open windows. Run the full unfiltered `swift test` locally before
  proposing anything that touches export, composition, the editor or the
  timeline.

### Scope

Design decisions live in `docs/superpowers/specs/2026-09-02-snitt-design.md`,
in a numbered decision log. If a change contradicts a decision there, say so in
the pull request and argue it — decisions are sticky, not frozen, but reversing
one silently means the next reader inherits a premise that is no longer true.
