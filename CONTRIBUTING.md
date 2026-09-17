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

## Signing off, and the licence your contribution arrives under

There is no CLA. Sign your commits off instead:

```bash
git commit -s        # appends a Signed-off-by line using your git identity
```

That line is your agreement to the [Developer Certificate of
Origin](#developer-certificate-of-origin-11) below — the same one the Linux
kernel uses. It certifies that you wrote the change or have the right to submit
it. **It is not a copyright assignment**: you keep your copyright and remain
free to use your work anywhere else, for anything.

### The dual inbound licence

The DCO certifies a right to submit "under the open source license indicated in
the file". For this project that licence is stated here, and it is two:

> Unless you state otherwise, any contribution you intentionally submit for
> inclusion in Snitt shall be licensed **both under the Mozilla Public License
> 2.0 and under the [Apache License, Version
> 2.0](https://www.apache.org/licenses/LICENSE-2.0)**, at the recipient's
> option, without any additional terms or conditions.

Snitt still ships under the MPL-2.0 and there is no plan to change that. The
second grant exists so that it *could* change — a Mac App Store build, or terms
nobody has thought of yet — without tracking down every past contributor for
permission, which in practice means it never happens.

**This is not a grant to the maintainer alone.** Everyone who receives Snitt
gets the same permissive rights you granted, including the right to fork it
under other terms. A contributor licence agreement is the only instrument that
makes a closed fork the maintainer's private option, and this project has
deliberately given that up: near-zero friction for you, and no special
privileges for anyone.

### Developer Certificate of Origin 1.1

*Reproduced verbatim from <https://developercertificate.org>. Do not edit.*

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

### One thing the DCO does not cover

If your change includes third-party code, **say so in the pull request**, with
its source and its licence. The DCO asks you to certify you had the right to
submit it; it does not ask you to point it out, and a reviewer cannot always
tell.

## Conduct, and reporting something dangerous

By taking part you agree to the [Code of Conduct](CODE_OF_CONDUCT.md).

**Found a security problem? Do not open an issue.** Use
[private vulnerability reporting](https://github.com/impressiver/snitt/security/advisories/new),
which is visible only to you and the maintainer. [`SECURITY.md`](SECURITY.md)
says what is in scope and what to expect.

## Before you open a pull request

Read [`docs/DEVELOPING.md`](docs/DEVELOPING.md) for environment setup, building
and running locally.

### Tests

Every test must name a plausible wrong implementation and be **verified to fail
against it**. A test that passes whether or not the code is correct is worse
than no test, because it reads as coverage. This project has found twenty-six
tests that asserted a property *adjacent* to the one that mattered.

Three project-specific traps:

- **`swift test` exits 0 when the test bundle segfaults.** Only the
  `Test run with N tests ... passed` line is trustworthy. Piping to `grep`
  returns grep's exit status, not the suite's.
- **CI runs five of seven targets.** `SnittExportTests` and `SnittAppTests` hang
  on a headless GitHub runner — they build AVFoundation compositions, encode
  movies, or open windows. Run the full unfiltered `swift test` locally before
  proposing anything that touches export, composition, the editor or the
  timeline.
- **A LOCKED SCREEN FAILS TESTS THAT LOOK UNRELATED.** Anything that hit-tests
  a real `NSHostingView` needs the window server, and macOS does not composite
  for a locked session — so the run comes back with failures in the editor
  chrome and a lower test COUNT than usual, neither of which has anything to do
  with the change under test. Unlock the Mac and run it again before believing
  a failure. If you are not sure whether that is what you are looking at,
  `ioreg -n Root -d1 -a | grep -q CGSSessionScreenIsLocked` answers it.

### Continuous integration

CI runs on every pull request, including from a fork. It uses the
`pull_request` trigger with a read-only token and no repository secrets, so
nothing you push can reach anything — which is also why no job here can sign,
notarize or publish.

Three jobs: hygiene checks on Ubuntu, then build-and-test and a release build on
macOS 26. The macOS runner matches `Package.swift`'s floor deliberately, so an
API newer than the floor fails here rather than shipping and trapping on a
supported machine.

If this is your first contribution, a maintainer has to approve the workflow run
before it starts. That is a GitHub setting for public repositories, not a
judgement about you.

### Documentation

User-facing documentation is the [wiki](https://github.com/impressiver/snitt/wiki),
and its source is [`docs/wiki/`](docs/wiki/) in this repository. Edit it here, in
a pull request, and a maintainer publishes with `Scripts/publish-wiki.sh`. A
wiki has no review; this way the copy people read went through some.

### Scope

Design decisions live in `docs/superpowers/specs/2026-09-02-snitt-design.md`,
in a numbered decision log. If a change contradicts a decision there, say so in
the pull request and argue it — decisions are sticky, not frozen, but reversing
one silently means the next reader inherits a premise that is no longer true.
