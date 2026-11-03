#!/usr/bin/env bash
# run-eval-suite.sh - run the whole evaluation in order, stop at the first failure, resume where it stopped.
# Every step is an existing script that is itself idempotent, undoable and traced; this one only orchestrates.
# It never deletes anything itself (undo calls each step's own undo, which removes only the files it generated).
#
#   ./run-eval-suite.sh plan                      what each step is and whether it still has work to do
#   ./run-eval-suite.sh status                    same, compact
#   ./run-eval-suite.sh apply [options]           run the steps (asks for sudo once, keeps it alive)
#   ./run-eval-suite.sh report                    print the reports of all steps and save them to data/benchmarks
#   ./run-eval-suite.sh undo [options]            undo the steps in REVERSE order (each step's own undo)
#   options: --dry-run  --yes  --from N  --only N,M  --skip N,M  --with-thinking
#
# Steps (the time estimates are guesses from earlier runs, not promises):
#   1 fit-memory     GPU memory per quant and context length                      ~1 min      reads metadata only
#   2 eval-kl        distance of every quant from Q8_0 on real code (KL)          ~25 min
#   3 bench-fit      speed vs context depth, quants that fit in VRAM              ~20 min
#   4 eval-short     8 short coding tasks x 3 seeds, thinking off, all quants     ~60-90 min  Q5_K_M/Q8_0 are slow
#   5 bench-spill    speed vs layers on the GPU, quants that spill (f16 KV)       ~45-60 min
#   6 eval-thinking  (optional, --with-thinking) coding tasks with thinking ON, IQ3_XXS/IQ3_S/Q3_K_XL, q8_0 KV, 2 slots   ~1-3 h (not measured)
# Run ONE of these at a time and do not use the GPU/CPU meanwhile: the CPU-offload numbers are noise-sensitive.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUITE_DIR=${SUITE_DIR:-$HERE}                       # where the step scripts live (tests point this at stubs)
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/eval-suite}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

KB_DATA=${KB_DATA_DIR:-$HOME/code/ai-workstation-kb/data/benchmarks}
VRAM_BASELINE_MAX_MIB=${VRAM_BASELINE_MAX_MIB:-3500}
IDLE_WAIT_SECONDS=${IDLE_WAIT_SECONDS:-180}
ALL_STEPS=(1 2 3 4 5)

DRY_RUN=0; WITH_THINKING=0; FROM=1; ONLY=""; SKIP=""
cmd=${1:-plan}; (($#)) && shift
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --with-thinking) WITH_THINKING=1 ;;
    --from) shift; FROM=${1:-1} ;;
    --only) shift; ONLY=${1:-} ;;
    --skip) shift; SKIP=${1:-} ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
((EUID == 0)) && { echo "Do not run as root; the step scripts call sudo themselves." >&2; exit 2; }
((WITH_THINKING)) && ALL_STEPS+=(6)

step_name() { case $1 in 1) echo fit-memory;; 2) echo eval-kl;; 3) echo bench-fit;; 4) echo eval-short;; 5) echo bench-spill;; 6) echo eval-thinking;; esac; }
step_est()  { case $1 in 1) echo "~1 min";; 2) echo "~25 min";; 3) echo "~20 min";; 4) echo "~60-90 min";; 5) echo "~45-60 min";; 6) echo "~30-60 min";; esac; }
step_desc() {
  case $1 in
    1) echo "GPU memory per quant and context length (metadata only)";;
    2) echo "KL distance of every quant from Q8_0 on your code";;
    3) echo "speed vs context depth, quants that fit in VRAM";;
    4) echo "8 short coding tasks x 3 seeds (thinking off), all quants";;
    5) echo "speed vs layers on the GPU, quants that spill (f16 KV, 6 threads)";;
    6) echo "short coding tasks with thinking ON (IQ3_XXS, IQ3_S, Q3_K_XL; q8_0 KV, 2 slots)";;
  esac
}
step_state_dir() { case $1 in 1) echo fit-memory;; 2) echo eval-kl;; 3|5) echo llama-bench;; 4|6) echo eval-short;; esac; }

