#!/usr/bin/env bash
# eval-kl.sh - how far is each quantisation from the highest-precision one (Q8_0) on real code?
# Uses llama.cpp's own llama-perplexity: save the reference model's next-token distributions once
# (--kl-divergence-base), then score every other quant against them (--kl-divergence). The result is
# a continuous, low-noise number (mean KL divergence, "same top token" rate), unlike a 24-sample pass rate.
# It measures damage from quantisation, NOT coding ability. Idempotent, undoable, traced.
#
#   ./eval-kl.sh status | apply | report | export | undo
#   options: --quant Q (repeatable; default: every quant present except the reference)
#            --chunks 32  --ctx 2048  --corpus-dir DIR (repeatable)  --dry-run  --yes
#
# The reference logits file is big: chunks x (ctx - 1 - ctx/2) x n_vocab x 2 bytes
# (32 x 1023 x 248320 x 2 = 15.2 GiB). The corpus is built from YOUR code and never leaves this machine;
# only aggregate numbers are exported.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/eval-kl}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
IMAGE_STATE=${LLAMA_IMAGE_STATE:-$HOME/.local/state/ai-workstation/llama-image/image-digest.txt}
KB_DATA=${KB_DATA_DIR:-$HOME/code/ai-workstation-kb/data/benchmarks}
RESULTS="$STATE_DIR/results"; WORK="$STATE_DIR/work"; mkdir -p "$RESULTS" "$WORK"
REF_QUANT=${REF_QUANT:-Q8_0}
ALL_QUANTS=(UD-IQ3_XXS UD-IQ3_S UD-Q3_K_XL UD-IQ4_XS UD-Q4_K_M UD-Q5_K_M)
N_VOCAB=${N_VOCAB:-248320}           # read from the model's tokenizer (Qwen3.8-27B)
THREADS=${EVAL_THREADS:-6}
FIT_MARGIN_MIB=1024
VRAM_BASELINE_MAX_MIB=${VRAM_BASELINE_MAX_MIB:-3500}
MIN_CORPUS_BYTES=${MIN_CORPUS_BYTES:-350000}

d() { sudo docker "$@"; }
image_ref() { head -1 "$IMAGE_STATE" 2>/dev/null; }

DRY_RUN=0; CHUNKS=32; CTX=2048; QUANTS=(); CORPUS_DIRS=(); QUANT_GIVEN=0
cmd=${1:-status}; (($#)) && shift
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --quant) shift; QUANTS+=("${1:-}"); QUANT_GIVEN=1 ;;
    --chunks) shift; CHUNKS=${1:-} ;;
    --ctx) shift; CTX=${1:-} ;;
    --corpus-dir) shift; CORPUS_DIRS+=("${1:-}") ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ $CHUNKS =~ ^[1-9][0-9]*$ && $CTX =~ ^[1-9][0-9]*$ ]] || { echo "--chunks and --ctx must be positive integers" >&2; exit 2; }
