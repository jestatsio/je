# Pi bounded qualification trial

Date: 2026-11-13. Machine: Eric's laptop, macOS 27.2.1 (26B131),
36 GiB physical memory. This is the bounded tabulate trial named
in [`PI_DISCOVERY.md`](PI_DISCOVERY.md), run so Pi has task-quality
evidence beside the earlier Codex and Claude Code runs of the same
baseline. It qualifies one exact assignment only. It changes no
settled decision and adds nothing to the launch set.

Exact assignment: Pi 1.5.2 (`@earendil-works/pi-coding-agent`
1.5.2, npm install inside the trial image; `pi --version` prints
`1.5.2` in the container), RPC headless launch mode, host Ollama
0.40.16 over its OpenAI-compatible `/v1` endpoint, model
`studio-harness-qwen35:4b`, digest
`49112559145fb326b4bc232c811d7d57314f7c82d1f15b8e83a9356199ecf185`
(the same artifact the baseline Codex and Claude Code runs used),
executed on this laptop inside Docker. Thinking level was Pi's
default, reported as `medium` in `get_state`.

Boundary: plain Docker, following Pi's shipped
`docs/containerization.md`. Trial image `pi-trial:1.5.2`
(`sha256:fefc2eb0e330…fba91b`, deleted after the trial) was built
locally from `python:3.12-slim-bookworm` (Python 3.12.16) with
Node v24.22.3 copied from `node:24-bookworm-slim`. Pi never ran
on the host. Every container ran as non-root uid 10001 with
`--cap-drop ALL`, `--security-opt no-new-privileges`, a read-only
root filesystem, a 512 MiB tmpfs at `/tmp`, 4 GiB memory, 4 CPU,
and 256 pid limits, and no published ports. The only mounts were
the trial working copy at `/workspace` and a scratch
`PI_CODING_AGENT_DIR` at `/agent`; `HOME=/tmp`,
`PI_OFFLINE=1`. Real `~/.pi` was never mounted or read by the
trial (file times still predate it, spot-checked after cleanup).
Git was absent from the image, matching the bounded fixture. The
only credential was the dummy `apiKey` value `ollama`, which
Ollama ignores. Network used the default Docker bridge with
`host.docker.internal` reaching host Ollama at port 11434; no
egress firewall was applied, so internet reachability from inside
the boundary is recorded as possible but unused (the task forbids
it, provisioning was offline, and no install command appears in
the event log). Docker base images and the npm and pip packages
were fetched at image build time, on the host side, before any
agent run. No model was downloaded.

Baseline: the tabulate bug-fix fixture recorded in the jestudio
repository under `deploy/studio-trials/tabulate/` (`task.md`,
`test_studio_regression.py`, `requirements-core.lock`, fixture
`README.md`). The broken source came from the retained clean
checkout of that trial and was hash-checked before use; it
crashes with `AttributeError: 'bool' object has no attribute
'splitlines'` on the task example. Before any model ran, the
broken copy was qualified on host Python 3.12.12 with pytest
8.3.5: 288 passed, the four intended trial cases failed,
40 skipped, matching the fixture record. Each model run got a
fresh identical copy with `.venv` pre-provisioned offline from
the pinned wheels, and received `task.md` verbatim as its single
prompt. No hints, steering, follow-ups, or mid-run help were
given. The hard bound was 20 minutes from prompt send, the
limit the baseline trial applied; the run settled well inside
it. Run flags were pinned per the discovery doc's trial shape:
`--mode rpc --provider ollama-local --model
studio-harness-qwen35:4b --no-approve --tools
read,bash,edit,write --no-mcp`. The scratch `models.json`
declared provider `ollama-local` with
`baseUrl http://host.docker.internal:11434/v1`,
`api openai-completions`, `contextWindow` 65536 (the model's
Ollama `num_ctx`), `maxTokens` 8192, `reasoning` true,
`input` text and image, and zero costs. No compatibility
overrides were set. Event logs, driver, workspaces, and the
image were scratch and have been removed; this document records
the decisive lines and counts.

## Verdict in one paragraph

For this one exact assignment, the bounded trial passes. The
single Pi RPC run fixed the wrapped-table bug unaided: its
patch passes the full original suite plus the four trial cases
under independent host verification (292 passed, 40 skipped),
leaves every test file byte-identical, and shows no output
difference from the broken baseline on a 14-case differential
probe battery covering the regression classes that sank the
baseline attempts. Tool driving was reliable at the wire level
(72 of 72 calls completed, no malformed records) and RPC abort
settled a second run about 20 milliseconds after it was sent,
with the aborted session resumable afterward. That is a stronger
single result than either baseline harness produced with the
same model artifact, but it remains one run, one task, one mode,
one small model, inside an external Docker boundary that
substitutes for the approvals Pi does not have. It closes the
discovery unknowns listed below for this assignment and no
other.

