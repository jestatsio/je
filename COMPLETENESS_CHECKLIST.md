# December launch completeness checklist

Snapshot date: 2026-11-09.

Status owner: Eric Hare.

Decision under audit: Q26 in [ROADMAP.md](ROADMAP.md).

Shipped user client: `je` 0.3.1.

## Verdict

**Q26 status: not met today, and at risk for 2026-12-31.**

Eric reconfirmed full platform completeness on 2026-11-09. The scope does
not shrink to fit current evidence. December 31 remains the judgment date.
An incomplete required system or matrix cell on that date means Q26 is not
met under its own terms.

Version 0.3.0 is a complete native replacement for the Python 0.2.0 user
client. It is not yet the complete December launch platform settled in
Q1 through Q25.

The strongest completed work is the public native user core. It covers
profiles, Keychain-backed profile writes, connection checks, harness
launch, the deterministic routing core, assignment authoring, bounded
qualification, the narrow built-in path, content-free usage traces, and a
signed and notarized Homebrew release.

The December risk comes from breadth and evidence rather than the basic
launch plumbing. The launch matrix has 1 qualified cell, 87 planned cells,
and 24 cells declared unsupported on Muse trial evidence. Several settled platform
systems have no implementation in this public tree. Other required systems
belong to a private host build or private Studio services, and this audit
cannot verify their state from this repository.

This checklist does not lower a safety gate to make December look closer.
An unavailable capability stays unavailable in this document until code and
recorded qualification evidence support a different status.

## How this audit was made

The audit compares the settled answers in [ROADMAP.md](ROADMAP.md) with
[IMPLEMENTATION.md](IMPLEMENTATION.md), [SUPPORT_MATRIX.md](SUPPORT_MATRIX.md),
the Swift sources under [Sources/](Sources/), the tests under
[Tests/](Tests/), the public release state, and the installed 0.3.1 client.

Public-tree evidence can prove the user artifact. It cannot prove the
private operator host build, hosted memory or history services, Google and
network onboarding, workspace operations, or service-side enforcement.
Items in those areas name the evidence still needed instead of guessing.

### Status meanings

| Status | Meaning |
| --- | --- |
| Done | The December requirement is implemented in the audited scope and has shipped or test evidence. |
| Partial | A real foundation or slice exists, but the settled requirement is still incomplete. |
| Missing | No implementation was found in the audited scope. |
| Private or unverified | The settled owner sits outside this repository and this audit has no direct evidence. |
| Blocked | A contract, hardware, service, or qualification gate prevents completion today. |

Status measures the full settled requirement. A strong shipped slice can
still be Partial when other people, places, modes, or qualification cells
remain outside its evidence.

## Scoreboard at 2026-11-09

| Measure | Current state |
| --- | --- |
| Q1 through Q25 | 1 Done, 18 Partial, 5 Missing, 1 Private or unverified |
| Launch matrix | 1 qualified, 87 planned, 24 unsupported, 112 total |
| Qualified roles | `fast` only |
| Qualified engines | Ollama only |
| Qualified harnesses or paths | Built-in only |
| Qualified launch modes | Single-step only |
| Qualified execution places | Personal machine only |
| Named December workflows | W1 to W6 adopted in Gate A. Fixtures and W3/W4 participants still open |
| Two-person workflow evidence | None recorded in this repository |
| Studio hardware | Due 2026-12-10 to 2026-12-17 under the roadmap |
| December judgment date | 2026-12-31 |

The Q count is a management summary, not a percentage of remaining effort.
Several Partial items contain most of the hard local plumbing. Several
Missing items are whole systems.

## Launch support matrix audit

The published matrix in [`SupportMatrix`](Sources/JECore/SupportMatrix.swift)
has two roles, four engine families, four harness or built-in paths, and
two execution places. Coding harnesses use interactive and headless modes.
The built-in path uses single-step mode.

| Slice | Cells | Qualified |
| --- | ---: | ---: |
| Fast role | 56 | 1 |
| Strong role | 56 | 0 |
| Ollama | 28 | 1 |
| MLX native | 28 | 0 |
| LM Studio | 28 | 0 |
| llama.cpp | 28 | 0 |
| Codex | 32 | 0 |
| Claude Code | 32 | 0 |
| Muse | 32 | 0 |
| Built-in | 16 | 1 |
| Personal machine | 56 | 1 |
| Studio workspace | 56 | 0 |

The one qualified cell is
`fast/ollama/built_in/single_step/personal_machine`. Its recorded evidence
is `evidence:qualification:c7f949ad37209589a3fa353f88c8a026810281cb4a0abcc8fecdf6e69fb0156e`
for `studio-harness-qwen35:4b` on Ollama 0.40.15. The bounded built-in suite
passed its three exact-answer tasks on 2026-11-09.

