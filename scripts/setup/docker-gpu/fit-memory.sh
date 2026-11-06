#!/usr/bin/env bash
# fit-memory.sh - measure how much GPU memory each (quant, KV type, context length) needs,
# using llama.cpp's own estimator (llama-fit-params --fit-print). Read-only on the model:
# it reads GGUF metadata only, loads no weights, and does not need free VRAM.
#
#   ./fit-memory.sh status | apply | report | compare | export | undo   [--quant Q] [--kv KV] [--dry-run] [--yes]
#
# For every context length it records, in MiB: model weights, KV/context, compute buffer.
# `report` then derives (a) the KV size per token, (b) the largest context that fits in free VRAM.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/fit-memory}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
IMAGE_STATE=${LLAMA_IMAGE_STATE:-$HOME/.local/state/ai-workstation/llama-image/image-digest.txt}
KB_DATA=${KB_DATA_DIR:-$HOME/code/ai-workstation-kb/data/benchmarks}
FIT_BIN=${FIT_BIN:-/app/llama-fit-params}
RESULTS="$STATE_DIR/results"; mkdir -p "$RESULTS"

QUANTS=(UD-IQ3_XXS UD-IQ3_S UD-Q3_K_XL UD-IQ4_XS UD-Q4_K_M UD-Q5_K_M Q8_0)
KV_TYPES=(f16 q8_0)
CONTEXTS=(4096 8192 16384 32768 49152 65536 98304 131072 196608 262144)
MARGIN_MIB=${MARGIN_MIB:-1024}   # VRAM to keep free when deciding what "fits"

d() { sudo docker "$@"; }

DRY_RUN=0; QUANT_FILTER=""; KV_FILTER=""; QUANT_GIVEN=0
cmd=${1:-status}; (($#)) && shift
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --quant) shift; QUANT_FILTER=${1:-}; QUANT_GIVEN=1 ;;
    --kv) shift; KV_FILTER=${1:-} ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }

JOBS=()
for q in "${QUANTS[@]}"; do
  [[ -z $QUANT_FILTER || $q == "$QUANT_FILTER" || $q == "UD-$QUANT_FILTER" ]] || continue
  for kv in "${KV_TYPES[@]}"; do
    [[ -z $KV_FILTER || $kv == "$KV_FILTER" ]] || continue
    JOBS+=("$q $kv")
  done
