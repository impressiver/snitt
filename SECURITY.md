# Security policy

## Reporting a vulnerability

**Use [private vulnerability reporting](https://github.com/impressiver/snitt/security/advisories/new).**
It is a form on this repository, visible only to you and the maintainer, and it
is the only channel that does not publish the problem while it is still
exploitable.

Do not open a public issue. A public issue cannot be unpublished, and the person
filing one usually does not realise that until it is done.

If the form is unavailable, email **security@impressiver.com**.

## What to expect

Snitt has one maintainer and no security team. Rather than promise a response
time nobody is staffed to meet, here is what actually happens: reports are
triaged when they are seen, a fix is worked in the open once the report is
understood, and the advisory is published with credit unless you ask otherwise.

If you have had no reply in two weeks, assume it was missed and chase it. That
is not rudeness, it is the correct action.

## Scope

Snitt records the screen, captures audio, can log input timing, and runs a local
socket that agents drive. The things worth reporting are anything that lets
software record without the explicit permission the app claims to require:

- Recording that starts without the system picker, or continues after the
  visible indicator says it stopped
- An agent reaching the automation socket without the opt-in being on, or
  escalating past what it was granted (window scope, session cap, kill switch)
- Input event logging capturing anything beyond timing, or running when the
  setting is off
- A diagnostics bundle or exported recording carrying data it says it strips:
  window titles, file paths, keystroke content
- Anything that lets a different process on the machine impersonate an
  authorised agent to the socket
- Update machinery: an appcast or archive that installs code without the
  EdDSA signature check passing

**Out of scope**, because it describes the product working as designed:

- A person with physical access to an unlocked Mac can record that Mac. That is
  what the app is for.
- macOS re-prompting for Screen Recording periodically. That is the platform,
  and `ConsentExplainer` explains it.
- A build from source being unsigned, and therefore trusted differently by
  macOS than the notarized release.

## Supported versions

The latest release. Snitt is pre-1.0 with one maintainer, so there is no
backport branch and claiming one would be a promise nobody can keep.