Matrix semantics were settled in [GATE_A_DECISIONS.md](GATE_A_DECISIONS.md)
on 2026-11-09. D1: one current exact pass completes a broad cell. D2:
protocol stays in exact assignment evidence. D3: a private committed
copy is the December evidence record. The export step that fills that
record is still to build. Local laptop state alone still does not
count as retained evidence.

Bounded Muse trials on 2026-11-09 proved no arbitrary local endpoint
contract in 1.4.14. The only local route is the gated Glimmer
experiment. Under Gate A D5, the 24 Muse cells on non-MLX engines are
now declared `unsupported` ahead of qualification, and the 4 MLX
headless cells moved from blocked to `planned` because their contract
is discovered. No Muse cell is qualified. See
[MUSE_CONTRACT_TRIALS.md](MUSE_CONTRACT_TRIALS.md).

## Checklist by platform area

### Native artifacts, packaging, and public source

Status: **Partial**.

- [x] Publish the native user core under Apache-2.0 in a public tree.
- [x] Build the user artifact without host workspace, network, or
  service-control modules. [`ArtifactBoundary`](Sources/JECore/ArtifactBoundary.swift)
  names the boundary and tests reject host-only modules in the user set.
- [x] Ship `je` as a signed and notarized native standalone through the
  Homebrew tap. [`release-macos.sh`](scripts/release-macos.sh) records the
  signed build path.
- [x] Keep the Python 0.2.0 client available as the prior release and
  parity oracle for completed port slices.
- [x] Publish user documentation, plugins, skills, security reporting,
  and contribution guidance.
- [ ] Prove the private operator host build consumes only pinned public
  interfaces. That build is outside this repository.
- [ ] Publish or privately record versioned compatibility evidence across
  the user client, hosted services, saved profiles, and catalogs as one
  release set. The public tree has profile schemas and catalog checks, but
  no cross-artifact compatibility record.
- [ ] Decide whether a Linux user release belongs to the December bar.
  Swift tests run on Ubuntu in CI. The shipped release and Keychain helper
  path are macOS arm64 today.

### Front door and deterministic routing

Status: **Partial**.

- [x] Make `je ask` the explicit front-door verb and retain `je why` for
  route explanation without execution.
- [x] Implement deterministic hard filters for person, role, qualification,
  availability, execution place, never-cloud state, and cloud authorization
  in [`RoutingPolicy`](Sources/JECore/RoutingPolicy.swift).
- [x] Show the selected route before launch and fail closed when no
  qualified route survives.
- [x] Keep advisory scores inert in the starter policy. The policy records
  supplied scores with `advisoryApplied` set to false.
- [x] Compute a prompt-size bucket without storing prompt text in the
  usage trace.
- [ ] Load trusted project policy for route roles and preferences. The
  policy type accepts project values, but [`AskWhy`](Sources/JECore/AskWhy.swift)
  does not load them from a project source.
- [ ] Load personal defaults for roles, preferences, cloud intent, and
  built-in eligibility. The command line currently supplies explicit values
  and otherwise requires a role.
- [ ] Load operator defaults through a versioned and inspectable config
  surface. The policy type accepts operator values, but no operator config
  loader ships in the user core.
- [ ] Record live candidate availability from engine or service health.
  Routing currently consumes assignment availability as saved metadata.
- [ ] Give profile ownership a stronger operator and person model than a
  local state directory plus assignment `allowedPersonIDs`. Hosted and
  multi-person enforcement needs service evidence.
- [ ] Implement post-launch cloud escalation. Current support covers an
  explicit initial cloud authorization reference and explicit gateway use
  through the older profile commands. It has no failure trigger, cost and
  budget display, context-boundary display, one-step approval, or approved
  escalation launch.
- [ ] Make configured cloud targets inspectable, revisable, and removable
  as policy objects rather than only as assignment metadata.

### Roles, engines, models, and lifecycle

Status: **Partial** for roles and Ollama. **Missing** for the settled
lifecycle surface.

- [x] Limit general ask roles to `fast` and `strong`, with embeddings and
  triage modeled as internal roles.
- [x] Refuse an unfilled role instead of silently substituting another
  capability.
- [x] Carry all four settled engine families in assignment identity and in
  the launch matrix.
- [x] Implement the Ollama native profile, connection check, loopback relay,
  and built-in native chat route.
- [ ] Qualify at least one `strong` assignment. No strong cell is qualified.
- [ ] Record the current internal embeddings assignment and its evidence,
  or qualify its replacement. Advisory triage stays with Q11 and gains no
  routing authority from an embeddings result.
