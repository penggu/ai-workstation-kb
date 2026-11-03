#!/usr/bin/env python3
"""Pick the depth ladder for a bench job from the memory measurements of fit-memory.sh.

usage: maxctx.py RESULTS_JSONL MARGIN_MIB PCT "MENU..."
  RESULTS_JSONL  one job's rows written by fit-memory.sh (fields ctx, dev_*_mib, vram_*_mib)
  MARGIN_MIB     VRAM to keep free (same value fit-memory.sh's report uses)
  PCT            only use depths <= PCT percent of the largest context that fits
  MENU           space-separated candidate depths

prints "0,d1,d2,..." (always starts with 0), or just "0" if nothing but an empty context fits.
Also usable with --max to print only the largest context that fits.
"""
import json
import sys


def max_context(rows, margin):
    rows = sorted(rows, key=lambda r: r["ctx"])
    budget = rows[0]["vram_total_mib"] - rows[0]["vram_used_at_run_mib"] - margin
    tot = [(r["ctx"], r["dev_model_mib"] + r["dev_context_mib"] + r["dev_compute_mib"]) for r in rows]
    if tot[0][1] > budget:
        return 0
    best = 0
    for (c1, t1), (c2, t2) in zip(tot, tot[1:]):
        if t2 <= budget:
            best = c2
        else:
            return int(c1 + (budget - t1) * (c2 - c1) / (t2 - t1))
    return best


def main():
    args = sys.argv[1:]
    only_max = "--max" in args
    args = [a for a in args if a != "--max"]
    path, margin, pct, menu = args[0], int(args[1]), int(args[2]), [int(x) for x in args[3].split()]
    rows = [json.loads(line) for line in open(path) if line.strip()]
    mx = max_context(rows, margin)
    if only_max:
        print(mx)
        return
    limit = mx * pct / 100
    depths = [0] + [d for d in menu if d <= limit]
    print(",".join(str(d) for d in depths))


if __name__ == "__main__":
    main()
