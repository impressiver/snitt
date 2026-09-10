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

The **DMG inherits the same trap, one level deeper.** A DMG built from an
unstapled app mounts and launches fine; the failure arrives after the user
drags the app to /Applications, which is the entire point of a DMG. From
that moment Gatekeeper assesses the app on its own, and stapling the *image*
does not help — a DMG's ticket covers the DMG, and the copied-out app is not
the DMG. So the DMG is built in step 7, after the app is stapled, and gets
its own notarization on top.

**The DMG is not an update artifact.** Sparkle's appcast enclosure is, and
stays, the zip from step 4. The DMG exists for one job: somebody arriving at
the Releases page with no copy of Snitt installed. `make-appcast.sh` never
names it, and pointing an enclosure at it would change how updates install
for every existing user.

### Diagnosing notarization state changes the answer

`xcrun stapler validate` reports success for an app with **no ticket attached**
when Apple has one on file — it fetches it, printing "Downloaded ticket has
been stored at ...", and *caches* it. Measured on 0.2.0, same bundle, untouched,
in this order:

```
spctl --assess --type execute   -> rejected: source=Unnotarized Developer ID
xcrun stapler validate          -> exit 0, "The validate action worked!"
spctl --assess --type execute   -> accepted: source=Notarized Developer ID
```

The middle command changed the verdict of the third. So neither tool proves a
ticket is *attached* while online, and a bundle you have already probed will lie
to you afterwards. The only offline signal is the absence of that "Downloaded
ticket" line. Stapling an app bundle rewrites `Contents/CodeResources` in place
and adds no new file, which is why nothing visible appears in the bundle.

## Cutting a release

```sh
SNITT_SIGN_IDENTITY="Developer ID Application: impressiver LLC (TEGDRM8W7U)" \
  ./Scripts/release.sh <version>
```

`Scripts/release.sh` runs every step below in order and then checks what
actually landed. Prefer it to running the steps by hand.

**Why it exists.** The steps below used to end in a paragraph asking a
person to remember to upload three files. That step is the one with no
failure mode: a release missing its DMG looks exactly like a release, and
the person who finds out is somebody arriving at the Releases page with no
copy of Snitt installed and nothing to click. v0.1.0 shipped that way —
run `./Scripts/release.sh --verify 0.1.0` to watch it fail.

The script keeps **one list** of required assets, used both to upload and
to verify. A fourth artifact added there is enrolled in the check
automatically; two lists is how one gets added to the upload and never to
the check.

Other modes, none of which need credentials or touch anything:

```sh
./Scripts/release.sh --verify 0.2.0     # check a past release's assets
./Scripts/release.sh --assets 0.3.0     # print the required asset names
./Scripts/release.sh 0.3.0 --dry-run    # print every command, run none
./Scripts/release.sh 0.3.0 --resume-from 7   # after a diagnosed failure
```

It refuses, before spending a network round trip, to: release a version
that disagrees with `AppVersion.fallback`; release without
`SNITT_SIGN_IDENTITY`; release from a dirty tree or a non-default branch;
re-use an existing tag; or publish with any required asset missing or
zero-length.

`Tests/SnittAppTests/ReleaseScriptTests.swift` pins those refusals and,
more importantly, pins that the upload list and the verification list are
the same list.

## The path, in order

Bump `AppVersion.fallback` in `Sources/SnittDocument/AppVersion.swift`
first — everything below reads the version from there, and step 0 of the
script refuses if the argument disagrees with it.

