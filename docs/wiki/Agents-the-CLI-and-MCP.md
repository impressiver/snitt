# Agents, the CLI and MCP

Snitt has three front ends over one core: the app, a command-line tool, and an
MCP server. They drive the same recorder and edit the same documents, so
anything one can do the others can too.

**All of it is off until you enable it** in **Settings ▸ Agent ▸ Allow
recording**. See [Privacy and permissions](Privacy-and-permissions) for the
rules that apply once you do.

## MCP

Register the server once:

```bash
snitt setup --apply
```

An agent can then call:

| | |
|---|---|
| `snitt_list_targets` | What can be recorded |
| `snitt_start_recording` / `snitt_stop_recording` | Start and stop |
| `snitt_pause_recording` / `snitt_resume_recording` | Pause without splitting the document |
| `snitt_mark` | Drop a labelled marker (was `snitt_add_marker`, still accepted) |
| `snitt_screenshot` | A still, without recording |
| `snitt_status` | Whether anything is recording |
| `snitt_inspect` | Read a bundle: markers, transcript, duration |
| `snitt_trim` / `snitt_auto_deep_trim` / `snitt_crop` | Edit |
| `snitt_estimate` / `snitt_export` | Size first, then render (`snitt_estimate_export` still accepted) |
| `snitt_report_input` | Report input timing from the agent's own session |
| `snitt_diagnostics_export` | Write a support bundle |

Markers an agent drops as it works become chapters in the exported video, which
is the point: the recording arrives already indexed by what the agent was doing.

## CLI

```bash
snitt targets list                                  # what can be recorded
snitt record start --app com.google.Chrome          # prints a session id
snitt record mark <session> --label "the bug"
snitt record stop <session>                         # prints the bundle path

snitt auto-deep-trim recording.snitt                # cut the dead air
snitt export recording.snitt --format mp4 --out demo.mp4 \
      --resolution 1080p --chapters
```

`snitt --help` lists every verb.

**JSON on stdout, human text on stderr.** A script parses one while a person
reads the other, and neither has to be turned off for the other to work.

## How a request is authorised

The CLI and MCP server reach the app over a local socket. The app reads the
caller's process id, executable path and **code signature** from the kernel
rather than trusting anything the caller says about itself, and every
agent-initiated session is disclosed in the UI and written to an audit log you
can read with `snitt diagnostics export`.

An agent that asks for something the opt-in does not permit gets a specific
refusal naming what a person would have to change, rather than a silent failure.
