# Editing a recording

The editor opens when a recording stops, and reopens any `.snitt` bundle you
double-click.

## The panel

A side panel on the right holds two indexes of the same recording, and both can
be open at once because they are read together: a marker says **where**
something happened, the transcript says **what was said** there.

**Markers.** Every marker you dropped while recording, with its timestamp.
Click a row to go there. Double-click to rename. Right-click for Edit Details,
which lets you fix the time as well as the name — a marker landed a second late
is easier to correct by typing than by dragging.

Press **+** to add a marker at the playhead, which is how you mark something you
only realised was important afterwards.

**Transcript.** On-device transcription of the microphone track, broken into
phrases at the speaker's own pauses, each with its timestamp.

Reading it is the interface. Click a word to jump the preview there; select a
phrase and delete it to cut those seconds out of the recording. That is a much
faster way to remove a stumble than finding it on the timeline by dragging.

Transcription reads the **microphone track only**. A screen recording of a video
call, where every voice arrived as system audio, transcribes to nothing —
correctly, and it looks broken. The pane says so when it happens.

## The timeline

Below the preview: the filmstrip, the audio tracks, markers, and a transcript
lane showing phrase chips where the talking is.

- **Drag** to select a range. **Delete** cuts it.
- **Click a phrase chip** to select that whole utterance, then Delete to cut it.
  The highlight shows exactly what would go.
- **A cut becomes a fold**, a marker on the timeline rather than a hole.
  Double-click one to expand it and see what is inside, select it and press
  Delete to put the footage back.
- **Gain and mute** per audio track, from the controls on the left.

## Auto-trim

**Auto-Trim** in the toolbar finds the dead air and cuts it, using the input
timing captured while you recorded. Silence where nothing was happening goes;
silence where you were clicking or typing stays, because that is someone working
rather than nothing happening.

It needs **Capture events** to have been on during the recording. Without that
log there is nothing to tell thinking apart from an empty room.

Every cut it makes is an ordinary fold, so you can inspect and undo any of them
individually.

## Crop

**Crop** in the toolbar draws a box on the preview. It is stored in `edit.json`
like every other edit and applied at export, so it is reversible and costs
nothing until you export.

## Overlays

**Playback ▸ Show** toggles click rings, subtitles and marker banners in the
preview. Whatever you turn on there is what the export sheet offers by default,
so what you set up while watching is what you get when you export.
