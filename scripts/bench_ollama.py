#!/usr/bin/env python3
"""Reproducible Ollama chat benchmark (stdlib only).

For each model and each num_ctx: unload everything, run 1 cold run (reports load time),
then 3 warm runs with a fixed prompt, temperature 0, seed 1, num_predict 256.
Records tok/s, prompt tok/s, load time, VRAM share (from /api/ps) and GPU memory used.
Output: JSON lines in OUT.
"""
import json, os, statistics, subprocess, sys, time, urllib.request, datetime

HOST = "http://127.0.0.1:11434"
OUT = sys.argv[1]
MODELS = sys.argv[2].split(",")
CTXS = [int(x) for x in sys.argv[3].split(",")]
PROMPT = ("Explain, in about 200 words, how a hash map handles collisions, "
          "then give a short Python example using separate chaining.")


def call(path, payload=None, timeout=900):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(HOST + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def unload_all():
    for m in call("/api/ps").get("models", []):
        call("/api/generate", {"model": m["name"], "keep_alive": 0})
    for _ in range(20):
        if not call("/api/ps").get("models"):
            return
        time.sleep(1)


def gpu_mem():
    o = subprocess.run(["nvidia-smi", "--query-gpu=memory.used,memory.total",
                        "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout
    used, total = [int(x) for x in o.strip().split(",")]
    return used, total


def run(model, ctx):
    return call("/api/generate", {
        "model": model, "prompt": PROMPT, "stream": False, "keep_alive": "5m",
        "options": {"num_ctx": ctx, "num_predict": 256, "temperature": 0, "seed": 1}})


def rec(model, ctx, r, kind):
    return {
        "kind": kind,
        "load_s": round(r["load_duration"] / 1e9, 2),
        "prompt_tokens": r["prompt_eval_count"],
        "prompt_tps": round(r["prompt_eval_count"] / (r["prompt_eval_duration"] / 1e9), 1)
        if r.get("prompt_eval_duration") else None,
        "gen_tokens": r["eval_count"],
        "gen_tps": round(r["eval_count"] / (r["eval_duration"] / 1e9), 2),
    }


def main():
    version = call("/api/version")["version"]
    base_used, total = gpu_mem()
    with open(OUT, "a") as f:
        for model in MODELS:
            for ctx in CTXS:
                unload_all()
                time.sleep(2)
                base_used, total = gpu_mem()
                cold = run(model, ctx)
                ps = [m for m in call("/api/ps")["models"]][0]
                used, _ = gpu_mem()
                warm = [rec(model, ctx, run(model, ctx), "warm") for _ in range(3)]
                tps = [w["gen_tps"] for w in warm]
                row = {
                    "date": datetime.date.today().isoformat(),
                    "ollama": version, "model": model, "num_ctx": ctx,
                    "model_bytes": ps["size"], "vram_bytes": ps["size_vram"],
                    "gpu_share_pct": round(100 * ps["size_vram"] / ps["size"], 1),
                    "gpu_mem_used_mib": used - base_used, "gpu_mem_total_mib": total,
                    "cold": rec(model, ctx, cold, "cold"),
                    "warm_gen_tps_median": statistics.median(tps),
                    "warm_gen_tps_runs": tps,
                    "warm_prompt_tps_median": statistics.median(
                        [w["prompt_tps"] for w in warm if w["prompt_tps"]] or [0]),
                }
                f.write(json.dumps(row) + "\n"); f.flush()
                print(f"{model} ctx={ctx}: gen {row['warm_gen_tps_median']} tok/s, "
                      f"GPU share {row['gpu_share_pct']}%, +{row['gpu_mem_used_mib']} MiB, "
                      f"cold load {row['cold']['load_s']}s", flush=True)
        unload_all()


main()
