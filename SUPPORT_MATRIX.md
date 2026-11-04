# Launch support matrix

The machine-readable matrix in `JECore` is the source of truth. Print it with:

```sh
swift run je support-matrix --json
```

## Dimensions

Each cell names one model role, one engine family, one harness or built-in
path, one launch mode, and one execution place.

| Dimension | Launch values |
| --- | --- |
| Roles | `fast`, `strong` |
| Engines | `ollama`, `mlx_native`, `lm_studio`, `llama_cpp` |
| Harnesses | `codex`, `claude_code`, `muse`, `built_in` |
| Launch modes | `interactive`, `headless`, `single_step` for the built-in path |
| Places | `personal_machine`, `studio_workspace` |

The first published matrix has 112 cells. Muse headless cells are marked
`blocked_on_contract_discovery`. Other unqualified cells are marked `planned`.

## Rules

- A cell counts as complete only with a current recorded qualification pass.
- A failed cell is not removed after results are read to preserve a claim.
- A cell can be declared unsupported only ahead of qualification and under a
  settled contract reason.
- Passing a named workflow is evidence for covered cells. It does not qualify
  the whole matrix.
- December success under the Final roadmap requires every required cell in
  this launch matrix to be complete.
