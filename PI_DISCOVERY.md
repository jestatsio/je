# Pi harness discovery probe

Date: 2026-11-13. Machine: Eric's laptop, macOS 27.2.1 (26B131),
36 GiB physical memory (38,654,705,664 bytes), Node v26.12.1.

Binary under probe: Pi 1.5.2 at `/opt/homebrew/bin/pi`, a symlink to
the global npm install of `@earendil-works/pi-coding-agent` 1.5.2
under `/opt/homebrew/lib/node_modules/`. It was already installed.
No install was run for this probe, into a scratch prefix or
anywhere else. A different install, upgrade, or removal stays
Eric's call.

Question: whether Pi (pi.dev, earendil-works/pi) can serve as je's
open harness behind `je ask`, for someone used to Codex and Claude
Code. Named need under Q13: the `je ask` power requirement. This
document is discovery evidence only. It changes no settled
decision, amends no roadmap text, and qualifies nothing.

Isolation: every check that can write state ran with `HOME` and
`PI_CODING_AGENT_DIR` under `/tmp/pi-trials/`, with `PI_OFFLINE=1`,
in a scratch working directory. Help and version reads came first;
they wrote nothing (real `~/.pi/agent/` file times still predate
this probe; contents were not read). No inference call ran, no
model was downloaded, and no real harness configuration for Pi,
Codex, Claude Code, or Muse was edited. The only key used was a
dummy value in a child environment variable, resolved against an
unreachable loopback address for config checks only. Logs stay
under `/tmp/pi-trials/logs/` on this machine. This document
records exit codes and the decisive output lines only.

Evidence basis, in order: the installed binary's help surfaces,
the documentation and schemas shipped in the 1.5.2 package, and
the bounded no-inference checks P01 to P09 below. Web sources were
not needed and are not cited as evidence.

## Verdict in one paragraph

Pi 1.5.2 clears more of adapter contract v1 at surface level than
any candidate je has probed: a real arbitrary OpenAI-compatible
endpoint contract in both launch families, three distinct headless
surfaces (print, JSON events, long-lived RPC) with documented
framing, first-class session trees with resume, fork, and export,
and the same Agent Skills format je already ships. It also fails
one contract item by design and says so itself: there are no
native per-tool approvals and no sandbox, so that item can only
ever be declared unsupported, with isolation supplied outside Pi.
Everything that needs a model to run (tool-driving quality, task
qualification, cancellation under load, MCP behavior through the
Q16 broker, resume across profiles) stays unproven here by
design. Those are bounded-trial work, on this laptop or the
Studio, only if Eric decides to run them.

## Checks

Scratch checks used an empty agent directory unless stated. Docs
citations name files under the package `docs/` directory.

| ID | Check | Result |
| --- | --- | --- |
| P01 | Presence and version | `pi` on PATH at `/opt/homebrew/bin/pi`. `pi --version` prints `1.5.2`, exit 0. Package `package.json` agrees (1.5.2, MIT, Node >= 22.19.0). |
| P02 | Help surfaces | `pi --help` and `pi <command> --help` for install, remove, update, list, config, auth, mcp all exit 0. Help is complete enough to map the contract below without guessing. Unknown flag exits 1 with `Error: Unknown option`. |
| P03 | Empty-home package and MCP state | `pi list` prints `No packages installed.`, exit 0. `pi mcp list` prints `No MCP servers configured.`, exit 0; `--json` prints empty `servers` and `errors`. Pi created only `auth.json` and `models-store.json` in the scratch agent dir, both mode 0600, plus an empty sessions tree. |
| P04 | Credential readiness, no secrets | `pi auth check --provider openai` prints `not_ready`, exit 1; `--json` adds reason `credentials_not_configured`. Documented exits: 0 ready, 1 not ready, 2 invalid (`docs/cli.md`). |
| P05 | Custom endpoint config, no call | A scratch `models.json` declared provider `studio-gateway` (`baseUrl http://127.0.0.1:9/v1`, `api openai-completions`, `apiKey "$JE_PI_PROBE_KEY"`, one model). Without the env var, `--list-models` reports no models available, exit 0. With a dummy value, it lists `studio-gateway probe-fast` with the declared 32.8K context and 4.1K max output, and `auth check` reports `ready`, exit 0. The endpoint was unreachable and offline mode was on, so listing and readiness are config-only here. |
| P06 | Print mode, no credentials | `pi --print --no-session` exits 1: `No API key found for the selected model.` No session saved. |
| P07 | JSON mode, no credentials | Stdout carries exactly one record, the session header (`type session`, version 3, UUID id, cwd). The same no-key error goes to stderr. Exit 1, matching the rule that an invocation error is nonzero (`docs/cli-integration.md`). |
| P08 | RPC framing, no model | `get_state` returns success with a placeholder `unknown` model, a session UUID, and queue modes. Malformed JSON returns a `parse` failure with no request id. Responses can arrive out of order, so clients correlate by `id`. `new_session` and idle `abort` succeed. Closing stdin exits 0. An empty session left no file on disk. |
| P09 | Export of a missing file | `pi --export` on a nonexistent session file exits 1: `Error: File not found`. Export of real content needs a model run and was not tried. |

