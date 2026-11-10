<p align="center">
  <img src="docs/assets/favicon.svg" alt="je" width="72" height="72">
</p>

<h1 align="center">je</h1>

<p align="center"><strong>Your tools. Your context. Your Studio.</strong></p>

<p align="center">
  The local-first command line for your AI work.<br>
  Keep the harnesses you know. Bring your own models and memory.
</p>

<p align="center">
  <a href="https://jestatsio.github.io/je/">Documentation</a> ·
  <a href="https://github.com/jestatsio/je/releases">Releases</a> ·
  <a href="ROADMAP.md">Roadmap and open decisions</a> ·
  <a href="https://github.com/jestatsio/je/issues">Issues</a>
</p>

---

`je` connects the AI tools already on your machine to models you choose. It saves each connection as a named profile, checks it without spending inference, and opens your harness with that connection for one session. Codex, Claude Code, and the native Ollama CLI work today. Your files, instructions, and approval settings stay exactly where they were.

The direction from here is local-first. A capable machine on your desk should carry most of the daily work, with cloud models one explicit choice away and never a silent fallback. The [roadmap](ROADMAP.md) records what is settled, what is still open, and the order we plan to build it.

## Install

You need an Apple silicon Mac with Homebrew. je ships as a signed and notarized native binary. You do not need Python or a source checkout.

```sh
brew install jestatsio/tap/je
je --version
je setup
```

Setup finds your installed Codex and Claude Code CLIs and asks before adding the native je plugin to each one. Install those clients separately. Setup changes no model settings and attaches no memory.

If 0.2.0 is already installed, run `brew upgrade jestatsio/tap/je` instead. Your saved profiles still load, and new profile writes store keys in macOS Keychain.

## Quickstart

Ask your Studio operator for an endpoint, a permitted model name, and a personal key. Then save the connection once and reuse it by name.

```sh
# Save a connection. The key prompt stays private in your terminal.
je profile add studio \
  --endpoint https://models.example.test \
  --model YOUR_MODEL_NAME

# Check it. This verifies access without generating a response.
je doctor --profile studio

# Work. Run this inside the project you want the harness to see.
je connect claude --profile studio
```

