#!/usr/bin/env python3
"""Run 8 short coding tasks (from a private evaluation set) against an OpenAI-compatible server and grade them.

The tasks and the grader (hidden tests, `python -I -S` subprocess) come from a separate checkout
(--tasks-repo, module --tasks-module); nothing from that repository is copied here.

usage: eval_short.py --tasks-repo DIR --tasks-module MOD --base-url URL --out FILE --label L --mode instruct|thinking
                     [--seeds 1,2,3] [--parallel 4] [--max-tokens N] [--key-env NAME]

One JSON object per (task, seed) is appended to --out as soon as it is graded, so an interrupted run
resumes where it stopped. A final {"event": "summary"} line is written when every sample is there.
Truncated answers (finish_reason == "length") are counted separately from wrong answers.
"""
import argparse
import json
import math
import os
import re
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# Sampling recommended by the model card (Qwen3.8-27B); max_tokens from the evaluation set's profiles
# (instruct) and a generous budget for thinking so that truncation does not decide the score.
PROFILES = {
    "instruct": dict(temperature=0.7, top_p=0.8, top_k=20, min_p=0.0, presence_penalty=1.5, repeat_penalty=1.0, max_tokens=1800),
    "thinking": dict(temperature=1.0, top_p=0.95, top_k=20, min_p=0.0, presence_penalty=0.0, repeat_penalty=1.0, max_tokens=12000),
}
SUFFIX = "\n\nReply with one python code block containing the complete solution and nothing else."


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def post(url, body, key, timeout):
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST",
                                 headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tasks-repo", required=True)
    ap.add_argument("--tasks-module", required=True)
    ap.add_argument("--base-url", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--label", required=True)
    ap.add_argument("--mode", choices=sorted(PROFILES), default="instruct")
    ap.add_argument("--seeds", default="1,2,3")
    ap.add_argument("--parallel", type=int, default=4)
    ap.add_argument("--max-tokens", type=int)
    ap.add_argument("--key-env", default="AIW_EVAL_KEY")
    ap.add_argument("--timeout", type=int, default=3600, help="per request, seconds")
    a = ap.parse_args()

    import importlib
    sys.path.insert(0, a.tasks_repo)
    tasks = importlib.import_module(a.tasks_module)  # the user's own tasks and grader

    prof = dict(PROFILES[a.mode])
    if a.max_tokens:
        prof["max_tokens"] = a.max_tokens
    key = os.environ.get(a.key_env, "")
    seeds = [int(s) for s in a.seeds.split(",")]
    want = [(t["name"], s) for t in tasks.TASKS for s in seeds]

    done = {}
    if os.path.exists(a.out):
        for line in open(a.out):
            if line.strip():
                r = json.loads(line)
                if r.get("event") == "task" and not r.get("errored"):   # a failed request is retried next time
                    done[(r["task"], r["seed"])] = r
    todo = [(t, s) for t in tasks.TASKS for s in seeds if (t["name"], s) not in done]
    print(f"{len(want) - len(todo)} of {len(want)} samples already done; running {len(todo)} with {a.parallel} in parallel", flush=True)

    lock = threading.Lock()
    out = open(a.out, "a", buffering=1)

    def one(item):
        t, seed = item
        body = dict(model="eval", seed=seed, messages=[{"role": "user", "content": t["prompt"] + SUFFIX}], **prof)
        t0 = time.time()
        reply, fin, toks, ok, err = "", "error", 0, False, ""
        try:
            r = post(a.base_url + "/v1/chat/completions", body, key, a.timeout)
            ch = r["choices"][0]
            reply = ch["message"].get("content") or ""
            reply = re.sub(r"<think>.*?</think>", "", reply, flags=re.S)  # in case thoughts were left in the content
            fin = ch.get("finish_reason")
            toks = r["usage"]["completion_tokens"]
            ok, e = tasks.run_code(tasks.extract_code(reply), t["tests"])
            err = "" if ok else (e.strip().splitlines()[-1][:160] if e.strip() else "")
        except Exception as ex:  # noqa: BLE001 - a failed request is recorded, not hidden
            err = ("%s: %s" % (type(ex).__name__, ex))[:200]
        row = dict(event="task", label=a.label, mode=a.mode, task=t["name"], seed=seed, passed=bool(ok), finish=fin,
                   truncated=(fin == "length"), errored=(fin == "error"), completion_tokens=toks,
                   seconds=round(time.time() - t0, 1), err=err, max_tokens=prof["max_tokens"])
        with lock:
            out.write(json.dumps(row) + "\n")
            print("  %-16s seed %d: %-4s finish=%-6s tokens=%-5d %5.1fs %s" %
                  (t["name"], seed, "PASS" if ok else "FAIL", fin, toks, row["seconds"], err[:60]), flush=True)

    t_start = time.time()
    with ThreadPoolExecutor(max_workers=max(1, a.parallel)) as ex:
        list(ex.map(one, todo))
    wall = time.time() - t_start

    rows = {}
    for line in open(a.out):
        if line.strip():
            r = json.loads(line)
            if r.get("event") == "task":
                rows[(r["task"], r["seed"])] = r
    got = [rows[k] for k in want if k in rows]
    n = len(got)
    k = sum(r["passed"] for r in got)
    tr = sum(r["truncated"] for r in got)
    er = sum(r["errored"] for r in got)
    clean = [r for r in got if not r["truncated"] and not r["errored"]]
    lo, hi = wilson(k, n)
    summary = dict(event="summary", label=a.label, mode=a.mode, passed=k, of=n, truncated=tr, errored=er,
                   passed_of_untruncated="%d/%d" % (sum(r["passed"] for r in clean), len(clean)),
                   ci95=[round(lo, 3), round(hi, 3)], wall_seconds=round(wall, 1),
                   mean_completion_tokens=round(sum(r["completion_tokens"] for r in got) / max(n, 1), 1),
                   per_task={t["name"]: "%d/%d" % (sum(rows[(t["name"], s)]["passed"] for s in seeds if (t["name"], s) in rows),
                                                   sum((t["name"], s) in rows for s in seeds)) for t in tasks.TASKS},
                   complete=(n == len(want)))
    out.write(json.dumps(summary) + "\n")
    print("SUMMARY %d/%d passed (95%% CI %.0f%%-%.0f%%), %d truncated, %d errors, %.0fs"
          % (k, n, lo * 100, hi * 100, tr, er, wall), flush=True)
    sys.exit(0 if (n == len(want) and er == 0) else 3)


main()
