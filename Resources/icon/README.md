# The Snitt app icon

The icon is **generated**, not drawn: `Scripts/generate-app-icon.swift` renders
it and `Scripts/make-app-icon.sh` compiles the result into
`Resources/AppIcon.icns`. Both the `.icns` and the 1024pt reference
`Resources/AppIcon.png` are committed, so a build never depends on either
script having been run.

There are deliberately **no `.svg` layer files here.** The generator draws the
icon layer by layer and holds the geometry as named constants, so it already
is the layered source. A parallel set of vectors would be a second source of
truth for the same shapes, and the first thing this rev fixed was a colour
that had drifted between two places claiming to define it.

## Identity

Unchanged since v0.1.0: a window outline on deep ink with a ringed record dot.
Rev 5 (W10) changed the *rendering* — a flat full-bleed square became the
system squircle with layered, glass-lit artwork, which is the macOS 26+
idiom — and did not touch the motif.

## Geometry

Every value is a fraction of the icon's side, and lives in `Geometry` in the
generator. Recorded here so a re-render starts from the numbers rather than
from eyeballing the previous one.

| Constant | Value | What it sets |
|---|---|---|
| `squircleInset` | 0.055 | transparent margin around the tile |
| `cornerRadius` | 0.225 | the system squircle |
| `paneSideMargin` | 0.15 | window pane, left and right |
| `paneTopMargin` | 0.19 | window pane, top and bottom |
| `paneCorner` | 0.045 | the pane's own corner radius |
| `paneStroke` | 0.023 | the pane's outline weight |
| `dotDiameter` | 0.31 | the record dot |
| `ringWidth` | 0.021 | the white ring around it |

## Colour

The dot is `recordRed` — the same components as `SnittPalette.recordRed` and
`RecordingIcon.recordRed`. `AppIconArtworkTests.generatorUsesTheBrandRed`
asserts the generator's constant against the palette's, because they had
silently disagreed: the artwork was drawn in 0.92/0.18/0.22 while both
constants said 0.933/0.267/0.267.

**Colours are constructed in an explicit sRGB space.**
`CGColor(red:green:blue:alpha:)` creates a *generic RGB* colour whose
components shift when drawn into an sRGB context — the same trap
`TimelineView.Palette` documents for `NSColor(white:)`. The generator's
`srgb(...)` helper exists for this and nothing else.

## Sizes

Every rendition is drawn **at its own size** rather than downscaled from one
master. The specular wash, the tile shadow and the dot's sheen are a few
pixels tall at 16pt, and downscaling turns them into grey mush over the only
shape that still has to read; below 64pt they are dropped and the shape
carries it alone. `RecordingIcon` records the same finding for the poster
badge.

## The Icon Composer question, and where it stands

Rev 5 asked whether an Icon Composer `.icon` document could enter this bundle,
which would get the system's own Liquid Glass treatment rather than an
approximation of it.

**Checked, and deferred with a reason.** `Icon Composer.app` ships with the
installed Xcode 26.6 and `actool` is on the path, so the tooling exists. What
does not fit is the build: `Scripts/make-app.sh` assembles the bundle from a
SwiftPM product and copies `AppIcon.icns` in, and compiling a `.icon` means
running `actool` over an asset catalog — which would make a full Xcode install
a requirement of every build, where today only the Swift toolchain is.

That is a real trade and not one to make silently as part of an icon refresh,
so the flat rendition ships. Reopen when there is a reason to depend on Xcode
in `make-app.sh` anyway, or when `.icon` compilation becomes available without
it.
