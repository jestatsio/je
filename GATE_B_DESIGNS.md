# Gate B design sketches

Status: **draft for Eric to review.** Nothing here is settled beyond
what Q1 through Q26 already settled. These sketches exist so host work
does not harden around ad hoc shapes. Each one names the contract, the
fail-closed rule, and the proof December needs.

Date: 2026-11-09.

## 1. MCP broker registry (Q16)

One reviewed registry file, versioned, in the authoritative state for
each artifact. The user artifact owns personal-machine entries. The
host build owns Studio entries. Neither silently enables the other's.

Registry entry fields:

- `id`, `kind` (`mcp_server` or `skill_source`)
- `source` (URL or path, no credentials), `version`
- `digest` (content digest or toolprint-style fingerprint)
- `capabilities` (declared tool names with read or write character)
- `required_scopes`, `supported_harnesses`, `execution_places`
- `trust_state` (`reviewed`, `revoked`)
- `credential_reference` (Q20 secret reference name only, per person)

Broker runtime rules, already settled and restated as checks:

- Verify person, enabled server and tool, version or fingerprint,
  scopes, execution place, and revocation at session start and on
  each brokered call.
- Deny outside scope. Never replace native harness approval. Add no
  second interactive approval layer.
- Broker down or revoked means broker-managed tools are visibly
  unavailable. No direct fallback.
- Audit records metadata only: person, session, server and tool
  identity, policy result, timing, status. No arguments, results,
  credentials, prompts, or memory text.

Open for Eric: registry file location inside state (`broker.json`
proposed), fingerprint algorithm for MCP tool lists, and transport
shape per harness. Proof needed: one brokered read-only memory call
plus one denial, each with audit records, before any December claim.

## 2. Memory sync contract (Q17)

The Studio service stays the single system of record. The laptop
holds a bounded cache plus a pending-operation outbox. This sketch
names the missing service contract only. It builds nothing.

Service additions needed, versioned as sync contract 1:

- A per-person monotonic change sequence. Each accepted mutation
  (save, edit, undo, delete, restore, purge) advances it once.
- `sync_changes(since_sequence, limit)` returning ordered changes:
  record id, revision, state (active, trashed, purged), and the
  sequence high-water mark. Bodies fetch separately by id and
  revision, reusing existing bounded reads.
- A completeness rule: a cache may treat absence as removal only
  after a full reconciliation or after consuming an unbroken change
  range ending at the current high-water mark. Purged records appear
  as explicit purge markers, never as silent absence mid-range.
- Outbox replay keeps existing semantics: stable operation IDs,
  expected revisions, per-record capture order, conflict stops for
  the person. No merge, no last-writer-wins.

Cache record fields: record id, revision, state, text, provenance
for display, `sync_state` (`current`, `stale`, `pending`), last
reconciled sequence, purge marker flag. Offline search is keyword
only and labeled stale. Semantic search stays service-side.

Proof needed: offline save → pending → accepted receipt, one
revision conflict, one purge propagating to cache body removal, each
with the service as the only authority throughout.

## 3. History redaction and erasure proof (Q19, Q21)

Hosted detailed storage stays off until this proof passes end to
end. The proof is a checklist run, not a design argument:

1. Write one synthetic hosted session containing planted canaries in
   every field class (prompt-shaped, path, token-shaped, output).
2. Show stored form contains no canary in primary store or index.
   Redaction happens before storage, with coverage labeled per
   harness (observed versus gap, never reconstructed).
3. Delete the session. Show ordinary access revoked at once.
4. Run the erasure path. Search primary store, indexes, caches,
   je-controlled exports, and a restored backup for every canary.
   All absent or unreadable, or the proof fails.
5. Repeat after 30-day expiry simulation (clock injection), same
   result required.

Client-only history needs its own smaller proof: pause, per-session
delete, and clear remove local events and their detailed usage
traces together, with aggregate deletion as the person's separate
choice. Native harness histories are outside the claim and labeled
as such in every surface.

## 4. Companion status interfaces (Q12, Q24)

The menu-bar companion consumes stable machine-readable output only.
It never parses human text. Existing surfaces it may read today:

- `je doctor --json` (health overview, warnings)
- `je models --json` (engines, assignments, storage, qualification)
- `je status --json` and `je support-matrix --json`

Missing and needed before any companion build:

- `je jobs` does not exist. Job list and job detail JSON shapes come
  first, with owner-only visibility and content-free fields.
- Warm or cold state per assignment (Q12) joins the models report
  additively when the warm-set manager exists. Warmth never reads
  as availability.
- Notification events are content-free: kind, time, and a reference
  the person opens in the full surface. Escalation approval and
  memory proposal acceptance never happen in the companion.

Rule: a new field is additive within a schema version. A breaking
shape change bumps `schema_version` and keeps the old reader working
until the companion's minimum version moves in writing.

## 5. Remote access groundwork (Q22, no exposure)

Nothing public moves in this stage. Groundwork that is safe now:

- Google Cloud project for sign-in: create project, OAuth consent in
  testing mode, no production redirect yet. Record project ID in the
  private evidence packet, never in this public tree.
- DNS and TLS ownership: name the registrar records and certificate
  path for `studio.jestats.io` on paper first. No record points at a
  service until its surface qualifies on Tailscale.
- Allowlist model: Google account → je person link, operator-managed,
  revocable in one action. Session expiry, revocation, CSRF and
  origin defenses, rate limits, and audit shape are per-surface
  design items, settled before that surface's Tailscale trial.
- One independent disable switch per public surface, tested while
  the surface is still Tailscale-only.
- Permanently Tailscale-only: operator administration, lifecycle,
  workspace administration, broker control, backups, databases,
  secret management, raw metrics.

Qualification order stays settled: every surface on Tailscale
first, then one public surface at a time (own home and setup status,
memory web, browser chat, own usage and history views).

## What Eric still decides

- Broker registry filename and fingerprint method (section 1).
- Whether sync contract 1 ships before Studio arrival or rides the
  host build (section 2). Cache claims wait either way.
- Companion timing stays after `je jobs` (section 4). No change
  proposed.
- Google project creation is an account action only Eric should run
  (section 5). This draft does not create it.
