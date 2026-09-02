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