1. **Build, with the real Developer ID.**

   ```sh
   SNITT_SIGN_IDENTITY="Developer ID Application: impressiver LLC (TEGDRM8W7U)" ./Scripts/make-app.sh

   Setting `SNITT_SIGN_IDENTITY` also makes this a UNIVERSAL build (arm64 +
   x86_64). That is deliberate coupling, not a coincidence: a release must not
   be able to ship one architecture because a second flag was forgotten. Check
   it landed with `lipo -archs build/Snitt.app/Contents/MacOS/Snitt`, which
   should print both. Development builds stay native and single-arch.
   ```

   Produces `build/Snitt.app`, version-stamped from
   `Sources/SnittDocument/AppVersion.swift`'s `AppVersion.fallback` (both
   `CFBundleShortVersionString` and `CFBundleVersion`).

   `SNITT_SIGN_IDENTITY` is what selects the Developer ID — it is never
   picked automatically just because the certificate exists in the
   keychain. Plain `./Scripts/make-app.sh` (no variable set) keeps signing
   with the self-signed local identity — see
   `docs/superpowers/notes/signing.md` — which is for local testing only;
   never notarize or publish a build signed that way. A name that doesn't
   match an installed identity is a hard, loud failure (`Scripts/signing-
   identity.sh` lists what's actually in the keychain), never a silent
   fall-back to the local identity or to ad-hoc.

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

5. **Sign the update for Sparkle's own EdDSA check** (see "The EdDSA
   signing key" below):

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

   Refuses outright (before writing anything) if `$SIGNATURE` is empty.
   With `SUPublicEDKey` configured, that signature is verified on the
   client before an update installs — see "The EdDSA signing key" below.

7. **Build the DMG, and give it its own notarization.**

   ```sh
   SNITT_SIGN_IDENTITY="Developer ID Application: impressiver LLC (TEGDRM8W7U)" \
     ./Scripts/make-dmg.sh build/Snitt.app
   ./Scripts/notarize.sh Snitt-<version>.dmg
   ```

   `make-dmg.sh` refuses an app Apple has never notarized, so it cannot run
   before step 3. It stages the app plus an `/Applications` symlink — nothing
   else — names the image from the app's own `CFBundleShortVersionString`
   rather than from `AppVersion.swift`, and signs the image when
   `SNITT_SIGN_IDENTITY` is set. An unsigned DMG is refused by Gatekeeper on
   download, before the user ever reaches the app inside it.

   The image needs its own ticket: notarizing the app does not notarize an
   image that later contains it. `notarize.sh` takes either, detects which
   from the artifact, and submits a DMG as itself rather than zipping it.

8. **Publish to GitHub Releases.**

   Create the release (tag `v<version>`), and upload three assets:
   - `Snitt-<version>.zip` (from step 4 — the stapled, notarized archive)
   - `appcast.xml` (from step 6)
   - `Snitt-<version>.dmg` (from step 7 — the installer, download only)

   Sparkle's `SUFeedURL` points at
   `https://github.com/impressiver/snitt/releases/latest/download/appcast.xml`,
   which resolves to whatever the **latest** release's `appcast.xml` asset
   is — so the release must be marked "latest" (GitHub's default for a
   new, non-prerelease tag) for existing installs to find it.

## The EdDSA signing key

`SUPublicEDKey` **is** configured in `Scripts/make-app.sh`'s Info.plist,
so `sparkle:edSignature` is verified on the client before an update
installs. Integrity rests on three independent things — TLS to
github.com, the Developer-ID code-signature match, and the EdDSA
signature — rather than on the first two alone. A release asset replaced
by something signed with the same Developer ID is now caught.

The private half lives **only** in the maintainer's login keychain:

| | |
|---|---|
| Keychain | `~/Library/Keychains/login.keychain-db` |
| Service | `https://sparkle-project.org` |
| Account | `ed25519` |

In Keychain Access.app: select **login**, search `sparkle`. The public
half is not a secret and is committed; the private half must never enter
this repo.

**Losing the private key is unrecoverable.** Every installed copy of
Snitt would reject every future update, and the only remedy is shipping a
new build by hand to each user. Back it up to a password manager:

```bash
./.build/artifacts/sparkle/Sparkle/bin/generate_keys -x ~/Desktop/snitt-sparkle-private.key
# copy the contents into a password manager, then:
rm ~/Desktop/snitt-sparkle-private.key
```

`Scripts/generate-sparkle-key.sh` reports the existing key, warns if more
than one exists for the service, and prints the plist line to paste. Run
it by hand, only with intent to ship — it touches the real login
keychain, so it is deliberately not part of any build or test path. It
does not overwrite an existing key.

**If the keychain key and the plist's public half ever disagree**,
updates verify on the machine that built them and fail on every other
one — the same failure signature as an unstapled archive, and just as
invisible locally. `sign_update` and `SUPublicEDKey` must be the same
keypair.

**Never set `SUPublicEDKey` to an empty string.** Verified against
Sparkle's source (`SUHost.m` / `SUSignatures.m`): an *absent* key reads
as `SUSigningInputStatusAbsent` and Sparkle falls back to code-signature
validation, but an *empty* one decodes to a zero-length `NSData`, reads
as `SUSigningInputStatusInvalid`, and `SPUUpdater` refuses to start at
all with `SUNoPublicDSAFoundError`. To ship without a key, delete the two
plist lines entirely.

## First-real-release checklist (needs a Developer ID and Apple's servers)

These can't be verified in this repo or in CI — they need real credentials
and a second machine:

1. `sign_update` signs with the same keypair whose public half is in
   `SUPublicEDKey` — a mismatch verifies locally and fails everywhere
   else. Check with `Scripts/generate-sparkle-key.sh`.
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
