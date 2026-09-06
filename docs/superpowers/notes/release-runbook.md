# Release runbook

The exact order of commands for shipping a Snitt release, from build to a
GitHub Release a user's Sparkle-enabled install can find and apply. Every
step names the artifact it produces and which script consumes it next.

## Why the order matters

`Scripts/notarize.sh` zips `build/Snitt.app` into a temp directory it
deletes as soon as it's done (`trap cleanup EXIT`) — that zip exists only
to satisfy `notarytool submit`. `Scripts/make-appcast.sh` takes a `<zip>`
argument that nothing else in this repo produces. Between the two there is
a real gap: **the archive you publish must be zipped AFTER
`stapler staple`, not before.**

An app that is signed and notarized but zipped *before* stapling launches
fine on the machine that built it — Gatekeeper falls back to asking
Apple's servers whether the notarization ticket exists, and it does. It
fails, silently and only for the affected user, on a machine that's
offline, on a restrictive network, or hits Apple during an outage. There is
no local test that catches this: `notarize.sh` and `spctl --assess` both
pass either way, because both run against the `.app` on disk, and stapling
mutates that `.app` in place. Only the *zip* can be built at the wrong
time, and only a user who can't reach Apple's servers ever sees it fail.

## The path, in order

1. **Build.**

   ```sh
   ./Scripts/make-app.sh
   ```

   Produces `build/Snitt.app`, version-stamped from
   `Sources/SnittDocument/AppVersion.swift`'s `AppVersion.fallback` (both
   `CFBundleShortVersionString` and `CFBundleVersion`), signed with a real
   Developer ID (or the self-signed local identity — see
   `docs/superpowers/notes/signing.md` — for local testing only; never
   notarize or publish a locally-signed build).

2. **Verify the signature.**

   ```sh
   codesign --verify --deep --strict build/Snitt.app
   ```

   `notarize.sh` also runs this check itself and refuses to proceed if it
   fails — this step is a fast local check before spending a network round
   trip.

3. **Notarize and staple.**

   ```sh
   ./Scripts/notarize.sh build/Snitt.app
   ```

   Reads credentials from `NOTARY_PROFILE` or the `NOTARY_KEY` /
   `NOTARY_KEY_ID` / `NOTARY_ISSUER` trio (see the script's header for how
   to create a keychain profile — this is the preferred path since the
   credential then lives in the keychain, not a shell variable). Zips
   `build/Snitt.app` into a **temporary** archive purely for submission,
   submits it with `notarytool submit --wait`, then runs
   `stapler staple build/Snitt.app` and `spctl --assess` against the
   **app bundle itself**. The temp submission zip is deleted; it is not
   the artifact you publish.

   Read the printed `notarytool submit` status, not just this script's
   exit code — some Xcode versions have been reported to exit 0 on a
   submission whose own status was "Invalid" rather than "Accepted". A
   rejected submission still fails safely here: `stapler staple` has no
   ticket to attach and exits non-zero, so the run ends in a loud failure
   either way — but reading the status directly once is worth doing.

   After this step, `build/Snitt.app` on disk is the stapled bundle.
   **Nothing has been zipped for distribution yet.**

4. **Zip the STAPLED bundle — this is the step that's easy to skip.**

   ```sh
   ditto -c -k --keepParent build/Snitt.app Snitt-<version>.zip
   ```

   Use `ditto`, not `zip` — it preserves extended attributes and resource
   forks that `zip` can silently drop, which can invalidate the code
   signature inside the archive. `<version>` matches
   `AppVersion.fallback`. This command must run **after** step 3, against
   the now-stapled `build/Snitt.app`. Running it before step 3, or reusing
   a zip made before stapling, produces the failure mode described above.

   `Snitt-<version>.zip` is the artifact every remaining step consumes.

5. **Sign the update for Sparkle's own EdDSA check** (once a keypair
   exists — see "Before the first real release" below):

   ```sh
   SIGNATURE="$(.build/artifacts/sparkle/Sparkle/bin/sign_update -p Snitt-<version>.zip)"
   ```

   `sign_update` is not on `PATH` — it ships inside the Sparkle SPM
   checkout at `.build/artifacts/sparkle/Sparkle/bin/sign_update` (see
   `Scripts/make-appcast.sh`'s header for the equivalent
   `.build/checkouts/Sparkle` location if the artifact path differs on
   your machine). **The `-p` flag is required.** Without it, `sign_update`
   prints the whole `sparkle:edSignature="…" length="…"` attribute pair,
   not a bare signature — pasting that into step 6's `[signature]`
   argument would produce a nested, quote-escaped garbage attribute in the
   appcast. `make-appcast.sh` now refuses a signature shaped like that
   mistake (a `"`, `sparkle:edSignature`, `length=`, or embedded
   whitespace) as a defense in depth, but don't rely on it — run `-p` and
   get a clean signature in the first place. `-p` alone prints just the
   base64 signature, which is what `$SIGNATURE` must hold for the next
   step.

