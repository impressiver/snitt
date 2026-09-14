# Installing

## The signed build (recommended)

Download the latest DMG from
[Releases](https://github.com/impressiver/snitt/releases), open it, and drag
Snitt to Applications.

The DMG and the app inside it are signed with a Developer ID and notarized by
Apple, so macOS opens them without a warning. If you see "Snitt is damaged and
can't be opened", the download was corrupted — re-download rather than
right-click-opening, which works around a real problem.

## Homebrew

```bash
brew install --cask impressiver/snitt/snitt
```

Same signed build, same notarization. `brew upgrade --cask snitt` updates it,
as does Snitt's own in-app updater.

## From source

```bash
git clone https://github.com/impressiver/snitt.git
cd snitt
./Scripts/make-app.sh          # writes build/Snitt.app
open build/Snitt.app
```

**A build from source is not signed with a Developer ID**, and that matters more
than it sounds. macOS ties Screen Recording, Microphone and Input Monitoring
permissions to an app's **code signature**. An ad-hoc signature changes whenever
you rebuild, so macOS treats each build as a different application and the
permissions you granted the last one do not carry over.

`docs/DEVELOPING.md` covers giving your local builds one stable identity so you
grant those permissions once instead of every time. If you are building Snitt to
work on it, read that section before granting anything.

## Updating

Snitt checks for updates through [Sparkle](https://sparkle-project.org), the
standard macOS updater. The check is off until you turn it on, in
**Settings ▸ Updates & Diagnostics ▸ Check for updates automatically**, and
nothing is downloaded or installed until you choose it.

This is the only network request Snitt makes.

## Uninstalling

Drag Snitt out of Applications. Recordings are yours and stay where you put
them; the default is `~/Documents/Snitt`.

To remove its settings as well:

```bash
defaults delete com.impressiver.snitt
```

macOS keeps its own record of the permissions you granted, in
**System Settings ▸ Privacy & Security**. Remove Snitt from the Screen
Recording, Microphone and Input Monitoring lists there.
