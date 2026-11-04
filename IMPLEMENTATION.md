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
- Apple-only helper work stays outside the portable core until a signed helper
  boundary is implemented and qualified.

## What this slice contains

- A SwiftPM package with a portable `JECore` library and a `je` executable.
- Frozen oracle contract metadata for the Python profile schemas, public
  profile fields, legacy command names, secret handling, and no-echo parse
  errors.
- A machine-readable launch support matrix covering roles, engine families,
  harnesses, launch modes, execution places, and qualification status.
- A user-artifact boundary model with a test that rejects host-only modules.
- `status`, `support-matrix`, and `contracts` commands with JSON output.
- Read-only gateway, memory, and native Ollama profile list and show parity,
  including strict legacy schemas and private directory and file checks.
- A deterministic routing policy core with hard filters, settled preference
  layers, explicit cloud authorization, replayable filter results, and traced
  advisory scores that do not change the starter route.
- A content-free usage ledger core with duplicate-safe run identities and
  daily aggregates that keep actual cost, estimated cost, and unknown
  measurements distinct.

## What this slice does not contain

- Connection writes and checks, native Ollama launch, connect, run, doctor,
  export, or credential commands.
- Harness launch, engine lifecycle, broker traffic, memory sync, history
  storage, credential migration, or remote access. Routing and ledger code
  exist only as library cores. Neither is wired to `je ask` yet.
- Any qualified local model assignment. Matrix cells remain planned or blocked
  until recorded qualification evidence exists.

## Local checks

```sh
swift test
swift run je --version
swift run je status --json
swift run je support-matrix --json
swift run je contracts --json
```

## Next slices

Port one oracle surface at a time. Each port needs parity checks against the
Python behavior for that surface before new feature work builds on it. The
support matrix is updated only with qualification evidence, never by moving a
failed cell out of scope after results are read.