6. **Generate the appcast item.**

   ```sh
   ./Scripts/make-appcast.sh <version> Snitt-<version>.zip \
     https://github.com/impressiver/snitt/releases/download/v<version>/Snitt-<version>.zip \
     "$SIGNATURE" \
     --output appcast.xml
   ```

   `<release-url>` must be the exact URL the asset will have once uploaded
   in step 7 — this script never constructs it, so a renamed or re-tagged
   release fails loudly instead of shipping a 404. `--output appcast.xml`
   is required, not `> appcast.xml`: the redirect form truncates any
   existing good feed before this script runs a single check; `--output`
   validates fully, then writes atomically. The filename must be exactly
   `appcast.xml` — it's the basename of `SUFeedURL` in `make-app.sh`, and
   Sparkle fetches that literal URL.

   Refuses outright (before writing anything) if `$SIGNATURE` is empty —
   see "the real situation" below for what that guarantee does and does
   not currently protect against.

7. **Publish to GitHub Releases.**

   Create the release (tag `v<version>`), and upload two assets:
   - `Snitt-<version>.zip` (from step 4 — the stapled, notarized archive)
   - `appcast.xml` (from step 6)

   Sparkle's `SUFeedURL` points at
   `https://github.com/impressiver/snitt/releases/latest/download/appcast.xml`,
   which resolves to whatever the **latest** release's `appcast.xml` asset
   is — so the release must be marked "latest" (GitHub's default for a
   new, non-prerelease tag) for existing installs to find it.

## Before the first real release: the EdDSA key situation

`Scripts/make-app.sh`'s Info.plist has **no `SUPublicEDKey`** — not a
placeholder, entirely absent. Verified against Sparkle's source
(`SUHost.m` / `SUSignatures.m`): an absent key reads back as
`SUSigningInputStatusAbsent`, and Sparkle's config check falls back to
requiring the downloaded update be code-signed to match the installed
app's Developer ID. On an HTTPS feed with a code-signed build (both true
here), that fallback does not accept a forged update — but it means
**Sparkle never reads `sparkle:edSignature` at all.** `make-appcast.sh`
refusing to emit an unsigned item is a real, enforced guarantee on the
*feed* — the signature it insists on is genuinely generated and published
— but it is currently **unenforceable on the client**, because nothing
checks it. Today, update integrity rests entirely on TLS-to-github.com
plus Developer-ID code-signature matching, with no EdDSA defense in depth
and no protection if a release asset were ever replaced by something
signed with the same identity.

This is a known, accepted gap for M5b, not a defect to work around here.
**Before the first real release**, close it:

1. Run Sparkle's `generate_keys` once, by hand, on the maintainer's own
   machine. It writes the private key to the login Keychain — never a
   file, never this repo — and prints the public half.
2. Paste that public half into `SUPublicEDKey` in `Scripts/make-app.sh`'s
   Info.plist block.
3. Rebuild (step 1 above) so the shipped plist actually carries the key.

**Do not run `generate_keys` as part of routine maintenance or tooling
work on this repo** — it touches the real login keychain and only the
maintainer, on their own machine, with intent to ship a real key, should
run it.

## First-real-release checklist (needs a Developer ID and Apple's servers)

These can't be verified in this repo or in CI — they need real credentials
and a second machine:

1. `SUPublicEDKey` configured (above).
2. A real `codesign -dvv` on the signed bundle prints
   `TeamIdentifier=<TEAMID>` (the exact form
   `Scripts/lib/needs-teamless-workaround.sh` compares against), and
   `codesign -d --entitlements -` on the result shows **no**
   `disable-library-validation` — confirming the teamless workaround
   didn't fire on a real Developer ID.
3. `SNITT_FAKE_TEAM_IDENTIFIER_LINE` is unset in the release shell.
4. Steps 3–4 above run end to end, with the printed `notarytool` status
   read directly.
5. The stapled, re-zipped app (step 4's artifact, extracted) launches
   without a Gatekeeper warning on a machine that has never seen it —
   the only real check that notarization and stapling both worked.
6. A full 0.1.0 → 0.1.1 offer-and-install cycle.
7. A genuinely fresh install performs no update check until the user
   opts in (`UpdateSettings`/§5) — see `com.impressiver.snitt` cleanup
   below if this machine has run earlier test builds.

## Housekeeping: stale keys in the real preference domain

Earlier, pre-fix test runs against `build/Snitt.app` (before the fixture
isolation in `UpdaterControllerTests` existed) wrote real Sparkle keys into
`com.impressiver.snitt` — `SUEnableAutomaticChecks`, `SUHasLaunchedBefore`,
`SULastCheckTime`. Current tests are isolated (each drives a throwaway
bundle with its own `SUDefaultsDomain`) and do not write there, but old
residue from before that fix can still be sitting on a developer machine,
and would make a "fresh install performs no check" test (checklist item 7
above) behave as already-checked — masking the exact bug that fixture
isolation exists to catch.

To clear it by hand, once, before relying on a "fresh install" check on a
machine that has run this app before:

```sh
defaults delete com.impressiver.snitt SUEnableAutomaticChecks
defaults delete com.impressiver.snitt SUHasLaunchedBefore
defaults delete com.impressiver.snitt SULastCheckTime
```

This is real machine state, not something to script or automate away —
run it deliberately, only on a machine you're about to do a fresh-install
check on, and confirm afterward with
`defaults read com.impressiver.snitt`.
