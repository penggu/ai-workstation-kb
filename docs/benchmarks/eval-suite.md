# Evaluating quantisations of a 27B model on a 16 GB GPU

> Status: draft, 2026-11-02. Scripts live in `scripts/setup/docker-gpu/`. Everything is reproducible with one command; each step can also be run alone.

Results from the first full run (2026-11-02) are in `../recipes/qwen-27b-quantisation-16gb.md`.

## What the suite answers

| Question | Step | Why this measurement |
|---|---|---|
| How much VRAM does a quant need at a given context length? | `fit-memory.sh` | llama.cpp's own estimator, metadata only; fast and exact enough to plan with |
| How far is each quant from the highest-precision one? | `eval-kl.sh` | mean KL divergence against Q8_0 on real code: continuous and low-noise, ranks quants that a pass-rate cannot |
| How fast is it, and how does speed fall with context depth? | `bench-ladder.sh --tier fit` | `llama-bench`, depth ladder picked from the measured memory limit |
| How does speed fall when layers spill to the CPU? | `bench-ladder.sh --tier spill` | auto-fit layer count, then fewer layers on the GPU; 6 CPU threads |
| Is a quant broken for coding? (a gate, not a ranking) | `eval-short.sh` | 8 short tasks x 3 seeds with hidden tests; 24 samples cannot separate two good quants |

## Run it

```bash
cd scripts/setup/docker-gpu
./run-eval-suite.sh plan                 # what is left to do
./run-eval-suite.sh apply --dry-run      # what each step would do
./run-eval-suite.sh apply                # runs the steps in order, stops at the first failure
./run-eval-suite.sh report               # all reports, saved under data/benchmarks/
./run-eval-suite.sh undo                 # reverse order, each step removes only the files it generated
```

Options: `--from N`, `--only N,M`, `--skip N,M`, `--with-thinking` (adds a thinking-mode coding run for the quants that fit), `--yes`.

Re-running after a failure resumes: finished jobs are skipped, partly finished ones continue (a spill sweep keeps its finished points; an interrupted coding run keeps its graded samples).

## Rules the scripts follow

- **Idempotent**: every step checks the real state first.
- **Undoable**: every step has its own undo; the suite undoes in reverse order. Undo deletes only files the script generated (it tracks them), never a whole folder it did not create.
- **Traced**: each run writes a human log, a bash xtrace and a `last-error.txt` under `~/.local/state/ai-workstation/<step>/`.
- **Clean measurements**: before each measurement the scripts refuse to start if another benchmark or server is running, or if something else holds the GPU. A running model download is allowed but recorded in the data (`download_running`).
- The llama.cpp image is pinned by digest; the build and commit are recorded with every row.

## Method notes and limits

- **Memory estimates** are made from the file size alone (weights-on-GPU is linear in file size; KV and compute buffers do not depend on the quant). Checked on seven quants: weights within about 100 MiB for interpolated quants (mean 189 MiB, worst 412 MiB when extrapolating); the largest context that fits is within about -3 % to +8 %, with no fixed direction.
- **KV cache type** (f16 vs q8_0) costs 1-2 % generation speed at short depth and up to about 9 % at 48K depth; its benefit is memory (about 2x the context).
- **CPU-offloaded runs** are the noise-sensitive ones: use a fixed thread count (6 beat the default 8 by about 12 % here), stop other CPU/IO work and do not run two benchmarks at once.
- **KL divergence** measures damage from quantisation, not coding ability. The corpus is built from the machine owner's own code and is never published; only aggregate numbers are.
- **The coding gate** can say a configuration is broken; it cannot rank two good ones. Truncated answers (`finish_reason == length`) are counted separately from wrong answers.
- Thinking mode is the model's default; the gate runs with thinking off to stay comparable with earlier baselines unless `--with-thinking` is given.
