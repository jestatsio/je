# Muse contract trials

Date: 2026-11-09. Machine: Eric's laptop, macOS 27.2.1 (26B131),
36 GiB physical memory (38,654,705,664 bytes).

Binary under trial: Muse Code 1.4.14 (1.4.14-R7309.1) at
`~/.local/bin/muse`. Local Ollama 0.40.16 was already serving on
127.0.0.1:11434. No cloud account or key was used. One dummy key was
sent to the local Ollama address only.

Isolation: every trial ran with `HOME`, `XDG_CONFIG_HOME`, and
`XDG_DATA_HOME` under `/tmp/muse-trials/`, in a scratch git workspace.
No real Muse configuration, session, or plugin state was touched.
Each trial had a hard timeout. Logs stay under `/tmp/muse-trials/logs/`
on this machine. This document records exit codes and the decisive
output lines only.

## Verdict in one paragraph

Muse 1.4.14 has no arbitrary local endpoint contract in either launch
mode. The only local route is the gated built-in Glimmer experiment.
It needs `MUSE_EXPERIMENTAL_LOCAL_MODELS` and at least 64 GiB of
physical memory. This laptop has 36 GiB, so Glimmer execution, tool
behavior, and task quality stay unproven here by design. They are
Studio work. Everything around that route (parsing, gates, events,
export, plugins) is now proven at the level stated below.

## Trials

| ID | Trial | Result |
| --- | --- | --- |
| T01 | `je doctor muse --json` (help surfaces) | Interactive lists local. Headless lists echo and meta only. Auth accepts meta only. Status `builtin_glimmer_unavailable_memory`. Evidence `evidence:muse-contract:6adca317…df1be`. |
| T02 | Headless echo, `--json` | Exit 0. JSONL session events stream. Terminal text `echo: Reply with exactly: trial-ok`. Usage event reports 1 call. |
| T03 | Headless `--provider local`, no experiment | Exit 1. Parser accepts `local` (help omits it). Runtime refuses: `Local models are disabled. Enable the local_models experiment and restart TBH.` |
| T04 | Headless local with experiment | Exit 1. `Local models require at least 64 GiB of physical memory.` |
| T05 | Headless meta with `--base-url http://127.0.0.1:11434` | Exit 1. `failed to fetch model catalog: API error 404: 404 page not found`. The override speaks the Meta catalog protocol. An Ollama root is not an accepted arbitrary endpoint. |
| T06 | Interactive non-TTY, trusted for the run | Echo reaches the TUI and exits 0 on stdin EOF. Local with experiment hits the same 64 GiB refusal, exit 1. Without trust, both stop at the workspace trust prompt. |
| T07 | `plugins validate` on `plugins/je` | `valid: true`, compatibility `full`, skills connect, memory, status supported. Exit 0. |
| T08 | MSP schema export | Exit 0. Schema keys cover methods, notifications, requests, errors, capabilities. No `chat/completions` and no `/v1/models`. It is a session wire schema, not a model endpoint contract. Fingerprint `sha256:c94c3d1f…049c6`. |
| T09 | Session export of T02 | `muse export --last --out` writes one JSON document offline. Top-level keys include `events`, `sessions`, `export_schema_version`. Default export is raw. Use `--redacted` before sharing. |
| T11 | `model-profile` surface | Resolves catalog model ids per knob and effort tier. Catalog means the Meta catalog. No local artifact resolution was found. |
| T12 | Plugin lifecycle, isolated home | Install, list, inspect, and remove of `plugins/je` all succeed. Trust records as `user-local`. Manifest `sha256:74e4769a…ec1c`, package `sha256:4252c343…fac`. Removal empties the list. Capability approve was not exercised. |

T10 (cancellation) has no trial. Echo and both refusals finish at
once, so there was nothing honest to cancel. Cancellation stays
unproven and unstated, per Q13.

## Adapter contract claims after these trials

Contract items follow Q13 harness adapter contract version 1.

| Item | Claim now |
| --- | --- |
| Discovery and exact version | Proven. `muse --version` and PATH discovery, exact `1.4.14` gating in `je doctor muse`. |
| Profile, endpoint, model mapping | Proven negative for arbitrary endpoints (T05). Proven shape for Glimmer only: `--provider local`, experiment env, model `local` or `glimmer` per saved assignment. No per-endpoint profile mapping exists to qualify. |
| Interactive launch | Launch and gates proven (T06). Model execution unproven below 64 GiB. |
| Headless launch | Plumbing proven on echo (T02). Local parser acceptance proven (T03). Local execution unproven below 64 GiB (T04). |
| Native approvals and sandbox | Flags and trust gate observed (help, T06). Approval behavior under a real local model is unproven. No claim beyond preservation by construction: je passes no approval-widening flags. |
| Plugin install and trust flow | Validate, install, list, inspect, remove proven (T07, T12). Capability approve and runtime skill behavior unproven. `je setup` still does not manage Muse. |
| MCP and memory attachment | Surface only. MCP servers live under `mcpServers` in settings with OAuth login. No attach trial ran, because no local model session can start on this machine. Unproven. |
| Session identity and resume | Session UUIDs in every event (T02). Offline export proven (T09). Resume opens a picker or a named session (help). Resume across profiles unproven. |
| Exit and event behavior | Headless JSONL events and exit codes proven on echo and on both refusals (0 on completion, 1 on refusal). |
| Cancellation | Unproven. Stated nowhere as supported. |
| Setup preview and removal | Plugin removal proven (T12). je-side Muse setup does not exist yet and stays gated on this contract. |
| Task qualification | Harness exists in je with fake-runner tests. No real Muse cell has passed. A pass needs a 64 GiB+ machine. |

## Gate A D5 declaration

Gate A D5 set 2026-12-05 as the deadline to declare a Muse mode
unsupported if bounded trials prove no native route. These trials are
that proof for non-MLX engines, ahead of any Studio qualification:

- No native route exists for Muse with Ollama, LM Studio, or
  llama.cpp in 1.4.14, in either launch mode (T01, T03, T05, T08).
  Those 24 cells move to `unsupported` in
  [`SupportMatrix`](Sources/JECore/SupportMatrix.swift).
- Muse with MLX native (the Glimmer route, protocol
  `muse-local-glimmer`) keeps 8 cells. Headless was
  `blocked_on_contract_discovery`. The contract is now discovered
  (T03, T04), so those 4 cells move to `planned`, matching
  interactive. None is qualified. Qualification needs the Studio.

Matrix after this change: 112 cells. 1 qualified, 87 planned,
24 unsupported, 0 blocked. Unsupported here follows the settled rule:
declared ahead of qualification, with this trial record as the
contract reason. If a future Muse version ships a real arbitrary
local endpoint contract, those cells return only through new
discovery, a new exact assignment identity, and a recorded pass.

## What the Studio must still prove

- One Glimmer run per mode on 64 GiB+: model load, one tool call,
  approval prompt behavior, and clean exit.
- The bounded four-task qualification suite per exact assignment
  claimed selectable, interactive and headless separately.
- MCP attachment and session resume under the qualifying assignment.
- Cancellation, only at the level a bounded trial proves.