- [ ] Implement engine discovery and health checks for MLX native,
  LM Studio, and llama.cpp as distinct protocol and lifecycle surfaces.
  The MLX name appears today in matrix identity and in the gated Muse
  built-in Glimmer checks, not in a general MLX serving adapter.
- [x] Add user-facing `je models` inspection for engines, artifacts,
  assignments, storage use, and qualification status. Implemented
  read-only on `main` in
  [`ModelsInspection.swift`](Sources/JECore/ModelsInspection.swift) with
  tests. A release carrying it is still pending.
- [ ] Add explicit personal-machine lifecycle actions with previews for
  source, version, digest when available, format, size, destination,
  remaining space, and affected assignments.
- [ ] Prove the private host lifecycle for Studio installs, model pulls,
  pins, publication, withdrawal, storage reclamation, and qualification.
  This audit cannot inspect that private build.
- [ ] Record measured resident size and cold-load time for lifecycle and
  warm-set decisions.

### Harnesses, protocol routes, and qualification

Status: **Partial**.

- [x] Launch Codex and Claude Code through saved profiles with native
  temporary settings and fail-closed checks.
- [x] Align `je ask` harness launch with the tested `je connect` launch
  configuration.
- [x] Enforce Codex catalog version, content, digest, model, context, and
  private snapshot checks on catalog-bound routes.
- [x] Probe gateway Responses and Messages protocol surfaces only under an
  explicit doctor probe.
- [x] Store content-addressed qualification evidence with exact candidate
  identity, task results, exit codes, durations, and output digests.
- [x] Ship a bounded four-task file suite for harness candidates and a
  bounded three-task exact-answer suite for built-in candidates.
- [ ] Pass a recorded qualification for any Codex cell.
- [ ] Pass a recorded qualification for any Claude Code cell.
- [ ] Complete Muse adapter contract version 1 as an explicit reviewed
  contract. Laptop trials on 2026-11-09 proved discovery, headless
  events, both local gates, plugin lifecycle, and offline export, and
  disproved arbitrary local endpoints. Glimmer execution, plugin
  capability approval, MCP attachment, resume, and cancellation stay
  unproven until Studio trials. See
  [MUSE_CONTRACT_TRIALS.md](MUSE_CONTRACT_TRIALS.md).
- [ ] Add Muse to `je setup` only after its plugin and trust flow is
  proven. Setup currently manages Codex and Claude Code.
- [ ] Qualify interactive and headless modes separately for each harness,
  engine, role, and place cell claimed complete.
- [ ] Automate reviewed Codex catalog candidate production while keeping
  digest verification and fail-closed behavior. The shipped path consumes
  an operator-supplied reviewed catalog.
- [ ] State cancellation and session resume behavior only where bounded
  trials prove it for the exact harness and launch mode.

### Narrow built-in path

Status: **Partial**, with the launch slice itself in good shape.

- [x] Require explicit `--single-step` selection for built-in execution.
- [x] Make one bounded model request with no shell, edits, tools offered
  to the model, memory saves, external writes, or session state.
- [x] Support bounded file list, explicit file reads, and literal search
  under an explicit context root.
- [x] Support explicit read-only memory search with a credential that
  advertises no write tools and with schema and size checks.
- [x] Reject traversal, symlinks, binary context, oversized context, and
  profile secrets in assembled context.
- [x] Record a passing built-in qualification for one exact Ollama
  assignment on a personal machine.
- [ ] Qualify built-in routes beyond the Ollama native chat protocol. The
  other 15 built-in cells remain planned.
- [ ] Decide how route, profile, model, and qualification inspection from
  the settled read-only surface should appear. The shipped path assembles
  context before one request and does not offer model-called inspection
  tools.
- [ ] Repeat adversarial filesystem qualification whenever the context
  loader, protocol route, model, engine version, or tool surface changes.

### Apple Foundation Models and advisory triage

Status: **Partial**. Evaluation-only helper and titling evaluation
exist. Advisory routing scores and memory proposals do not.

- [x] Build the small signed native helper for Apple Foundation Models on
  the macOS side of a personal machine and the Studio. The
  `je-foundation-helper` target is built on `main` and joins the signed
  release set in [`release-macos.sh`](scripts/release-macos.sh). A
  release carrying it is still pending. Studio proof follows the laptop.
- [x] Qualify titling as its own task with provider, helper version,
  operating system build, and availability recorded. The predeclared
  three-case synthetic set in
  [`Triage.swift`](Sources/JECore/Triage.swift) passed 3/3 live on
  2026-11-09 (macOS 27.2.1, build 26B131) via
  `je triage evaluate-titling`. An OS update invalidates it until rerun.
