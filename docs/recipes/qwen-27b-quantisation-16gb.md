# Choosing a quantisation of a 27B model for a 16 GB GPU (llama.cpp in Docker, WSL2)

> **Last verified:** 2026-11-02 · **Status:** draft · **Model:** Qwen3.8-27B GGUF (Unsloth "UD" quants + Q8_0) · **Engine:** llama.cpp `full-cuda` image pinned by digest (digest and build are recorded in every raw data row)
>
> Machine and setup: see `llm-chat.md`. Method and limits of each measurement: `../benchmarks/eval-suite.md`. Full printed report: `data/benchmarks/eval-suite-report-2026-11-02.txt`.

## Short answer

| If you want... | Use | Why (numbers below) |
|---|---|---|
| A daily driver for long-context coding (64K) | **`UD-IQ3_S` + `-ctk q8_0 -ctv q8_0`** | fits 73.8K tokens; 42 tok/s at 32K depth; 27 % lower KL than `IQ3_XXS` |
| Better quality, context up to about 40K | `UD-Q3_K_XL` + q8_0 KV | fits 43.6K; KL 30 % lower than `IQ3_S`; about 4 % slower at short depth |
| The most context, quality secondary | `UD-IQ3_XXS` + q8_0 KV | fits 101K; fastest (53.5 tok/s) |
| Quality matters more than speed | `UD-Q4_K_M`, about 9.7 tok/s | KL 0.017, but 57 of 65 layers on the GPU and the rest on the CPU |

Everything above `UD-IQ4_XS` either does not fit in 16 GB with a usable context, or spills to the CPU and falls to single-digit tok/s. `UD-IQ4_XS` fits but only to about 12K tokens, too short for agentic coding.

**What this does not tell you:** which of these produces better code on your real tasks. KL measures distance from Q8_0, not correctness; the coding gate (24 samples) cannot rank neighbouring quants. See "Limits".

## 1. Memory: how much context fits

