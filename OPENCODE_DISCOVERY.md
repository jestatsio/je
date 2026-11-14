# OpenCode discovery probe

Date: 2026-11-13. Machine: Eric's laptop, macOS 27.2.1 (26B131),
36 GiB physical memory (38,654,705,664 bytes). Prompted by handoff
003: `je ask` must be powerful enough for someone used to Codex and
Claude Code, so can je use an open harness? This document records
discovery evidence only. It amends no settled roadmap decision. The
launch harness set stays Codex, Claude Code, and Muse under Q13
until Eric decides otherwise with this evidence in hand.

Binaries under probe: two installs. `opencode` on PATH resolves to
`~/.opencode/bin/opencode`, which reports `opencode v2.1.4`. A
Homebrew install at `/opt/homebrew/bin/opencode` reports `1.19.5`
and is shadowed by the first. Handoff 003 states Realm's rv pins
1.19.4; that pin was not re-verified in the local realm-swe checkout
during this probe. Neither installed build is 1.19.4. Per Q13, a
harness version does not inherit qualification from another version,
so 2.1.4, 1.19.5, and the pinned 1.19.4 are three separate
qualification subjects. Local Ollama 0.40.16 was already serving on
127.0.0.1:11434. No cloud account or real key was used. Probes that
needed a key value used one dummy value in an environment variable,
pointed only at a closed local port. No inference call ran.

Isolation: probes ran with `HOME`, `XDG_CONFIG_HOME`, and
`XDG_DATA_HOME` under `/tmp/opencode-discovery/`, in scratch git
workspaces, each command under a hard timeout with stdin closed.
Eric's real OpenCode configuration was read for file names only and
never opened. One exception, corrected at once: a single
`mcp add` probe ran with the je repo as its working directory and
created `./opencode.json` there. The file was removed immediately
and the tree re-verified clean with `git status`. No real
configuration, session, or credential was touched. Logs stay under
`/tmp/opencode-discovery/logs/` on this machine. This document
records exit codes and the decisive output lines only.

## Verdict in one paragraph

OpenCode has the arbitrary local endpoint contract Muse lacks. Both
installed builds accept a per-run custom OpenAI-compatible provider
with the key supplied by environment reference, never as a command
argument, without touching saved defaults. Headless JSON events,
session identity, export, MCP add and list, and je's own skills all
work at discovery level. The costs are version discipline and
service discipline: the two builds differ in config schema, error
shape, MCP shape, and provider discovery, and 2.1.4 defaults to a
shared background service that breaks isolated runs unless
`--standalone` is passed. Whether a local model drives its tools
well stays unproven here by design. That is qualification-trial
work, and it is feasible on this laptop.

## Probes

