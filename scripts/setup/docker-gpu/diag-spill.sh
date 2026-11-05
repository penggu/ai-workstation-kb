#!/usr/bin/env bash
# diag-spill.sh - two quick diagnostics for the "llama.cpp is ~2.5x slower than Ollama when a
# 27B model spills out of VRAM" question. Idempotent, undoable, leaves a debug trace.
#
#   ./diag-spill.sh status
#   ./diag-spill.sh apply [A|B|all]     (default: all)
#   ./diag-spill.sh report | export
#   ./diag-spill.sh undo  [A|B|all]
#   options: --dry-run  --yes
#
# A  thread count: Q5_K_M at the auto-fit layer count, default threads vs -t 4,6,8.
#    Question: is the slow CPU part caused by the thread setting?
# B  same-file control: take the exact GGUF file Ollama uses for qwen3.8:27b (read-only mount) and run
#    llama.cpp on it. Question: engine difference, or quantisation/placement difference?
#    The file may not load in upstream llama.cpp; that outcome is recorded as the result.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/diag-spill}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
IMAGE_STATE=${LLAMA_IMAGE_STATE:-$HOME/.local/state/ai-workstation/llama-image/image-digest.txt}
KB_DATA=${KB_DATA_DIR:-$HOME/code/ai-workstation-kb/data/benchmarks}
SPILL_RESULTS=${SPILL_RESULTS:-$HOME/.local/state/ai-workstation/llama-bench/results}
OLLAMA_MODELS_DIR=${OLLAMA_MODELS_DIR:-/usr/share/ollama/.ollama/models}
OLLAMA_MODEL=${DIAG_OLLAMA_MODEL:-qwen3.8}
OLLAMA_TAG=${DIAG_OLLAMA_TAG:-27b}
OLLAMA_REF_JSON=${OLLAMA_REF_JSON:-$KB_DATA/ollama-chat-27b-spill-2026-11-02.jsonl}
RESULTS="$STATE_DIR/results"; mkdir -p "$RESULTS"

FIT_CTX=8832            # 512 + 128 + 8192, same as bench-ladder.sh
MARGIN_MIB=1024
VRAM_BASELINE_MAX_MIB=${VRAM_BASELINE_MAX_MIB:-3500}
JOBS_ALL=(A B)

d() { sudo docker "$@"; }
image_ref() { head -1 "$IMAGE_STATE" 2>/dev/null; }

DRY_RUN=0
cmd=${1:-status}; (($#)) && shift
SEL=()
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    A|a) SEL+=(A) ;;
    B|b) SEL+=(B) ;;
    all) SEL+=("${JOBS_ALL[@]}") ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
