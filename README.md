# ai-workstation-kb

Notes, scripts and measurements from setting up a local-AI workstation (RTX 5070 Ti 16 GB, Windows 11 + WSL2).

- `docs/base/` - machine setup that other pages build on (`tailscale-wsl.md`: reach the WSL machine at a stable address).
- `docs/recipes/` - how to run a workload, with measured results. Start with `qwen-27b-quantisation-16gb.md`; `claude-code-local.md` shows how to run Claude Code on the local model.
- `docs/benchmarks/` - how the measurements are made and what they can and cannot tell you.
- `scripts/` - idempotent, undoable, traced shell scripts (run `setup.sh` / `run-eval-suite.sh` with `plan` first).
- `data/benchmarks/` - raw results behind the tables.

Everything here is a snapshot of one machine on the date in each file. Check "Last verified" before relying on it.

## Licence

- Scripts (`scripts/`): MIT, see `LICENSE`.
- Documentation and data (`docs/`, `data/`): CC BY 4.0, see `LICENSE-docs-data.txt`.
