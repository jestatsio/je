---
name: connect
description: Set up or select a personal J&E Studio model connection with the je CLI for Codex, Claude Code, or the native Ollama CLI.
---

Help the user connect an installed client to J&E Studio. Read `je --help` and the relevant subcommand help before choosing commands. Use `je profile list` to find existing model connections. Use `je profile show NAME` to inspect public connection metadata. These commands omit credentials.

For a new connection, obtain the endpoint and permitted model name from the user's operator instructions. Give the user the `je profile add` command to run in their own terminal. Its private prompt accepts the key. Never ask for a key in chat, put one in command arguments, or open a saved profile file.

Run `je doctor --profile NAME` to check a saved connection without inference. Request permission before using `--probe`, which sends model requests. Report the checks that actually ran.

Codex needs a route and reviewed model catalog matching the installed Codex version. Do not invent those values or treat a successful model listing as proof of task quality. Claude Code uses its tested route. The native Ollama CLI uses a separate native profile and credential through `je ollama`.

Explain the appropriate `je connect` or `je ollama` command. Start a new agent or interactive model session only when the user asks. Keep the native client's approval controls and the user's default model settings unchanged.