| ID | Probe | Result |
| --- | --- | --- |
| P01 | Binary discovery and versions | PATH resolves to 2.1.4 at `~/.opencode/bin/opencode` (`opencode v2.1.4`, exit 0). Homebrew 1.19.5 at `/opt/homebrew/bin/opencode` (`1.19.5`, exit 0) is shadowed. Version output formats differ. A 1.19.5 session and the 2.1.4 background service were already running; neither was touched. |
| P02 | Help surfaces, both builds | Both declare TUI (default command), `mini`, `run`, `serve`, `models`, `mcp`, `session`, `plugin`, auth, and debug surfaces. CLI frameworks differ: 1.19.5 uses `providers` (alias `auth`), top-level `export`/`import`, and `agent`; 2.1.4 uses `auth`, `session export`/`import`, and `debug agents`. Both `run` helps offer `--model provider/model`, `--format default\|json`, `--session`, `--continue`, `--fork`, and `--auto`. |
| P03 | `debug paths`, isolated home | Both builds report data, config, cache, state, log, and database paths under the scratch `HOME`/`XDG` roots, exit 0. The temporary directory stays in the system temp root in both builds. State is relocatable by environment. |
| P04 | Model listing, isolated home, no config | 1.19.5 lists only `opencode/*` catalog models; `models ollama` exits 1, `Provider not found: ollama`. 2.1.4 with `--standalone` also lists four `ollama/*` models matching the running Ollama catalog exactly, minus the embedding-only model. Per official docs, 2.1.4 probes 127.0.0.1:11434 and adds completion-capable models. The listing read the local catalog (`/api/tags` class); no generation ran and no key was sent. Identical across two runs. |
| P05 | Custom provider, project config | A scratch `opencode.json` defining provider `jeprobe` at `http://127.0.0.1:9/v1` with key `{env:JEPROBE_KEY}` makes `jeprobe/probe-model` listable in 1.19.5 (`provider` + `npm: @ai-sdk/openai-compatible` + `options`), exit 0. The v2 shape (`providers` + `package: @opencode/ai/providers/openai-compatible` + `settings` + `env` list) lists in 2.1.4, exit 0. 2.1.4 also reads the 1.x shape. 1.19.5 ignores the v2 shape: `Provider not found: jeprobe`, exit 1. Listing made no call to the closed port. With a project config present, the 2.1.4 list dropped the `ollama/*` entries (13 lines vs 16); whether explicit config suppresses local discovery stays unproven. |
| P06 | Run-scoped config by environment | 1.19.5 honors `OPENCODE_CONFIG_CONTENT` as a final inline merge: a provider defined only in that variable lists its model, exit 0, with no file written to user configuration. The built-in config skill also documents `OPENCODE_CONFIG` (extra config file) and `OPENCODE_DISABLE_PROJECT_CONFIG`. `debug config` in 1.19.5 prints the resolved config with `apiKey` redacted as `***`. |
| P07 | Config validation (1.19.5) | Malformed JSON exits 1 with a parse error. A wrong-typed known field (`"model": 42`) exits 1: `Configuration is invalid ... Expected string \| undefined, got 42 model`. An unknown top-level key exits 0 and is silently dropped from the resolved config. A misspelled key name therefore fails silently; verification must read resolved state, not trust exit 0. |
| P08 | Headless refusal, `--format json` | `run` against undefined provider `jeunknown` cannot infer; it refuses before any endpoint exists. 1.19.5: exit 1, one stdout JSON event, type `error`, name `UnknownError`, message `Unexpected server error. Check server logs for details.`, with a minted `sessionID`. 2.1.4 standalone: exit 1, type `error`, `provider.no-route`, message `Model unavailable: jeunknown/probe-model`, with `sessionID`. Error shapes differ by version; event parsers are per-version. |
| P09 | Session list, export, resume | Each refusal left a session record. `session list --format json` returns id, title (1.19.5 only), timestamps, `projectId`, and `directory`; empty-state output differs (1.19.5 prints nothing, 2.1.4 prints `[]`). Export works offline in both, exit 0, one JSON document with top-level `info` and `messages`; `info` key sets differ (1.19.5 carries `agent`, `permission`, `version`; 2.1.4 carries `location`, `outcome`). Re-running 1.19.5 with `--session <id>` reuses the exact session id and refuses again, exit 1. Both builds opened the same scratch `opencode.db`, yet each lists only its own session: a shared data directory silently partitions sessions by build. Binary, version, and data directory must be pinned together. |
| P10 | MCP add and list, isolated | 1.19.5 `mcp add` writes the global config by default (`mcp.<name>` with `type: local\|remote`); 2.1.4 writes the project config by default (`mcp.servers.<name>`), with `--global` to override. Both add local (`-- <command>`) and remote (`--url`) servers, exit 0. 1.19.5 `mcp list` is a live probe: it spawned the local stub and dialed the closed port, reported both `failed` with reasons, and still exited 0. Exit 0 from `mcp list` does not mean servers are healthy. `--header` and `--env` take literal `KEY=VALUE` arguments, so je must write MCP config directly with `{env:VAR}` references instead of passing secret values to `mcp add`. |
| P11 | je skills and plugin surface (1.19.5) | The three skill folders from `plugins/je/skills/` copied verbatim into scratch `.opencode/skills/` are discovered by `debug skill` (names `connect`, `memory`, `status` with file locations), exit 0. A one-line no-op TypeScript plugin in `.opencode/plugin/` auto-loads and appears in `debug info`, exit 0. Installed-plugin management is npm-spec based (`plugin add <package>` in both helps). Nothing was installed into real configuration. |
| P12 | Permission defaults (1.19.5) | `agent list` resolves seven agents. The `build` agent carries 18 rules: default `*` allows, with `ask` on `doom_loop`, `external_directory`, and `*.env` reads, and `deny` on `question` and plan transitions. Project edits and shell commands therefore run without a prompt by default. Both builds offer `--auto` (auto-approve what is not explicitly denied); 1.19.5 help labels it dangerous. Run-scoped `permission` config can narrow these defaults; that narrowing was not exercised under a model. |
| P13 | Background service behavior (2.1.4) | 2.1.4 defaults to a managed service on fixed port 49374, already held by Eric's real service. In the scratch home, commands without `--standalone` that need the server fail, exit 1: `Managed service port 49374 on 127.0.0.1 is already in use by another process.` Observed for `debug config`, `debug agents`, `plugin list`, and `mcp list`, whose helps offer no `--standalone`. Commands with `--standalone` (`models`, `run`, `session`, `auth list`) run privately and succeed. Pure config writes (`mcp add`) need no server. |
| P14 | Error exits | Unknown flag exits 1 in both builds. Unknown provider in `models` exits 1 (1.19.5). Export of a missing session exits 1 in both (`Session not found: ...`). `auth list --format json` in the isolated home returns `[]`, exit 0 (2.1.4 standalone); 1.19.5 reports `0 credentials` with the scratch `auth.json` path. Credential stores respect isolation. |
| P15 | Credential-printing surfaces (help only) | 2.1.4 `auth export` help states: `print stored credentials, including secrets, as JSON`. It was not executed. A je adapter must never invoke it. `auth import`/`export` also mean stored credentials are portable files under the data directory; setup preview must treat that directory as secret-bearing. |