Method: `llama-fit-params` (llama.cpp's own estimator) per quant x KV type x 10 context sizes. Budget = 16303 MiB total - 1441 MiB used by the Windows desktop - 1024 MiB safety margin = 13838 MiB. Raw: `data/benchmarks/fit-memory-2026-11-02.jsonl`.

| Quant | File (GiB) | Max context, f16 KV | Max context, q8_0 KV |
|---|---:|---:|---:|
| `UD-IQ3_XXS` | 10.2 | 54,807 | 101,426 |
| `UD-IQ3_S` | 11.2 | 39,825 | 73,845 |
| `UD-Q3_K_XL` | 12.2 | 23,520 | 43,563 |
| `UD-IQ4_XS` | 13.3 | 6,585 | 12,112 |
| `UD-Q4_K_M` | 15.3 | does not fit | does not fit |
| `UD-Q5_K_M` | 18.4 | does not fit | does not fit |
| `Q8_0` | 27.0 | does not fit | does not fit |

"Max context" is interpolated between the measured context sizes. The result is the largest context for which the whole model plus KV cache plus compute buffers fits in the budget. Without the 1 GiB margin, roughly 1.3x to 1.7x more fits, but then the desktop has no room to grow.

- **q8_0 KV roughly doubles the context that fits.** The model is hybrid: only about every fourth layer uses full attention, so its KV cache is small for a 27B, but it still dominates at long context.
- **Estimator:** weights-on-GPU is close to linear in file size (`0.9446 x file - 129 MiB`). Fitted on four quants, it predicted the other three (`IQ3_S`, `IQ4_XS`, `Q4_K_M`) to within 102 MiB for weights, and the largest context to within about -3 % to +8 %. Predictions were written down before measuring (`data/benchmarks/fit-memory-predictions-before-measuring-2026-11-02.txt`). Extrapolating beyond the fitted range is worse (up to 412 MiB off for `Q8_0`).

## 2. Quality: distance from Q8_0

Method: `llama-perplexity --kl-divergence` against saved Q8_0 logits, 32 chunks x 2048 tokens of code (the owner's own Python/Shell/PowerShell, 29 files, about 570 KB). Lower KLD = closer. Raw: `data/benchmarks/eval-kl-2026-11-02.jsonl`.

| Quant | Size (GiB) | Mean KLD | ± se | Same top token | PPL (ref 3.145) |
|---|---:|---:|---:|---:|---:|
| `UD-Q5_K_M` | 18.41 | 0.0090 | 0.0011 | 97.5 % | 3.144 |
| `UD-Q4_K_M` | 15.33 | 0.0174 | 0.0016 | 96.4 % | 3.147 |
| `UD-IQ4_XS` | 13.27 | 0.0265 | 0.0018 | 95.2 % | 3.156 |
| `UD-Q3_K_XL` | 12.24 | 0.0395 | 0.0019 | 93.9 % | 3.180 |
| `UD-IQ3_S` | 11.21 | 0.0563 | 0.0025 | 92.6 % | 3.202 |
| `UD-IQ3_XXS` | 10.18 | 0.0769 | 0.0023 | 90.9 % | 3.290 |

- Each step up lowers KLD by roughly 27-34 % (`Q4_K_M` to `Q5_K_M`: 48 %). Neighbouring quants differ by 3.8-6.1 reported standard errors.
- The reported standard errors treat tokens as independent; tokens in one text are correlated, so the true uncertainty is larger. The ordering is unlikely to flip given the gaps, but the exact percentages should be read as approximate.
- Perplexity barely separates the top four (within 0.4 % of the reference); KLD does, which is why it was used.
- **Reference is Q8_0, not BF16.** Q8_0 has its own small error.
- Corpus is one person's code in three languages. Other languages or prose could rank differently.

## 3. Speed

Method: `llama-bench`, `-fa on`, `-p 512 -n 128`, `-r 3` (mean ± sd), 6 CPU threads (6 beat the default 8 by about 12 % for spilled runs). Depths are chosen from the memory measurements so every point fits. Raw: `data/benchmarks/llama-ladder-2026-11-02.jsonl`.

### 3a. Models that fit entirely in VRAM: generation (tok/s) by context depth

| Quant + KV | 0 | 8K | 16K | 32K | 48K | 64K |
|---|---:|---:|---:|---:|---:|---:|
| `IQ3_XXS` f16 | 54.2 | 52.5 | 51.3 | 47.9 | 44.8 | - |
| `IQ3_XXS` q8_0 | 53.5 | 51.8 | 49.2 | 45.0 | 40.9 | 37.7 |
| `IQ3_S` f16 | 52.2 | 50.9 | 48.6 | 45.9 | - | - |
| `IQ3_S` q8_0 | 51.6 | 49.7 | 45.2 | 42.2 | 39.4 | 36.5 |
| `Q3_K_XL` f16 | 49.9 | 48.6 | 47.0 | - | - | - |
| `Q3_K_XL` q8_0 | 49.6 | 47.7 | 45.4 | 41.8 | - | - |
| `IQ4_XS` f16 | 48.0 | - | - | - | - | - |
| `IQ4_XS` q8_0 | 47.7 | 45.8 | - | - | - | - |

("-" = that depth does not fit in memory; `IQ4_XS` f16 was also measured at 4K: 47.5.)

- Speed falls with depth because attention reads the whole KV cache for every token: about 30 % from depth 0 to 64K for q8_0.
- **q8_0 KV costs 1-2 % at depth 0 and 7-9 % at 16K-48K**, compared with f16 at the same depth (e.g. `IQ3_S` at 16K: 48.6 vs 45.2). Earlier in this work "only 1-3 %" was stated; that held only up to 8K depth.
- Prompt processing (pp512, tok/s), `IQ3_S` q8_0: 1970 at depth 0, 1520 at 16K, 1146 at 32K, 839 at 64K. Reading a 64K prompt therefore takes on the order of a minute.

### 3b. Models that spill to the CPU (f16 KV, depth 0)

| Quant | GPU layers (of 65) | Generation (tok/s) | Prompt (tok/s) |
|---|---:|---:|---:|
| `Q4_K_M` | 57 (auto-fit) / 49 / 41 / 33 | 9.7 / 6.0 / 4.2 / 3.2 | 907 / 667 / 499 / 397 |
| `Q5_K_M` | 46 (auto-fit) / 38 / 30 / 22 | 4.6 / 3.3 / 2.6 / 2.2 | 429 / 389 / 290 / 260 |
| `Q8_0` | 32 (auto-fit) / 24 / 16 / 8 | 2.0 / 1.6 / 1.4 / 1.2 | 233 / 206 / 173 / 151 |

- At 8K depth: `Q4_K_M` 8.3, `Q5_K_M` 3.6, `Q8_0` 1.7 tok/s.
- Moving layers to the CPU costs speed with no knee: the CPU side (dual-channel DDR4, PCIe 3.0) is the bottleneck for every token.
- **Comparison with Ollama** (same hardware, `qwen3.8:27b` default 4-bit, `llm-chat.md` 3b): 9.0 tok/s at 8K context. Running Ollama's own GGUF file in llama.cpp gave 7.71 tok/s, i.e. 14 % slower than Ollama on the identical file (engine or settings; I did not isolate which). So the 9.7 above for `Q4_K_M` is not evidence that llama.cpp is faster: it is a different, slightly smaller file with more layers on the GPU. Raw: `data/benchmarks/diag-spill-2026-11-02.jsonl`.

## 4. Coding gate (not a ranking)

Method: 8 short coding tasks from a private evaluation set (not published), 3 seeds each, hidden unit tests, thinking off (instruct sampling: T 0.7, top-p 0.8, presence 1.5, max 1800 tokens), served by `llama-server` with f16 KV, 4 parallel slots. Raw: `data/benchmarks/eval-short-2026-11-02.jsonl`.

| Quant | Passed | 95 % CI (Wilson) | Failed tasks (count) |
|---|---:|---|---|
| `UD-IQ3_XXS` | 22/24 | 74-98 % | `lru_cache` 1, `evaluate` 1 |
| `UD-IQ3_S` | 22/24 | 74-98 % | `lru_cache` 2 |
| `UD-Q3_K_XL` | 22/24 | 74-98 % | `evaluate` 2 |
| `UD-IQ4_XS` | 21/24 | 69-96 % | `lru_cache` 1, `evaluate` 2 |
| `UD-Q4_K_M` | 20/24 | 64-93 % | `lru_cache` 1, `evaluate` 3 |
| `UD-Q5_K_M` | 24/24 | 86-100 % | none |
| `Q8_0` | 23/24 | 80-99 % | `lru_cache` 1 |

No answers were truncated and no requests failed. The earlier baseline for a 3-bit 27B was 21/24.

- **All intervals overlap heavily; 24 samples cannot separate these quants.** The order is not monotonic in bit-width (`Q4_K_M` lowest, `Q5_K_M` highest, `Q8_0` one below `Q5_K_M`), which points to noise, not to a real effect. Do not pick a quant from this table.
- What it does show: no quant is broken for short coding tasks.
- All failures are on two of the eight tasks. A typical `lru_cache` failure is `NameError: Node` (a helper class that was never defined); `evaluate` failures are parsing errors. That is a model weakness at this size, not a quantisation effect.
- Wall time in the table of the full report is dominated by CPU offload for `Q4_K_M` and up (the server auto-fits layers), not a speed benchmark.

## 5. Reproduce

All steps are scripts in `scripts/setup/docker-gpu/`; each is idempotent, writes a trace under `~/.local/state/ai-workstation/<step>/`, and has an undo that removes only files the script generated.

```bash
cd scripts/setup/docker-gpu
./run-eval-suite.sh plan
./run-eval-suite.sh apply        # asks for sudo once; about 2.5-3 h in total on this machine
./run-eval-suite.sh report       # saves the full report under data/benchmarks/
```

Server flags used by the coding gate (verified to start and serve on this image; not yet used for long agent sessions):

```
llama-server -m <gguf> --jinja --reasoning off --no-webui -np 4 -t 6 -fit on -fitt 1024 \
             -ctk q8_0 -ctv q8_0 -c <ctx>
```

(`-ctk/-ctv q8_0` and `-c` are what you add for long-context coding; the gate itself ran with f16 KV and `-c 16384`. Bind to loopback and set an API key before exposing it.)

## 6. Limits

- Speed numbers: one machine, one day, one pinned image. Spilled runs are the noise-sensitive ones.
- KL: a proxy. It says how far a quant is from Q8_0, not how often the code it writes is wrong.
- The coding gate cannot rank good quants, and thinking mode (the model's default) was not tested.
- No test with real long agentic sessions (tool calls, file edits, 50K+ prompts). That is where `IQ3_S` and `Q3_K_XL` may differ in practice, and it is the missing evidence for the recommendation above.

## 7. Next

- Thinking-mode run: `./run-eval-suite.sh apply --only 6 --with-thinking` (4 quants, about 1-2 h).
- A larger, repo-based coding evaluation (more tasks, more seeds) to separate `IQ3_S` from `Q3_K_XL`.
