# Native core implementation

This document records the first build slice after the Final roadmap. It is a
foundation slice, not a claim that the launch platform is complete.

## Settled implementation choices

- The shared native core language is Swift.
- The public user core is Apache-2.0 licensed from its first source release.
- The private Python 0.2.0 client remains the behavior reference and test
  oracle during the port.
- The user artifact must build without host-only workspace, network, or
  service-control modules.
- Apple-only credential work lives in `je-secret-helper`. It uses macOS
  Keychain generic passwords through a narrow JSON stdin and stdout protocol.
  Secrets never travel in process arguments. Signing and notarization of the
  helper remain release work.

## What this slice contains

- A SwiftPM package with a portable `JECore` library and a `je` executable.
- Frozen oracle contract metadata for the Python profile schemas, public
  profile fields, legacy command names, secret handling, and no-echo parse
  errors.
- A machine-readable launch support matrix covering roles, engine families,
  harnesses, launch modes, execution places, and qualification status.
- A user-artifact boundary model with a test that rejects host-only modules.
- `status`, `support-matrix`, and `contracts` commands with JSON output.
- Gateway, memory, and native Ollama profile list and show parity. Native
  writes keep credentials in platform secret storage. Gateway profiles use
  schema 3, including catalog-bound writes. Memory and Ollama profiles use
  schema 2 secret references. Legacy embedded-secret files keep their strict
  private-file checks.
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
- `je ollama --profile NAME check` performs a bounded, no-redirect,
  non-inference native model listing check with the saved key. It reports only
  whether the default model is available.
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

## What this slice does not contain

- Native Ollama launch, connect, run, export, or credential commands.
- Muse arbitrary local endpoints, harness-attached memory context, and non-Ollama
  built-in protocol routes, engine lifecycle,
  broker traffic, memory sync, history storage, credential migration, or
  remote access. Unsupported launch cells fail closed after route display.
- Any qualified local model assignment. Matrix cells remain planned or blocked
  until recorded qualification evidence exists.

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

## Next slices

Port one oracle surface at a time. Each port needs parity checks against the
Python behavior for that surface before new feature work builds on it. The
support matrix is updated only with qualification evidence, never by moving a
failed cell out of scope after results are read.