No check exercised a model, a tool call, an MCP server, an
extension, or a login flow. Behavior claims below never go past
what P01 to P09, the help text, and the shipped 1.5.2 docs
support.

## Adapter contract claims after this probe

Contract items follow Q13 harness adapter contract version 1.
"Surface proven" means the control exists and behaves as
documented at help, config, or refusal level. It never means a
model ran well. Every claim binds to Pi 1.5.2 only; another
version inherits nothing until policy records it as tested.

| Contract item | Claim now | Evidence |
| --- | --- | --- |
| Discovery and exact version | Surface proven. PATH discovery plus `pi --version` gives an exact `1.5.2` a future `je doctor pi` could gate on. | P01, P02. |
| Profile, endpoint, model, role mapping | Endpoint and model mapping surface proven, including arbitrary OpenAI-compatible endpoints (next section). Role mapping is je-side only: Pi has no fast or strong roles. A role would resolve to one provider and model per session via `--provider`/`--model` (or `provider/id`, optional `:thinking`) or settings `defaultProvider`/`defaultModel`. Thinking level is an effort knob, not a role. In-Pi virtual-model routing exists only as an extension surface; under Q5 it must not become route authority, so an adapter selects physical models itself or treats any router plus version as part of the exact assignment. | Help; `docs/models.md`, `docs/settings.md`, `docs/virtual-models.md`; P05. |
| Interactive launch | Surface proven as a mode (default TUI on a terminal; piped input or output selects print instead). Model execution, tool behavior, and trust-prompt flow with a real model unproven. | Help; `docs/cli-integration.md`, `docs/security.md`. |
| Headless launch: print | Plumbing and refusal proven. Final text on stdout, errors on stderr; a final `error`, `aborted`, or `length` stop gives a nonzero exit (`length` still prints partial text with a warning). Successful model completion unproven. | P06; `docs/cli-integration.md`. |
| Headless launch: JSON events | Framing and refusal proven: session header, then LF-delimited events on stdout only, diagnostics on stderr. Two adapter traps are documented, not discovered the hard way: an in-run failed or aborted response does not by itself make the exit nonzero, so the caller must read events (`agent_settled`, message stop reasons) instead of trusting exit 0; and `message_update` records are deltas, with `message_end` authoritative. Full event sequence under a model unproven. | P07; `docs/json.md`, `docs/cli-integration.md`. |
| Headless launch: RPC | Framing, command correlation, state query, session creation, idle abort, and orderly stdin-EOF shutdown proven with no model configured. A `prompt` success means accepted, not completed; completion is `agent_settled`. Full prompt, steer, tool, and extension-UI flows unproven. RPC is the only Pi surface that fits a supervised `je ask` child with steer and abort; print and JSON are one-shot. | P08; `docs/rpc.md`, `docs/rpc-commands.md`. |
| Native approvals and sandbox | Proven negative. Unsupported, by upstream design. Pi asks for no approval before tool calls and provides no sandbox; tools run with the launching user's rights. Details and partial mitigations below. No adapter may imitate this item. | `docs/security.md`; help (no permission mode exists). |
| Plugin install and trust flow | Surface proven for listing and removal grammar; install itself not run (it writes settings and can fetch code). Packages bundle extensions, skills, prompts, and themes from npm, git, or local paths, recorded in settings, removable with `pi remove`. Project resources load only after project trust; trust is a config-loading gate, not a tool boundary (below). Runtime behavior of any package unproven. | P03; help; `docs/packages.md`, `docs/security.md`. |
| Guidance-only je plugin | Plausible, low risk. je's existing bundle is skills-only (connect, memory, status), and Pi implements the same Agent Skills `SKILL.md` format, including `~/.agents/skills/` and `.agents/skills/` discovery. A skills-and-templates Pi package with no extension code fits je's current guidance shape. Whether a local model follows that guidance well is a task-quality question, unproven. | `plugins/je` in this repo; `docs/skills.md`, `docs/prompt-templates.md`. |
| MCP and memory attachment | Attachment surface proven; broker fit unproven. Built-in MCP reads user `mcp.json` plus trusted-project `.pi/mcp.json`, over stdio or streamable HTTP (no legacy SSE), tools named `mcp__<server>__<tool>`, exposure modes `codemode` (default), `deferred`, `direct`, `hidden`. `pi mcp list` connects and exits 1 on invalid or unconnected servers (empty state proven, P03). Pi connects directly from its own process. Meeting Q16 means pointing Pi at the je broker as its only server endpoint and keeping direct servers out of its config; Pi itself enforces no broker, revocation, or per-person scoping, and extensions can register session servers outside the file. Memory would attach as an explicit MCP server entry like any other; nothing attaches it by default. | P03; help; `docs/mcp.md`. |
| Session identity, resume, branching, export | Identity surface proven: UUID session ids in the JSON header and RPC state, JSONL tree files under the agent dir grouped by working directory, `--continue`/`--resume`/`--session`/`--fork`/`--session-id`/`--no-session` controls, in-session `/tree`, `/fork`, `/clone`, and HTML or JSONL export paths. An empty RPC session persisted no file (P08), so on-disk persistence of real content, resume fidelity, branching, and export of content all stay unproven until a model run exists to resume. Resume across je profiles is separately unproven and riskier: a session restores its recorded model selection, which an adapter must reconcile with the route je displays. | P07, P08, P09; `docs/sessions.md`, `docs/session-format.md`. |
| Exit and event behavior | Proven at refusal and framing level, per mode above: help and version 0; unknown flag, missing export file, and no-credential print/JSON 1; `auth check` 0/1/2 by readiness (0 and 1 observed); `mcp list` 0 empty, documented 1 on failure; RPC reports per-command success in-band and exits 0 on orderly EOF. Exit codes for completed, failed-mid-run, and truncated model runs are documented for print, but only the refusal end was observed. | P02 to P09; `docs/cli-integration.md`, `docs/cli.md`. |
| Cancellation | Idle RPC `abort` proven as a no-op success (P08). Documented surfaces: RPC `abort`, `abort_retry`, `abort_bash`; interactive Escape (`app.interrupt`); RPC shutdown on stdin EOF, SIGTERM, or SIGHUP with a second signal forcing exit. Whether abort stops provider streaming, a running bash tool, and downstream inference promptly under load is unproven and stated nowhere as supported. Print and JSON have no in-band cancel; only signals to the child, also unproven. | P08; `docs/rpc.md`, `docs/rpc-commands.md`, `docs/keybindings.md`. |
| Setup preview and removal | Partial. Pi-side surfaces exist (`pi config` TUI, `pi list`, `pi remove`, settings files je could preview as diffs), but there is no Pi dry-run verb, and je-side Pi setup does not exist. Any `je setup` preview for Pi would be je-authored around settings, `models.json`, and `mcp.json` writes, then qualified like other harnesses. No install or removal was run in this probe. | Help; P03. |
| Task qualification | None. No Pi cell exists in the support matrix, and this probe adds none. The bounded trial below is the only path from discovery to selectable. | Q13; hard limits of this probe. |