## Trials

| ID | Trial | Result |
| --- | --- | --- |
| Q01 | Preflight, print mode, separate empty workspace, `--no-tools --no-session`, prompt `Reply with exactly: trial-ok` | Prints `trial-ok`, exit 0, 10.5 s wall including container start and venv provisioning. Proves the endpoint path with `PI_OFFLINE=1` set. Setup only; not task evidence. |
| Q02 | Main bounded run, RPC mode, verbatim `task.md` prompt, fresh copy | `agent_settled` at 575.9 s after spawn (573 s after prompt send), final stop reason `stop`, container exit 0 on stdin EOF 0.56 s later, stderr empty. 73 turns, 72 tool calls. Agent reported `292 passed, 40 skipped`. Session `01a1d7f6-b117-74d0-9818-c1476af799c9` persisted. |
| Q03 | Independent verification, host Python 3.12.12, no container | Full command below: 292 passed, 40 skipped in 0.76 s. All nine test and helper files plus `TASK.md` hash-identical to before; the only changed file is `tabulate/__init__.py`. Differential probes pass as detailed below. |
| Q04 | Cancellation probe, RPC `abort` on a second fresh copy | Abort sent 18.72 s after spawn, during generation in turn 5. `agent_end`, `agent_settled` with `aborted: true`, and the abort response all arrived at 18.741 s, about 20 ms after the send. Final stop reason `aborted`, exit 0. No source edits were left; only `find`, `ls`, and `read` had run. Session `01a1d800-0dbe-71d8-aaac-58c11f6bda25` persisted. |
| Q05 | Resume of the aborted session, new container, same mounts, `--continue` | `get_state` succeeds against the aborted session; `get_messages` returns the same 11 messages the cancelled run recorded (1 user, 5 assistant, 4 tool results, plus system). Exit 0 in 0.64 s. Same profile and assignment only. |

Independent verification command (Q03), run with the candidate
checkout as working directory and the host verify venv's
interpreter, Python 3.12.12 and pytest 8.3.5:

```sh
python -m pytest -v --doctest-modules --ignore benchmark -ra \
  --junitxml REPORT.xml
```

The candidate patch is one hunk in `_wrap_text_to_colwidths`:
boolean cells, the strings `"True"` and `"False"`, and `None`
are stringified explicitly before wrapping instead of passing
through `_type(cell)(cell)`, which produced a `bool` or raised
for those inputs. Two `edit` calls made the change; the agent
never used `write`.

Because the baseline trial showed a passing suite does not
establish acceptance, Q03 also ran 14 differential probes
against both the broken baseline and the candidate on host
Python: the task example, boolean values with and without
wrapping, `None` without wrapping, numeric wrapping with and
without `disable_numparse=True`, numeric strings, a bytes value,
string-valued Enum members, a datetime value, trailing
nonbreaking whitespace, an empty-string cell, multiline text,
and plain wrapped text. Candidate output was byte-identical to
baseline output on all 12 probes where the baseline does not
crash, which covers every regression class the baseline review
recorded. The task example crashes on the baseline and prints
the exact expected grid on the candidate. One crash is shared
identically by both: an empty-string cell under wrapping raises
`TypeError: NoneType takes no arguments`. That is a pre-existing
defect in the historical library, outside this task, unchanged
by the candidate.

## Task correctness

Pass, at the baseline's stated criteria, for this assignment.
The four trial acceptance cases pass, the original suite count
is preserved (288 baseline passes plus the 4 trial cases, same
40 skips), tests are untouched, and the differential battery
found no behavior change outside the fixed crash. For
comparison only: in the baseline trial, Codex needed three
attempts and Claude Code two, with neither final candidate
passing review. This Pi result came from a single unaided run
with no review follow-ups. That is evidence about this task
and assignment, not a harness ranking: input path (RPC prompt
versus editor), host load, and sampling all differ.

## Tool-call reliability

Clean at the protocol level, wasteful at the work level. The
main run streamed 9,551 JSONL records with zero parse failures:
73 turn starts, 72 `tool_execution_start` records each matched
by an end, 147 messages, one `agent_end`, one `agent_settled`.
Calls were 58 `bash`, 12 `read`, 2 `edit`, 0 `write`. No
malformed tool call was observed; every call carried valid
arguments for its tool. Four `bash` calls ended `isError` true,
all exit code 1 from the code under test or the model's own
probe scripts: two were the target bug reproducing, one was a
`SyntaxError` in a probe the model wrote, and one probed the
`None` path that raises. Pi surfaced each as a normal tool
result and the agent recovered without retry events, stalls, or
compaction. The inefficiency is the model's: dozens of
redundant one-line Python probes through `bash` re-derived the
same facts about `_type`, `_isbool`, and `_isnumber` before the
first edit at 406.7 s. A person used to Codex or Claude Code
would recognize the shape of the work and find it slow and
repetitive; nothing in the harness layer caused that.

