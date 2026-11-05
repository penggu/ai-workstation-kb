#!/usr/bin/env bash
# llama-image.sh - pull the official llama.cpp CUDA image and prove it works on this GPU
# (Blackwell, sm_120). Idempotent, undoable, leaves a debug trace like setup.sh.
#
#   ./llama-image.sh status | apply | undo   [--dry-run] [--yes]
#
# Steps
#   1  pull ghcr.io/ggml-org/llama.cpp:full-cuda and record its digest + build version
#   2  the container sees the GPU (llama.cpp device list, compute capability)
#   3  a real CUDA kernel runs: llama-bench on the smallest GGUF found (proves sm_120 kernels exist)
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/llama-image}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

IMAGE=${LLAMA_IMAGE:-ghcr.io/ggml-org/llama.cpp:full-cuda}
MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
DIGEST_FILE="$STATE_DIR/image-digest.txt"
DEVICES_OK="$STATE_DIR/devices-ok"
KERNEL_OK="$STATE_DIR/kernel-ok"

STEP_IDS=(l1 l2 l3)
l1_desc() { echo "pull $IMAGE and record digest + version"; }
l2_desc() { echo "container sees the GPU (llama.cpp device list)"; }
l3_desc() { echo "real CUDA kernel runs (llama-bench on the smallest GGUF)"; }

d() { sudo docker "$@"; }   # this user is not in the docker group, by design

_bin() { # find a llama.cpp binary inside the image; print its path
  d run --rm --entrypoint sh "$IMAGE" -c \
    "for p in /app/$1 /app/full/$1 /usr/local/bin/$1; do [ -x \$p ] && { echo \$p; exit 0; }; done; find / -maxdepth 4 -name $1 -type f 2>/dev/null | head -1"
}

_smallest_gguf() { # smallest *complete* GGUF in MODEL_DIR (hf writes the final name only when done)
  [[ -d $MODEL_DIR ]] || return 0
  find "$MODEL_DIR" -maxdepth 1 -name '*.gguf' -type f -printf '%s %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2-
}

# ---------------------------------------------------------------- l1
l1_check() { [[ -s $DIGEST_FILE ]]; }
l1_apply() {
  local existed=1
  d image inspect "$IMAGE" >/dev/null 2>&1 || existed=0
  ((existed)) || : >"$CREATED_DIR/l1__image"
  d pull "$IMAGE"
  local digest; digest=$(d image inspect --format '{{index .RepoDigests 0}}' "$IMAGE")
  [[ -n $digest ]] || die "could not read the image digest"
  local bench; bench=$(_bin llama-bench)
  [[ -n $bench ]] || die "llama-bench not found inside $IMAGE (ls /app shown below)"
  info "llama-bench at: $bench"
  d run --rm --entrypoint sh "$IMAGE" -c 'ls -1 /app | head -40'
  local ver; ver=$(d run --rm --gpus all --entrypoint "$(_bin llama-cli)" "$IMAGE" --version 2>&1 | grep -E 'version|built' | head -2 | tr '\n' ' ')
  printf '%s\n' "$digest" >"$DIGEST_FILE"
  printf 'bench=%s\nversion=%s\n' "$bench" "$ver" >>"$DIGEST_FILE"
  info "digest:  $digest"
  info "version: $ver"
}
l1_undo() {
  rm -f "$DIGEST_FILE" "$DEVICES_OK" "$KERNEL_OK"
  if [[ -e $CREATED_DIR/l1__image ]]; then
    d rmi "$IMAGE" >/dev/null 2>&1 || warn "could not remove $IMAGE (in use?)"
    rm -f "$CREATED_DIR/l1__image"
    info "removed image $IMAGE"
  else
    info "image was already present before this script; left alone"
  fi
}