Mode note for a future adapter: interactive, print, JSON, and RPC
share one agent, session, and tool core, but Q13 still qualifies
launch modes separately. Shared internals are a reason to expect
similar behavior, never evidence that one mode's result transfers
to another.

## Local-endpoint contract

This is the strongest part of the fit, and the part a future
adapter would write most directly. Sources: `docs/models.md`,
`docs/models-configuration.md`, `docs/configuration.md`, the
shipped `schemas/models.schema.json`, and P05.

A custom endpoint lives in `<agent-dir>/models.json` (agent dir
defaults to `~/.pi/agent`, moved by `PI_CODING_AGENT_DIR`). Each
key under `providers` is a provider id. A new provider needs a
`baseUrl` and an `api` (`openai-completions` for Ollama, LM
Studio, vLLM, SGLang, and the Studio gateway shape;
`openai-responses`, `anthropic-messages`, and
`google-generative-ai` also exist). Each entry under `models`
needs an `id`, the exact string sent to the API. The documented
Ollama shape sets `baseUrl` to `http://localhost:11434/v1` with a
dummy `apiKey` of `ollama`, which Ollama ignores but Pi requires
before the model counts as available. A Studio gateway entry is
the same shape with the gateway base URL, a real key source
(below), and explicit limits. Setting only `baseUrl` on a
built-in provider id instead repoints that provider's catalog
models through a proxy; that is a different assignment and must
not be conflated with a custom local provider. Under Q14, any
gateway component that transforms message, tool, streaming,
error, or cancellation semantics joins the assignment identity
with its exact version and configuration. Compatibility overrides
(`compat`) describe verified endpoint differences only; Pi's docs
warn against enabling them from advertised compatibility alone,
which matches je's native-route rule.