- [ ] Evaluate advisory routing scores without granting routing authority.
  Routing suggestions stay inert until a task-specific evaluation passes
  and Eric makes an explicit policy change.
- [ ] Evaluate memory extraction proposals as a separate task. No proposal
  may save memory by itself.
- [ ] Prove clean fallback when the system model is unavailable. Template
  titling fallback is implemented and tested. The full claim also needs
  deterministic-routing and absent-proposal evidence in a wired surface,
  which does not exist yet because triage is evaluation-only.

### MCP, skills, and the live broker

Status: **Missing** for the broker. **Partial** for direct plugin and MCP
attachment.

- [x] Install the static Studio plugin skills through Codex and Claude
  Code native plugin managers.
- [x] Check a memory MCP connection inside bounded request, page, tool,
  and byte limits without calling a memory tool.
- [x] Attach a saved memory MCP connection explicitly on supported
  `je connect` sessions.
- [ ] Publish one reviewed registry for MCP servers and skill sources with
  versions, digests or fingerprints, capabilities, scopes, supported
  harnesses, execution places, and trust state.
- [ ] Run a live broker that verifies person, enabled server and tool,
  version or fingerprint, scopes, execution place, and revocation state at
  session start and on each brokered call.
- [ ] Configure supported harnesses to reach je-managed MCP servers through
  the broker rather than directly.
- [ ] Fail broker-managed tools closed when the broker is unavailable or
  revokes access. A direct fallback does not satisfy Q16.
- [ ] Record broker audit metadata without tool arguments, result content,
  credentials, prompt text, or memory text.
- [ ] Keep per-person tool credentials separate and revocable.
- [ ] Prove that broker denial never replaces native harness approval and
  never adds a second interactive approval layer.

### Memory service, cache, saving, and sync

Status: **Partial** for connection and read-only search. **Missing** for
cache, outbox, proposals, and sync in the public user core.

- [x] Save separate memory profiles and inspect them without printing a
  token.
- [x] Initialize the saved MCP service and page its tool list under strict
  bounds in `je memory check`.
- [x] Report read and write tool availability without calling a memory
  tool during the check.
- [x] Use read-only memory search as explicit built-in context under
  bounded query, result, and total-size rules.
- [ ] Prove the private Studio memory service is the one system of record
  with per-person authorization, revision checks, idempotent operations,
  trash, purge, and receipt behavior. That service is outside this audit.
- [ ] Add the bounded per-person local cache with revision, provenance,
  sync, stale, and purge state.
- [ ] Add the pending-operation outbox for offline saves, edits, undos,
  deletes, and restores. Pending work must never look authoritative.
- [ ] Define and implement the versioned service sync contract needed for
  efficient incremental reconciliation and completeness-checked purge
  propagation.
- [ ] Label service and cache results with source and stale state in every
  route that can use attached memory.
- [ ] Enforce proposals-only memory saving in the service or broker. A
  model instruction does not count as enforcement.
- [ ] Add one-key proposal acceptance with the same operation identity and
  provenance from proposal to service receipt.
- [ ] Keep automatic saving off until a predeclared evaluation passes and
  the person opts in. No evaluation harness or opt-in state exists in the
  user core today.
- [ ] Attach memory explicitly on `je ask` harness routes under the same
  scope rules used by `je connect`. Built-in read-only search is a separate
  shipped surface and does not close this item.

### History, usage, retention, and erasure

Status: **Missing** for history. **Partial** for usage.

- [x] Define a content-free detailed usage trace with a stable run ID,
  person, harness, launch mode, role, engine, place, provider kind,
  assignment, policy version, winning layer, duration, token counts, cost
  actuals or estimates, estimate source, and outcome.
- [x] Keep actual cost, estimated cost, and unknown measurements distinct.
- [x] Reject conflicting duplicate run IDs rather than double-counting a
  retry.
- [x] Calculate daily aggregates from detailed traces.
- [x] Record completed or failed content-free traces for shipped `je ask`
  runs and surface a usage summary in bare `je doctor`.
- [ ] Store detailed traces with the correct Q19 history store for the
  execution place. The shipped ledger writes local ask traces and has no
  hosted history placement.
- [ ] Record traces for connect, run, jobs, broker calls, escalations, and
  warm or cold load observations where Q21 requires them.
- [ ] Add hard-filter outcomes, scorer identity and scores, session and job
  references, harness versions, broker outcome, and escalation decisions to
  the detailed trace when those events exist.
- [ ] Add person-facing inspection for detailed traces and aggregates with
  the settled operator visibility boundary. The doctor summary is not a
  ledger browser.
- [ ] Implement retention, pause, clear, per-session delete, aggregate
  deletion choices, and opt-in aggregate sync with field and date preview.
