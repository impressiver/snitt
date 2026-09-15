# The Snitt CLA has been retired

**Snitt no longer uses a contributor licence agreement.** Sign your commits off
instead — `git commit -s` — and see
[`CONTRIBUTING.md`](CONTRIBUTING.md#signing-off-and-the-licence-your-contribution-arrives-under)
for what that certifies.

This file is kept rather than deleted so that links to it from old pull
requests, issues and commit messages still explain themselves.

## Why it went

The CLA justified itself in one sentence: the project needed to be able to
relicense in future, "for example to ship a Mac App Store build, whose terms are
incompatible with some open-source licences, or to offer a commercial licence
alongside the free one".

Both halves turned out to be false.

**The App Store half.** MPL-2.0 already ships on the App Store. Brave is MPL-2.0
on iOS; Collabora Online is MPLv2 on iOS, iPadOS and macOS. Apple's terms
conflict with the GPL's whole-work conditions, not with the MPL's file-scoped
ones — Mozilla's own tracking bug on the subject remarks that "it's lucky we
aren't GPLed". Snitt does have real App Store blockers, but they are
`CGEventTap` and the agent surface, and neither is a licensing problem.

**The commercial-licence half.** That plan was abandoned: there is no licence to
enforce and no subscription to gate, and being free and open source is named as
part of what distinguishes this project.

So the agreement was asking every contributor for broad rights in exchange for
two things the project had stopped wanting.

## What replaced it, and what changed

A Developer Certificate of Origin, plus a declared **dual inbound licence**:
contributions arrive under the MPL-2.0 *and* the Apache-2.0.

A DCO on its own could not have done this. It sets inbound equal to outbound and
grants nothing extra, so a DCO-only project still needs unanimous permission to
relicense — the exact problem the CLA existed to avoid, and the usual mistake
when people swap one for the other. The DCO's own wording is what makes it work:
it certifies a right to submit "under the open source license indicated in the
file", so the project declares that licence as two.

**One thing genuinely changed, and it is worth being plain about.** Under the
CLA, the maintainer alone could have taken Snitt closed. Under the dual grant,
everybody gets the same permissive rights — including the right to fork it under
other terms. That privilege was given up deliberately.

## If you already agreed to it

Nobody did: every commit in this repository up to the change is the maintainer's
own or Dependabot's. Had anyone signed, their contributions would remain covered
by the terms they agreed to at the time; this change binds future contributions
only.

---

*The agreement that used to be here was adapted from the Apache Individual
Contributor Licence Agreement. It is preserved in this repository's history.*
