# S9 — Can Sparkle live in a hand-assembled bundle?

**Question (M5b):** §13 names Sparkle for updates and §4.3 chooses direct
download first. But `Snitt.app` is not an Xcode target — `Scripts/make-app.sh`
assembles it by hand from a SwiftPM build. Sparkle ships as an XCFramework and
normally relies on Xcode's "Embed Frameworks" phase. Does it work here at all?

**Date:** 2026-09-05 · **macOS:** 26.5.2 · **Status:** Resolved

## Method

A throwaway SwiftPM package depending on `sparkle-project/Sparkle` from 2.6.0,
with an executable that constructs an `SPUStandardUpdaterController`. Kept
outside the real `Package.swift` deliberately: a negative result should not
leave a dependency to back out of.

## Observations

```
[2/7] Copying Sparkle.framework
[7/9] Linking SparkleProbe
Build complete! (16.27s)

$ ./.build/debug/SparkleProbe
SPIKE Sparkle linked; updater=SPUUpdater

$ otool -l .build/debug/SparkleProbe | grep -A2 LC_RPATH
  path /usr/lib/swift
  path @loader_path
  path …/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx
```

## Answers

1. **Sparkle resolves, builds and links under SwiftPM**, with no Xcode project.
   SPM copies `Sparkle.framework` into the build directory itself.
2. **The linked binary runs** and instantiates `SPUUpdater`, so the framework is
   found at runtime.
3. **The rpath SPM emits is `@loader_path`** — the framework must sit beside the
   executable. In a bundle the executable is `Contents/MacOS/Snitt`, so either
   copy `Sparkle.framework` next to it, or use the conventional
   `Contents/Frameworks/` and add `@executable_path/../Frameworks` with
   `install_name_tool`. Both are available to `make-app.sh`; the first needs no
   rpath surgery.

## Not required here

Sparkle 2's `Downloader.xpc` and `Installer.xpc` services exist for **sandboxed**
apps. Snitt is not sandboxed — it needs Screen Recording, and §4.3 ships it by
direct download — so the framework alone is sufficient. Recorded because the
XPC requirement is prominent in Sparkle's documentation and looks mandatory.

## What this does NOT establish

The probe links and launches a bare executable. It does **not** show that a
signed, notarized `Snitt.app` with an embedded framework passes Gatekeeper, nor
that the framework's own signature survives `make-app.sh`'s `codesign --force`
on the bundle. Framework signing order matters — inner code first, then the
bundle — and that is M5b's first task to verify, not something this spike
settled.