- [ ] Build hard-split detailed history for personal-machine and Studio
  workspace work.
- [ ] Prove redaction before hosted storage and all-copy erasure across
  primary stores, indexes, caches, controlled exports, and backups.
  Hosted detailed storage stays off until that proof passes.
- [ ] Add one person's-eye local search across both history stores with
  store, place, coverage, redaction, and expiry labels on every result.

### Credentials and secret handling

Status: **Partial**, with the macOS user-artifact foundation shipped.

- [x] Store new gateway, memory, and Ollama profile secrets in macOS
  Keychain through the signed `je-secret-helper`.
- [x] Keep profile files to public fields plus an opaque secret reference
  for native writes. Gateway writes use schema 3. Memory and Ollama writes
  use schema 2.
- [x] Namespace references by purpose and profile, including
  `gateway/profile/`, `memory/profile/`, and `ollama/profile/` prefixes.
- [x] Load legacy embedded-secret profiles only under strict private-file
  checks.
- [x] Keep secrets out of process arguments for je-managed launches and out
  of exported setup bundles.
- [x] Warn in `je doctor` when a profile still uses embedded legacy
  storage.
- [x] Offer explicit secret deletion as a separate profile removal step
  through `--delete-secret`, with a reference-use check in the store.
- [x] Implement Q20 migration one profile at a time. Migration must
  allocate a fresh reference, write the secret, read back the exact value,
  run a no-inference check, atomically switch the profile, and only then
  remove the embedded secret. A failure must leave the working profile
  unchanged and produce a per-profile report. Implemented on `main` for
  all three profile kinds in
  [`CredentialMigration.swift`](Sources/JECore/CredentialMigration.swift)
  with tests in
  [`CredentialMigrationTests.swift`](Tests/JECoreTests/CredentialMigrationTests.swift).
  Shipped in 0.3.1 on 2026-11-09.
- [x] Warn during migration that older backups and exports may still hold
  embedded secrets. Every migration report carries the warning.
- [ ] Prove rotation by verifying a replacement before switching the
  reference for every profile kind. Manual replacement exists through
  profile rewrite, but it is not yet the settled migration and rotation
  flow.
- [ ] Qualify the Linux secret-service path or require the settled
  short-lived session credential path. The shipped release is macOS-only.
- [ ] Prove the separate operator Keychain domain and boot access for the
  private host build under its actual service account and launch mode.
- [ ] Keep secret references nonportable across machines until an explicit
  secret-transfer design exists. Setup and recovery docs need to keep that
  limit visible.

### Background jobs, warmth, and the menu-bar companion

Status: **Missing**.

- [ ] Add user `je jobs` submission, inspection, and stop requests for a
  person's own work only.
- [ ] Record owner, working context, policy version, resolved route, and
  route trace at submission, then recheck hard constraints at start.
- [ ] Make interactive work win over queued work.
- [ ] Make jobs wait and report at harness approvals and cloud escalation
  points. No unattended cloud escalation is allowed.
- [ ] Support authoritative cancel before start and honestly labeled
  best-effort stop after start.
- [ ] Publish a bounded Studio warm set with per-engine budgets inside one
  total budget and a deterministic inspectable eviction order.
- [ ] Show warm or cold state in status and route traces without treating
  warmth as availability. The current detailed usage trace has no warm or
  cold field.
- [ ] Build the signed optional macOS menu-bar companion on stable
  machine-readable status and job interfaces.
- [ ] Limit companion notifications to content-free events and require the
  full review surfaces for escalation approval and memory proposal
  acceptance.

[`ArtifactBoundary`](Sources/JECore/ArtifactBoundary.swift) names
`jobs_client` and `menu_bar_companion` as user modules. No job client or
companion implementation exists in `Package.swift` or `Sources` today.

### Trusted group, onboarding, workspaces, and remote access

Status: **Private or unverified** from this repository, with user-core
foundations in place.

- [x] Separate people in the routing and assignment model through person
  IDs, named profiles, and assignment allow lists.
- [x] Refuse host workspace administration in the user artifact.
- [ ] Prove server-side per-person authorization for model, memory,
  workspace, history, and usage records. This repository cannot prove it.
- [ ] Build and qualify Google sign-in, account allowlisting, and person
  linkage for the trusted group.
- [ ] Qualify every remote surface on Tailscale before any public move.
- [ ] Qualify the first public class at `studio.jestats.io` one surface at
  a time. The settled class covers a person's own home and setup status,
  memory web, browser chat, and Studio-hosted usage and history views.
- [ ] Prove object-level authorization, session expiry and revocation,
  CSRF and origin defenses, rate limits, audit records, monitored TLS,
  and an independent disable switch for each public surface.