Credentials resolve in this order: runtime `--api-key`, then
`auth.json`, then `models.json` `apiKey`, then provider
environment variables or ambient cloud credentials. In
`models.json`, an `apiKey` or header value is a literal, a
`$NAME` or `${NAME}` environment interpolation, or a
`!command` whose output is used; commands run at request time
and are not cached. `auth.json` holds `/login` and `pi auth
login` material. Pi created `auth.json` and `models-store.json`
mode 0600 in the scratch home (P03), which matches owner-only
handling, but 0600 is not Q20 platform-native storage and must
not be presented as equivalent.

je's rule is that a key never appears as a command argument and
is never printed. Pi can meet it, but only by avoiding two of its
own conveniences. `--api-key` puts the key in argv and
`pi auth print-api-key` / `print-bearer-token` write resolved
secrets to stdout by design; an adapter must use neither on any
path je logs, traces, or displays. Compliant routes exist:
child-only environment plus `$NAME` interpolation (proven in
P05), a `!command` that fetches from Keychain at request time
(so the file holds no secret), or a secret stored by an explicit
login step in `auth.json`. Which of these a je profile should
use, and how rotation and removal work, is Q20 design work this
probe does not settle. One caution from the upstream security
doc: after project trust, project extensions execute inside the
Pi process, so credential files and credential commands must be
treated as reachable by trusted-project code, not as sealed from
it.

Context declaration is the easy place to get a local route
quietly wrong. `contextWindow` defaults to 128,000 and
`maxTokens` to 16,384 when omitted. Pi acts on the declared
window for context accounting and compaction, so an omitted
value is a false claim about most local models, not a safe
default. Every local model entry must declare its true
`contextWindow` (and `maxTokens`, `input`, and `reasoning`
where they differ), with zero costs for local models so usage
accounting stays honest. P05 confirmed the declared values are
what `--list-models` surfaces. The llama.cpp router is a
separate first-class local route (`docs/llama-cpp.md`, `/llama`
and `/model`); it discovers and loads GGUF models itself and
would be a distinct engine surface under Q9, not a variant of
the `models.json` contract above. It was not exercised.

