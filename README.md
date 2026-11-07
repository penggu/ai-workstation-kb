# ai-workstation-kb

Notes, scripts and measurements from setting up a local-AI workstation (RTX 5070 Ti 16 GB, Windows 11 + WSL2). The aim is a system that works day to day, not a comparison of models.

## Start here

1. `docs/base/tailscale-wsl.md` - reach the WSL machine from another computer at a stable address (SSH). Only needed if you work from a second machine.
2. `docs/recipes/claude-code-local.md` - run Claude Code on a local model. It covers both servers (llama.cpp in Docker and Strata), the `--backend` choice, the API key, saved presets, use from a Mac through an SSH tunnel, and the problems met.
3. `docs/recipes/qwen-27b-quantisation-16gb.md` - which quantisation of the 27B model fits 16 GB, with measurements. Read it when you want to change the llama.cpp model.

## Docs

| Folder | What is there |
|---|---|
| `docs/base/` | machine setup that other pages build on (`tailscale-wsl.md`) |
| `docs/recipes/` | how to run a workload, with measured results: `claude-code-local.md`, `qwen-27b-quantisation-16gb.md`, `llm-chat.md` (Ollama chat) |
| `docs/research/` | sourced reading notes: `strata-telemetry-and-api-key.md` (what Strata sends, how its key works) |
| `docs/benchmarks/` | how the measurements are made and what they can and cannot tell you |
| `docs/agents/` | how the issue tracker and domain docs are laid out, for coding agents |
| `data/benchmarks/` | raw results behind the tables |

There is no page yet for the root-owned controller (`aiw-llm-ctl`, installed by `sudo-local-llm.sh`) that lets the normal user start and stop the llama.cpp container without a sudo password or docker access; its design is in the two scripts' headers (issue #12).

## Scripts

Every setup script is idempotent, undoable and leaves a debug trace. Run `setup.sh` / `run-eval-suite.sh` with `plan` first, and the others with `status` or `--dry-run`.

| Path | What it does |
|---|---|
| `scripts/setup/docker-gpu/local-llm.sh` | start, stop and restart the llama.cpp server container |
| `scripts/setup/docker-gpu/sudo-local-llm.sh`, `aiw-llm-ctl.template` | the passwordless controller for that container |
| `scripts/setup/docker-gpu/claude-local.sh` | one Claude Code session on a local server: `--backend llama\|strata\|auto`, local or through an SSH tunnel |
| `scripts/setup/docker-gpu/setup.sh`, `steps.sh`, `lib.sh` | one-time machine setup and the shared helpers |
| `scripts/setup/docker-gpu/run-eval-suite.sh` and the `eval-*`, `bench-*`, `fit-memory.sh` scripts | the measurements behind the recipes |
| `scripts/setup/strata/strata.sh` | install the Strata terminal (the model and engine are downloaded by hand, see the recipe) |
| `scripts/setup/tailscale/tailscale.sh` | install and join Tailscale in WSL |
| `scripts/mcp/web_search_mcp.py` | the web-search tool that `claude-local.sh` gives the local session |
| `scripts/check.sh` | the offline checks, below |

## Checks

`make check` (or `bash scripts/check.sh`) runs everything offline: `bash -n` and `shellcheck` on every shell script, `test-lib.sh`, `test-aiw-llm-ctl.sh` and `test-claude-local.sh` (with `AIW_TEST_MODE=1`), and the MCP unit tests (`python3 -I -m unittest`). It needs no sudo, docker or GPU. `test-lib.sh` and `test-aiw-llm-ctl.sh` assume GNU coreutils and bash >= 4.4 (i.e. WSL Ubuntu); on macOS they are skipped with a note, since macOS ships bash 3.2 and a BSD `stat`/`realpath` — CI (ubuntu-latest) still runs them. `test-claude-local.sh` runs everywhere. If `shellcheck` is missing it is skipped with a warning locally; set `REQUIRE_SHELLCHECK=1` to make that an error. GitHub Actions runs it on every push and PR.

## Reading the pages

Everything here is a snapshot of one machine on the date in each file. Check "Last verified" before relying on it, and read the "not verified" lists: a claim is only as strong as the measurement behind it.

## Licence

- Scripts (`scripts/`): MIT, see `LICENSE`.
- Documentation and data (`docs/`, `data/`): CC BY 4.0, see `LICENSE-docs-data.txt`.
