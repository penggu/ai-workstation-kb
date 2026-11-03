#!/usr/bin/env bash
# download-gguf.sh - download Qwen3.8-27B GGUF quantisations from Hugging Face (unsloth), resumable,
# verified against the sha256 that Hugging Face publishes. Idempotent, undoable, leaves a debug trace.
#
#   ./download-gguf.sh status [QUANT...]
#   ./download-gguf.sh apply  [QUANT...]       (default QUANTs: UD-IQ3_S UD-IQ4_XS UD-Q4_K_M)
#   ./download-gguf.sh undo   [QUANT...]       deletes ONLY files this script downloaded
#   options: --dry-run  --yes
#
# Files that already existed before (the first four quants) are never deleted by `undo`.
# Needs no root. Hashing runs at the lowest CPU/IO priority so it disturbs measurements as little as possible.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/download-gguf}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

REPO=${GGUF_REPO:-unsloth/Qwen3.8-27B-GGUF}
DEST=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
DEFAULT_QUANTS=(UD-IQ3_S UD-IQ4_XS UD-Q4_K_M)
VERIFIED="$STATE_DIR/verified"; mkdir -p "$VERIFIED" "$DEST"

DRY_RUN=0
cmd=${1:-status}; (($#)) && shift
QUANTS=()
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) QUANTS+=("$1") ;;
  esac
  shift
done
((${#QUANTS[@]})) || QUANTS=("${DEFAULT_QUANTS[@]}")
((EUID == 0)) && { echo "Do not run as root." >&2; exit 2; }

fname() { echo "Qwen3.8-27B-$1.gguf"; }
marker_ok()      { echo "$VERIFIED/$(fname "$1").sha256"; }
marker_created() { echo "$CREATED_DIR/$(fname "$1")"; }

# expected "size oid" for a quant, from the Hugging Face API (AIW_TREE_JSON overrides it for tests)
expected() { # quant -> prints "size oid"
  python3 - "$REPO" "$(fname "$1")" <<'PY'
import json, os, sys, urllib.request
repo, name = sys.argv[1:3]
if os.environ.get("AIW_TREE_JSON"):
    tree = json.load(open(os.environ["AIW_TREE_JSON"]))
else:
    req = urllib.request.Request(f"https://huggingface.co/api/models/{repo}/tree/main?recursive=1", headers={"User-Agent": "aiw"})
    tree = json.load(urllib.request.urlopen(req, timeout=30))
for f in tree:
    if f["path"] == name:
        lfs = f.get("lfs", {})
        print(lfs.get("size", f["size"]), lfs.get("oid", ""))
        sys.exit(0)
sys.exit(f"{name} not found in {repo}")
PY
}

sha256_low_priority() { # path -> hex digest, at the lowest priority
  local pre=(nice -n 19)
  command -v ionice >/dev/null 2>&1 && pre=(ionice -c3 nice -n 19)
  "${pre[@]}" python3 - "$1" <<'PY'
import hashlib, sys
h = hashlib.sha256()
with open(sys.argv[1], "rb") as f:
    for b in iter(lambda: f.read(1 << 24), b""): h.update(b)
print(h.hexdigest())
PY
}

is_done() { # quant -> 0 if the file exists, has the expected size, and was verified against the expected sha256
  local q=$1 f="$DEST/$(fname "$1")" size oid
  [[ -f $f && -f $(marker_ok "$q") ]] || return 1
  read -r size oid < <(expected "$q") || return 1
  [[ $(stat -c %s "$f") == "$size" && $(cat "$(marker_ok "$q")") == "$oid" ]]
}

download_one() { # quant
  local q=$1 f="$DEST/$(fname "$1")" size oid
  read -r size oid < <(expected "$q")
  [[ -n $oid ]] || die "no sha256 published for $(fname "$q")"
  local present=0; [[ -f $f ]] && present=1
  if ((present)) && [[ $(stat -c %s "$f") == "$size" ]]; then
    info "$(fname "$q"): full-size file already there; verifying it"
  else
    ((present)) || : >"$(marker_created "$q")"
    local free; free=$(df -B1 --output=avail "$DEST" | tail -1)
    ((free > size + 5 * 1024 * 1024 * 1024)) || die "not enough disk space for $(fname "$q") ($((size / 1048576)) MiB needed)"
    info "downloading $(fname "$q") ($((size / 1048576)) MiB) -> $DEST"
    local try
    for try in 1 2 3; do
      if uvx --quiet --from huggingface_hub hf download "$REPO" "$(fname "$q")" --local-dir "$DEST" >/dev/null 2>"$TMPD/hf.err"; then break; fi
      warn "attempt $try failed: $(tail -n 2 "$TMPD/hf.err" | tr '\n' ' ' | cut -c1-200)"; sleep 5
      ((try < 3)) || die "download failed 3 times for $(fname "$q")"
    done
  fi
  [[ $(stat -c %s "$f") == "$size" ]] || die "size mismatch for $(fname "$q"): $(stat -c %s "$f") != $size"
  info "verifying sha256 (low priority)..."
  local got; got=$(sha256_low_priority "$f")
  if [[ $got != "$oid" ]]; then
    mv -f "$f" "$f.bad"; die "sha256 MISMATCH for $(fname "$q"): got $got, expected $oid (file kept as $f.bad)"
  fi
  printf '%s' "$oid" >"$(marker_ok "$q")"
}

init_logging "dl-$cmd"
info "command: $cmd quants=${QUANTS[*]} dry-run=$DRY_RUN repo=$REPO"
snapshot

case "$cmd" in
  status)
    printf '%-14s %-10s %s\n' QUANT STATE FILE
    for q in "${QUANTS[@]}"; do
      if is_done "$q"; then st=DONE; elif [[ -f $DEST/$(fname "$q") ]]; then st="PRESENT (unverified or partial)"; else st=PENDING; fi
      printf '%-14s %-10s %s\n' "$q" "$st" "$(fname "$q")"
    done
    ;;
  apply)
    for q in "${QUANTS[@]}"; do
      CURRENT_STEP=$q; CURRENT_ACTION=check
      if is_done "$q"; then ok "$q already downloaded and verified"; record "$q" download skipped; continue; fi
      if ((DRY_RUN)); then read -r size _ < <(expected "$q"); info "[dry-run] would download $(fname "$q") ($((size / 1048576)) MiB)"; continue; fi
      info ">>> $q"; CURRENT_ACTION=download
      download_one "$q"
      ok "$q done"; record "$q" download done
    done
    ;;
  undo)
    ((DRY_RUN)) || confirm "Delete the files this script downloaded (${QUANTS[*]})?" || die "aborted"
    for q in "${QUANTS[@]}"; do
      CURRENT_STEP=$q; CURRENT_ACTION=undo
      f="$DEST/$(fname "$q")"
      if [[ -e $(marker_created "$q") ]]; then
        if ((DRY_RUN)); then info "[dry-run] would delete $f"; continue; fi
        rm -f "$f" "$f.bad" "$(marker_created "$q")" "$(marker_ok "$q")"
        rm -f "$DEST/.cache/huggingface/download/$(fname "$q")."* 2>/dev/null || true
        info "deleted $f"; record "$q" download undone
      else
        info "$(fname "$q") was not downloaded by this script (or is already gone): left alone"
        rm -f "$(marker_ok "$q")"
      fi
    done
    ;;
  *) echo "usage: $0 status|apply|undo [QUANT...] [--dry-run] [--yes]" >&2; exit 2 ;;
esac