((${#SEL[@]})) || SEL=("${JOBS_ALL[@]}")
((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }

job_done() { [[ -f $RESULTS/$1.ok ]]; }

# ------------------------------------------------------------------ shared helpers
spill_n() { # the layer count llama-fit-params chose for Q5_K_M/f16 in bench-ladder.sh (fallback 46)
  local f="$SPILL_RESULTS/UD-Q5_K_M__f16.fit.json"
  if [[ -f $f ]]; then python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["fit_ngl"])' "$f"; else echo 46; fi
}

preflight() {
  local ref; ref=$(image_ref)
  [[ -n $ref ]] || die "no pinned image digest at $IMAGE_STATE; run ./llama-image.sh apply first"
  d image inspect "$ref" >/dev/null 2>&1 || die "image $ref is not present locally"
  local procs
  procs=$(running_jobs || true)
  if [[ -n $procs ]]; then echo "$procs" | cut -c1-160; die "another benchmark/download is running; wait for it to finish (these numbers are CPU-sensitive)"; fi
  local used; used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  info "GPU memory in use before the run: ${used} MiB (limit ${VRAM_BASELINE_MAX_MIB})"
  if ((used > VRAM_BASELINE_MAX_MIB)); then
    warn "if Ollama holds a model: run 'ollama ps' then 'ollama stop <model>'"
    die "something else is using the GPU (${used} MiB)"
  fi
  local load; load=$(awk '{print $1}' /proc/loadavg)
  info "1-minute load average: $load"
  if awk -v l="$load" 'BEGIN { exit !(l > 1.5) }'; then
    warn "CPU is not idle (load $load > 1.5); the CPU-offload numbers may be noisy"
  fi
}

# lb MOUNT OUTFILE ARGS...   run llama-bench in the pinned image. Returns non-zero on failure
# (stderr tail saved to $TMPD/lb.err) so the caller decides whether that is fatal.
lb() {
  local mount=$1 out=$2; shift 2
  local ref; ref=$(image_ref)
  info "llama-bench $*"
  local t0=$SECONDS
  if ! d run --rm --gpus all -v "$mount" --entrypoint /app/llama-bench "$ref" "$@" >"$out" 2>"$TMPD/lb.err"; then
    return 1
  fi
  info "finished in $((SECONDS - t0)) s"
  tail -n 4 "$TMPD/lb.err" | sed 's/^/    stderr: /'
  return 0
}

# validate_rows FILE NGL KV NROWS  -> one-line verdict; exit 1 if invalid
validate_rows() {
  python3 - "$@" <<'PY'
import json, sys
path, ngl, kv, nrows = sys.argv[1], int(sys.argv[2]), sys.argv[3], int(sys.argv[4])
rows = [json.loads(l) for l in open(path) if l.strip()]
bad = []
if len(rows) != nrows: bad.append(f"expected {nrows} rows, got {len(rows)}")
for r in rows:
    if not r.get("avg_ts", 0) > 0: bad.append("avg_ts <= 0")
    if r.get("n_gpu_layers") != ngl: bad.append(f"n_gpu_layers {r.get('n_gpu_layers')} != {ngl}")
    if r.get("type_k") != kv: bad.append(f"KV type {r.get('type_k')} != {kv}")
bad = list(dict.fromkeys(bad))
if bad: print("INVALID: " + "; ".join(bad)); sys.exit(1)
print("; ".join(f"t={r.get('n_threads')} {'pp512' if r['n_prompt'] else 'tg128'}@d{r['n_depth']}={r['avg_ts']:.2f}" for r in rows))
PY
}

# ------------------------------------------------------------------ A: threads
run_A() {
  local N file=Qwen3.8-27B-UD-Q5_K_M.gguf mount verdict
  [[ -f $MODEL_DIR/$file ]] || die "missing model file: $MODEL_DIR/$file"
  mount="$MODEL_DIR:/models:ro"
  N=$(spill_n); info "layers on GPU (from bench-ladder's auto-fit): $N"
  local base=(-m "/models/$file" -ngl "$N" -fa on -ctk f16 -ctv f16 -p 512 -n 128 -d 0 -o jsonl)
  rm -f "$RESULTS"/A_*.jsonl

  info "A1: default thread count (also tells us what the default is: see n_threads)"
  lb "$mount" "$RESULTS/A_default.jsonl" "${base[@]}" -r 3 || { tail -n 30 "$TMPD/lb.err"; die "A1 failed"; }
  verdict=$(validate_rows "$RESULTS/A_default.jsonl" "$N" f16 2) || die "A1 invalid: $verdict"
  info "$verdict"

  info "A2: thread sweep -t 4,6,8"
  lb "$mount" "$RESULTS/A_threads.jsonl" "${base[@]}" -t 4,6,8 -r 2 || { tail -n 30 "$TMPD/lb.err"; die "A2 failed"; }
  verdict=$(validate_rows "$RESULTS/A_threads.jsonl" "$N" f16 6) || die "A2 invalid: $verdict"
  info "$verdict"
  : >"$RESULTS/A.ok"
}

# ------------------------------------------------------------------ B: same file as Ollama
resolve_blob() { # prints the blob file name (sha256-...) of the model layer of the Ollama manifest
  local man="$OLLAMA_MODELS_DIR/manifests/registry.ollama.ai/library/$OLLAMA_MODEL/$OLLAMA_TAG"
  if ! sudo test -f "$man"; then
    warn "manifest not found: $man"; sudo find "$OLLAMA_MODELS_DIR/manifests" -type f 2>/dev/null | head -20 || true
    die "cannot locate the Ollama manifest for $OLLAMA_MODEL:$OLLAMA_TAG (set DIAG_OLLAMA_MODEL / DIAG_OLLAMA_TAG)"
  fi
  sudo cat "$man" | python3 -c '
import json, sys
m = json.load(sys.stdin)
layers = [l for l in m.get("layers", []) if l.get("mediaType", "").endswith(".image.model")]
if len(layers) != 1: sys.exit("expected exactly one model layer, found %d" % len(layers))
print(layers[0]["digest"].replace(":", "-"))'
}

run_B() {
  local blob path ref size verdict
  ref=$(image_ref)
  blob=$(resolve_blob)
  path="$OLLAMA_MODELS_DIR/blobs/$blob"
  sudo test -f "$path" || die "blob file not found: $path"
  size=$(sudo stat -c %s "$path")
  info "Ollama model file: $blob ($((size / 1048576)) MiB)"
  [[ $(sudo head -c 4 "$path") == GGUF ]] || die "the Ollama blob is not a GGUF file"
  rm -f "$RESULTS"/B.*
  local mount="$OLLAMA_MODELS_DIR/blobs:/blobs:ro"

  # 1) can upstream llama.cpp read it at all? (metadata only)
  local fit_out
  info "B1: llama-fit-params on Ollama's file"
  if ! fit_out=$(d run --rm --gpus all -v "$mount" --entrypoint /app/llama-fit-params "$ref" \
        -m "/blobs/$blob" -c "$FIT_CTX" -fitc "$FIT_CTX" -fitt "$MARGIN_MIB" -fa on -ctk f16 -ctv f16 2>"$TMPD/fitB.err"); then
    tail -n 25 "$TMPD/fitB.err" | tee "$RESULTS/B.neg"
    warn "RESULT: upstream llama.cpp (this build) cannot load Ollama's file; recorded as the outcome of B"
    : >"$RESULTS/B.ok"; return 0
  fi
  info "fit result: $fit_out"
  local N
  if [[ $fit_out =~ -ngl[[:space:]]+(-?[0-9]+) ]]; then N=${BASH_REMATCH[1]}; else die "cannot parse -ngl from: $fit_out"; fi

  # 2) benchmark it exactly like bench-ladder.sh does for the spill point
  info "B2: llama-bench on Ollama's file at -ngl $N (depth 0 and 8192)"
  if ! lb "$mount" "$RESULTS/B.jsonl" -m "/blobs/$blob" -ngl "$N" -fa on -ctk f16 -ctv f16 -p 512 -n 128 -d 0,8192 -r 3 -o jsonl; then
    tail -n 25 "$TMPD/lb.err" | tee "$RESULTS/B.neg"
    warn "RESULT: llama.cpp read the metadata but failed to run the model; recorded as the outcome of B"
    rm -f "$RESULTS/B.jsonl"; : >"$RESULTS/B.ok"; return 0
  fi
  verdict=$(validate_rows "$RESULTS/B.jsonl" "$N" f16 4) || { warn "$verdict"; die "B result invalid"; }
  info "$verdict"
  python3 - "$RESULTS/B.meta.json" "$blob" "$size" "$N" "$fit_out" <<'PY'
import json, sys, datetime
p, blob, size, n, fit = sys.argv[1:6]
json.dump({"date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "ollama_blob": blob,
           "size_bytes": int(size), "fit_ngl": int(n), "fit_output": fit}, open(p, "w"), indent=1)
PY
  : >"$RESULTS/B.ok"
}

# ------------------------------------------------------------------ report / export
report() {
  python3 - "$RESULTS" "$OLLAMA_REF_JSON" <<'PY'
import json, os, sys
res, ref = sys.argv[1:3]
def rows(name):
    p = os.path.join(res, name)
    return [json.loads(l) for l in open(p) if l.strip()] if os.path.exists(p) else []
print("== A: thread count, Q5_K_M, f16 KV, depth 0 ==")
a = rows("A_default.jsonl") + rows("A_threads.jsonl")
if not a: print("(not run)")
else:
    byt = {}
    for r in a:
        byt.setdefault(r["n_threads"], {})["pp" if r["n_prompt"] else "tg"] = (r["avg_ts"], r["stddev_ts"])
    print(f"{'threads':>8} {'pp512 tok/s':>16} {'tg128 tok/s':>16}")
    default_t = rows("A_default.jsonl")[0]["n_threads"] if rows("A_default.jsonl") else None
    for t in sorted(byt):
        pp, tg = byt[t].get("pp", (0, 0)), byt[t].get("tg", (0, 0))
        print(f"{t:>8} {pp[0]:>10.1f}±{pp[1]:<4.1f} {tg[0]:>10.2f}±{tg[1]:<4.2f}" + ("   <- llama-bench default" if t == default_t else ""))
print("\n== B: the same GGUF file Ollama uses (qwen3.8:27b) ==")
if os.path.exists(os.path.join(res, "B.neg")):
    print("llama.cpp could NOT use Ollama's file. Error tail:")
    print(open(os.path.join(res, "B.neg")).read()[-1200:])
elif not os.path.exists(os.path.join(res, "B.ok")): print("(not run)")
else:
    meta = json.load(open(os.path.join(res, "B.meta.json")))
    b = rows("B.jsonl")
    def cell(kind, d):
        for r in b:
            if ("pp" if r["n_prompt"] else "tg") == kind and r["n_depth"] == d: return r["avg_ts"], r["stddev_ts"]
        return None
    o = None
    if os.path.exists(ref):
        for l in open(ref):
            r = json.loads(l)
            if r.get("num_ctx") == 8192: o = r
    print(f"file: {meta['ollama_blob']}  ({meta['size_bytes'] / 2**30:.2f} GiB), llama.cpp auto-fit -ngl {meta['fit_ngl']}")
    print(f"{'engine':<34} {'tg128 d0':>12} {'tg128 d8192':>13} {'on GPU':>8}")
    if o: print(f"{'Ollama (its own engine), ctx 8192':<34} {o['warm_gen_tps_median']:>12.2f} {'-':>13} {o['gpu_share_pct']:>7.0f}%")
    g0, g8 = cell("tg", 0), cell("tg", 8192)
    print(f"{'llama.cpp, same file':<34} {g0[0]:>9.2f}±{g0[1]:<2.1f} {g8[0]:>10.2f}±{g8[1]:<2.1f} {'(fit)':>8}")
PY
}

export_results() {
  mkdir -p "$KB_DATA"
  local out; out="$KB_DATA/diag-spill-$(date +%F).jsonl"
  python3 - "$RESULTS" "$out" <<'PY'
import json, os, sys
res, out = sys.argv[1:3]; n = 0
with open(out, "w") as o:
    for name, tag in (("A_default.jsonl", "A-default-threads"), ("A_threads.jsonl", "A-thread-sweep"), ("B.jsonl", "B-ollama-file")):
        p = os.path.join(res, name)
        if not os.path.exists(p): continue
        for l in open(p):
            if l.strip(): r = json.loads(l); r["diag"] = tag; o.write(json.dumps(r) + "\n"); n += 1
print(f"{n} rows -> {out}")
if n == 0: os.remove(out)
PY
}

# ------------------------------------------------------------------ driver
init_logging "diag-$cmd"
info "command: $cmd jobs=${SEL[*]} dry-run=$DRY_RUN"
snapshot
[[ $cmd == apply ]] && ((!DRY_RUN)) && [[ ${SKIP_SUDO_V:-0} != 1 ]] && { info "asking for sudo once"; sudo -v; }

desc() { case "$1" in A) echo "thread-count sweep on Q5_K_M";; B) echo "same-file control: Ollama's GGUF in llama.cpp";; esac; }

show_status() {
  local j st
  printf '%-4s %-8s %s\n' JOB STATE DESCRIPTION
  for j in "${SEL[@]}"; do
    if job_done "$j"; then st=DONE; [[ -f $RESULTS/$j.neg ]] && st="DONE (llama.cpp could not load the file)"; else st=PENDING; fi
    printf '%-4s %-8s %s\n' "$j" "$st" "$(desc "$j")"
  done
}

case "$cmd" in
  status) show_status ;;
  report) report ;;
  export) export_results ;;
  apply)
    todo=0
    for j in "${SEL[@]}"; do
      CURRENT_STEP=$j; CURRENT_ACTION=check
      if job_done "$j"; then ok "$j already done"; record "$j" diag skipped; continue; fi
      todo=$((todo + 1))
      if ((DRY_RUN)); then info "[dry-run] would run $j - $(desc "$j")"; continue; fi
      ((todo == 1)) && preflight
      info ">>> run $j - $(desc "$j")"; CURRENT_ACTION=run
      "run_$j"
      ok "$j done"; record "$j" diag "done"
    done
    echo; show_status; echo; report
    ((DRY_RUN)) || export_results
    ;;
  undo)
    ((DRY_RUN)) || confirm "Delete the results of diagnostics ${SEL[*]}?" || die "aborted"
    for j in "${SEL[@]}"; do
      CURRENT_STEP=$j; CURRENT_ACTION=undo
      if ((DRY_RUN)); then info "[dry-run] would delete $j"; continue; fi
      rm -f "$RESULTS/$j".* "$RESULTS/${j}_"*; info "deleted results of $j"; record "$j" diag undone
    done
    ((DRY_RUN)) || export_results
    echo; show_status
    ;;
  *) echo "usage: $0 status|apply|report|export|undo [A|B|all] [--dry-run] [--yes]" >&2; exit 2 ;;
esac
