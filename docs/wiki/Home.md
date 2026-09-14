# Snitt

A native macOS screen recorder for developers, and for the agents working
alongside them. It records, trims and exports without an account, a server, or
a network call.

## Start here

- **[Installing](Installing)** — DMG, Homebrew, or from source
- **[Recording a screen](Recording-a-screen)** — the hotkey, the menu bar, what the picker is for
- **[Editing a recording](Editing-a-recording)** — markers, the transcript, trimming
- **[The .snitt document](The-snitt-document)** — what a recording actually is
- **[Exporting and sharing](Exporting-and-sharing)** — mp4, GIF, destination presets
- **[Privacy and permissions](Privacy-and-permissions)** — what macOS asks for and why
- **[Agents, the CLI and MCP](Agents-the-CLI-and-MCP)** — driving Snitt without a person
- **[Troubleshooting](Troubleshooting)** — the failures that look like bugs and are not

## What makes it different

Most screen recorders are built for an audience. Snitt is built for a **reader**
— the person you send it to, who wants the answer and not a film.

- **The recording is a document, not a file.** A `.snitt` bundle keeps the
  original capture untouched and stores your edits alongside it, so a trim is
  never destructive and can always be undone.
- **It knows what you did, not just what it looked like.** Markers, clicks and
  input timing are captured as data, so the editor can find the dead air and cut
  it, and an agent can read back what happened.
- **Nothing leaves your Mac.** No account, no upload, no telemetry. The only
  network request the app makes is the update check.

## Contributing

Snitt is [MPL-2.0](https://github.com/impressiver/snitt/blob/main/LICENSE) and
takes patches. Start with
[CONTRIBUTING.md](https://github.com/impressiver/snitt/blob/main/CONTRIBUTING.md)
and [docs/DEVELOPING.md](https://github.com/impressiver/snitt/blob/main/docs/DEVELOPING.md).

Design decisions live in a numbered log in
[the spec](https://github.com/impressiver/snitt/blob/main/docs/superpowers/specs/2026-09-02-snitt-design.md).
If something looks missing, it may be there with a reason attached.
