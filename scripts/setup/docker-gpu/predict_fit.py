#!/usr/bin/env python3
"""Predict GPU memory needs of a quantisation from its file size, then compare with the fit-memory.sh measurement.

usage: predict_fit.py RESULTS_DIR MODEL_DIR MARGIN_MIB [--loo] [--quants q1,q2,...]

Method (all numbers come from fit-memory.sh measurements, nothing is assumed):
  * weights on the GPU  = a * file_size + b      (least squares over the BASELINE quants that were measured)
  * KV cache            = slope * ctx + intercept (per KV type, measured on UD-IQ3_XXS: it does not depend on the quant)
  * compute buffer      = interpolated from the UD-IQ3_XXS measurements
  * budget              = total VRAM - VRAM used by the desktop at measurement time - margin
The prediction is made WITHOUT looking at the measurement of the quant being predicted.
  default mode: predict every target quant whose file size is known, and show the measurement next to it when it exists
  --loo       : leave-one-out check of the method on the baseline quants themselves (honest error bars)
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from maxctx import max_context  # noqa: E402

BASELINE = ["UD-IQ3_XXS", "UD-Q3_K_XL", "UD-Q5_K_M", "Q8_0"]
TARGETS = ["UD-IQ3_S", "UD-IQ4_XS", "UD-Q4_K_M"]
# file sizes in MiB from the Hugging Face API (unsloth/Qwen3.8-27B-GGUF), used only if the file is not on disk yet
HF_SIZES_MIB = {"UD-IQ3_S": 11483, "UD-IQ4_XS": 13593, "UD-Q4_K_M": 15702, "UD-Q4_K_S": 14647}
KVS = ["f16", "q8_0"]


def load(results):
    rows = {}
    for f in glob.glob(os.path.join(results, "*.jsonl")):
        if not os.path.exists(f[:-6] + ".ok"):
            continue
        for line in open(f):
            if line.strip():
                r = json.loads(line)
                rows.setdefault((r["quant"], r["kv"]), []).append(r)
    for k in rows:
        rows[k].sort(key=lambda r: r["ctx"])
    return rows


def file_mib(model_dir, q):
    p = os.path.join(model_dir, f"Qwen3.8-27B-{q}.gguf")
    if os.path.exists(p) and os.path.getsize(p) > 1 << 20:
        return os.path.getsize(p) / 2**20, "disk"
    return HF_SIZES_MIB.get(q), "hf-api"


def fit_line(points):
    n = len(points)
    sx = sum(x for x, _ in points); sy = sum(y for _, y in points)
    sxx = sum(x * x for x, _ in points); sxy = sum(x * y for x, y in points)
    a = (n * sxy - sx * sy) / (n * sxx - sx * sx)
    return a, (sy - a * sx) / n


def kv_model(rows, kv):
    s = rows[("UD-IQ3_XXS", kv)]
    (c1, k1), (c2, k2) = (s[0]["ctx"], s[0]["dev_context_mib"]), (s[-1]["ctx"], s[-1]["dev_context_mib"])
    sl = (k2 - k1) / (c2 - c1)
    return sl, k1 - sl * c1


def compute_at(rows, kv, ctx):
    s = [(r["ctx"], r["dev_compute_mib"]) for r in rows[("UD-IQ3_XXS", kv)]]
    for (c1, v1), (c2, v2) in zip(s, s[1:]):
        if c1 <= ctx <= c2:
            return v1 + (v2 - v1) * (ctx - c1) / (c2 - c1)
    return s[-1][1]


def predicted_need(rows, line, fmib, kv, ctx):
    sl, ic = kv_model(rows, kv)
    return line[0] * fmib + line[1] + sl * ctx + ic + compute_at(rows, kv, ctx)


def predicted_max_ctx(rows, line, fmib, kv, limit):
    lo, hi = 0, 262144
    while hi - lo > 64:
        mid = (lo + hi) // 2
        if predicted_need(rows, line, fmib, kv, mid) > limit:
            hi = mid
        else:
            lo = mid
    return lo


def main():
    a = sys.argv[1:]
    loo = "--loo" in a
    a = [x for x in a if x != "--loo"]
    quants = None
    if "--quants" in a:
        i = a.index("--quants"); quants = a[i + 1].split(","); del a[i:i + 2]
    results, model_dir, margin = a[0], a[1], int(a[2])
    rows = load(results)
    base_have = [q for q in BASELINE if (q, "f16") in rows and file_mib(model_dir, q)[0]]
    if len(base_have) < 3 or ("UD-IQ3_XXS", "f16") not in rows:
        sys.exit("need the measurements of at least 3 baseline quants incl. UD-IQ3_XXS (run fit-memory.sh apply first)")
    ref = rows[("UD-IQ3_XXS", "f16")][0]
    free = ref["vram_total_mib"] - ref["vram_used_at_run_mib"]
    budgets = {"with margin": free - margin, "no margin": free}
    print(f"VRAM: {ref['vram_total_mib']} MiB total, {ref['vram_used_at_run_mib']} MiB used by the desktop -> "
          f"{free} MiB free; budget with a {margin} MiB margin = {free - margin} MiB\n")

    def line_for(excluded=None):
        pts = []
        for q in base_have:
            if q == excluded:
                continue
            pts.append((file_mib(model_dir, q)[0], rows[(q, "f16")][0]["dev_model_mib"]))
        return fit_line(pts), pts

    if loo:
        print("LEAVE-ONE-OUT: predict each baseline quant from the other baseline quants")
        print(f"{'quant':<12} {'file MiB':>9} {'predicted':>10} {'measured':>9} {'error MiB':>10}")
        errs = []
        for q in base_have:
            ln, _ = line_for(q)
            f = file_mib(model_dir, q)[0]
            pred = ln[0] * f + ln[1]
            meas = rows[(q, "f16")][0]["dev_model_mib"]
            errs.append(pred - meas)
            print(f"{q:<12} {f:>9.0f} {pred:>10.0f} {meas:>9d} {pred - meas:>+10.0f}")
        print(f"\nweights: mean |error| {sum(abs(e) for e in errs) / len(errs):.0f} MiB, worst {max(abs(e) for e in errs):.0f} MiB\n")
        print("Max context that fits (tokens), predicted without using that quant's own measurement")
        print(f"{'quant':<12} {'KV':<5} {'budget':<12} {'predicted':>10} {'measured':>9} {'error':>8}")
        for q in base_have:
            ln, _ = line_for(q)
            f = file_mib(model_dir, q)[0]
            for kv in KVS:
                if (q, kv) not in rows:
                    continue
                for name, lim in budgets.items():
                    p = predicted_max_ctx(rows, ln, f, kv, lim)
                    m = max_context(rows[(q, kv)], margin if name == "with margin" else 0)
                    print(f"{q:<12} {kv:<5} {name:<12} {p:>10,} {m:>9,} {p - m:>+8,}")
        return

    ln, pts = line_for()
    print(f"weights-on-GPU line from {len(pts)} baseline quants: dev = {ln[0]:.4f} * file + {ln[1]:.0f}\n")
    targets = quants or TARGETS
    print(f"{'quant':<11} {'file MiB':>9} | {'weights MiB':^21} | {'max ctx f16 (margin / none)':^30} | {'max ctx q8_0 (margin / none)':^30}")
    print(f"{'':<11} {'':>9} | {'predicted':>9} {'measured':>11} | {'predicted':>13} {'measured':>14} | {'predicted':>13} {'measured':>14}")
    verdicts = []
    for q in targets:
        f, src = file_mib(model_dir, q)
        if f is None:
            print(f"{q:<11} (file size unknown)")
            continue
        wp = ln[0] * f + ln[1]
        wm = rows[(q, "f16")][0]["dev_model_mib"] if (q, "f16") in rows else None
        cells = []
        for kv in KVS:
            p1 = predicted_max_ctx(rows, ln, f, kv, budgets["with margin"])
            p0 = predicted_max_ctx(rows, ln, f, kv, budgets["no margin"])
            if (q, kv) in rows:
                m1, m0 = max_context(rows[(q, kv)], margin), max_context(rows[(q, kv)], 0)
                cells.append((f"{p1:,} / {p0:,}", f"{m1:,} / {m0:,}"))
                for need_ctx in (50000,):
                    verdicts.append((q, kv, need_ctx, predicted_need(rows, ln, f, kv, need_ctx) <= budgets["with margin"], m1 >= need_ctx))
            else:
                cells.append((f"{p1:,} / {p0:,}", "not measured"))
        print(f"{q:<11} {f:>9.0f} | {wp:>9.0f} {(str(wm) if wm is not None else '-'):>11} | "
              f"{cells[0][0]:>13} {cells[0][1]:>14} | {cells[1][0]:>13} {cells[1][1]:>14}   [size from {src}]")
    if verdicts:
        print("\nDoes a 50,000-token context fit with the 1 GiB margin?   predicted vs measured")
        for q, kv, c, pred, meas in verdicts:
            print(f"  {q:<10} {kv:<5} predicted {'yes' if pred else 'no ':<3} measured {'yes' if meas else 'no ':<3} {'(agree)' if pred == meas else '(DISAGREE)'}")


main()