# ---------------------------------------------------------------- l2
l2_check() { [[ -f $DEVICES_OK ]]; }
l2_apply() {
  [[ -s $DIGEST_FILE ]] || die "apply l1 first"
  local cli out; cli=$(_bin llama-cli)
  out=$(d run --rm --gpus all --entrypoint "$cli" "$IMAGE" --list-devices 2>&1) || true
  echo "$out"
  if grep -qiE 'no kernel image|CUDA error|invalid device' <<<"$out"; then die "CUDA error while listing devices"; fi
  grep -qiE '5070|CUDA0' <<<"$out" || die "no CUDA device reported by llama.cpp (see output above)"
  printf '%s\n' "$out" >"$DEVICES_OK"
}
l2_undo() { rm -f "$DEVICES_OK"; info "l2: marker removed"; }

# ---------------------------------------------------------------- l3
l3_check() { [[ -f $KERNEL_OK ]]; }
l3_apply() {
  [[ -s $DIGEST_FILE ]] || die "apply l1 first"
  local gguf; gguf=$(_smallest_gguf)
  if [[ -z $gguf ]]; then
    warn "l3 SKIPPED: no complete .gguf in $MODEL_DIR yet; re-run apply when a download has finished"
    return 0
  fi
  info "using $(basename "$gguf") ($(du -h "$gguf" | cut -f1))"
  local bench out; bench=$(_bin llama-bench)
  if ! out=$(d run --rm --gpus all -v "$(dirname "$gguf")":/models:ro --entrypoint "$bench" "$IMAGE" \
        -m "/models/$(basename "$gguf")" -ngl 99 -p 64 -n 16 -r 1 2>&1); then
    echo "$out"
    grep -qi 'no kernel image' <<<"$out" && warn "'no kernel image' = this build has no kernels for sm_120 (Blackwell). Try LLAMA_IMAGE=ghcr.io/ggml-org/llama.cpp:full-cuda13"
    die "llama-bench failed"
  fi
  echo "$out"
  grep -qE 'tg16|pp64' <<<"$out" || die "llama-bench finished but printed no result rows"
  printf '%s\n%s\n' "$(basename "$gguf")" "$out" >"$KERNEL_OK"
}
l3_undo() { rm -f "$KERNEL_OK"; info "l3: marker removed"; }

# ------------------------------------------------------------- driver
DRY_RUN=0
cmd=${1:-status}; (($#)) && shift
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }

init_logging "llama-$cmd"
info "command: $cmd (dry-run=$DRY_RUN)  image: $IMAGE"
snapshot
[[ $cmd != status ]] && ((!DRY_RUN)) && [[ ${SKIP_SUDO_V:-0} != 1 ]] && { info "asking for sudo once"; sudo -v; }

show_status() {
  local id
  printf '%-4s %-8s %s\n' STEP STATE DESCRIPTION
  for id in "${STEP_IDS[@]}"; do
    if "${id}_check"; then printf '%-4s %-8s %s\n' "$id" DONE "$("${id}_desc")"
    else printf '%-4s %-8s %s\n' "$id" PENDING "$("${id}_desc")"; fi
  done
}

case "$cmd" in
  status) show_status ;;
  apply)
    for id in "${STEP_IDS[@]}"; do
      CURRENT_STEP=$id; CURRENT_ACTION=check
      if "${id}_check"; then ok "$id already done"; record "$id" apply skipped; continue; fi
      ((DRY_RUN)) && { info "[dry-run] would apply $id - $("${id}_desc")"; continue; }
      info ">>> apply $id - $("${id}_desc")"; CURRENT_ACTION=apply
      "${id}_apply"
      CURRENT_ACTION=post-check
      if "${id}_check"; then ok "$id done"; record "$id" apply "done"
      else warn "$id did not reach its goal (see warnings above); it will run again next time"; record "$id" apply incomplete; fi
    done
    echo; show_status
    ;;
  undo)
    ((DRY_RUN)) || confirm "Undo l3, l2, l1 (removes the pulled image if this script pulled it)?" || die "aborted"
    for id in l3 l2 l1; do
      CURRENT_STEP=$id; CURRENT_ACTION=undo
      ((DRY_RUN)) && { info "[dry-run] would undo $id"; continue; }
      info "<<< undo $id"; "${id}_undo"; record "$id" undo "done"
    done
    echo; show_status
    ;;
  *) echo "usage: $0 status|apply|undo [--dry-run] [--yes]" >&2; exit 2 ;;
esac
