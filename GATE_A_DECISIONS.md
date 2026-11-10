# Gate A measurement rules

Status: **settled. Eric approved Gate A on 2026-11-09.** Nothing here
changes Q26 scope. These rules bind new Studio qualification results.
Workflow participants for W3 and W4 are still to be named. Eric has no
candidates yet, so those workflows cannot pass until real people fill
them. No placeholder names count.

Snapshot date: 2026-11-09. Judgment date stays 2026-12-31.

Build order locked by Eric on 2026-11-09: Gate A, then Q20 credential
migration, then Q10, then Q13, then Q11.

## D1. When one broad matrix cell counts as complete

**Recommendation: one current exact pass completes the cell.**

A cell in [`SupportMatrix`](Sources/JECore/SupportMatrix.swift) is
complete when at least one exact assignment for that cell holds a
current passing qualification record. The exact identity is:

- role
- engine family and engine version
- model artifact, format, and digest when the source provides one
- harness kind and harness version, or the built-in path version
- launch mode
- protocol implementation and protocol version
- configuration or catalog digest
- execution place

Rules:

- Any change to that identity needs a new qualification run. The old
  pass does not carry over.
- A second model in the same cell does not uncomplete the cell. Each
  assignment still needs its own pass before policy may select it.
- A failed exact assignment stays recorded as failed. It does not
  block a different exact assignment in the same cell from completing
  the cell.
- Personal-machine cells need one qualified exact assignment. They do
  not need one per person. Personal assignments stay selectable only
  for their owner and place.
- Studio-workspace cells need one qualified published Studio
  assignment. Two-person behavior is proven by workflows W3 and W5,
  not by multiplying every cell per person.
- Operating system build belongs to Q11 triage identity only. It is
  not part of a general cell identity unless a harness or engine
  record shows it changed behavior.

This keeps December at 112 cells. It does not lower the bar inside a
cell. An unqualified assignment stays unavailable even in a complete
cell.

## D2. Protocol stays in exact evidence

**Recommendation: do not add protocol as a sixth matrix dimension.**

Q14 already makes protocol implementation and version part of exact
assignment identity. Q26 names protocol as a cell dimension. This
decision records the audit mapping in writing:

- The published matrix keeps five dimensions: role, engine, harness
  or built-in path, launch mode, and execution place.
- Every qualification record that supports a cell must name its
  protocol implementation and version.
- A cell with no named protocol in its evidence is not complete.
- Two protocols in one broad cell are two exact assignments. Each
  needs its own pass. Either pass can complete the broad cell under
  D1, but only the passed protocol route becomes selectable.

Expanding the matrix now would multiply cells without adding a new
user promise. The evidence rule above keeps the same proof burden.

## D3. Where qualification evidence lives

**Recommendation: local state stages evidence. A private committed
copy is the December record.**

- Owner: Eric Hare.
- Staging: the local `je` state directory where
  `je assignments qualify` writes content-addressed records today.
- Canonical December home: an `evidence/qualification/` directory in
  the private Studio repository. One JSON file per record, named by
  its content address, plus a plain index that maps each matrix cell
  to its supporting record.
- Backup: the existing Studio backup path, external drive plus
  encrypted Google Cloud Storage. The laptop copy alone never counts
  as retained evidence.
- Review: any reviewer with private-repo access can open the record
  behind a content address. A bare hash with no readable record does
  not support a December claim.
- Retention: keep every December record, pass and fail, at least
  through the judgment and for one year after it.
- Content rule stays as shipped: records hold exact identity, task
  results, exit codes, durations, and output digests. They hold no
  prompts, secrets, memory text, or file contents.

Open action: add an export step that copies staged records into the
canonical directory and verifies each content address. Until that
ships, a manual copy with checksum verification is the interim path.
Name who ran it and when in the index.

## D4. Named workflows W1 through W6

**Recommendation: adopt W1 through W6 as the December workflow set.
Freeze fixtures and pass rules before trial results are read.**

