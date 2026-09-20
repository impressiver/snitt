# Demo assets

`agent-drives-the-editor.gif` is the README's hero. Every frame of it was
produced by an agent through `snitt` alone — no pointer, no keystrokes into
Snitt, no hand editing.

## How it was made, so it can be made again

Two takes.

**The inner take** is `demo-overview-source.html`, a page that types itself:
an overview of Snitt and what it does, written out character by character with
a blinking cursor. It is served locally and opened in a Chrome **app-mode**
window (`--app=`, its own `--user-data-dir`), which matters for two reasons —
no tab strip, so no other tab's title is in frame, and a throwaway profile, so
no history or session is either. The page sizes its own window with
`resizeTo`, because Chrome ignores `--window-size` when an instance is already
running and an Apple Event needs a permission an agent cannot grant itself.

That take is recorded, then narrated with `snitt narrate` — including one
deliberately fluffed line, which is what the demo goes on to remove.

**The outer take** opens the inner one in Snitt's editor at a size chosen for
filming:

```sh
snitt editor open <inner>.snitt --width 1000 --height 660
```

Sizing is the whole reason the GIF is legible. The editor opens at 75% of the
screen by default, and scaled down to README width its transcript pane and
timeline labels cannot be read.

Then, while recording Snitt's own editor window:

```sh
snitt editor seek   <inner>.snitt --to 24
snitt editor select <inner>.snitt --from 24 --to 26.5
snitt editor cut    <inner>.snitt
```

Each lands in the window on screen, as one undo entry, with the **"Agent
editing"** badge beside the filename — which is visible in the GIF, and is the
editor telling a person what is happening to their document.

Finally `snitt trim`, `snitt narrate` for the captions, and:

```sh
snitt export <outer>.snitt --format gif --out docs/assets/agent-drives-the-editor.gif \
  --captions --max-size 3500000
```

## What is deliberately not committed

The `.snitt` bundles. Footage is cheap to recreate and expensive to store; the
timing, the geometry and the words are what were hard, and those are here — in
this file and in the page beside it.
