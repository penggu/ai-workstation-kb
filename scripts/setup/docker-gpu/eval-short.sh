#!/usr/bin/env bash
# eval-short.sh - grade a quantisation on 8 short coding tasks (from a private evaluation set; see PRIVATE CONFIG below).
# Starts llama-server in Docker (loopback only, random API key, normal user), sends the tasks in
# parallel, grades the answers with the hidden tests, stops the server. Idempotent, undoable, traced.
#
#   ./eval-short.sh status | apply | report | export | undo
#   options: --quant Q   (default: the four quants we have)   --kv f16|q8_0 (default f16)
#            --mode instruct|thinking (default instruct)      --seeds 1,2,3   --parallel 4
#            --dry-run  --yes
#
# What it answers: "is this configuration broken?" (a gate). 24 samples cannot rank two good quants;
# use eval-kl.sh for that. Qwen3.8 thinks by default (model card): `--mode thinking` is its default way of
# working, `instruct` (thinking off) is what the earlier 21/24 baseline used.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/eval-short}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

# PRIVATE CONFIG: where the task set lives is not in this repository. Put it in a file outside the repo
# (default ~/.config/ai-workstation/private.env, override with AIW_PRIVATE_ENV), for example:
#   EVAL_TASKS_REPO=$HOME/code/<your-eval-repo>     # a checkout whose root is put on sys.path
#   EVAL_TASKS_MODULE=<package.module>              # module in it that provides the tasks and the grader
AIW_PRIVATE_ENV=${AIW_PRIVATE_ENV:-$HOME/.config/ai-workstation/private.env}
# shellcheck disable=SC1090
[[ -f $AIW_PRIVATE_ENV ]] && source "$AIW_PRIVATE_ENV"
EVAL_TASKS_REPO=${EVAL_TASKS_REPO:-}
EVAL_TASKS_MODULE=${EVAL_TASKS_MODULE:-}
MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
IMAGE_STATE=${LLAMA_IMAGE_STATE:-$HOME/.local/state/ai-workstation/llama-image/image-digest.txt}
KB_DATA=${KB_DATA_DIR:-$HOME/code/ai-workstation-kb/data/benchmarks}
RESULTS="$STATE_DIR/results"; mkdir -p "$RESULTS"
PORT=${EVAL_PORT:-18081}
THREADS=${EVAL_THREADS:-6}            # 6 beat the default 8 in diag-spill (A)
FIT_MARGIN_MIB=1024
READY_TIMEOUT=${READY_TIMEOUT:-900}
VRAM_BASELINE_MAX_MIB=${VRAM_BASELINE_MAX_MIB:-3500}
DEFAULT_QUANTS=(UD-IQ3_XXS UD-IQ3_S UD-Q3_K_XL UD-IQ4_XS UD-Q4_K_M UD-Q5_K_M Q8_0)
SLOT_CTX_INSTRUCT=4096                # per parallel slot; the total -c is slots x this
SLOT_CTX_THINKING=16384

d() { sudo docker "$@"; }
image_ref() { head -1 "$IMAGE_STATE" 2>/dev/null; }

DRY_RUN=0; KV=f16; MODE=instruct; SEEDS="1,2,3"; NP=4; QUANTS=()
cmd=${1:-status}; (($#)) && shift
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --quant) shift; QUANTS+=("${1:-}") ;;
    --kv) shift; KV=${1:-} ;;
    --mode) shift; MODE=${1:-} ;;
    --seeds) shift; SEEDS=${1:-} ;;
    --parallel) shift; NP=${1:-} ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