## Contract and compatibility observations

RPC behaved as the shipped 1.5.2 docs describe, under a model,
for the first time in je's evidence. `get_state` before the
prompt echoed the declared assignment (provider
`ollama-local`, model id, base URL, context window 65536,
max output 8192, thinking level `medium`). The `prompt`
response reported disposition `started` and completion arrived
as `agent_settled`, never as the response itself. Ollama's
`/v1` endpoint satisfied Pi's `openai-completions` wire
expectations with no `compat` overrides, including streamed
deltas (8,840 `message_update` records) and usage accounting:
input 56,404 tokens, output 16,044, cache read 1,500,071,
cost 0 as declared, peak context 36,923 of 65,536 (56%).
`PI_OFFLINE=1` did not block inference. Session files on disk
match the documented format: version 3 header, one
`model_change`, one `thinking_level_change`, then message
entries (147 in the main run, 11 in the cancelled run), stored
under the scratch agent dir grouped by working directory.
Orderly stdin-EOF shutdown exited 0 within 0.56 s of settle in
the main run. One probe artifact must not be misread: the
cancel run's driver waited an extra 120 s after settle for a
second settle event it had already consumed, so that run's
spawn-to-exit span (139.4 s) measures the trial driver, not Pi.
Abort itself settled in about 20 ms at the Pi layer; whether
Ollama stopped generating tokens downstream was not directly
observed and stays unproven. The abort also landed between
tool executions, during generation, so abort during a running
`bash` tool and RPC `abort_bash` remain unprobed.

## Timing

All times are wall clock on this laptop at load averages near
8 to 9, far quieter than the baseline trial's host contention,
so these are not a speed comparison against that trial.
Container spawn to first `get_state` response was 2.9 s,
including offline `.venv` provisioning. Prompt send to first
streamed delta was 1.24 s, to first tool call 2.87 s. Prompt
send to settled was 573 s (about 9.6 minutes) across 73 turns,
against the 20-minute bound. Independent suite verification
took 0.76 s. The cancel probe reached abort at 18.72 s and
settled at 18.741 s; the resume probe completed in 0.64 s.

## Discovery claims update

Claims bind to the exact assignment above. "Closed" means this
trial's evidence now proves the point for that assignment; it
transfers to no other model, engine, mode, version, or place.

| Discovery unknown | State after this trial |
| --- | --- |
| Local-model tool-driving quality | Closed here. The 4B artifact drove `read`, `bash`, and `edit` through Pi RPC for 72 calls with no malformed call and finished real coding work. Quality was repetitive but effective on this task. |
| Task qualification | Closed here, one cell. Pi 1.5.2, RPC mode, Ollama 0.40.16 `/v1`, `studio-harness-qwen35:4b` digest above, laptop Docker boundary: bounded pass with independent verification. |
| Session persistence with real content, resume | Closed here. Real sessions persisted as documented; an aborted session resumed under the same assignment with full message continuity (Q04, Q05). |
| Cancellation under load | Partly closed. RPC `abort` during generation settled in about 20 ms with `aborted: true` and no partial edits. Backend inference stop at Ollama, abort during a running `bash` call, and print or JSON mode signals stay unproven. |
| Exit and event behavior under a model | Closed for RPC completed and aborted runs (exit 0 on orderly EOF; settle and stop reasons as documented). Print mode has only the Q01 one-line preflight; JSON mode and interactive runs with a model stay unproven. |
| MCP through the Q16 broker | Remains. Runs used `--no-mcp`; no MCP server was configured or called, by design. Broker-as-only-endpoint, scoping, revocation, and codemode behavior are all still open. |
| Resume across profiles or models | Remains. Resume was same-profile, same-assignment only; stale-route restoration risk is untouched. |
| Native approvals and sandbox | Unchanged proven negative. Safety in this trial came from the external Docker boundary, which the route display would have to name; nothing here is approval parity with Codex or Claude Code. |
| Fork, tree branching, export, compaction | Remain. None was exercised; context peaked at 56%, below compaction pressure. |
| Extension and package runtime, Studio fast and strong assignments, long-session stability | Remain, untouched by this trial. |

## Cleanup and verification of scope

Trial containers ran with `--rm` and none remains. The trial
image was deleted, both scratch trees (the repo-local mount
root and `/tmp/pi-trial-006`, holding workspaces, the scratch
agent dir and sessions, logs, driver, and verify venv) were
removed, and no trial key ever existed beyond the dummy Ollama
value inside the scratch `models.json`. Spot-checks after
cleanup: real `~/.pi/agent` file times unchanged
(`auth.json` and `settings.json` still 2026-11-08,
`models.json` 2026-08-11), the jestudio source checkout the
copies came from is unmodified (its `tabulate/__init__.py`
still carries its 2025 timestamp), and this repository shows
no change other than this document.
