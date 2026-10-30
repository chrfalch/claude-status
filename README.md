## What it does

ClaudeStatus is a macOS menu bar app that checks `claude agents --json` every five seconds. Open its menu to see each agent and refresh the list. It has no Dock icon.

Dead sessions are hidden: interactive agents by pid check, background agents by `~/.claude/daemon/roster.json`.
Each agent shows a short summary of its latest message, generated locally when Apple Intelligence is available.

## Colors

- Blue: waiting for you.
- Green: working, including unknown states.
- Gray: all idle.
- Orange: error. The menu shows the error text.

## Build

Run `scripts/build-app.sh`. This builds and ad hoc signs `build/ClaudeStatus.app`. Requires the Swift toolchain and macOS 14 or later.

## Run

Run `open build/ClaudeStatus.app`.

## Start at login

Drag the app to Login Items in System Settings.

## CLAUDE_BIN override

Set the `CLAUDE_BIN` environment variable to an executable Claude binary path in the app's launch environment. Otherwise the app checks common install paths, then your login shell. Successful lookups are cached until the app restarts. Failed lookups retry on the next poll.