Interactive launch has no probe. Help declares the TUI (default
command, optional project path) and `mini` in both builds, with
`--session`, `--continue`, and `--prompt`. No TUI was started:
this probe is discovery only, and a non-TTY TUI run would prove
little beyond waiting for input. Cancellation likewise has no
probe. Refusals and listings finish at once, so there was nothing
honest to cancel. Cancellation stays unproven and unstated, per
Q13, exactly as in the Muse trials.

## Adapter contract claims after this probe

Contract items follow Q13 harness adapter contract version 1.
Claims name the exact build where the builds differ. "Discovery
level" means help surfaces plus isolated non-inference probes; no
model executed work in any probe.

| Item | Claim now |
| --- | --- |
| Discovery and exact version | Proven, with a trap. PATH discovery finds 2.1.4, not the Homebrew 1.19.5 it shadows, and version output formats differ (`opencode v2.1.4` vs `1.19.5`). An adapter must resolve and record the absolute binary path and gate on one exact version string. Neither build inherits qualification from the other, and neither matches the 1.19.4 pin stated in handoff 003. |
| Profile, endpoint, model mapping | Proven shape in both builds (P04–P06). Models are `provider/model` strings; per-model config lives under the provider's `models` map; roles map to agents (`build`, `plan`, subagents) selectable with `--agent` and configurable per agent, including per-agent model and permission. Endpoint and key can be supplied per run by project config or `OPENCODE_CONFIG_CONTENT` (1.19.5 probed) with `{env:VAR}` key references, leaving saved defaults untouched. Config schemas differ (`provider` vs `providers`); 2.1.4 reads both, 1.19.5 only its own. Wire protocols: official docs select the runtime per provider, including OpenAI-compatible chat and Responses packages and an Anthropic-compatible package, so a local OpenAI-compatible gateway (Studio gateway, Ollama `/v1`) is addressable in either style. Which protocol bytes a given package sends is unproven without a call. 2.1.4 also auto-discovers local Ollama, LM Studio, and vLLM catalogs; 1.19.5 does not surface `ollama` until configured. |
| Interactive launch | Surface only. TUI and `mini` declared in help for both builds, with session continue and prompt flags. Not exercised. |
| Headless launch | Plumbing proven at refusal level in both builds (P08): `opencode run --format json` emits JSON events on stdout and exits 1 with a session id when no route exists. Successful generation, tool calls, and streaming event sequences are unproven; no inference ran by design. |
| Native approvals and sandbox | Defaults observed (P12). The `build` agent allows project edits and shell by default, asking only on loop, external-directory, and `.env` boundaries. Preservation claim is by construction only: je passes no approval-widening flags, and must never pass `--auto`. Approval behavior under a real local model is unproven. Native defaults must be stated plainly to users, since "approval preserved" here means most writes run unprompted unless je narrows `permission` per run. OpenCode has no separate sandbox claim in help; none is made. |
| Plugin install and trust flow | Surface plus scratch load proof (P11). je's skills carry over verbatim; a guidance-only plugin shim loads. The agent-plugins.org `plugin.json` is not an OpenCode artifact: a je bundle for OpenCode needs repackaging as skills plus an optional local plugin file or npm package, with no credentials and no model-switching hooks (the hook surface can mutate config and chat parameters, so the no-switch rule is bundle discipline, not host enforcement). Install, list, and remove commands exist in help; no install into real configuration was attempted, and trust behavior is unproven. |
| MCP and memory attachment | Attachment shape proven in scratch (P10): local and remote servers, per-server environment and headers, OAuth login surfaces in help. Defaults and config shapes differ by build. `mcp list` actively probes servers yet exits 0 on failure, so je must parse status, not exit codes. MCP configuration is file-scoped (global or project), not session-scoped; je's explicit per-session memory attachment would need run-scoped config injection, which P06 shows is available. Brokered calls under Q16 and memory read/write scopes are unproven. |
| Session identity and resume | Identity proven: session ids appear in headless events, listings, and exports (P09). Resume by `--session` reuses the exact id at refusal level (1.19.5). Offline export proven in both builds; exported key sets differ by version, and default export is unredacted transcript data (use `--sanitize` before sharing). Resume across profiles, models, or builds is unproven; a shared data directory partitions sessions by build. |
| Exit and event behavior | Proven at discovery level (P08, P14): 0 on success, 1 on usage, config, provider, session, and refusal errors, with JSON error events in headless mode. Event error shapes differ by version (`UnknownError` with an opaque reference in 1.19.5; typed `provider.no-route` in 2.1.4), so adapters parse per exact version. Full success-event vocabulary (tool, text, usage events) is unproven without a model run. |
| Cancellation | Unproven. Stated nowhere as supported. No timeout flag appears in `run` help; a trial must establish signal behavior mid-generation before any claim. |
| Setup preview and removal | Feasible shape, unbuilt. State relocates cleanly under `HOME`/`XDG` (P03), config is plain JSON(C) files je can preview and diff, and `debug config` (1.19.5) shows resolved state with keys redacted. Two hazards for preview: unknown config keys drop silently (P07), so preview must verify resolved state; and 2.1.4's shared background service means "installed" state includes a service port and running process, not just files (P13). No je-side OpenCode setup or removal exists yet. |
| Task qualification | No OpenCode cell has passed anything. The support matrix is unchanged by this probe and gains no OpenCode harness: Q13 closed the launch set, and this document records evidence for Eric's later decision, not a set change. |

