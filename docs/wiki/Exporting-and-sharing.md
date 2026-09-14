# Exporting and sharing

## Export

**File ▸ Export…** (⌘E), or the toolbar button.

| | |
|---|---|
| **Format** | mp4 or GIF |
| **Resolution** | source, or a smaller rung with its estimated size |
| **Overlays** | click rings, subtitles, marker banners, burned in |
| **Chapters** | markers written as real chapter markers in the mp4 |

Exports land beside the recording they came from, named after it.

**Overlays are burned in, not a sidecar track.** Slack and Discord render
neither a `.vtt` file nor a soft subtitle track, and a GIF cannot carry either.
A caption nobody sees is not a caption.

## Export for…

**File ▸ Export for ▸** produces a file a specific place will actually accept,
and copies it to the clipboard. The size ceilings and dimensions are each
destination's real published limits, so you find out before uploading rather
than after.

No dialog: the settings are already decided by where it is going.

A recording longer than a destination allows is exported anyway and reported,
rather than silently trimmed. Destroying content to satisfy someone else's
limit is not a decision an export should make on your behalf.

## Share

**File ▸ Share ▸** lists the destinations your Mac has — AirDrop, Mail,
Messages, Notes, and any share extension you have installed. The menu opens
immediately; the recording is exported once you pick a destination.

## GIF

GIF has no size estimate, and the reason is worth knowing: a GIF's size tracks
how much the **picture moves**, not how long it runs. A ten-second recording of
a mostly static screen can be smaller than a three-second one of a scrolling
page, so an estimate based on duration would be confidently wrong.

GIF exports are capped at 1280px wide. Above that, the encoder has to hold every
frame in memory at once to build a single colour palette, and a Retina-resolution
recording will exhaust it.