# run_child N MODE [extra args]  - run step N's script with MODE (apply|status|undo|report). Children must not
# inherit this script's state dir, and they must not ask for sudo again (it is kept alive here).
run_child() {
  local n=$1 mode=$2; shift 2
  local script args=()
  case $n in
    1) script=fit-memory.sh; [[ $mode == report ]] && mode=compare ;;
    2) script=eval-kl.sh ;;
    3) script=bench-ladder.sh; args=(--tier fit) ;;
    4) script=eval-short.sh; args=(--mode instruct) ;;
    5) script=bench-ladder.sh; args=(--tier spill --kv f16) ;;
    # Step 6: q8_0 KV and 2 slots (ctx 32768) are the only setting at which these three stay entirely on the GPU.
    # The old setting (f16, 4 slots, ctx 65536) exceeded what fits for ALL four quants (max f16 ctx: 54.8K, 39.8K,
    # 23.5K, 6.6K), so every run would have spilled to the CPU. IQ4_XS is left out: even with q8_0 only 12K tokens
    # fit, less than one thinking sample needs.
    6) script=eval-short.sh; args=(--mode thinking --kv q8_0 --parallel 2 --quant UD-IQ3_XXS --quant UD-IQ3_S --quant UD-Q3_K_XL) ;;
  esac
  env -u AIW_STATE_DIR SKIP_SUDO_V=1 "$SUITE_DIR/$script" "$mode" "${args[@]}" "$@"
}

# pending_count N -> number of jobs of step N that still need work (parsed from the step's own `status`)
pending_count() {
  local out; out=$(run_child "$1" status 2>&1 || true)
  grep -vE '^\[[0-9:]+\]' <<<"$out" | grep -cE '(PENDING|PARTIAL|STALE)' || true
}
done_count() {
  local out; out=$(run_child "$1" status 2>&1 || true)
  grep -vE '^\[[0-9:]+\]' <<<"$out" | grep -cE '(^|[[:space:]])DONE' || true
}

selected_steps() { # -> step numbers, honouring --from/--only/--skip
  local n
  for n in "${ALL_STEPS[@]}"; do
    ((n >= FROM)) || continue
    if [[ -n $ONLY ]]; then [[ ",$ONLY," == *",$n,"* ]] || continue; fi
    if [[ -n $SKIP && ",$SKIP," == *",$n,"* ]]; then continue; fi
    echo "$n"
  done
}

# ------------------------------------------------------------------ sudo kept alive for the whole run
KEEPALIVE_PID=""
start_sudo_keepalive() {
  [[ ${SKIP_SUDO_V:-0} == 1 ]] && return 0
  info "asking for sudo once; it is refreshed in the background until this script ends"
  sudo -v
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || exit 0; sleep 50; done ) &
  KEEPALIVE_PID=$!
}
stop_sudo_keepalive() {
  if [[ -n $KEEPALIVE_PID ]]; then
    pkill -P "$KEEPALIVE_PID" 2>/dev/null || true      # the 'sleep' it is waiting in
    kill "$KEEPALIVE_PID" 2>/dev/null || true
  fi
  KEEPALIVE_PID=""
}

wait_until_idle() { # between steps: the previous step's containers are gone and the GPU is back at its baseline
  local t0=$SECONDS used procs
  while :; do
    procs=$(running_jobs --no-downloads || true)
    used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' || echo 0)
    [[ -z $procs && ${used:-0} -le $VRAM_BASELINE_MAX_MIB ]] && return 0
    ((SECONDS - t0 < IDLE_WAIT_SECONDS)) || { warn "not idle after ${IDLE_WAIT_SECONDS}s (GPU ${used:-?} MiB); the next step will check again and may refuse"; return 0; }
    sleep 5
  done
}

fmt_duration() { printf '%dh%02dm%02ds' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60)); }

# ------------------------------------------------------------------ driver
init_logging "suite-$cmd"
trap '_rc=$?; stop_sudo_keepalive; _cleanup "$_rc"' EXIT
trap 'exit 130' INT TERM
info "command: $cmd steps=$(selected_steps | tr '\n' ' ') dry-run=$DRY_RUN with-thinking=$WITH_THINKING"
snapshot