- [ ] Keep operator administration, lifecycle, workspace administration,
  broker control, backups, databases, secret management, and raw metrics
  on Tailscale permanently.
- [ ] Prove hosted workspace entry, file and process isolation,
  port-forwarding rules, session revocation, and owned-workspace cleanup
  under the actual host build.
- [ ] Run onboarding for a second person from clean state and record the
  result. A single-operator success does not close Q2.

## Q-by-Q status index

| Question | Settled subject | Status | One-line audit result |
| --- | --- | --- | --- |
| Q1 | Core job | Partial | The front door exists, while completeness depends on qualified routes and platform systems still missing. |
| Q2 | First user | Partial | Person separation exists in local models, while onboarding and service enforcement remain unverified. |
| Q3 | One binary or two | Partial | The user artifact and boundary ship, while the private host build is unverified here. |
| Q4 | Command grammar | Done | Explicit `je ask` is the only prompt invocation and older verbs keep their meanings. |
| Q5 | Who chooses the route | Partial | Deterministic policy ships, while project, personal, and operator signal loading does not. |
| Q6 | Escalation to cloud | Partial | Initial explicit cloud selection has schema support, while post-launch ask-first escalation is missing. |
| Q7 | Routing signals | Partial | The closed policy types ship, while trusted config sources for most soft layers do not. |
| Q8 | Model roles | Partial | Fast and strong are modeled, while strong has no qualified assignment and role cloud targets are not configured as policy. |
| Q9 | Inference engines | Partial | Four families are named, while only Ollama has a shipped general route and qualification. |
| Q10 | Model and engine lifecycle | Partial | Read-only `je models` inspection exists. Previewed lifecycle actions do not. |
| Q11 | Small on-device model | Partial | Evaluation-only helper exists. Titling passed 3/3 live. Routing scores and memory proposals are unevaluated and inert. |
| Q12 | Scheduling and background work | Missing | No jobs client, warm-set manager, or warm-state reporting exists. |
| Q13 | Harness set | Partial | Codex and Claude Code launch well. Muse trials prove the gated Glimmer route only. 24 non-MLX Muse cells are unsupported. |
| Q14 | Protocol translation | Partial | Native checks are strong on shipped routes, while no harness cell has passed qualification. |
| Q15 | Built-in agent loop | Partial | The narrow single-step path ships, while 15 built-in cells and non-Ollama protocols remain unqualified. |
| Q16 | MCP and skills | Missing | Direct plugin and MCP attachment ship, while the registry and live broker do not. |
| Q17 | Where memory lives | Partial | Memory connection and read-only search ship, while cache, outbox, and sync do not. |
| Q18 | Automatic saving | Missing | No proposals-only enforcement, acceptance flow, evaluation, or opt-in state exists in the user core. |
| Q19 | History across harnesses | Missing | No hard-split detailed history store, redaction, search, retention, or erasure proof exists. |
| Q20 | Credential storage | Partial | Native secret references ship on macOS, while settled migration and host-domain proof remain open. |
| Q21 | Usage ledger | Partial | Ask traces and aggregate math ship, while placement, breadth, retention, sync, and browsing remain open. |
| Q22 | Remote access | Private or unverified | The public tree contains no Tailscale qualification, Google onboarding, DNS, TLS, or public-surface evidence. |
| Q23 | Language and packaging | Partial | The signed native user artifact ships, while the separate host build remains private and unverified here. |
| Q24 | Interfaces beyond terminal | Missing | No menu-bar companion implementation exists. |
| Q25 | Going public | Partial | The public user core and hygiene files ship, while future public components and host consumption remain incomplete or unverified. |
| Q26 | December bar | Not met | One of 112 matrix cells is qualified and multiple required systems remain missing or unverified. |

## Named real workflows still to settle and run

Q26 requires named real workflows in addition to matrix cells. Passing
only these workflows would not satisfy Q26, and passing only synthetic
matrix tasks would not satisfy the workflow evidence requirement.

No workflow below counts as passed today. These are candidate names and
shapes for Eric to settle before results are read. Each needs a named
person or user type, sanitized fixtures, exact pass rules, a trial window,
and recorded route and ledger evidence.

| Candidate | Workflow | Required evidence |
| --- | --- | --- |
| W1 | Eric makes a small coding change with tests on his own machine | Qualified local route, native approvals preserved, changed files and test result recorded |
| W2 | Eric completes a read-only repository or research task | Built-in or harness route shown first, bounded context named, no writes outside the declared surface |
| W3 | A second technical person completes coding or data work in an owned Studio workspace | Separate identity, profiles, files, memory, usage, and revocation behavior recorded |
| W4 | A family user uses browser chat with personal memory recall and correction | Correct person linkage, recall from that person's records only, correction visible in later recall |
| W5 | One-person and two-person simultaneous use | Interactive priority, capacity behavior, per-person separation, latency, failures, and cost recorded without invented quotas |
| W6 | Explicit cloud choice and declined escalation | Cloud target, account, budget display, context boundary, approval or decline, and no silent fallback recorded |

