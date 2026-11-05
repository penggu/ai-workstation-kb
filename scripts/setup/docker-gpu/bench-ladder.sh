#!/usr/bin/env bash
# bench-ladder.sh - llama.cpp quantisation-ladder benchmark for Qwen3.8-27B, in Docker.
# Idempotent (finished jobs/points are skipped), undoable, leaves a debug trace like setup.sh.
#
#   ./bench-ladder.sh status
#   ./bench-ladder.sh apply  [--tier fit|spill|all] [--quant Q] [--kv f16|q8_0]
#   ./bench-ladder.sh report | export
#   ./bench-ladder.sh undo   [--tier ...] [--quant Q] [--kv KV]
#   options: --dry-run  --yes
#
# One job = one (quant, KV-cache type).
#   fit tier   (quant is smaller than VRAM): one llama-bench run, all layers on the GPU (-ngl 99)
#              -p 512 -n 128 -d 0,8192 -r 3
#   spill tier (quant is bigger than VRAM): llama-fit-params first asks "how many layers fit?" (= N),
#              then llama-bench runs at N, N-8, N-16, N-24 layers on the GPU:
#              the N point:   -d 0,8192 -r 3     the other points: -d 0 -r 2 (they are slow)
# The image is pinned by digest (from llama-image.sh). See docs/benchmarks/llama-bench-explained.md.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/llama-bench}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
IMAGE_STATE=${LLAMA_IMAGE_STATE:-$HOME/.local/state/ai-workstation/llama-image/image-digest.txt}
KB_DATA=${KB_DATA_DIR:-$HOME/code/ai-workstation-kb/data/benchmarks}
RESULTS="$STATE_DIR/results"
mkdir -p "$RESULTS"

FIT_QUANTS=(UD-IQ3_XXS UD-IQ3_S UD-Q3_K_XL UD-IQ4_XS)     # smaller than VRAM (IQ4_XS: only short contexts fit; the depth ladder comes from fit-memory)
SPILL_QUANTS=(UD-Q4_K_M UD-Q5_K_M Q8_0)  # bigger than VRAM
KV_TYPES=(f16 q8_0)
VRAM_BASELINE_MAX_MIB=${VRAM_BASELINE_MAX_MIB:-3500}  # desktop uses ~1.4 GiB; more = something else holds the GPU
FIT_CTX=8832                 # 512 (prompt) + 128 (gen) + 8192 (depth): the context the deepest test needs
SPILL_MARGIN_MIB=1024        # VRAM llama-fit-params must leave free
SPILL_STEP=8                 # layers removed from the GPU between sweep points
SPILL_POINTS=4
# CPU threads for the spill tier only (layers on the CPU). diag-spill A found 6 beat llama-bench's default of 8
# by ~12 %; eval-short.sh uses the same value. The all-GPU fit tier is left at the default: threads do not matter there.
SPILL_THREADS=${SPILL_THREADS:-6}
BENCH_EXTRA=()
# Depth ladder for the fit tier: taken from the memory measurements of fit-memory.sh so every depth is
# known to fit (<= DEPTH_PCT % of the largest context that fits). Falls back to 0,8192 without them.
FITMEM_RESULTS=${FITMEM_RESULTS:-$HOME/.local/state/ai-workstation/fit-memory/results}
FIT_MARGIN_MIB=${FIT_MARGIN_MIB:-1024}   # must match MARGIN_MIB used by fit-memory.sh
DEPTH_PCT=${DEPTH_PCT:-90}
DEPTH_MENU="4096 8192 16384 32768 49152 65536 98304"

d() { sudo docker "$@"; }

DRY_RUN=0; TIER=fit; QUANT_FILTER=""; KV_FILTER=""
cmd=${1:-status}; (($#)) && shift
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --tier) shift; TIER=${1:-} ;;
    --quant) shift; QUANT_FILTER=${1:-} ;;
    --kv) shift; KV_FILTER=${1:-} ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
