# Native core implementation

This document records the native implementation through the 0.3.0 release,
which replaces the Python client in the Homebrew tap, plus the Q20
credential migration prepared on `main` for the 0.3.1 patch. The 0.3.1
release itself is still pending. This document is not a claim that the
launch platform is complete.

## Settled implementation choices

- The shared native core language is Swift.
- The public user core is Apache-2.0 licensed from its first source release.
- The private Python 0.2.0 client was the behavior reference and test
  oracle during the port. It remains available in the v0.2.0 release.
- The user artifact must build without host-only workspace, network, or
  service-control modules.
- Apple-only credential work lives in `je-secret-helper`. It uses macOS
  Keychain generic passwords through a narrow JSON stdin and stdout protocol.
  Secrets never travel in process arguments. Release builds sign both
  binaries with a Developer ID identity (`io.jestats.je` and
  `io.jestats.je-secret-helper`), hardened runtime, and a secure timestamp,
  then notarize them through `scripts/release-macos.sh`, so the helper keeps
  a stable Keychain identity across upgrades.

## What the native core contains

- A SwiftPM package with a portable `JECore` library and a `je` executable.
- Frozen oracle contract metadata for the Python profile schemas, public
  profile fields, legacy command names, secret handling, and no-echo parse
  errors.
- A machine-readable launch support matrix covering roles, engine families,
  harnesses, launch modes, execution places, and qualification status.
- A user-artifact boundary model with a test that rejects host-only modules.
- `status`, `support-matrix`, and `contracts` commands with JSON output.
- `je setup` finds the installed Codex and Claude Code CLIs and adds the
  Studio plugin through their native plugin managers, matching the Python
  client: version and JSON capability checks, marketplace source
  verification, displayed plans, `--yes` or interactive confirmation,
  `--dry-run` inspection, post-change verification, and `--remove` while
  keeping the marketplace registered. With setup ported, every Python user
  command has a native counterpart.
- Gateway, memory, and native Ollama profile list and show parity. Native
  writes keep credentials in platform secret storage. Gateway profiles use
  schema 3, including catalog-bound writes. Memory and Ollama profiles use
  schema 2 secret references. Legacy embedded-secret files keep their strict
  private-file checks.
- `je profile migrate`, `je memory migrate`, and
  `je ollama profile migrate` move one legacy embedded secret at a time to
  native secret storage under Q20: allocate a fresh reference, write the
  secret, read back the exact value, run the bounded no-inference check for
  that profile kind, then atomically switch the profile file to the
  reference schema. Gateway migration also revalidates a saved Codex
  catalog binding before switching. Any failure leaves the working profile
  unchanged and removes the new secret. Already-migrated profiles are a
  no-op without a check. `--all` migrates each saved profile in turn and
  reports every result, `--dry-run` previews without writing or checking,
  and `--json` prints the machine-readable report. Every report warns
  that older backups and exports may still contain embedded secrets.
  Secrets never print.
- A deterministic routing policy core with hard filters, settled preference
  layers, explicit cloud authorization, replayable filter results, and traced
  advisory scores that do not change the starter route.
- A content-free usage ledger core with duplicate-safe run identities and
  daily aggregates that keep actual cost, estimated cost, and unknown
  measurements distinct.
- A private assignment registry that builds routing candidates only for cells
  in the launch support matrix. The user artifact can author personal-machine
  assignments with `je assignments`. Studio publication stays host-only.
- `je why` route explanations and `je ask` harness launch for selected
  personal-machine Codex, Claude Code, and Muse built-in local assignments.
  Explicit `je ask --single-step` can select only a qualified built-in
  assignment. The first built-in executor makes one bounded Ollama native
  chat request with no tools, shell, edits, or session state. It accepts
  only explicit text context under `--context-root` through repeated
  `--context-file` values, `--context-list`, and repeated literal
  `--context-search` values. The loader bounds count, depth, file size,
  matches, and total size. It rejects traversal, symlinks, binary data,
  and profile secrets. It also accepts explicit read-only memory search
  context through `--memory-profile` with repeated `--memory-search`
  values. The fetcher requires a credential that advertises no write
  tools, verifies the advertised search schema, calls only the search
  tool, and bounds queries, result size, and the combined context total.
  Catalog-bound Codex requires an exact version check, digest check, catalog
  validation, and a private exact-byte snapshot. Muse local requires the
  exact qualified CLI version, the `muse-local-glimmer` protocol, the MLX
  engine family, and at least 64 GiB of physical memory. Ask records a
  content-free completed or failed usage trace.
- `je doctor --profile NAME` performs a bounded, no-redirect, non-inference
  gateway model listing check with the saved key. With `--probe` it also
  runs the bounded Responses and Messages protocol checks from the Python
  client and writes a private report under `reports/` in the state directory.
- Bare `je doctor` prints a local health overview (also `--json`): version,
  machine, saved profiles with secret-storage kind, published assignments,
  support-matrix totals, discovered harness executables, usage summary, and
  warnings for embedded credentials, unloadable profiles, dangling
  assignment references, and missing executables. It never resolves secret
  values, contacts a service, or runs inference, and exits 1 when warnings
  are present.
