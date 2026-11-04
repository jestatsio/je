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

## What this slice does not contain

- Ported profile, memory, connect, run, doctor, export, or credential commands.
- Model routing, harness launch, engine lifecycle, broker traffic, memory
  sync, history storage, credential migration, or remote access.
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