case "$TIER" in fit|spill|all) ;; *) echo "--tier must be fit, spill or all" >&2; exit 2 ;; esac
[[ -z $KV_FILTER ]] || [[ " ${KV_TYPES[*]} " == *" $KV_FILTER "* ]] || { echo "--kv must be one of: ${KV_TYPES[*]}" >&2; exit 2; }
((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }

is_spill() { local q; for q in "${SPILL_QUANTS[@]}"; do [[ $q == "$1" ]] && return 0; done; return 1; }
job_id()   { echo "$1__$2"; }
planned_depths() { # quant kv -> "0,4096,..." (fit tier only)
  local f; f="$FITMEM_RESULTS/$(job_id "$1" "$2").jsonl"
  if [[ -f ${f%.jsonl}.ok ]]; then python3 "$HERE/maxctx.py" "$f" "$FIT_MARGIN_MIB" "$DEPTH_PCT" "$DEPTH_MENU"
  else echo "0,8192"; fi
}
# done = finished AND, for the fit tier, measured with the depth ladder that is planned today
job_done() {
  local id; id=$(job_id "$1" "$2")
  [[ -f $RESULTS/$id.ok ]] || return 1
  if is_spill "$1"; then [[ $(cat "$RESULTS/$id.threads" 2>/dev/null) == "$SPILL_THREADS" ]]; return; fi
  [[ $(cat "$RESULTS/$id.depths" 2>/dev/null) == "$(planned_depths "$1" "$2")" ]]
}
archive_job() { # move a stale job's files out of the way (kept, not deleted)
  local id=$1 dir; dir="$STATE_DIR/results-archive/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$dir"; mv "$RESULTS/$id".* "$dir/" 2>/dev/null || true
  info "archived old results of $id -> $dir"
}
model_file() { echo "Qwen3.8-27B-$1.gguf"; }

JOBS=()   # "quant kv"
add_jobs() {
  local q kv
  for q in "$@"; do
    if [[ -n $QUANT_FILTER && $q != "$QUANT_FILTER" && $q != "UD-$QUANT_FILTER" ]]; then continue; fi
    for kv in "${KV_TYPES[@]}"; do
      if [[ -n $KV_FILTER && $kv != "$KV_FILTER" ]]; then continue; fi
      JOBS+=("$q $kv")
    done
  done
}
case "$TIER" in
  fit) add_jobs "${FIT_QUANTS[@]}" ;;
  spill) add_jobs "${SPILL_QUANTS[@]}" ;;
  all) add_jobs "${FIT_QUANTS[@]}" "${SPILL_QUANTS[@]}" ;;
