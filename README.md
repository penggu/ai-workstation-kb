# ai-workstation-kb

Notes, scripts and measurements from setting up a local-AI workstation (RTX 5070 Ti 16 GB, Windows 11 + WSL2).

- `docs/base/` - machine setup that other pages build on (`tailscale-wsl.md`: reach the WSL machine at a stable address).
- `docs/recipes/` - how to run a workload, with measured results. Start with `qwen-27b-quantisation-16gb.md`; `claude-code-local.md` shows how to run Claude Code on the local model.
- `docs/benchmarks/` - how the measurements are made and what they can and cannot tell you.
- `scripts/` - idempotent, undoable, traced shell scripts (run `setup.sh` / `run-eval-suite.sh` with `plan` first).
- `data/benchmarks/` - raw results behind the tables.

Everything here is a snapshot of one machine on the date in each file. Check "Last verified" before relying on it.

## Checks

`make check` (or `bash scripts/check.sh`) runs everything offline: `bash -n` and `shellcheck` on every shell script, `test-lib.sh` and `test-aiw-llm-ctl.sh` (with `AIW_TEST_MODE=1`), and the MCP unit tests (`python3 -I -m unittest`). It needs no sudo, docker or GPU. If `shellcheck` is missing it is skipped with a warning locally; set `REQUIRE_SHELLCHECK=1` to make that an error. GitHub Actions runs it on every push and PR.

## Licence

- Scripts (`scripts/`): MIT, see `LICENSE`.
- Documentation and data (`docs/`, `data/`): CC BY 4.0, see `LICENSE-docs-data.txt`.
