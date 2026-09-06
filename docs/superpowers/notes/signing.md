# Local code-signing identity

Snitt signs local development builds with a self-signed certificate named
"Snitt Development" rather than ad-hoc (`codesign -s -`).

## Why

macOS TCC keys permission grants — including Screen Recording — to an app's
code identity. Ad-hoc signing derives that identity from the code directory
hash, which changes on every build. The practical effect is that macOS forgets
Screen Recording permission each time you rebuild, and you re-approve constantly.

That matters beyond annoyance. Spec §5.5 sets the rule that a monthly
re-consent prompt is expected OS behaviour, while anything more frequent is a
defect worth fixing. With an unstable identity nobody can tell those apart, so
the rule is unenforceable and real bugs hide behind expected noise.

## What this is not

This is a local development convenience, not distribution. Developer ID
signing and notarization remain part of M5 packaging; this certificate never
leaves the machine that created it and confers no trust anywhere else.

## Selecting the Developer ID for a release build

`Scripts/signing-identity.sh` never reaches for a Developer ID on its own,
even when one is installed: re-signing a bundle under a different identity
resets its Screen Recording TCC grant exactly like ad-hoc signing does, so a
developer who only meant to install a certificate should not lose that
grant as a side effect.

Set `SNITT_SIGN_IDENTITY` to the exact identity name to sign with it
instead — see `docs/superpowers/notes/release-runbook.md` step 1 for the
release invocation. An identity that isn't installed under that exact name
is a hard failure naming both what was requested and what
`security find-identity -p codesigning` actually lists — never a silent
fall-back to "Snitt Development" or to ad-hoc. Setting the variable to an
empty string is also a hard failure, not "use the default": it is easy to
export it empty by accident (`SNITT_SIGN_IDENTITY= ./Scripts/make-app.sh`),
and treating that the same as unset would make a broken CI or shell
config silently sign a "release" build with the local dev identity.
