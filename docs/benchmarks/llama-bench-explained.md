# How to read the llama.cpp / Ollama benchmarks in this knowledge base

> Last verified: 2026-11-02 · llama.cpp build 12033 (commit `785322d17`) · Ollama 0.40.13

## 1. What is actually being measured

Generating text with an LLM has two phases with very different speed limits:

| Phase | What happens | Speed limit | Name in results |
|---|---|---|---|
| **Prompt processing** (prefill) | The model reads all prompt tokens at once | Compute (GPU arithmetic) | `pp512` = 512 prompt tokens |
| **Token generation** (decode) | The model produces one token at a time; each token needs a pass over (nearly) all weights | **Memory bandwidth** | `tg128` = 128 generated tokens |

Both are reported in **tokens per second (tok/s)**. A token is roughly three-quarters of an English word. Reading speed is about 5-10 tok/s, so generation above ~15 tok/s already feels fast; prompt processing matters when you paste long documents.

Sanity check that decode is bandwidth-bound: 55 tok/s x 10.9 GB (the model file) = ~600 GB/s of weights streamed per second, which is the order of magnitude of a modern GPU's memory bandwidth.

## 2. `llama-bench` flags used here

```
llama-bench -m MODEL.gguf -ngl 99 -fa on -ctk f16 -ctv f16 -p 512 -n 128 -d 0,8192 -r 3 -o jsonl
```

| Flag | Meaning | Why this value |
|---|---|---|
| `-m` | Model file (GGUF format: weights + metadata) | The quantisation under test |
| `-ngl N` | **N**umber of **G**PU **L**ayers: how many transformer layers live in VRAM. The rest run on the CPU from system RAM | `99` = "all of them" (more than the model has). In the spill tests it is set explicitly: N, N-8, N-16, N-24 |
| `-fa on` | **F**lash **A**ttention: a memory-efficient way to compute attention. Also required to quantise the V half of the KV cache | Standard on modern GPUs; same setting for every run |
| `-ctk` / `-ctv` | Data type of the **K**ey / **V**alue cache. `f16` = 16-bit floats (default), `q8_0` = 8-bit quantised (about half the memory) | Tested both: q8_0 buys context length for ~1-3 % speed |
| `-p 512` | Prompt length to process in the `pp` test | Long enough for a stable number, short enough to be quick |
| `-n 128` | Tokens to generate in the `tg` test | Same reasoning |
| `-d 0,8192` | **D**epth: tokens already in the context *before* measuring. 0 = empty chat; 8192 = a long conversation | Generation slows as context grows; this shows how much |
| `-r 3` | **R**epetitions of each test. Output is mean and standard deviation | One run is not a measurement; 3 shows the noise |
| `-o jsonl` | Output format (one JSON object per test) | Easy to store and re-analyse |

Docker flags around it: `--gpus all` (give the container the GPU), `-v DIR:/models:ro` (mount model files read-only), `--entrypoint /app/llama-bench` (run this program instead of the image default), image pinned by **digest** so the exact build is reproducible.

### Key concepts

- **KV cache**: the model stores the Keys and Values of every earlier token so it never recomputes them. It grows linearly with context length and lives in VRAM, which is why long contexts consume memory.
- **Quantisation**: storing weights with fewer bits. Names like `UD-IQ3_XXS`, `UD-Q3_K_XL`, `Q8_0` encode the scheme: the number is roughly bits per weight, `UD` = Unsloth Dynamic (precision varies by layer), `K`/`IQ` = block-wise schemes, `XXS/S/M/L/XL` = size variants. Fewer bits = smaller and faster, usually slightly lower quality.
- **Spill / offload**: when a model is larger than VRAM, some layers run on the CPU. Decode then also waits for system RAM (a few tens of GB/s instead of hundreds), so speed falls sharply.

## 3. The auto-fit helper (spill tests)

`llama-fit-params` reads only the model metadata and prints how many layers fit in free VRAM:

```
llama-fit-params -m MODEL.gguf -c 8832 -fitc 8832 -fitt 1024 -fa on -ctk f16 -ctv f16
```

| Flag | Meaning |
|---|---|
| `-c 8832` | Context size to plan for: 512 + 128 + 8192, what the deepest test needs |
| `-fitc 8832` | Do not let the fitter shrink the context below that |
| `-fitt 1024` | Keep **1024 MiB** of VRAM free as a safety margin |

Its output is `-c ... -ngl N`; the benchmark then measures at N, N-8, N-16, N-24 layers on the GPU to draw a speed-versus-offload curve.

## 4. The Ollama benchmark (`scripts/bench_ollama.py`)

Same idea, different tool. Per model and context size: 1 cold run (includes model load), then 3 warm runs.

| Setting | Meaning |
|---|---|
| `num_ctx` 8192 / 32768 | Context window allocated (determines KV-cache memory) |
| `num_predict 256` | Stop after 256 generated tokens |
| `temperature 0`, `seed 1` | Deterministic output, so runs are comparable |
| prompt | One fixed ~30-token question, so prompt-processing numbers are not meaningful |
| reported | generation tok/s, load time, share of the model on the GPU (from `/api/ps`), extra VRAM from `nvidia-smi` |

"Thinking" models spend tokens on hidden reasoning; those tokens are counted in tok/s.

## 5. Pitfalls when comparing numbers

- Different tools (Ollama vs llama.cpp), quantisations, context sizes or prompts are **not** comparable.
- `llama-bench` measures raw speed with no chat template, sampling or server overhead; real chat is somewhat slower.
- A background download, another GPU process or a hot GPU changes results. Each run records GPU temperature, clocks and whether a download was running.
- Speed is not quality. None of these runs evaluate answer quality.
