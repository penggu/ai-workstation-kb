# Local LLM chat with Ollama (RTX 5070 Ti 16 GB, WSL2)

> **Last verified:** 2026-11-02 · **Ollama:** 0.40.13 · **Status:** draft, template for other recipes

## Reference machine

| Item | Value |
|---|---|
| GPU | NVIDIA GeForce RTX 5070 Ti, 16 GB (Blackwell) |
| CPU / RAM | Intel Core i7-9700F (8 cores, PCIe 3.0) / 64 GB DDR4 |
| OS | Windows 11 Pro host, Ubuntu 26.04 in WSL2 (kernel 6.18, systemd on) |
| Driver | Windows NVIDIA driver 617.42 (CUDA UMD 13.4); **no Linux driver in WSL** |
| Network | Wi-Fi, ~72 Mbit/s link (downloads were ~6 MB/s; wired is much faster) |

PCIe 3.0 and DDR4 matter when a model spills out of VRAM. Everything below fit entirely in VRAM, so they did not affect these numbers.

## 1. Install (native, pinned)

Ollama's installer detects WSL2 and **does not install a Linux GPU driver**; it only checks that `nvidia-smi` works.

```bash
sudo apt install -y zstd
curl -fsSL https://ollama.com/install.sh -o ~/ollama-install.sh
less ~/ollama-install.sh                       # read it first
OLLAMA_VERSION=0.40.13 sh ~/ollama-install.sh  # no leading "v": "v0.40.13" gives a 404
```

The installer is a third-party script and changes over time, so it is not copied into this repository. The copy that was read and run for this recipe (downloaded 2026-11-02, 15,902 bytes) has this fingerprint:

```bash
sha256sum ~/ollama-install.sh
# 25f64b810b947145095956533e1bdf56eacea2673c55a7e586be4515fc882c9f  (reviewed 2026-11-02)
```

A different hash means the official script has been updated: read it again before running it. The same hash only tells you that you have the file that was reviewed; it is not a statement that the script is safe.

Verify:

```bash
ollama --version                  # 0.40.13
systemctl is-active ollama        # active
ss -tlnp | grep 11434             # must show 127.0.0.1:11434, NOT 0.0.0.0
nvidia-smi --query-gpu=name,driver_version --format=csv,noheader
```

**Security:** the Ollama API has no authentication. Keep it on loopback. To use it from another machine, tunnel it:

```bash
ssh -N -L 11434:localhost:11434 <your-gpu-host>   # then use http://localhost:11434 locally
```

## 2. Models tested

| Model tag | Download | Notes |
|---|---|---|
| `qwen3.5:9b` | 6.6 GB | tools + thinking, 256K context window |
| `gpt-oss:20b` | 14 GB | tools + thinking, 128K context window |

```bash
ollama pull qwen3.5:9b
ollama pull gpt-oss:20b
ollama run gpt-oss:20b --verbose       # --verbose prints tokens/s after each reply
ollama ps                              # PROCESSOR column should read "100% GPU"
```

## 3. Results

Fixed prompt, `temperature=0`, `seed=1`, `num_predict=256`. Median of 3 warm runs after one cold run. Raw data: `data/benchmarks/ollama-chat-2026-11-02.jsonl`.

| Model | `num_ctx` | Generation (tok/s) | GPU share | Extra VRAM used | Cold load |
|---|---:|---:|---:|---:|---:|
| qwen3.5:9b | 8 192 | 76.8 | 100 % | 6.7 GiB | 40 s |
| qwen3.5:9b | 32 768 | 77.2 | 100 % | 7.6 GiB | 3.4 s |
| gpt-oss:20b | 8 192 | 131.6 | 100 % | 12.6 GiB | 26 s |
| gpt-oss:20b | 32 768 | 127.9 | 100 % | 13.2 GiB | 4.0 s |

Run-to-run spread was within about 5 %.

## 3b. A model larger than VRAM (dense 27B, partial CPU offload)

`qwen3.8:27b` from the Ollama library (default tag, 18 GB download, 4-bit). Same method and prompt as above. Raw data: `data/benchmarks/ollama-chat-27b-spill-2026-11-02.jsonl`.

| Model | `num_ctx` | Generation (tok/s) | Share of model on GPU | Model size / on GPU | Cold load |
|---|---:|---:|---:|---:|---:|
| qwen3.8:27b | 8 192 | 9.0 | 73 % | 18.4 GB / 13.4 GB | 7.7 s |
| qwen3.8:27b | 32 768 | 6.8 | 64 % | 19.1 GB / 12.1 GB | 7.1 s |

- Ollama chose the split automatically and kept roughly 2 GiB of VRAM free (it used ~14.2 GiB of 16 GiB in both runs).
- A larger context lowers the GPU share: the KV cache takes VRAM that would otherwise hold layers, so more layers run on the CPU.
- The speed drop is steep: about 5 GB of weights were on the CPU, and a dense model must read all of its weights for every token. Rough sanity check: dual-channel DDR4 gives a few tens of GB/s, so ~5 GB per token puts the ceiling in the single-digit to low-teens tok/s range, which matches. This is an explanation consistent with the numbers, not something I isolated.
- Prompt processing was only ~80-95 tok/s here (short prompt, so treat as a rough figure).
- **Not comparable** to llama.cpp numbers from other stacks or other quantisations (a 3-bit file that fits entirely in VRAM is a different situation).

### What the numbers mean

- **Both models fit entirely in 16 GB**, even at a 32K context. `gpt-oss:20b` leaves about 3 GiB of headroom at 32K; a much longer context or a second model loaded at the same time will not fit.
- `gpt-oss:20b` was about 1.7x faster than the smaller `qwen3.5:9b`. I did not verify why; the likely reason is that its architecture activates far fewer parameters per token, but check the model card rather than trusting this note.
- Context length cost little speed here (8K to 32K), but it costs VRAM.
- "Cold load" is the first load after unloading. The 26-40 s first-load times dropped to ~3-4 s for the second context size once files were cached. I did not isolate how much of the first-load time is disk read versus one-time GPU initialisation.

### Caveats

- **Speed only, not quality.** I did not evaluate answer quality. Pick on your own tasks.
- Both are "thinking" models; the token counts include thinking tokens.
- The prompt was short (~30 tokens), so the prompt-processing speeds in the raw data are not a reliable measure of long-prompt performance.
- One prompt, one machine, one day. Treat as ballpark.

## 4. Reproduce

```bash
python3 scripts/bench_ollama.py out.jsonl qwen3.5:9b,gpt-oss:20b 8192,32768
```

Stop other GPU work first. The script only needs the Python standard library.

## 5. Where models live

Ollama stores models under `/usr/share/ollama/.ollama/models` on the WSL ext4 disk. Keep actively used models there (measured 4.6 GB/s sequential read, versus ~330 MB/s for a Windows drive mounted under `/mnt`). Use a Windows drive only as cold archive; copy to ext4 before running.

## 6. Known issues / gotchas

- `OLLAMA_VERSION` must not have a leading `v`.
- `/usr/share/ollama` is owned by the `ollama` user, so `du` on it as a normal user fails with "Permission denied".
- Wi-Fi downloads were slow (~6 MB/s). Use Ethernet for large models.

## 7. Next

- Done: a 27B model's quantisation ladder, memory, speed, spill and quality measured with llama.cpp in Docker: see `qwen-27b-quantisation-16gb.md`.
- Still open: larger MoE models that spill out of VRAM.
- Open WebUI front end.
- A coding-agent harness against the same local API.