| ID | Workflow | Pass rule in one line |
| --- | --- | --- |
| W1 | Eric makes a small coding change with tests on his own machine | Qualified local route, native approvals intact, tests pass |
| W2 | Eric completes a read-only repository or research task | Route shown first, bounded context named, no writes |
| W3 | A second technical person works in an owned Studio workspace | Separate identity, files, memory, usage, and revocation |
| W4 | A family user uses browser chat with memory recall and correction | Own records only, correction visible in later recall |
| W5 | One-person and two-person simultaneous use | Interactive priority and per-person separation recorded |
| W6 | Explicit cloud choice and declined escalation | Budget and context shown, decline honored, no silent fallback |

Each workflow record names:

- the person or user type
- sanitized fixtures
- the exact pass rule, written before the run
- the trial window
- route and ledger evidence references

Eric still needs to name the second technical person and the family
user. A workflow with no named participant cannot pass. Synthetic
qualification suites do not substitute for these workflows, and these
workflows do not substitute for matrix cells.

## D5. Muse unsupported deadline

**Recommendation: decide by 2026-12-05, before Studio qualification.**

- Run Muse local-contract trials on the laptop first, interactive
  and headless separately. That is the Q13 slice in the locked order.
- If no native arbitrary local endpoint contract is proven for
  headless mode by 2026-12-05, declare Muse headless unsupported
  ahead of Studio results. Those 16 cells move from blocked to
  unsupported with the trial record as the reason.
- Judge interactive mode on its own trial. The gated built-in
  Glimmer route alone does not qualify arbitrary endpoint cells.
- No mode stays blocked by default into late December. Blocked is a
  temporary state with this deadline, not a December outcome.

An unsupported declaration follows the settled rule: ahead of
qualification, with a contract reason on record. It is never a quiet
removal after results are known.

## D6. Build order for the remaining systems

**Recommendation: keep Eric's locked order, then design before host
work hardens.**

Laptop stage, in order:

1. Q20 credential migration, shipped as the 0.3.1 patch with the
   help-text correction already on `main`.
2. Q10 read-only `je models` inspection.
3. Q13 Muse contract trials.
4. Q11 Apple Foundation Models helper, evaluation-only.

Design work that should land before Studio arrival, in order:

1. Q22 groundwork with no public exposure: Google project and OAuth
   plan, DNS and TLS ownership, allowlist and revocation design,
   audit design, and per-surface disable switches.
2. Q17 memory sync contract, Q16 broker registry, and Q19 redaction
   and erasure proof design. Host code should not harden around
   ad hoc shapes before these exist.

After Studio arrival:

1. Gate C installation and qualification in a published cell order.
2. Q12 warmth and jobs, which need qualified assignments and
   measured load data.
3. Q24 menu-bar companion, which needs stable status and job
   interfaces first.

This ranking is build order only. Under full Q26, deferring any
required system past December still means December is not met. The
ranking makes that risk visible early instead of hiding it.

Related call: the December user release stays macOS arm64. Linux
keeps CI test coverage only. Record that now, ahead of results, so
the release claim never grows after the fact.

## D7. Private evidence packet

**Recommendation: Eric supplies one dated packet per private system.
This public audit closes no private row by inference.**

Each packet is a short markdown note plus command output or a service
report. It holds no secrets. It names versions, dates, and who ran it.

- Host build: build identity, the pinned public core version it
  consumes, and proof it uses only pinned public interfaces.
- Memory service: per-person authorization, revision, idempotency,
  trash, purge, and receipt checks.
- Workspaces: entry, file and process isolation, port rules,
  revocation, and owned-workspace cleanup.
- Onboarding: one second-person run from clean state, start to work.
- Network: Tailscale qualification per surface, then public-surface
  checks one surface at a time.
- Backups: one restore proof that covers evidence and service state.

Until a packet exists, its checklist row stays private or unverified.

## What approval changes

- New qualification runs cite D1 and D2 by name.
- The Muse deadline in D5 binds the Q13 slice.
- Q10, Q13, and Q11 proceed in the locked order after the 0.3.1 release.
- Still open after approval: name W3 and W4 participants, freeze
  workflow fixtures, build the evidence export step in D3, and supply
  the private packets in D7.
