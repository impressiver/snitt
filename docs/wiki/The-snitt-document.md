# The .snitt document

A recording is a **bundle**, not a file. It looks like a single document in the
Finder and is a directory underneath.

Inside:

| | |
|---|---|
| `capture.mov` | The original recording, untouched, forever |
| `edit.json` | Your edits: trims, crop, overlay toggles |
| `events.json` | Markers, clicks, and input timing |
| `transcript.json` | The on-device transcript, if you ran one |
| `metadata.json` | When it was recorded, and whether a person or an agent started it |

## Edits never touch the capture

Trimming does not delete video. It appends a range to `edit.json`, and the
editor and the exporter both read that list to decide what to show. The original
is always there, which means:

- Every edit is reversible, including after closing and reopening the document
- A trim that cut too much is one undo away, not a re-record
- Exporting the same document twice with different edits costs nothing but time

## It is plain JSON, on purpose

`edit.json` and `events.json` are readable and writable by anything. A script can
add a marker, apply a trim, or read back what happened in a recording without
going near the GUI, and the editor will show the result the next time it opens
the document.

That is the same interface the [CLI and the MCP server](Agents-the-CLI-and-MCP)
use. There is no private path: the GUI, the CLI and an agent all edit the same
document the same way.

## Sharing a bundle

A `.snitt` bundle is a directory, so it does not attach to a message the way a
file does. Zip it, or better, [export](Exporting-and-sharing) an mp4 or GIF,
which is what anyone else actually wants.

Keep the bundle. The export is a rendering of it, and the bundle is the thing
you can still edit in a month.