case "$cmd" in
  plan|status)
    printf '%-4s %-14s %-9s %-11s %s\n' STEP NAME WORK ESTIMATE DESCRIPTION
    total_pending=0
    for n in "${ALL_STEPS[@]}"; do
      p=$(pending_count "$n"); d=$(done_count "$n")
      [[ $p -eq 0 && $d -gt 0 ]] && work="done" || work="$p to do"
      printf '%-4s %-14s %-9s %-11s %s\n' "$n" "$(step_name "$n")" "$work" "$(step_est "$n")" "$(step_desc "$n")"
      total_pending=$((total_pending + p))
    done
    echo; info "jobs still to do across the steps: $total_pending"
    ;;

  apply)
    steps=(); while read -r n; do [[ -n $n ]] && steps+=("$n"); done < <(selected_steps)
    ((${#steps[@]})) || die "no steps selected"
    if ((DRY_RUN)); then
      for n in "${steps[@]}"; do
        info "=== step $n: $(step_name "$n") - $(step_desc "$n") [dry-run]"
        run_child "$n" apply --dry-run 2>&1 | grep -E 'dry-run\]|already|skipped|stale' | cut -c1-150 || true
      done
      exit 0
    fi
    start_sudo_keepalive
    suite_t0=$SECONDS
    for n in "${steps[@]}"; do
      CURRENT_STEP="step$n"; CURRENT_ACTION=check
      name=$(step_name "$n")
      p=$(pending_count "$n")
      if ((p == 0)); then ok "step $n ($name): nothing left to do"; record "$name" suite skipped; continue; fi
      info "=== step $n/${#ALL_STEPS[@]}: $name - $(step_desc "$n")  ($p job(s) to do, $(step_est "$n"))"
      CURRENT_ACTION=run; t0=$SECONDS
      wait_until_idle
      rc=0; run_child "$n" apply || rc=$?
      dur=$((SECONDS - t0))
      if ((rc != 0)); then
        record "$name" suite "failed($rc)"
        sd="$HOME/.local/state/ai-workstation/$(step_state_dir "$n")"
        err "step $n ($name) FAILED with exit code $rc after $(fmt_duration "$dur")"
        err "its error file:   $sd/last-error.txt"
        err "its latest log:   $(readlink -f "$sd/logs/latest.log" 2>/dev/null || echo "$sd/logs/")"
        err "fix the cause, then run this script again: finished work is kept and the step resumes"
        die "stopped at step $n ($name)"
      fi
      ok "step $n ($name) finished in $(fmt_duration "$dur")"; record "$name" suite "done($(fmt_duration "$dur"))"
    done
    ok "all selected steps finished in $(fmt_duration $((SECONDS - suite_t0)))"
    info "next: ./run-eval-suite.sh report"
    ;;

  report)
    out="$KB_DATA/eval-suite-report-$(date +%F).txt"; mkdir -p "$KB_DATA"
    {
      echo "Evaluation suite report - $(date -Is)"
      echo "image: $(head -1 "$HOME/.local/state/ai-workstation/llama-image/image-digest.txt" 2>/dev/null || echo unknown)"
      for n in "${ALL_STEPS[@]}"; do
        echo; echo "################ step $n: $(step_name "$n") - $(step_desc "$n")"
        if [[ $n == 5 ]]; then echo "(printed together with step 3: both use bench-ladder's single results table)"; continue; fi
        run_child "$n" report 2>&1 | grep -vE '^\[[0-9:]+\] \[(INFO|WARN)\]' || true
      done
    } | tee "$out" >/dev/null
    cat "$out"
    info "saved to $out"
    ;;

  undo)
    steps=(); while read -r n; do [[ -n $n ]] && steps+=("$n"); done < <(selected_steps)
    ((${#steps[@]})) || die "no steps selected"
    rev=(); for ((i = ${#steps[@]} - 1; i >= 0; i--)); do rev+=("${steps[$i]}"); done
    info "undo plan (reverse order): ${rev[*]}"
    ((DRY_RUN)) || confirm "Undo steps ${rev[*]}? Each step removes only the result files it generated." || die "aborted"
    for n in "${rev[@]}"; do
      CURRENT_STEP="step$n"; CURRENT_ACTION=undo
      if ((DRY_RUN)); then info "[dry-run] would undo step $n ($(step_name "$n"))"; continue; fi
      info "<<< undo step $n ($(step_name "$n"))"
      run_child "$n" undo --yes
      ok "step $n undone"; record "$(step_name "$n")" suite undone
    done
    ;;

  *) echo "usage: $0 plan|status|apply|report|undo [--dry-run] [--yes] [--from N] [--only N,M] [--skip N,M] [--with-thinking]" >&2; exit 2 ;;
esac