((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }
# PRIVATE CONFIG: which of your own code directories form the corpus is not recorded in this repository.
# Define CORPUS_DEFAULT_DIRS=(dir ...) in ~/.config/ai-workstation/private.env (override: AIW_PRIVATE_ENV).
AIW_PRIVATE_ENV=${AIW_PRIVATE_ENV:-$HOME/.config/ai-workstation/private.env}
# shellcheck disable=SC1090
[[ -f $AIW_PRIVATE_ENV ]] && source "$AIW_PRIVATE_ENV"
if ((${#CORPUS_DIRS[@]} == 0)); then
  for dd in "${CORPUS_DEFAULT_DIRS[@]:-$HOME/code/ai-workstation-kb/scripts}"; do [[ -d $dd ]] && CORPUS_DIRS+=("$dd"); done
fi
model_file() { echo "Qwen3.8-27B-$1.gguf"; }
if ((${#QUANTS[@]} == 0)); then
  for q in "${ALL_QUANTS[@]}"; do [[ -f $MODEL_DIR/$(model_file "$q") ]] && QUANTS+=("$q"); done
fi

EXPECTED_BYTES=$(( CHUNKS * (CTX - 1 - CTX / 2) * N_VOCAB * 2 ))
BASE_FILE="$WORK/base-$REF_QUANT.kld"
cfg_sig() { echo "ctx=$CTX chunks=$CHUNKS corpus=$(cat "$WORK/corpus.sha256" 2>/dev/null || echo none)"; }
base_done()  { [[ -f $RESULTS/base.ok && $(cat "$RESULTS/base.cfg" 2>/dev/null) == "$(cfg_sig)" && -f $BASE_FILE ]]; }
job_done()   { [[ -f $RESULTS/$1.ok && $(cat "$RESULTS/$1.cfg" 2>/dev/null) == "$(cfg_sig)" ]]; }

# ------------------------------------------------------------------ corpus (your code, local only)
build_corpus() {
  python3 - "$WORK/corpus.txt" "$WORK/corpus.manifest.json" "$MIN_CORPUS_BYTES" "${CORPUS_DIRS[@]}" <<'PY'
import hashlib, json, os, re, sys
out, manifest, min_bytes, dirs = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:]
SKIP_DIRS = {".git", ".venv", "venv", "node_modules", "outputs", "__pycache__", ".cache", "data", "dist", "build"}
SKIP_NAME = re.compile(r"(\.env|secret|credential|token|password|\.pem$|\.key$|id_rsa|id_ed25519)", re.I)
EXT = (".py", ".sh", ".ps1")
files = []
for root in dirs:
    for dp, dn, fn in os.walk(root):
        dn[:] = sorted(x for x in dn if x not in SKIP_DIRS)
        for f in sorted(fn):
            p = os.path.join(dp, f)
            if f.endswith(EXT) and not SKIP_NAME.search(p) and 0 < os.path.getsize(p) <= 300_000:
                files.append(p)
files = sorted(set(files), key=lambda p: hashlib.sha1(p.encode()).hexdigest())   # deterministic mix, not alphabetical
buf, used = [], []
total = 0
for p in files:
    try: t = open(p, encoding="utf-8").read()
    except (UnicodeDecodeError, OSError): continue
    buf.append(t); used.append(p); total += len(t.encode())
    if total >= min_bytes * 1.6: break
if total < min_bytes:
    sys.exit(f"corpus too small: {total} bytes from {len(files)} files (need {min_bytes}); add --corpus-dir")
text = "\n\n".join(buf)
open(out, "w", encoding="utf-8").write(text)
sha = hashlib.sha256(text.encode()).hexdigest()
json.dump({"files": len(used), "bytes": total, "sha256": sha, "dirs": [os.path.basename(d.rstrip("/")) for d in dirs]}, open(manifest, "w"), indent=1)
print(f"corpus: {len(used)} files, {total} bytes, sha256 {sha[:16]}")
open(out + ".sha", "w").write(sha[:16])
PY
  cp "$WORK/corpus.txt.sha" "$WORK/corpus.sha256"; rm -f "$WORK/corpus.txt.sha"
}

# ------------------------------------------------------------------ llama.cpp calls
layers_for() { # quant file -> number of layers that fit (plain integer on stdout)
  local ref out; ref=$(image_ref)
  out=$(d run --rm --gpus all -v "$MODEL_DIR":/models:ro --entrypoint /app/llama-fit-params "$ref" \
        -m "/models/$1" -c "$CTX" -fitc "$CTX" -fitt "$FIT_MARGIN_MIB" -fa on 2>"$TMPD/fit.err") || { tail -n 20 "$TMPD/fit.err" >&2; return 1; }
  if [[ $out =~ -ngl[[:space:]]+(-?[0-9]+) ]]; then echo "${BASH_REMATCH[1]}"; else echo "cannot parse: $out" >&2; return 1; fi
}

ppl() { # quant outlog extra-args...  -> runs llama-perplexity; log kept
  local quant=$1 log=$2; shift 2
  local file ngl ref; file=$(model_file "$quant"); ref=$(image_ref)
  ngl=$(layers_for "$file") || die "llama-fit-params failed for $file"
  info "$file: $ngl layers on the GPU"
  info "llama-perplexity -m $file -f corpus.txt -c $CTX --chunks $CHUNKS -ngl $ngl -t $THREADS $*"
  d run --rm --gpus all --user "$(id -u):$(id -g)" -e HOME=/tmp -v "$MODEL_DIR":/models:ro -v "$WORK":/work \
      --entrypoint /app/llama-perplexity "$ref" -m "/models/$file" -f /work/corpus.txt -c "$CTX" --chunks "$CHUNKS" \
      -ngl "$ngl" -t "$THREADS" "$@" >"$log" 2>&1 || { tail -n 25 "$log"; return 1; }
}

parse_kl() { # logfile -> JSON on stdout; exit 1 if the expected statistics are missing
  python3 - "$1" <<'PY'
import json, re, sys
t = open(sys.argv[1], encoding="utf-8", errors="replace").read()
def pm(label, unit=""):   # "label : value ± err"
    m = re.search(re.escape(label) + r"\s*:\s*(-?[\d.]+)\s*(?:±\s*([\d.]+))?", t)
    return (float(m.group(1)), float(m.group(2)) if m.group(2) else None) if m else None
need = {"ppl_q": pm("Mean PPL(Q)"), "ppl_base": pm("Mean PPL(base)"), "mean_kld": pm("Mean    KLD"),
        "same_top_p_pct": pm("Same top p"), "rms_dp_pct": pm("RMS Δp"), "mean_dp_pct": pm("Mean    Δp"),
        "kld_p99": pm("99.0%   KLD"), "kld_median": pm("Median  KLD"), "kld_max": pm("Maximum KLD"),
        "cor_ln_ppl": pm("Cor(ln(PPL(Q)), ln(PPL(base)))")}
missing = [k for k in ("ppl_q", "ppl_base", "mean_kld", "same_top_p_pct") if not need[k]]
if missing: print("MISSING " + ",".join(missing)); sys.exit(1)
res = {k: (v[0] if v else None) for k, v in need.items()}
res.update({k + "_se": (v[1] if v else None) for k, v in need.items() if k in ("ppl_q", "ppl_base", "mean_kld", "same_top_p_pct", "rms_dp_pct", "mean_dp_pct")})
if res["mean_kld"] < 0 or not (0 <= res["same_top_p_pct"] <= 100): print("IMPLAUSIBLE values"); sys.exit(1)
print(json.dumps(res))
PY
}

preflight() {
  local ref; ref=$(image_ref)
  [[ -n $ref ]] || die "no pinned image digest at $IMAGE_STATE; run ./llama-image.sh apply first"
  d image inspect "$ref" >/dev/null 2>&1 || die "image $ref is not present locally"
  [[ -f $MODEL_DIR/$(model_file "$REF_QUANT") ]] || die "reference model missing: $MODEL_DIR/$(model_file "$REF_QUANT")"
  local procs; procs=$(running_jobs --no-downloads || true)
  if [[ -n $procs ]]; then echo "$procs" | cut -c1-160; die "another benchmark/server is running; wait for it to finish"; fi
  local used; used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  info "GPU memory in use before the run: ${used} MiB (limit ${VRAM_BASELINE_MAX_MIB})"
  if ((used > VRAM_BASELINE_MAX_MIB)); then warn "if Ollama holds a model: 'ollama ps' then 'ollama stop <model>'"; die "something else is using the GPU (${used} MiB)"; fi
  local free; free=$(df -B1 --output=avail "$WORK" | tail -1)
  info "reference logits will need about $((EXPECTED_BYTES / 1073741824)) GiB; free: $((free / 1073741824)) GiB"
  ((free > EXPECTED_BYTES * 2)) || die "not enough free disk for the reference logits (need > $((EXPECTED_BYTES * 2 / 1073741824)) GiB)"
}

run_base() {
  [[ -s $WORK/corpus.txt ]] || { info "building the corpus from: ${CORPUS_DIRS[*]}"; build_corpus; }
  if base_done; then ok "reference logits already saved ($REF_QUANT)"; return 0; fi
  rm -f "$BASE_FILE" "$RESULTS/base.ok"
  info "reference run: $REF_QUANT saves its next-token distributions (this is the slow one)"
  ppl "$REF_QUANT" "$RESULTS/base.log" --kl-divergence-base "/work/$(basename "$BASE_FILE")" \
    || die "reference run failed (log: $RESULTS/base.log)"
  grep -q 'Final estimate: PPL' "$RESULTS/base.log" || die "reference run finished without a perplexity estimate (log: $RESULTS/base.log)"
  local sz; sz=$(stat -c %s "$BASE_FILE" 2>/dev/null || echo 0)
  info "reference logits file: $((sz / 1048576)) MiB (expected about $((EXPECTED_BYTES / 1048576)) MiB)"
  ((sz > EXPECTED_BYTES * 95 / 100)) || die "reference logits file is smaller than expected ($sz < ~$EXPECTED_BYTES bytes)"
  grep -E 'Final estimate' "$RESULTS/base.log" | tail -1 | sed 's/^/    /'
  cfg_sig >"$RESULTS/base.cfg"; : >"$RESULTS/base.ok"
}

run_target() { # quant
  local q=$1 js
  rm -f "$RESULTS/$q.ok"
  ppl "$q" "$RESULTS/$q.log" --kl-divergence-base "/work/$(basename "$BASE_FILE")" --kl-divergence \
    || die "KL run failed for $q (log: $RESULTS/$q.log)"
  js=$(parse_kl "$RESULTS/$q.log") || { warn "$js"; tail -n 30 "$RESULTS/$q.log"; die "could not read the statistics for $q"; }
  python3 - "$RESULTS/$q.json" "$q" "$js" "$(stat -c %s "$MODEL_DIR/$(model_file "$q")")" "$(download_running && echo true || echo false)" <<'PY'
import json, sys, datetime
p, q, js, size, dl = sys.argv[1:6]
r = json.loads(js); r.update({"quant": q, "file_bytes": int(size), "download_running": dl == "true",
                              "date": datetime.datetime.now().astimezone().isoformat(timespec="seconds")})
json.dump(r, open(p, "w"), indent=1)
PY
  info "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("mean KLD %.5f, same top token %.2f%%, PPL %.3f (reference %.3f)" % (r["mean_kld"], r["same_top_p_pct"], r["ppl_q"], r["ppl_base"]))' "$RESULTS/$q.json")"
  cfg_sig >"$RESULTS/$q.cfg"; : >"$RESULTS/$q.ok"
}

report() {
  python3 - "$RESULTS" "$CHUNKS" "$CTX" <<'PY'
import json, glob, os, sys
res, chunks, ctx = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
rows = []
for f in glob.glob(os.path.join(res, "*.json")):
    if os.path.exists(f[:-5] + ".ok"): rows.append(json.load(open(f)))
if not rows: print("(no finished jobs)"); sys.exit(0)
rows.sort(key=lambda r: r["mean_kld"])
print(f"Distance from the reference (Q8_0) on code text: {chunks} chunks x {ctx} tokens; lower KLD / higher same-top-token = closer to the reference")
print(f"{'quant':<12} {'size GiB':>8} {'mean KLD':>11} {'± se':>9} {'99% KLD':>9} {'same top token':>15} {'RMS dp %':>9} {'PPL':>8} {'ref PPL':>8}")
for r in rows:
    print(f"{r['quant']:<12} {r['file_bytes']/2**30:>8.2f} {r['mean_kld']:>11.5f} {(r.get('mean_kld_se') or 0):>9.5f} {(r.get('kld_p99') or 0):>9.4f} "
          f"{r['same_top_p_pct']:>13.2f} % {(r.get('rms_dp_pct') or 0):>9.2f} {r['ppl_q']:>8.3f} {r['ppl_base']:>8.3f}"
          + ("  [download was running]" if r.get("download_running") else ""))
PY
}

export_results() {
  mkdir -p "$KB_DATA"
  local out="$KB_DATA/eval-kl-$(date +%F).jsonl"
  python3 - "$RESULTS" "$out" "$CHUNKS" "$CTX" "$WORK/corpus.manifest.json" <<'PY'
import json, glob, os, sys
res, out, chunks, ctx, man = sys.argv[1:6]
corpus = json.load(open(man)) if os.path.exists(man) else {}
n = 0
with open(out, "w") as o:
    for f in sorted(glob.glob(os.path.join(res, "*.json"))):
        if not os.path.exists(f[:-5] + ".ok"): continue
        r = json.load(open(f)); r.update({"reference": "Q8_0", "ctx": int(ctx), "chunks": int(chunks),
                                          "corpus": {k: corpus.get(k) for k in ("files", "bytes", "sha256")}})
        o.write(json.dumps(r) + "\n"); n += 1
print(f"{n} rows -> {out}")
if n == 0: os.remove(out)
PY
}

# ------------------------------------------------------------------ driver
init_logging "evalkl-$cmd"
info "command: $cmd quants=${QUANTS[*]:-none} chunks=$CHUNKS ctx=$CTX dry-run=$DRY_RUN"
snapshot
[[ $cmd == apply ]] && ((!DRY_RUN)) && [[ ${SKIP_SUDO_V:-0} != 1 ]] && { info "asking for sudo once"; sudo -v; }

show_status() {
  local q
  printf '%-14s %s\n' JOB STATE
  printf '%-14s %s\n' "reference" "$(base_done && echo "DONE ($REF_QUANT logits saved)" || echo PENDING)"
  for q in "${QUANTS[@]}"; do printf '%-14s %s\n' "$q" "$(job_done "$q" && echo DONE || echo PENDING)"; done
}

case "$cmd" in
  status) show_status ;;
  report) report ;;
  export) export_results ;;
  apply)
    ((${#QUANTS[@]})) || die "no quantisations found in $MODEL_DIR besides the reference"
    if ((DRY_RUN)); then
      base_done && info "[dry-run] reference logits already saved" || info "[dry-run] would build the corpus and save the $REF_QUANT reference (~$((EXPECTED_BYTES / 1073741824)) GiB)"
      for q in "${QUANTS[@]}"; do job_done "$q" && info "[dry-run] $q already done" || info "[dry-run] would score $q"; done
    else
      preflight
      CURRENT_STEP=reference; CURRENT_ACTION=run
      run_base
      for q in "${QUANTS[@]}"; do
        CURRENT_STEP=$q; CURRENT_ACTION=check
        if job_done "$q"; then ok "$q already done"; record "$q" evalkl skipped; continue; fi
        [[ -f $MODEL_DIR/$(model_file "$q") ]] || { warn "$q skipped: file not there yet"; continue; }
        info ">>> score $q"; CURRENT_ACTION=run
        run_target "$q"
        ok "$q done"; record "$q" evalkl done
      done
    fi
    echo; show_status; echo; report
    ((DRY_RUN)) || export_results
    ;;
  undo)
    ((DRY_RUN)) || confirm "Delete the KL results of ${QUANTS[*]} (and the reference logits + corpus if no --quant was given)?" || die "aborted"
    for q in "${QUANTS[@]}"; do
      CURRENT_STEP=$q; CURRENT_ACTION=undo
      if ((DRY_RUN)); then info "[dry-run] would delete $q"; continue; fi
      rm -f "$RESULTS/$q".*; info "deleted results of $q"; record "$q" evalkl undone
    done
    if ((!DRY_RUN)); then
      if ((QUANT_GIVEN)); then
        info "kept the reference logits and the corpus (no --quant would delete them too)"
      else
        rm -f "$RESULTS/base".* "$BASE_FILE" "$WORK/corpus.txt" "$WORK/corpus.manifest.json" "$WORK/corpus.sha256" "$WORK/corpus.txt.sha"
        info "deleted the reference logits and the corpus (the files this script generated; the folders are left alone)"
      fi
      export_results
    fi
    echo; show_status
    ;;
  *) echo "usage: $0 status|apply|report|export|undo [--quant Q] [--chunks N] [--ctx N] [--corpus-dir D] [--dry-run] [--yes]" >&2; exit 2 ;;
esac