The current three-task built-in suite and four-task harness file suite
are qualification fixtures. They are not substitutes for these real
workflows.

## Critical path from 2026-11-09

### Gate A. Settle the measurement rules now

Target: before new Studio qualification results are read.

- [x] Keep full Q26 platform completeness as the December bar. Eric
  reconfirmed this on 2026-11-09. No quiet scope reduction is authorized.
- [x] Settle the exact-assignment rule for calling one broad matrix cell
  complete. Eric approved [GATE_A_DECISIONS.md](GATE_A_DECISIONS.md) D1
  on 2026-11-09: one current exact pass completes the cell.
- [x] Decide whether protocol becomes an explicit matrix dimension or
  remains part of exact assignment evidence under each broad cell. D2
  keeps protocol in exact evidence. The matrix stays at five dimensions.
- [x] Choose the qualification evidence registry, owner, backup, retention,
  and reviewer access path. D3 names the private committed copy as the
  December record. The export step that fills it is still to build.
- [ ] Settle candidate workflows W1 through W6 or replace them. Freeze
  fixtures and pass rules before trial results are read. D4 adopts
  W1 through W6. Fixtures are not frozen yet, and the W3 and W4
  participants are still to be named. Eric has no candidates yet.
- [x] Decide the deadline for declaring any Muse launch mode unsupported
  if bounded trials prove no native route. D5 sets 2026-12-05.
- [x] Rank Q10, Q11, Q12, Q16, Q17, Q19, Q22, and Q24 against the time
  left. D6 records the build order. Under current Q26, deferring any
  one of them still means December completeness fails.
- [x] Name the private evidence Eric will supply for host build, Studio
  services, workspaces, onboarding, and remote access. D7 names the
  packet per system. The packets themselves are still to supply. This
  public audit cannot close those rows by inference.

### Gate B. Finish laptop-stage foundations before Studio arrival

Target: before 2026-12-10.

- [x] Ship the implemented Q20 credential migration with the help-text
  correction already on `main` as the 0.3.1 patch release. Shipped
  2026-11-09: Developer ID signed and notarized (submission
  `9f562920-19fb-466c-9403-588a451a049a`, Accepted), GitHub release
  `v0.3.1`, Homebrew tap updated, and a local upgrade from 0.3.0 with
  `brew test` passing.
- [ ] Add versioned loading for trusted project policy, personal defaults,
  operator defaults, never-cloud state, and cloud intent. Route traces
  need to name each loaded source without copying secrets.
- [x] Run Muse local-contract trials separately for interactive and
  headless modes. Done on the laptop on 2026-11-09. Claims are recorded
  only at the level proven in
  [MUSE_CONTRACT_TRIALS.md](MUSE_CONTRACT_TRIALS.md). Glimmer tool
  behavior, MCP, resume, and cancellation need Studio trials.
- [ ] Attempt harness qualification on routes honestly available from the
  laptop. A failed local-model result stays failed or planned. The point
  is early blocker discovery, not a forced pass.
- [x] Add read-only `je models` inspection as the stable user surface for
  engines, artifacts, assignments, storage, and qualification status.
  Done on `main`. Release pending.
- [x] Prototype the Apple Foundation Models helper in evaluation-only mode,
  or record an explicit decision that changes its December status. Done
  on `main`. Titling passed live. Advisory and memory tasks remain.
- [ ] Design the broker registry, memory sync contract, history redaction
  and erasure proof, and companion status interfaces before host work
  hardens around ad hoc shapes.
- [ ] Complete Q22 groundwork that does not expose a service. That work
  includes Google project and OAuth planning, DNS and TLS ownership,
  allowlist and revocation design, audit design, and disable switches.

### Gate C. Studio arrival and qualification

Target: 2026-12-10 through 2026-12-31 under current Q26.

- [ ] Install the private host build separately from user installs and pin
  the public core version it consumes.
- [ ] Install and pin each claimed engine family through previewed host
  lifecycle actions. Record source, version, digest where available,
  format, size, destination, and affected assignments.
- [ ] Pull candidate fast and strong artifacts and qualify exact
  assignments in a published priority order.
- [ ] Run one-person and two-person trials while qualification proceeds.
  Record latency, load time, failures, escalations, and cost as evidence,
  not as invented quotas.
- [ ] Configure bounded warmth only from qualified and published
  assignments in regular use.