- `je credential --profile NAME` prints the saved gateway key for a desktop
  credential helper, matching the Python client. It resolves embedded
  legacy keys and native secret references through the gateway profile
  loader and prints nothing else.
- `je export --profile NAME` writes a desktop setup bundle for review under
  `exports/<profile>/bundle-<random>` in the state directory, matching the
  Python client byte for byte: a review README, manifest, Codex config
  fragment, Claude Desktop inference config, and Claude Code settings
  fragments, plus an exact catalog copy for catalog-bound profiles after
  the saved binding is rechecked. Bundles contain no credentials; apps fetch
  the key through the configured helper executable, which defaults to the
  installed `je` or can be set with `--helper-executable`.
- `je ollama --profile NAME check` performs a bounded, no-redirect,
  non-inference native model listing check with the saved key. It reports only
  whether the default model is available.
- `je ollama --profile NAME` starts the native Ollama CLI through a
  temporary loopback relay with a random capability-token path, matching the
  Python client: the default model opens interactively, arguments after
  `--` pass through verbatim, and exit codes propagate. The relay forwards
  only model inspection, chat, generate, and show requests with the saved
  key injected, sanitizes upstream error bodies, and closes when the CLI
  exits. Management requests are refused locally.
- `je run --profile NAME [--model MODEL] -- COMMAND [ARGS]` runs another
  OpenAI-compatible client with the saved gateway connection in its
  environment (`OPENAI_BASE_URL`, `OPENAI_API_KEY`, `OPENAI_MODEL`), matching
  the Python client: arguments after `--` pass through verbatim, the key is
  rejected in command arguments, a differing `--model` applies to this
  session only, and exit codes propagate as 128 plus the signal number.
- `je connect codex|claude --profile NAME` opens the harness with the saved
  gateway connection for one session, matching the Python client: a differing
  `--model` applies to this session only and drops the saved context window
  and catalog binding, arguments after `--` pass through verbatim, and exit
  codes propagate as 128 plus the signal number. Catalog-bound Codex profiles
  keep the exact version, digest, and private snapshot checks.
  `--memory-profile NAME` attaches the saved memory MCP connection for the
  session. Codex attachment requires the qualified `0.166.0-alpha.5.1` build
  and a matching catalog binding when one is saved. Claude launches verify
  `auth status` against temporary private settings before starting. The
  `je ask` harness launch and assignment qualification share the same oracle
  launch configuration, with the prompt passed as trailing harness arguments.
  Harness-attached memory on `ask` routes remains unimplemented.
- `je memory check NAME` initializes the saved MCP connection and pages the
  tool list inside bounded request, page, tool, and byte limits. It never
  calls a memory tool and reports only protocol, count, and read or write
  availability.
- `je doctor muse` performs bounded, non-inference contract discovery from
  public version and help surfaces. For Muse 1.4.14 it distinguishes the
  gated built-in Glimmer route from an arbitrary local endpoint contract and
  returns an evidence reference without claiming qualification.
- `je assignments qualify` runs a four-task bounded headless file suite in
  temporary private workspaces. The tasks cover exact copy, key selection,
  line filtering, and placeholder replacement. Built-in assignments run a
  separate three-task exact-answer suite through the same single-step route.
  It stores content-addressed qualification evidence with exact candidate
  identity, per-task results, exit codes, durations, and output digests. It
  marks an assignment qualified only on an explicit passing run.

## What it does not contain

- Muse arbitrary local endpoints, harness-attached memory context, and non-Ollama
  built-in protocol routes, engine lifecycle,
  broker traffic, memory sync, history storage, credential rotation with a
  pre-switch check, or remote access. Unsupported launch cells fail closed
  after route display.
- More than one qualified matrix cell. The
  `fast/ollama/built_in/single_step/personal_machine` cell is qualified on
  `evidence:qualification:c7f949ad37209589a3fa353f88c8a026810281cb4a0abcc8fecdf6e69fb0156e`,
  recorded 2026-11-09 for `studio-harness-qwen35:4b` on Ollama 0.40.15. The
  bounded suite `bounded-builtin-tasks-v1` passed all three exact-answer
  tasks, and `je ask --single-step` served a prompt through the route. The
  other 111 cells remain planned or blocked until their own recorded
  evidence exists.

## Local checks

```sh
swift test
swift run je --version
swift run je status --json
swift run je support-matrix --json
swift run je contracts --json
swift run je why --person alice --role fast --json -- "Explain this repo"
swift run je doctor muse --json
```

## Next work

Qualify more matrix cells one at a time, each on recorded evidence. The
support matrix is updated only with qualification evidence, never by moving
a failed cell out of scope after results are read. Studio-arrival work
follows the roadmap build order. The dated gap audit and critical path live
in [COMPLETENESS_CHECKLIST.md](COMPLETENESS_CHECKLIST.md).