## What remains unproven

- A local model actually driving tools: file reads, edits, shell,
  and multi-step completion under either build.
- Task quality on any baseline, in either launch mode.
- Interactive TUI behavior, including approval prompts as a user
  sees them.
- Session resume across profiles or models, and any cross-build
  session use.
- Cancellation: signal handling, partial-output events, and exit
  behavior mid-generation.
- MCP tool execution, including je-brokered servers under Q16 and
  explicit memory attachment with read/write scope behavior.
- Whether explicit project config suppresses 2.1.4 local endpoint
  auto-discovery (P05 observed the correlation once).
- 2.1.4 `debug config`, `debug agents`, `plugin list`, and
  `mcp list` behavior in isolation; each currently requires the
  shared service or fails against it (P13).
- Version drift control: both builds self-upgrade (`upgrade`
  command; `autoupdate` config in 1.x). A qualified exact version
  can move unless je re-checks `--version` at launch and refuses
  drift, as it already does for Codex catalog bindings.

## Bounded trial that would qualify OpenCode

Feasible on this laptop, if Eric decides to run it. Local Ollama
models are already installed, so no downloads are needed, and
36 GiB is not a barrier for the small local models present. The
natural task baseline is the tabulate task from handoff 002, run
per exact assignment, interactive and headless separately, in the
style of the Muse trials:

1. Pin one binary by absolute path and exact version first
   (2.1.4 as PATH resolves it, or 1.19.5 as the rv-adjacent
   lineage; Eric's choice). Record `debug paths` and the resolved
   config under an isolated home for every cell. For 2.1.4, run
   every cell with `--standalone`.
2. Supply the endpoint per run only: project config or
   `OPENCODE_CONFIG_CONTENT` naming the local Ollama `/v1`
   endpoint first, then the Studio gateway profile, with keys by
   `{env:VAR}` reference. Verify `models` lists the assignment
   before any task runs.
3. Run the tabulate baseline headless with `--format json`, then
   interactively. A pass needs correct task output, at least one
   observed tool call, approval posture recorded against the
   agent's resolved permission rules, clean exit, and a session
   export whose model and token fields match the assignment.
4. Resume the passing session by id under the same profile and
   confirm continuity; then attempt resume under a different
   profile and record the outcome plainly.
5. Start one slow generation and cancel it mid-run; record
   signals, events, and exit code at the level actually observed.

Each passing combination qualifies only its own exact assignment:
binary path and version, launch mode, model artifact, engine and
protocol, and execution place. Nothing in this probe pre-qualifies
any cell, and joining the launch set remains Eric's Q13 decision
after this evidence, not a consequence of it.