done
((${#JOBS[@]})) || { echo "no jobs match quant=${QUANT_FILTER:-any} kv=${KV_FILTER:-any}" >&2; exit 2; }

job_id()   { echo "$1__$2"; }
job_done() { [[ -f $RESULTS/$(job_id "$1" "$2").ok ]]; }
image_ref() { head -1 "$IMAGE_STATE" 2>/dev/null; }

parse_raw() { # raw out quant kv used total nctx -> prints a verdict; exit 1 if invalid
  python3 - "$@" <<'PY'
import json, re, sys
raw, out, quant, kv, used, total, nctx = sys.argv[1:8]
text = open(raw).read()
blocks = re.split(r"^### ctx=(\d+)\s*$", text, flags=re.M)[1:]   # [ctx, body, ctx, body, ...]
rows, bad = [], []
for ctx, body in zip(blocks[0::2], blocks[1::2]):
    ctx = int(ctx)
    m = re.search(r"^### rc=(\d+)", body, flags=re.M)
    if not m or m.group(1) != "0": bad.append(f"ctx {ctx}: rc={m.group(1) if m else '?'}"); continue
    dev = host = None
    for line in body.splitlines():
        parts = line.split()
        if len(parts) == 4 and all(p.isdigit() for p in parts[1:]):
            if parts[0] == "Host": host = list(map(int, parts[1:]))
            elif dev is None: dev = (parts[0], list(map(int, parts[1:])))
    if dev is None or host is None: bad.append(f"ctx {ctx}: could not parse device/host lines"); continue
    rows.append({"quant": quant, "kv": kv, "ctx": ctx, "device": dev[0],
                 "dev_model_mib": dev[1][0], "dev_context_mib": dev[1][1], "dev_compute_mib": dev[1][2],
                 "host_model_mib": host[0], "host_context_mib": host[1], "host_compute_mib": host[2],
                 "vram_used_at_run_mib": int(used), "vram_total_mib": int(total)})
if len(rows) != int(nctx): bad.append(f"expected {nctx} contexts, parsed {len(rows)}")
ks = [r["dev_context_mib"] for r in sorted(rows, key=lambda r: r["ctx"])]
if any(b < a for a, b in zip(ks, ks[1:])): bad.append("context memory is not monotonic in context length")
if bad: print("INVALID: " + "; ".join(bad)); sys.exit(1)
with open(out, "w") as o:
    for r in sorted(rows, key=lambda r: r["ctx"]): o.write(json.dumps(r) + "\n")
print(f"parsed {len(rows)} contexts; ctx={rows[0]['ctx']}..{rows[-1]['ctx']}, device {rows[0]['device']}")
PY
}

run_job() { # quant kv
  local quant=$1 kv=$2 id; id=$(job_id "$1" "$2")
  local file="Qwen3.8-27B-$quant.gguf" ref raw="$RESULTS/$id.raw" err="$TMPD/$id.err"
  ref=$(image_ref)
  [[ -n $ref ]] || die "no pinned image digest at $IMAGE_STATE; run ./llama-image.sh apply first"
  [[ -f $MODEL_DIR/$file ]] || die "missing model file: $MODEL_DIR/$file"
  info "$file, KV $kv, contexts: ${CONTEXTS[*]}"
  # One container per job. Positional args: FITBIN FILE KV CTX... ; each context prints a "### ctx" block.
  # shellcheck disable=SC2016  # the script runs inside the container, where $1 and $c must expand, not here
  local script='bin=$1; f=$2; kv=$3; shift 3
for c in "$@"; do
  echo "### ctx=$c"
  "$bin" -m "/models/$f" -c "$c" -ngl 99 -fa on -ctk "$kv" -ctv "$kv" -fitp on
  echo "### rc=$?"
done'
  if ! d run --rm --gpus all -v "$MODEL_DIR":/models:ro --entrypoint sh "$ref" -c "$script" sh \
        "$FIT_BIN" "$file" "$kv" "${CONTEXTS[@]}" >"$raw" 2>"$err"; then
    tail -n 30 "$err"; rm -f "$raw"; die "container run failed for $id"
  fi
  local used total
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
  local verdict
  verdict=$(parse_raw "$raw" "$RESULTS/$id.jsonl" "$quant" "$kv" "$used" "$total" "${#CONTEXTS[@]}") \
    || { warn "$verdict"; tail -n 20 "$raw"; die "result for $id failed validation (raw output tail above)"; }
  info "$verdict"
  : >"$RESULTS/$id.ok"
}

report() {
  python3 - "$RESULTS" "$MARGIN_MIB" <<'PY'
import json, glob, os, sys
res, margin = sys.argv[1], int(sys.argv[2])
rows = []
for f in sorted(glob.glob(os.path.join(res, "*.jsonl"))):
    if os.path.exists(f[:-6] + ".ok"):
        rows += [json.loads(l) for l in open(f) if l.strip()]
if not rows: print("(no finished jobs)"); sys.exit(0)
total = rows[0]["vram_total_mib"]; used = rows[0]["vram_used_at_run_mib"]
budget = total - used - margin
print(f"GPU {rows[0]['device']}: {total} MiB total, {used} MiB used by the desktop at measurement time, "
      f"margin {margin} MiB -> budget {budget} MiB ({budget/1024:.1f} GiB)\n")
keys = sorted({(r["quant"], r["kv"]) for r in rows})
ctxs = sorted({r["ctx"] for r in rows})
print("Total GPU memory needed (GiB) = weights + KV cache + compute buffer, all layers on the GPU (-ngl 99)")
print(f"{'quant':<12} {'KV':<5} " + " ".join(f"{c//1024:>6}K" for c in ctxs))
for q, kv in keys:
    sel = {r["ctx"]: r for r in rows if r["quant"] == q and r["kv"] == kv}
    cells = []
    for c in ctxs:
        r = sel.get(c)
        if not r: cells.append(f"{'-':>7}"); continue
        t = r["dev_model_mib"] + r["dev_context_mib"] + r["dev_compute_mib"]
        mark = "*" if t <= budget else " "
        cells.append(f"{t/1024:>6.1f}{mark}")
    print(f"{q:<12} {kv:<5} " + " ".join(cells))
print("\n* = fits in the budget above\n")
print(f"{'quant':<12} {'KV':<5} {'weights GiB':>11} {'KV KiB/token':>13} {'compute MiB':>12} {'max ctx that fits':>18}")
for q, kv in keys:
    sel = sorted([r for r in rows if r["quant"] == q and r["kv"] == kv], key=lambda r: r["ctx"])
    a, b = sel[0], sel[-1]
    kv_per_tok = (b["dev_context_mib"] - a["dev_context_mib"]) * 1024 / (b["ctx"] - a["ctx"])
    weights = a["dev_model_mib"]
    # largest ctx with total <= budget, linear interpolation between measured points
    best = 0
    tot = [(r["ctx"], r["dev_model_mib"] + r["dev_context_mib"] + r["dev_compute_mib"]) for r in sel]
    if tot[0][1] > budget: best_s = "does not fit"
    else:
        for (c1, t1), (c2, t2) in zip(tot, tot[1:]):
            if t2 <= budget: best = c2
            else:
                best = int(c1 + (budget - t1) * (c2 - c1) / (t2 - t1)); break
        best_s = f"{best:,}" + (" (>= model limit)" if best >= tot[-1][0] else "")
    print(f"{q:<12} {kv:<5} {weights/1024:>11.2f} {kv_per_tok:>13.1f} {a['dev_compute_mib']:>12} {best_s:>18}")
print("\nFor reference, KV/token estimated from the GGUF metadata: f16 ~64 KiB, q8_0 ~34 KiB (16 full-attention layers).")
PY
}

export_results() {
  mkdir -p "$KB_DATA"
  local out n=0 f; out="$KB_DATA/fit-memory-$(date +%F).jsonl"
  : >"$out"
  for f in "$RESULTS"/*.jsonl; do
    [[ -e $f && -f ${f%.jsonl}.ok ]] || continue
    cat "$f" >>"$out"; n=$((n + $(wc -l <"$f")))
  done
  if ((n == 0)); then rm -f "$out"; fi
  info "$n rows -> $out"
}

# ------------------------------------------------------------------ driver
init_logging "fitmem-$cmd"
info "command: $cmd quant=${QUANT_FILTER:-any} kv=${KV_FILTER:-any} dry-run=$DRY_RUN"
snapshot
[[ $cmd == apply ]] && ((!DRY_RUN)) && [[ ${SKIP_SUDO_V:-0} != 1 ]] && { info "asking for sudo once"; sudo -v; }

show_status() {
  local j q kv
  printf '%-30s %s\n' JOB STATE
  for j in "${JOBS[@]}"; do read -r q kv <<<"$j"; printf '%-30s %s\n' "$(job_id "$q" "$kv")" "$(job_done "$q" "$kv" && echo DONE || echo PENDING)"; done
}

case "$cmd" in
  status) show_status ;;
  report) report ;;
  compare)   # predictions (made from the baseline quants only) next to the measurements, and the method's own leave-one-out error
    python3 "$HERE/predict_fit.py" "$RESULTS" "$MODEL_DIR" "$MARGIN_MIB" --loo
    echo
    python3 "$HERE/predict_fit.py" "$RESULTS" "$MODEL_DIR" "$MARGIN_MIB"
    ;;
  export) export_results ;;
  apply)
    for j in "${JOBS[@]}"; do
      read -r q kv <<<"$j"; id=$(job_id "$q" "$kv"); CURRENT_STEP=$id; CURRENT_ACTION=check
      if job_done "$q" "$kv"; then ok "$id already done"; record "$id" fitmem skipped; continue; fi
      if [[ ! -f $MODEL_DIR/Qwen3.8-27B-$q.gguf ]]; then
        # not downloaded yet: skip (apply again later), unless the user asked for exactly this quant
        if ((QUANT_GIVEN)); then die "missing model file: $MODEL_DIR/Qwen3.8-27B-$q.gguf"; fi
        warn "$id skipped: Qwen3.8-27B-$q.gguf is not there yet"; continue
      fi
      if ((DRY_RUN)); then info "[dry-run] would measure $id at ${#CONTEXTS[@]} context lengths"; continue; fi
      info ">>> measure $id"; CURRENT_ACTION=run
      run_job "$q" "$kv"
      ok "$id done"; record "$id" fitmem "done"
    done
    echo; show_status; echo; report
    ((DRY_RUN)) || export_results
    ;;
  undo)
    ((DRY_RUN)) || confirm "Delete the memory measurements of these ${#JOBS[@]} jobs?" || die "aborted"
    for j in "${JOBS[@]}"; do
      read -r q kv <<<"$j"; id=$(job_id "$q" "$kv"); CURRENT_STEP=$id; CURRENT_ACTION=undo
      if ((DRY_RUN)); then info "[dry-run] would delete $id"; continue; fi
      rm -f "$RESULTS/$id".*; info "deleted $id"; record "$id" fitmem undone
    done
    ((DRY_RUN)) || export_results
    echo; show_status
    ;;
  *) echo "usage: $0 status|apply|report|compare|export|undo [--quant Q] [--kv KV] [--dry-run] [--yes]" >&2; exit 2 ;;
esac