- [ ] Qualify hosted workspace entry and the same front door inside an
  owned workspace.
- [ ] Qualify Tailscale surfaces before any public surface moves.
- [ ] Keep failed cells unavailable. Do not move a failed cell out of the
  matrix after results are read.

### Gate D. December judgment

Target: 2026-12-31.

- [ ] Re-run `je support-matrix --json` from the shipped client and
  reconcile every cell against retained qualification records.
- [ ] Reconcile every Q row against code, service evidence, workflow
  records, and two-person results.
- [ ] Publish the judgment in plain language. If any required cell or
  system remains incomplete, record December as not met and name the new
  completeness date rather than narrowing the claim after the fact.
- [ ] Keep all unqualified routes visibly unavailable after the judgment.

## Decisions Eric needs to make

1. **Full Q26 platform completeness. Settled again on 2026-11-09.** Eric
   chose to keep the full scope. Current evidence still does not support a
   credible claim that every Q1 through Q25 system and all 112 cells will
   be complete by 2026-12-31 without major acceleration or already-existing
   private work that this audit cannot see. The risk stays recorded rather
   than turning into an unapproved scope cut.
2. **Matrix completion semantics. Settled in Gate A D1 and D2.** One
   current exact pass completes a broad cell. Protocol stays in exact
   evidence.
3. **Evidence home. Settled in Gate A D3.** A private committed copy is
   the December record. The export step is still to build.
4. **Named workflows adopted. Participants still open.** D4 adopts
   W1 through W6. Fixtures still need a freeze, and Eric has no W3 or
   W4 participants yet.
5. **Muse unsupported deadline. Settled in Gate A D5.** Decide by
   2026-12-05 on laptop trial evidence.
6. **Next engineering order. Settled by Eric on 2026-11-09.** After
   credential migration: Q10 `je models` first, then Q13 Muse contract
   trials, then Q11 evaluation-only Foundation Models. Gate A was
   approved on 2026-11-09 in [GATE_A_DECISIONS.md](GATE_A_DECISIONS.md).
7. **Private evidence packet. Named in Gate A D7.** The packets
   themselves are still to supply.

## Audit evidence index

- Product requirements and settled choices: [ROADMAP.md](ROADMAP.md).
- Shipped slice account: [IMPLEMENTATION.md](IMPLEMENTATION.md).
- Matrix dimensions and rules: [SUPPORT_MATRIX.md](SUPPORT_MATRIX.md) and
  [`SupportMatrix`](Sources/JECore/SupportMatrix.swift).
- Routing core and ask path: [`RoutingPolicy`](Sources/JECore/RoutingPolicy.swift)
  and [`AskWhy`](Sources/JECore/AskWhy.swift).
- Harness and protocol checks: [`ConnectLaunch`](Sources/JECore/ConnectLaunch.swift),
  [`HarnessLaunch`](Sources/JECore/HarnessLaunch.swift),
  [`CodexCatalog`](Sources/JECore/CodexCatalog.swift), and
  [`MuseContractDiscovery`](Sources/JECore/MuseContractDiscovery.swift).
- Built-in execution and context: [`BuiltInExecution`](Sources/JECore/BuiltInExecution.swift),
  [`BuiltInContext`](Sources/JECore/BuiltInContext.swift), and
  [`MemoryContext`](Sources/JECore/MemoryContext.swift).
- Profiles and credentials: [`ProfileStore`](Sources/JECore/ProfileStore.swift),
  [`SecretStore`](Sources/JECore/SecretStore.swift), and
  [`je-secret-helper`](Sources/je-secret-helper/main.swift).
- Qualification records: [`QualificationEvidence`](Sources/JECore/QualificationEvidence.swift).
- Usage traces and aggregates: [`UsageLedger`](Sources/JECore/UsageLedger.swift).
- Artifact boundary: [`ArtifactBoundary`](Sources/JECore/ArtifactBoundary.swift).
- Release path: [`release-macos.sh`](scripts/release-macos.sh).
- Local checks at audit time: `swift test` passed 224 tests with 0 failures
  on the current tree during the 0.3.0 documentation pass. The installed
  client rendered the matrix counts used above. Host and hosted service
  checks were not run because those systems are outside this repository.

## How to update this checklist

Update a row only when new evidence exists. Useful evidence includes a
shipped commit, a passing repository test, a retained qualification
record, a named workflow record, or a private service test report that Eric
can point a reviewer to.

Do not update a matrix cell from a model listing, a doctor check, a basic
chat, or success on another harness, engine, protocol, model, version, or
execution place. Qualification does not transfer across those boundaries.

Keep the snapshot date current. Keep failed attempts visible when they
change the plan. A short honest gap list is more useful than a green board
that nobody can reproduce.