## The approvals gap, in plain terms

Pi has no built-in permission system and no sandbox. When the
model calls `bash`, `edit`, or `write`, the call runs at once
with everything the person who started Pi can do: every file
they can read or change, every credential their shell can reach,
every network service open to them. Nothing asks first. Upstream
says this plainly (`docs/security.md`: Pi "does not ask for
approval before every tool call," and the working folder "does
not prevent commands from accessing other paths available to the
Pi process") and treats the lack of a sandbox as expected
local-agent behavior, outside its security boundary. Q13
requires preservation of native approvals. Here there is nothing
native to preserve, so the only honest adapter declaration is
unsupported. A Pi route behind `je ask` would therefore need its
safety from outside Pi: a container, micro-VM, dedicated user,
or hosted workspace boundary that je can name in the route
display, exactly as upstream recommends in
`docs/containerization.md`. Without that outer boundary, `je ask`
through Pi is a one-command path from a prompt to unsupervised
shell access, including for prompt-injected repository content.
That may still be a trade Eric chooses for an open harness on his
own machine. It cannot be described as approval parity with
Codex or Claude Code, and the pre-run display would have to say
so.

Three partial mitigations exist. None is an equivalent, and the
claims table does not count them as one.

- Tool allowlists. `--tools`, `--exclude-tools`, `--no-tools`,
  and settings `defaultTools` select which tools exist for a run.
  The shipped read-only recipe is `--tools read,grep,find,ls`
  (the last three are read-only and off by default; defaults are
  `read`, `bash`, `edit`, `write`). An allowlist removes whole
  tools; it does not approve individual calls, constrain paths,
  or hold once `bash` itself is allowed. MCP tools need explicit
  `mcp__` patterns or `--exclude-tools` to remove.
- Permission-gate extensions. Extensions run in-process and can
  block tool calls through the `tool_call` event. The shipped
  `permission-gate.ts` example prompts only for three bash
  regexes (`rm -rf`, `sudo`, `chmod`/`chown 777`) and blocks by
  default with no UI; `protected-paths.ts` blocks writes under
  three substrings. These prove the hook exists, not that it is
  complete: coverage is whatever patterns someone writes, shell
  spelling bypasses regexes, the gate runs with the same rights
  it polices, and it disappears if the extension is disabled,
  not installed, or bypassed with `--no-extensions`. A je-managed
  gate could still be useful defense in depth inside an outer
  boundary. It is not a native approval system and must never be
  labeled one.
- Project trust. `--approve`/`--no-approve`, saved decisions in
  `trust.json`, and `defaultProjectTrust` decide whether
  project-local settings, extensions, skills, and MCP servers
  load. Despite the flag name, this is not tool approval: the
  security doc states trust "does not limit what tool calls can
  access or affect," context files load regardless, and the
  project `sessionDir` is read before trust resolves. In print,
  JSON, and RPC modes there is no trust prompt; `ask` and `never`
  skip protected resources unless an override, extension, or
  saved decision applies. An adapter must pin this explicitly per
  run (`--approve` or `--no-approve`) rather than inherit a saved
  decision silently.

## SDK question, at surface level

Three embeddable layers ship at the same 1.5.2 version. The
coding-agent package itself embeds in a Node.js or Bun process
and exposes direct TypeScript control of sessions, models,
tools, resources, events, steering, and abort, including
in-memory session and settings managers for hosts that own
state. Below it, the agent-core package offers a general agent
loop with transport abstraction and state management, and the ai
package offers a unified provider and model layer (catalogs,
credentials, streaming, provider APIs), with a separate MCP
client package beside them. SDK sessions load no built-in MCP,
codemode, or tool-search extensions unless the host adds them,
so an SDK host owns more of the assembly than the CLI does.
Under Q13 this is not another launch mode of a harness adapter.
An adapter drives an external harness process and preserves
whatever native behavior that process has; an SDK integration
makes je (or a je helper process) the host of the agent loop,
with its own tool assembly, session ownership, update cadence
tied to npm dependencies, and approval vacuum inherited
unchanged. That is a different integration class, closer to
Q15's built-in-path question than to adding a fourth harness,
and it would need its own settled decision before any design
work. It buys finer control than RPC. It does not buy
approvals, sandboxing, or qualification transfer from CLI-mode
evidence. No SDK call was run for this probe.

## What stays unproven

- Local-model tool-driving quality: whether any local model
  je can plausibly qualify drives Pi's four default tools,
  streaming, and compaction well enough for real coding work.
  Help output proves control surfaces, not competence; je's
  earlier small-model trials are the cautionary precedent.
- Task qualification for every exact assignment a Pi route
  would claim (harness version, launch mode, protocol
  implementation, engine and version, model artifact, execution
  place), including whether Ollama, LM Studio, vLLM, SGLang, or
  the Studio gateway each satisfy Pi's expected wire behavior
  natively under Q14.
- Session persistence with real content: resume, fork, tree
  branching, compaction, and export fidelity, plus resume across
  je profiles and models without silently restoring a stale
  route.
- Cancellation under load in every mode: provider stream,
  running bash tool, queued steering, retries, and whether
  downstream inference actually stops.
- MCP through the Q16 broker: broker-as-only-endpoint
  enforcement, per-person scoping, revocation mid-session,
  codemode and deferred exposure behavior under brokered calls,
  and extension-registered servers that bypass file config.
- Extension and package runtime behavior, including a
  guidance-only je package, any permission-gate extension, and
  codemode's script execution surface, which widens what a model
  can reach beyond declared tools.
- Interactive trust prompts, login flows, catalog refresh
  (`pi update --models`), telemetry and offline behavior beyond
  the flags observed, and any behavior that only appears with a
  terminal attached.
- Performance, memory, and stability of long RPC sessions, and
  version churn: 1.5.2 already postdates the roughly 1.4.0
  baseline this probe was scoped against, so discovery will
  need refreshing per exact version.

## Bounded trial that would qualify Pi, if Eric asks for it

Nothing below ran. It is recorded so a later decision has a
bounded shape to approve or decline. The natural workload is the
tabulate baseline from handoff 002, run unchanged so results
compare against existing harness evidence instead of inventing a
Pi-only bar.

Prerequisites before any model runs: name the exact assignment
(Pi 1.5.2 or a re-probed successor, one launch mode, one engine
and version, one model artifact, one execution place); declare
native approvals unsupported in the trial record; and choose the
outer boundary the run lives in (container, micro-VM, dedicated
user, or hosted workspace), with a scratch repository, pinned
`--no-approve` or `--approve`, an explicit `--tools` set, and an
isolated `PI_CODING_AGENT_DIR`. A trial on Eric's real home
directory with default tools would measure luck, not fitness.

Then, per launch mode claimed (interactive and headless
separately; print, JSON, and RPC separately within headless):
run the tabulate baseline to its existing pass criteria; record
tool-call correctness, exit or settled state, and full event
logs; abort once mid-run and once during a long bash call and
record what actually stops; resume the session, fork it, and
export it; and repeat one run with MCP reachable only through a
test broker endpoint, including a mid-session revocation. A pass
qualifies only that exact assignment and mode. It would not
qualify other models, engines, modes, Pi versions, or any
approval claim, and it would not by itself add Pi to the launch
set; that remains a roadmap decision for Eric, informed by this
evidence and any trial record that follows.

Feasibility on this laptop: yes for the trial as bounded above,
with two limits. The machine already has Pi 1.5.2 and can run
small local models, but 36 GiB and laptop-class engines only
qualify laptop assignments; the fast and strong Studio
assignments still need Studio hardware. And the laptop trial is
only meaningful inside the chosen outer boundary; setting that
boundary up is part of the trial cost, not an optional extra.