esac
((${#JOBS[@]})) || { echo "no jobs match: tier=$TIER quant=${QUANT_FILTER:-any} kv=${KV_FILTER:-any}" >&2; exit 2; }

image_ref() { head -1 "$IMAGE_STATE" 2>/dev/null; }
gpu_stats() { nvidia-smi --query-gpu=temperature.gpu,clocks.sm,clocks.max.sm,power.draw,memory.used --format=csv,noheader,nounits 2>&1 | head -1 | tr -d ' '; }

preflight() {
  local ref; ref=$(image_ref)
  [[ -n $ref ]] || die "no pinned image digest at $IMAGE_STATE; run ./llama-image.sh apply first"
  d image inspect "$ref" >/dev/null 2>&1 || die "image $ref is not present locally; run ./llama-image.sh apply"
  local used; used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  info "GPU memory in use before the run: ${used} MiB (limit ${VRAM_BASELINE_MAX_MIB})"
  if ((used > VRAM_BASELINE_MAX_MIB)); then
    nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv 2>&1 || true
    local loaded; loaded=$(curl -s --max-time 3 http://127.0.0.1:11434/api/ps 2>/dev/null | head -c 300 || true)
    [[ $loaded == *'"name"'* ]] && warn "Ollama has a model loaded: run 'ollama stop <model>' (see: ollama ps)"
    die "something else is using the GPU (${used} MiB); free it first so the numbers are clean"
  fi
}

# validate FILE QUANT KV NGL DEPTHS(comma list) -> one-line verdict, exit 0 if valid
validate() {
  python3 - "$@" <<'PY'
import json, sys
path, quant, kv, ngl, depths = sys.argv[1:6]
ngl = int(ngl); depths = [int(x) for x in depths.split(",")]
rows = [json.loads(l) for l in open(path) if l.strip()]
bad = []
want = {(k, dp) for dp in depths for k in ("pp", "tg")}
if len(rows) != len(want): bad.append(f"expected {len(want)} rows, got {len(rows)}")
seen = set()
for r in rows:
    kind = "pp" if r.get("n_prompt", 0) > 0 else "tg"
    seen.add((kind, r.get("n_depth")))
    if not (r.get("avg_ts", 0) > 0): bad.append(f"avg_ts <= 0 in {kind} depth {r.get('n_depth')}")
    if r.get("type_k") != kv or r.get("type_v") != kv: bad.append(f"KV type is {r.get('type_k')}/{r.get('type_v')}, wanted {kv}")
    if r.get("n_gpu_layers") != ngl: bad.append(f"n_gpu_layers is {r.get('n_gpu_layers')}, wanted {ngl}")
    if quant.split("-")[-1].replace("_", "").lower() not in r.get("model_filename", "").replace("_", "").lower():
        bad.append(f"model_filename {r.get('model_filename')} does not match {quant}")
if seen != want: bad.append(f"missing tests: {sorted(want - seen)}")
bad = list(dict.fromkeys(bad))
if bad: print("INVALID: " + "; ".join(bad)); sys.exit(1)
print(f"ngl={ngl}: " + ", ".join(f"{('pp512' if r['n_prompt'] else 'tg128')}@d{r['n_depth']}={r['avg_ts']:.1f}" for r in rows))
PY
}

write_meta() { # file image pre post download_running extra_json
  python3 - "$@" <<'PY'
import json, sys, datetime
path, ref, pre, post, dl, extra = sys.argv[1:7]
m = {"date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "image": ref,
     "gpu_before(temp,sm_clk,max_clk,power,mem_used)": pre, "gpu_after": post, "download_running": dl == "true"}
m.update(json.loads(extra or "{}"))
json.dump(m, open(path, "w"), indent=1)
PY
}

bench_run() { # quant kv ngl depths reps outfile  -> runs llama-bench once, appends validated rows to outfile
  local quant=$1 kv=$2 ngl=$3 depths=$4 reps=$5 out=$6
  local file ref pt="$TMPD/point.jsonl" err="$TMPD/point.err"
  file=$(model_file "$quant"); ref=$(image_ref)
  local args=(-m "/models/$file" -ngl "$ngl" -fa on -ctk "$kv" -ctv "$kv" -p 512 -n 128 -d "$depths" -r "$reps" -o jsonl "${BENCH_EXTRA[@]}")
  info "llama-bench ${args[*]}"
  local t0=$SECONDS
  if ! d run --rm --gpus all -v "$MODEL_DIR":/models:ro --entrypoint /app/llama-bench "$ref" "${args[@]}" >"$pt" 2>"$err"; then
    tail -n 30 "$err"
    die "llama-bench failed (ngl=$ngl); stderr tail above"
  fi
  info "finished in $((SECONDS - t0)) s"
  tail -n 4 "$err" | sed 's/^/    stderr: /'
  local verdict; verdict=$(validate "$pt" "$quant" "$kv" "$ngl" "$depths") || { warn "$verdict"; die "result failed validation (ngl=$ngl)"; }
  info "$verdict"
  cat "$pt" >>"$out"
}

run_job() { # fit tier: quant kv
  local quant=$1 kv=$2 id; id=$(job_id "$1" "$2")
  local file out="$RESULTS/$id.jsonl" pre post dl=false
  file=$(model_file "$quant")
  [[ -f $MODEL_DIR/$file ]] || die "missing model file: $MODEL_DIR/$file"
  info "model: $file ($(du -h "$MODEL_DIR/$file" | cut -f1)), KV cache: $kv"
  pre=$(gpu_stats); download_running && dl=true
  $dl && warn "a model download is still running (recorded in the data)"
  rm -f "$out"
  local depths; depths=$(planned_depths "$quant" "$kv")
  info "depth ladder (tokens already in the context before measuring): $depths"
  bench_run "$quant" "$kv" 99 "$depths" 3 "$out"
  post=$(gpu_stats)
  write_meta "$RESULTS/$id.meta.json" "$(image_ref)" "$pre" "$post" "$dl" "{\"tier\":\"fit\",\"depths\":\"$depths\"}"
  printf '%s' "$depths" >"$RESULTS/$id.depths"
  : >"$RESULTS/$id.ok"
}

run_spill_job() { # spill tier: quant kv
  local quant=$1 kv=$2 id; id=$(job_id "$1" "$2")
  local file out="$RESULTS/$id.jsonl" ref pre post dl=false
  file=$(model_file "$quant"); ref=$(image_ref)
  [[ -f $MODEL_DIR/$file ]] || die "missing model file: $MODEL_DIR/$file (is the download finished?)"
  info "model: $file ($(du -h "$MODEL_DIR/$file" | cut -f1)), KV cache: $kv"
  pre=$(gpu_stats); download_running && dl=true
  $dl && warn "a model download is still running: it competes for CPU, memory bandwidth and disk, which a CPU-offload test is sensitive to (recorded in the data)"

  # 1) ask llama.cpp how many layers fit (reads metadata only)
  local fit_args=(-m "/models/$file" -c "$FIT_CTX" -fitc "$FIT_CTX" -fitt "$SPILL_MARGIN_MIB" -fa on -ctk "$kv" -ctv "$kv")
  info "llama-fit-params ${fit_args[*]}"
  local fit_out
  if ! fit_out=$(d run --rm --gpus all -v "$MODEL_DIR":/models:ro --entrypoint /app/llama-fit-params "$ref" "${fit_args[@]}" 2>"$TMPD/fit.err"); then
    tail -n 30 "$TMPD/fit.err"; die "llama-fit-params failed"
  fi
  info "fit result: $fit_out"
  [[ $fit_out == *" -ot "* ]] && die "llama-fit-params proposed tensor overrides (-ot); this script only handles plain layer offload"
  local N
  if [[ $fit_out =~ -ngl[[:space:]]+(-?[0-9]+) ]]; then N=${BASH_REMATCH[1]}; else die "could not parse -ngl from: $fit_out"; fi
  ((N >= 0)) || die "fit returned a negative -ngl ($N)"
  ((N < 99)) || warn "fit says everything fits (-ngl $N); this quant is not really a spill case"

  # 2) sweep: N, N-8, N-16, N-24 (never below 0)
  local points=() i n
  for ((i = 0; i < SPILL_POINTS; i++)); do
    n=$((N - i * SPILL_STEP)); ((n >= 0)) || break; points+=("$n")
  done
  info "layers on GPU to measure: ${points[*]}"
  local first=1 depths reps
  BENCH_EXTRA=(-t "$SPILL_THREADS")
  for n in "${points[@]}"; do
    if [[ -f $RESULTS/$id.ngl$n.done ]]; then ok "point ngl=$n already done"; first=0; continue; fi
    if ((first)); then depths="0,8192"; reps=3; else depths="0"; reps=2; fi
    first=0
    CURRENT_ACTION="run ngl=$n"
    bench_run "$quant" "$kv" "$n" "$depths" "$reps" "$out"
    : >"$RESULTS/$id.ngl$n.done"
  done
  post=$(gpu_stats)
  python3 - "$RESULTS/$id.fit.json" "$fit_out" "$N" "${points[*]}" "$SPILL_MARGIN_MIB" "$FIT_CTX" <<'PY'
import json, sys
p, out, n, pts, margin, ctx = sys.argv[1:7]
json.dump({"fit_output": out, "fit_ngl": int(n), "points": [int(x) for x in pts.split()],
           "fit_margin_mib": int(margin), "fit_ctx": int(ctx)}, open(p, "w"), indent=1)
PY
  BENCH_EXTRA=()
  printf '%s' "$SPILL_THREADS" >"$RESULTS/$id.threads"
  write_meta "$RESULTS/$id.meta.json" "$ref" "$pre" "$post" "$dl" "$(cat "$RESULTS/$id.fit.json")"
  : >"$RESULTS/$id.ok"
}

report() {
  python3 - "$RESULTS" <<'PY'
import json, glob, os, sys
res = sys.argv[1]
rows = []
for f in sorted(glob.glob(os.path.join(res, "*.jsonl"))):
    if not os.path.exists(f[:-6] + ".ok"): continue
    quant, kv = os.path.basename(f)[:-6].split("__")
    for l in open(f):
        if l.strip():
            r = json.loads(l); r["_q"], r["_kv"] = quant, kv; rows.append(r)
if not rows: print("(no finished jobs)"); sys.exit(0)
depths = sorted({r["n_depth"] for r in rows})
keys = sorted({(r["_q"], r["_kv"], r["n_gpu_layers"]) for r in rows}, key=lambda k: (k[0], k[1], -k[2]))
def label(d): return "0" if d == 0 else (f"{d // 1024}K" if d % 1024 == 0 else str(d))
for kind, title in (("tg", "Generation speed, tg128 (tok/s, mean±sd) by context depth"),
                    ("pp", "Prompt processing, pp512 (tok/s, mean±sd) by context depth")):
    print(title)
    print(f"{'quant':<11} {'KV':<5} {'size GiB':>8} {'GPU layers':>10} | " + " ".join(f"{label(d):>10}" for d in depths))
    for q, kv, ngl in keys:
        sel = [r for r in rows if r["_q"] == q and r["_kv"] == kv and r["n_gpu_layers"] == ngl]
        def cell(d):
            for r in sel:
                if ("pp" if r["n_prompt"] else "tg") == kind and r["n_depth"] == d:
                    return f"{r['avg_ts']:.1f}±{r['stddev_ts']:.1f}"
            return "-"
        print(f"{q:<11} {kv:<5} {sel[0]['model_size'] / 2**30:8.2f} {ngl:>10} | " + " ".join(f"{cell(d):>10}" for d in depths))
    print()
PY
}

export_results() {
  mkdir -p "$KB_DATA"
  local out; out="$KB_DATA/llama-ladder-$(date +%F).jsonl"
  python3 - "$RESULTS" "$out" <<'PY'
import json, glob, os, sys
res, out = sys.argv[1:3]
n = 0
with open(out, "w") as o:
    for f in sorted(glob.glob(os.path.join(res, "*.jsonl"))):
        base = f[:-6]
        if not os.path.exists(base + ".ok"): continue
        quant, kv = os.path.basename(base).split("__")
        meta = json.load(open(base + ".meta.json"))
        for l in open(f):
            if not l.strip(): continue
            r = json.loads(l); r.update({"quant": quant, "kv": kv, "harness": meta}); o.write(json.dumps(r) + "\n"); n += 1
print(f"{n} rows -> {out}")
if n == 0: os.remove(out)
PY
}

# ------------------------------------------------------------------ driver
init_logging "bench-$cmd"
info "command: $cmd  tier=$TIER quant=${QUANT_FILTER:-any} kv=${KV_FILTER:-any} dry-run=$DRY_RUN"
snapshot
[[ $cmd == apply ]] && ((!DRY_RUN)) && [[ ${SKIP_SUDO_V:-0} != 1 ]] && { info "asking for sudo once"; sudo -v; }

job_state() { # quant kv
  local id; id=$(job_id "$1" "$2")
  if job_done "$1" "$2"; then echo DONE
  elif [[ -f $RESULTS/$id.ok ]]; then echo "STALE (settings changed: depth ladder or threads; will be archived and re-run)"
  elif compgen -G "$RESULTS/$id.ngl*.done" >/dev/null; then echo "PARTIAL ($(compgen -G "$RESULTS/$id.ngl*.done" | wc -l) points)"
  else echo PENDING; fi
}

show_status() {
  local j q kv
  printf '%-30s %-6s %s\n' JOB TIER STATE
  for j in "${JOBS[@]}"; do
    read -r q kv <<<"$j"
    printf '%-30s %-6s %s\n' "$(job_id "$q" "$kv")" "$(is_spill "$q" && echo spill || echo fit)" "$(job_state "$q" "$kv")"
  done
}

case "$cmd" in
  status) show_status ;;
  report) report ;;
  export) export_results ;;
  apply)
    todo=0
    for j in "${JOBS[@]}"; do
      read -r q kv <<<"$j"; id=$(job_id "$q" "$kv"); CURRENT_STEP=$id; CURRENT_ACTION=check
      if job_done "$q" "$kv"; then ok "$id already done"; record "$id" bench skipped; continue; fi
      if [[ ! -f $MODEL_DIR/$(model_file "$q") ]]; then
        if [[ -n $QUANT_FILTER ]]; then die "model file missing: $MODEL_DIR/$(model_file "$q") (download not finished?)"; fi
        warn "$id skipped: model file not there yet ($(model_file "$q"))"; continue
      fi
      todo=$((todo + 1))
      if ((DRY_RUN)); then
        [[ -f $RESULTS/$id.ok ]] && info "[dry-run] $id is stale: old results would be archived first"
        is_spill "$q" || info "[dry-run] depth ladder for $id: $(planned_depths "$q" "$kv")"
        if is_spill "$q"; then info "[dry-run] would run $id: llama-fit-params, then llama-bench at $SPILL_POINTS layer counts"
        else info "[dry-run] would run $id: llama-bench -ngl 99"; fi
        continue
      fi
      ((todo == 1)) && preflight
      [[ -f $RESULTS/$id.ok ]] && archive_job "$id"
      info ">>> run $id"; CURRENT_ACTION=run
      if is_spill "$q"; then run_spill_job "$q" "$kv"; else run_job "$q" "$kv"; fi
      ok "$id done"; record "$id" bench "done"
    done
    echo; show_status; echo; report
    ((DRY_RUN)) || export_results
    ;;
  undo)
    ((DRY_RUN)) || confirm "Delete the results of these ${#JOBS[@]} jobs?" || die "aborted"
    for j in "${JOBS[@]}"; do
      read -r q kv <<<"$j"; id=$(job_id "$q" "$kv"); CURRENT_STEP=$id; CURRENT_ACTION=undo
      if ((DRY_RUN)); then info "[dry-run] would delete $id"; continue; fi
      rm -f "$RESULTS/$id".*; info "deleted results of $id"; record "$id" bench undone
    done
    ((DRY_RUN)) || export_results
    echo; show_status
    ;;
  *) echo "usage: $0 status|apply|report|export|undo [--tier fit|spill|all] [--quant Q] [--kv KV] [--dry-run] [--yes]" >&2; exit 2 ;;
esac