Codex uses the same shape with its own tested route and reviewed model catalog. The [documentation](https://jestatsio.github.io/je/) walks through both, plus native Ollama and optional shared memory.

## What je does today

| Command | What it does |
| --- | --- |
| `je setup` | Detects installed clients and offers the native je plugin for each. |
| `je profile` | Saves and inspects named model connections, and migrates embedded keys to native secret storage. Keys never print. |
| `je doctor` | Checks authentication and model availability, with an opt-in live probe. |
| `je connect` | Opens Codex or Claude Code on a saved connection for one session. |
| `je ask` | Routes one prompt to a qualified assignment and shows the route first. |
| `je why` | Explains the selected qualified route without running anything. |
| `je assignments` | Authors personal-machine assignments and records qualification evidence. |
| `je models` | Inspects engines, published artifacts, assignments, storage, and qualification. Read-only. |
| `je memory` | Manages a separate personal memory connection, attached only on request. |
| `je ollama` | Runs the native Ollama CLI through its own connection and a temporary local relay. |
| `je run` | Hands a saved connection to any other OpenAI-compatible client. |
| `je export` | Writes desktop and editor setup files for review, without applying them. |
| `je workspace` (Studio host installation only) | Operates host-owned Coder and Lima workspaces. It is not part of the standalone user build above. |

Run `je --help`, or add `--help` to any command, for the options in your build. The roadmap settles this split for the next stage. Trusted users install only the user `je`. The operator host build stays on the Studio.

## How a session flows

```text
you ── je connect claude --profile studio ──▶ Claude Code
                                               your files · your approvals
                                                      │ model calls
                                                      ▼
                                          your model service
                                          local today · cloud by choice

shared memory attaches only when you add --memory-profile
```

je checks the connection first, then hands the harness temporary session settings. Your saved defaults stay untouched. If an existing sign-in conflicts with the route, the launch stops and says why instead of guessing.

## Design principles

- **Explicit connections.** You choose the profile for every connected session. Through `je ask`, layered policy resolves the route instead, and je shows the person and profile, the chosen harness, model, and route, any attached memory, and where the work will run before anything starts. Only qualified assignments launch. Explicit flags can override a soft preference, never a hard permission or privacy constraint. Installing je switches nothing on its own.
- **Local first, cloud by choice.** A local route never falls back to a cloud model silently. People can configure their own cloud profiles, defaults, and escalation targets ahead of time, so a wanted cloud run or an approved escalation stays one explicit step.
- **Credentials stay out of view.** Keys are prompted privately, stored in macOS Keychain through the bundled secret helper, and never printed or passed as command arguments.
- **The harness stays in charge.** Native instructions, tools, history, and approval settings keep working as they did before je arrived.
- **Check before inference.** The default checks prove access and model availability without generating anything. A listed model still has to earn its place through real task trials.

## Where je is going

The front door for local AI work shipped in 0.3.0, built for the small trusted Studio group from day one. You run `je ask "..."`, layered policy resolves the initial route, je shows that route and why, and a qualified local model does the work on your own machine or in your Studio workspace. One matrix cell is qualified today. The matrix grows one recorded qualification at a time, and the explicit launcher above still covers every other route. Cloud models stay available through each person's configured profiles and defaults for the jobs that need them. One codebase ships that user front door separately from the operator host build on the Studio.

The direction was decided one question at a time. [ROADMAP.md](ROADMAP.md) holds the Final settled calls and a provisional build order for the Mac Studio arriving in December 2026. It covers routing, model roles and inference engines, qualification, background jobs, shared memory and its bounded offline cache, Keychain storage, and publishing the user core source.

## This repository

| Path | What it holds |
| --- | --- |
| [docs/](docs/) | The documentation site published at jestatsio.github.io/je. |
| [plugins/je/](plugins/je/) | The shared connection, status, and memory skills for Codex and Claude Code. |
| [Sources/](Sources/) | The Swift user core and command line. |
| [IMPLEMENTATION.md](IMPLEMENTATION.md) | The native core implementation record and its limits. |
| [SUPPORT_MATRIX.md](SUPPORT_MATRIX.md) | The launch qualification matrix and its rules. |
| [COMPLETENESS_CHECKLIST.md](COMPLETENESS_CHECKLIST.md) | The December launch completeness audit, gaps, and critical path. |
| [GATE_A_DECISIONS.md](GATE_A_DECISIONS.md) | Settled measurement rules for December qualification. |
| [ROADMAP.md](ROADMAP.md) | The Final product direction and settled decisions. |
| [Releases](https://github.com/jestatsio/je/releases) | Downloadable user client builds with SHA-256 checksums and build manifests. |

The native user core develops here under Apache-2.0. As of 0.3.0 it is the released user client, replacing the Python 0.2.0 build in the Homebrew tap. Saved profiles and state files remain compatible. Host and service operations stay private.

## Service access

Installing je grants no access to a model or memory service. Your Studio operator provides the endpoint, the permitted model names, and your personal keys. The hosted Studio service is a private pilot for a small trusted group.

The plugins carry guidance only. They hold no credentials, switch no models, attach no memory, and install no hooks.

## Update and removal

```sh
brew update
brew upgrade jestatsio/tap/je
```

Those commands update the user client. Update the agent plugins through each client and its native plugin manager. The operator host installation on the Studio updates separately through its host install path, so a user upgrade never changes Studio services or workspace controls. To leave cleanly, run `je setup --remove` with confirmation, then `brew uninstall je`. Saved profiles remain on disk, and removing a local profile or the user client never revokes the server credential behind it.

---

<p align="center">Built by <a href="https://jestats.io">J&amp;E Stats</a> · Your tools. Your context. Your Studio.</p>