((${#QUANTS[@]})) || QUANTS=("${DEFAULT_QUANTS[@]}")
case "$KV" in f16|q8_0) ;; *) echo "--kv must be f16 or q8_0" >&2; exit 2 ;; esac
case "$MODE" in instruct|thinking) ;; *) echo "--mode must be instruct or thinking" >&2; exit 2 ;; esac
[[ $NP =~ ^[1-9][0-9]*$ ]] || { echo "--parallel must be a positive integer" >&2; exit 2; }
((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }

slot_ctx() { if [[ $MODE == thinking ]]; then echo "$SLOT_CTX_THINKING"; else echo "$SLOT_CTX_INSTRUCT"; fi; }
TOTAL_CTX=$(( NP * $(slot_ctx) ))
cfg_sig() { echo "mode=$MODE kv=$KV seeds=$SEEDS np=$NP ctx=$TOTAL_CTX threads=$THREADS"; }
job_id()   { echo "$1__${KV}__$MODE"; }
job_done() { local id; id=$(job_id "$1"); [[ -f $RESULTS/$id.ok && $(cat "$RESULTS/$id.cfg" 2>/dev/null) == "$(cfg_sig)" ]]; }
model_file() { echo "Qwen3.8-27B-$1.gguf"; }

# ------------------------------------------------------------------ server lifecycle
SERVER_NAME=""
KEY=""
capture_server_log() { # id
  [[ -n $SERVER_NAME ]] && d logs --tail 400 "$SERVER_NAME" >"$RESULTS/$1.server.log" 2>&1 || true
}
stop_server() {
  [[ -n $SERVER_NAME ]] || return 0
  d stop -t 15 "$SERVER_NAME" >/dev/null 2>&1 || true
  SERVER_NAME=""
}

preflight() {
  local ref; ref=$(image_ref)
  [[ -n $ref ]] || die "no pinned image digest at $IMAGE_STATE; run ./llama-image.sh apply first"
  d image inspect "$ref" >/dev/null 2>&1 || die "image $ref is not present locally"
  [[ -n $EVAL_TASKS_REPO && -n $EVAL_TASKS_MODULE ]] || die "EVAL_TASKS_REPO / EVAL_TASKS_MODULE are not set (put them in $AIW_PRIVATE_ENV)"
  [[ -f $EVAL_TASKS_REPO/${EVAL_TASKS_MODULE//.//}.py ]] || die "task module not found: $EVAL_TASKS_REPO/${EVAL_TASKS_MODULE//.//}.py"
  local procs; procs=$(running_jobs --no-downloads || true)
  if [[ -n $procs ]]; then echo "$procs" | cut -c1-160; die "another benchmark/server is running; wait for it to finish"; fi
  local used; used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  info "GPU memory in use before the run: ${used} MiB (limit ${VRAM_BASELINE_MAX_MIB})"
  if ((used > VRAM_BASELINE_MAX_MIB)); then warn "if Ollama holds a model: 'ollama ps' then 'ollama stop <model>'"; die "something else is using the GPU (${used} MiB)"; fi
  # ss, not a /dev/tcp connect: connecting to a closed port can hang for minutes in some network setups
  if [[ -n $(ss -ltn "sport = :$PORT" 2>/dev/null | tail -n +2) ]]; then die "port $PORT is already in use (set EVAL_PORT)"; fi
  download_running && warn "a model download is running; it is recorded in the data (it matters mostly for CPU-offloaded quants)"
  return 0
}

start_server() { # quant
  local quant=$1 file ref reasoning
  file=$(model_file "$quant"); ref=$(image_ref)
  [[ $MODE == thinking ]] && reasoning=on || reasoning=off
  { set +x; } 2>/dev/null   # tracing stays off while the key exists in a variable or file (it would land in the xtrace file)
  KEY=$(python3 -c 'import secrets; print(secrets.token_hex(16))')
  export AIW_EVAL_KEY="$KEY"   # read by eval_short.py; exported here so run_job never expands the key under xtrace
  local envf="$TMPD/llama.env"
  write_key_envfile "$envf" KEY
  SERVER_NAME="aiw-eval-$$"
  local args=(-m "/models/$file" -c "$TOTAL_CTX" -np "$NP" -fa on -ctk "$KV" -ctv "$KV" -t "$THREADS"
              --jinja --reasoning "$reasoning" --no-webui --host 0.0.0.0 --port 8080 -fit on -fitt "$FIT_MARGIN_MIB")
  info "llama-server ${args[*]}"
  d run -d --rm --name "$SERVER_NAME" --gpus all --user "$(id -u):$(id -g)" -e HOME=/tmp --env-file "$envf" \
      -v "$MODEL_DIR":/models:ro -p "127.0.0.1:$PORT:8080" --entrypoint /app/llama-server "$ref" "${args[@]}" >/dev/null
  rm -f -- "$envf"
  set -x
  local t0=$SECONDS code
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/health" || true)
    [[ $code == 200 ]] && break
    if [[ -z $(d ps -q -f "name=$SERVER_NAME") ]]; then
      warn "the server container exited early; last log lines:"; d logs --tail 40 "$SERVER_NAME" 2>&1 || true
      SERVER_NAME=""; die "llama-server did not start"
    fi
    ((SECONDS - t0 < READY_TIMEOUT)) || { capture_server_log "$(job_id "$quant")"; die "llama-server not ready after ${READY_TIMEOUT}s (health code '$code')"; }
    sleep 2
  done
  info "server ready after $((SECONDS - t0)) s"
}

run_job() { # quant
  local quant=$1 id; id=$(job_id "$1")
  local file; file=$(model_file "$quant")
  [[ -f $MODEL_DIR/$file ]] || die "missing model file: $MODEL_DIR/$file"
  info "model: $file ($(du -h "$MODEL_DIR/$file" | cut -f1)), KV $KV, mode $MODE, $NP slots x $(slot_ctx) ctx, seeds $SEEDS"
  local pre dl=false; pre=$(nvidia-smi --query-gpu=temperature.gpu,clocks.sm,memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  download_running && dl=true
  start_server "$quant"
  local offload; offload=$(d logs "$SERVER_NAME" 2>&1 | grep -iE 'offloaded [0-9]+/[0-9]+ layers' | tail -1 | sed 's/^.*\(offloaded\)/\1/' | cut -c1-80 || true)
  info "GPU placement: ${offload:-unknown (see $id.server.log)}"
  local rc=0
  python3 "$HERE/eval_short.py" --tasks-repo "$EVAL_TASKS_REPO" --tasks-module "$EVAL_TASKS_MODULE" --base-url "http://127.0.0.1:$PORT" \
      --out "$RESULTS/$id.jsonl" --label "$id" --mode "$MODE" --seeds "$SEEDS" --parallel "$NP" || rc=$?
  capture_server_log "$id"
  stop_server
  python3 - "$RESULTS/$id.meta.json" "$(image_ref)" "$pre" "$dl" "$offload" "$(cfg_sig)" <<'PY'
import json, sys, datetime
p, ref, pre, dl, off, cfg = sys.argv[1:7]
json.dump({"date": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "image": ref,
           "gpu_before(temp,sm_clk,mem_used)": pre, "download_running": dl == "true", "gpu_placement": off, "config": cfg}, open(p, "w"), indent=1)
PY
  ((rc == 0)) || die "eval_short.py exited with $rc (partial results are kept; re-run apply to continue)"
  cfg_sig >"$RESULTS/$id.cfg"
  : >"$RESULTS/$id.ok"
}

# ------------------------------------------------------------------ report / export
report() {
  python3 - "$RESULTS" <<'PY'
import json, glob, os, sys
res = sys.argv[1]
rows = []
for f in sorted(glob.glob(os.path.join(res, "*.jsonl"))):
    base = f[:-6]
    if not os.path.exists(base + ".ok"): continue
    summ = [json.loads(l) for l in open(f) if l.strip() and '"summary"' in l]
    if not summ: continue
    s = summ[-1]; meta = json.load(open(base + ".meta.json"))
    quant, kv, mode = os.path.basename(base).split("__")
    rows.append((quant, kv, mode, s, meta))
if not rows: print("(no finished jobs)"); sys.exit(0)
print("Short coding tasks (8 tasks x seeds). The earlier baseline for a 3-bit 27B was 21/24 (instruct).")
print(f"{'quant':<12} {'KV':<5} {'mode':<9} {'passed':>8} {'95% CI':>10} {'trunc':>6} {'pass/untrunc':>13} {'mean tok':>9} {'wall s':>7}  placement")
for quant, kv, mode, s, meta in rows:
    lo, hi = s["ci95"]
    print(f"{quant:<12} {kv:<5} {mode:<9} {s['passed']:>3}/{s['of']:<4} {lo*100:>4.0f}-{hi*100:<4.0f}% {s['truncated']:>6} {s['passed_of_untruncated']:>13} {s['mean_completion_tokens']:>9.0f} {s['wall_seconds']:>7.0f}  {meta.get('gpu_placement','')}"
          + ("  [download was running]" if meta.get("download_running") else ""))
print("\nper task:")
for quant, kv, mode, s, meta in rows:
    print(f"  {quant} {kv} {mode}: " + " ".join(f"{k}={v}" for k, v in s["per_task"].items()))
PY
}

export_results() {
  mkdir -p "$KB_DATA"
  local out="$KB_DATA/eval-short-$(date +%F).jsonl"
  python3 - "$RESULTS" "$out" <<'PY'
import json, glob, os, sys
res, out = sys.argv[1:3]; n = 0
with open(out, "w") as o:
    for f in sorted(glob.glob(os.path.join(res, "*.jsonl"))):
        base = f[:-6]
        if not os.path.exists(base + ".ok"): continue
        quant, kv, mode = os.path.basename(base).split("__")
        meta = json.load(open(base + ".meta.json"))
        final, summary = {}, None
        for l in open(f):                      # a resumed job holds older, superseded rows: last one wins
            if not l.strip(): continue
            r = json.loads(l)
            if r.get("event") == "task": final[(r["task"], r["seed"])] = r
            elif r.get("event") == "summary": summary = r
        for r in list(final.values()) + ([summary] if summary else []):
            r.update({"quant": quant, "kv": kv, "harness": meta}); o.write(json.dumps(r) + "\n"); n += 1
print(f"{n} rows -> {out}")
if n == 0: os.remove(out)
PY
}

# ------------------------------------------------------------------ driver
init_logging "evalshort-$cmd"
# always stop the server, however the script ends; keep the real exit status for _cleanup
trap '_rc=$?; stop_server; _cleanup "$_rc"' EXIT
trap 'exit 130' INT TERM
info "command: $cmd quants=${QUANTS[*]} kv=$KV mode=$MODE seeds=$SEEDS parallel=$NP dry-run=$DRY_RUN"
snapshot
[[ $cmd == apply ]] && ((!DRY_RUN)) && [[ ${SKIP_SUDO_V:-0} != 1 ]] && { info "asking for sudo once"; sudo -v; }

show_status() {
  local q
  printf '%-34s %s\n' JOB STATE
  for q in "${QUANTS[@]}"; do
    printf '%-34s %s\n' "$(job_id "$q")" "$(job_done "$q" && echo DONE || { [[ -s $RESULTS/$(job_id "$q").jsonl ]] && echo PARTIAL || echo PENDING; })"
  done
}

case "$cmd" in
  status) show_status ;;
  report) report ;;
  export) export_results ;;
  apply)
    todo=0
    for q in "${QUANTS[@]}"; do
      id=$(job_id "$q"); CURRENT_STEP=$id; CURRENT_ACTION=check
      if job_done "$q"; then ok "$id already done"; record "$id" evalshort skipped; continue; fi
      if [[ ! -f $MODEL_DIR/$(model_file "$q") ]]; then warn "$id skipped: $(model_file "$q") is not there yet"; continue; fi
      todo=$((todo + 1))
      if ((DRY_RUN)); then info "[dry-run] would run $id ($NP slots x $(slot_ctx) ctx, seeds $SEEDS)"; continue; fi
      ((todo == 1)) && preflight
      [[ -f $RESULTS/$id.ok ]] && { arch="$STATE_DIR/results-archive/$(date +%Y%m%d-%H%M%S)"; mkdir -p "$arch"; mv "$RESULTS/$id".* "$arch/" 2>/dev/null || true; info "config changed: archived the old results of $id -> $arch"; }
      info ">>> run $id"; CURRENT_ACTION=run
      run_job "$q"
      ok "$id done"; record "$id" evalshort done
    done
    echo; show_status; echo; report
    ((DRY_RUN)) || export_results
    ;;
  undo)
    ((DRY_RUN)) || confirm "Delete the results of ${#QUANTS[@]} job(s)?" || die "aborted"
    for q in "${QUANTS[@]}"; do
      id=$(job_id "$q"); CURRENT_STEP=$id; CURRENT_ACTION=undo
      if ((DRY_RUN)); then info "[dry-run] would delete $id"; continue; fi
      rm -f "$RESULTS/$id".*; info "deleted results of $id"; record "$id" evalshort undone
    done
    ((DRY_RUN)) || export_results
    echo; show_status
    ;;
  *) echo "usage: $0 status|apply|report|export|undo [--quant Q] [--kv KV] [--mode M] [--seeds S] [--parallel N] [--dry-run] [--yes]" >&2; exit 2 ;;
esac
