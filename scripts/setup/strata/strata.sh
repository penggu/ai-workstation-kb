#!/usr/bin/env bash
# strata.sh - install the Strata Terminal (github.com/Niko1221/Strata, MIT) in WSL2 Ubuntu.
# Idempotent, undoable, every run leaves a debug trace. Uses the shared helpers in ../docker-gpu/lib.sh.
#
#   ./strata.sh status | apply | undo | update | logs      [--dry-run] [--yes] [--installer-sha256 HASH]
#
# Steps:
#   st1  the Terminal: downloads the project's own install.sh, REFUSES to run it unless its SHA-256 is the one this
#        script was reviewed against, then runs it. The installer needs no sudo, writes only under ~/.local
#        (share/strata/terminal/<version> and a `strata` link in ~/.local/bin), checks its download's SHA-256 and a
#        signed release feed, and sends no telemetry (docs/SAFETY.md in the Strata repo).
#
# NOT done here, on purpose (each is big or changes behaviour; you decide):
#   * the engine and the model: `strata launch` downloads them the first time you choose a model (many GB).
#   * starting a model: it needs the whole GPU, so stop the llama.cpp server first (../docker-gpu/local-llm.sh stop),
#     and both default to port 8080.
#
# Model download (run by hand, in the background; resumable, about 68 GB for Q2_0, files go to ~/strata-data/models/Q2_0):
#   setsid nohup strata install --family qwen --model Q2_0 --yes --no-start --data-dir ~/strata-data > <logfile> 2>&1 &
# The model is Qwen3.8-Flash-Next, not the Qwen3.8-27B of docs/recipes/qwen-27b-quantisation-16gb.md. Remove it by
# deleting ~/strata-data/models/Q2_0 yourself (this script does not create or delete model files).
#
# If the installer changed since it was reviewed, apply stops and prints the new hash. Read the installer
# ($STATE_DIR/install.sh), then run again with --installer-sha256 <that hash>.
#
# undo removes only what the installer created: terminal/<version> (the version recorded at apply), the `current`
# link and ~/.local/bin/strata (only if it points into the Strata terminal folder). It never touches the engine
# components, models or settings that `strata launch` created; the paths are printed so you can decide.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/strata}"
# shellcheck source=../docker-gpu/lib.sh
source "$HERE/../docker-gpu/lib.sh"

INSTALLER_URL="https://github.com/Niko1221/Strata/releases/latest/download/install.sh"
# SHA-256 of the install.sh that was read line by line on 2026-11-04 (release v0.2.10)
REVIEWED_SHA256="d47754af1f74c95bf763e0b8d484232443466decd1a22d0be3208760a2f53822"
DATA_DIR="${STRATA_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/strata}"
BIN_DIR="${STRATA_BIN_DIR:-$HOME/.local/bin}"
VERSION_FILE="$STATE_DIR/installed-terminal-version"
STEP_IDS=(st1)

_strata_version() { "$BIN_DIR/strata" --version 2>/dev/null | head -1 || true; }

# ---------------------------------------------------------------- st1
st1_desc()  { echo "Strata Terminal (no sudo; $DATA_DIR/terminal, link $BIN_DIR/strata)"; }
st1_check() { [[ -x $BIN_DIR/strata && -n $(_strata_version) ]]; }
st1_apply() {
  command -v curl >/dev/null || die "curl is not installed (sudo apt install curl)"
  info "downloading the installer: $INSTALLER_URL"
  curl -fsSL --max-time 60 "$INSTALLER_URL" -o "$STATE_DIR/install.sh"
  [[ -s $STATE_DIR/install.sh ]] || die "the downloaded installer is empty"
  local got; got=$(sha256sum "$STATE_DIR/install.sh" | cut -d' ' -f1)
  info "installer sha256: $got"
  if [[ $got != "$WANT_SHA256" ]]; then
    err "the installer is not the one that was reviewed."
    err "  reviewed: $WANT_SHA256"
    err "  now:      $got"
    die "read $STATE_DIR/install.sh, and if it is fine run again with: --installer-sha256 $got"
  fi
  info "running the installer (user level; it downloads the Terminal archive and checks its checksum and signature)"
  sh "$STATE_DIR/install.sh"
  local cur; cur=$(readlink -f "$DATA_DIR/terminal/current" 2>/dev/null || true)
  [[ -d $cur ]] || die "the installer finished but $DATA_DIR/terminal/current is missing"
  basename "$cur" >"$VERSION_FILE"
  info "installed Terminal folder: $cur"
  info "strata --version: $(_strata_version)"
}
st1_undo() {
  local ver="" link target
  [[ -f $VERSION_FILE ]] && ver=$(head -1 "$VERSION_FILE")
  link="$BIN_DIR/strata"
  if [[ -L $link ]]; then
    target=$(readlink "$link" || true)
    if [[ $target == "$DATA_DIR/terminal/"* ]]; then rm -f -- "$link"; ok "removed link $link"
    else warn "$link points to $target (not the Strata terminal); left alone"; fi
  else info "st1: no $link link"; fi
  if [[ -L $DATA_DIR/terminal/current ]]; then rm -f -- "$DATA_DIR/terminal/current"; ok "removed link $DATA_DIR/terminal/current"; fi
  if [[ $ver =~ ^[A-Za-z0-9._+-]+$ && -d $DATA_DIR/terminal/$ver ]]; then
    rm -rf -- "$DATA_DIR/terminal/$ver"; ok "removed $DATA_DIR/terminal/$ver"
  else info "st1: no recorded Terminal folder to remove"; fi
  rmdir "$DATA_DIR/terminal" 2>/dev/null || true      # only if now empty
  rm -f -- "$VERSION_FILE"
  local left; left=$(ls -d "$DATA_DIR"/* "$HOME/.strata" 2>/dev/null || true)
  [[ -z $left ]] || { info "NOT removed (created later by 'strata launch', engine/models/settings; delete yourself if you want):"; echo "$left" | sed 's/^/    /'; }
}

# ---------------------------------------------------------------- driver
usage() { sed -n '2,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

step_apply() {
  local id=$1; CURRENT_STEP=$id; CURRENT_ACTION=check
  if "${id}_check"; then ok "$id already done - $("${id}_desc")"; record "$id" apply skipped; return 0; fi
  if ((DRY_RUN)); then info "[dry-run] would apply $id - $("${id}_desc")"; return 0; fi
  info ">>> apply $id - $("${id}_desc")"; CURRENT_ACTION=apply
  "${id}_apply"
  CURRENT_ACTION=post-check
  "${id}_check" || die "$id: apply finished but the check still fails (the step did not reach its goal)"
  ok "$id done"; record "$id" apply "done"
}
step_undo() {
  local id=$1; CURRENT_STEP=$id; CURRENT_ACTION=undo
  if ((DRY_RUN)); then info "[dry-run] would undo $id - $("${id}_desc")"; return 0; fi
  info "<<< undo $id - $("${id}_desc")"; "${id}_undo"; ok "$id undone"; record "$id" undo "done"
}
cmd_status() {
  local id state; printf '%-5s %-8s %s\n' STEP STATE DESCRIPTION
  for id in "${STEP_IDS[@]}"; do
    CURRENT_STEP=$id; CURRENT_ACTION=check
    if "${id}_check"; then state=DONE; else state=PENDING; fi
    printf '%-5s %-8s %s\n' "$id" "$state" "$("${id}_desc")"
  done
  if st1_check; then echo "version: $(_strata_version)"; fi
}
cmd_update() {
  st1_check || die "Strata is not installed; run apply first"
  CURRENT_STEP=update; CURRENT_ACTION=check
  if ((DRY_RUN)); then info "[dry-run] would run: strata update --check"; return 0; fi
  "$BIN_DIR/strata" update --check || true
  info "to update: $BIN_DIR/strata update   (it asks before stopping a running model)"
  record update check "done"
}
cmd_logs() {
  echo "state dir:    $STATE_DIR"
  echo "latest log:   $(readlink -f "$LOG_DIR/latest.log" 2>/dev/null || echo none)"
  echo "latest trace: $(readlink -f "$LOG_DIR/latest.trace" 2>/dev/null || echo none)"
  echo "last error:   $ERROR_FILE $([[ -f $ERROR_FILE ]] || echo '(none)')"
  [[ -f $ERROR_FILE ]] && { echo; head -12 "$ERROR_FILE"; }
}

main() {
  DRY_RUN=0; WANT_SHA256=$REVIEWED_SHA256
  local cmd=${1:-help}; (($#)) && shift
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --installer-sha256) shift; WANT_SHA256=${1:-}; [[ $WANT_SHA256 =~ ^[0-9a-f]{64}$ ]] || { echo "--installer-sha256 needs 64 hex characters" >&2; exit 2; } ;;
      --help|-h) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$cmd" in help|--help|-h) usage; exit 0 ;; logs) cmd_logs; exit 0 ;; esac
  ((EUID == 0)) && { echo "Do not run this as root (or with sudo). Run it as your normal user." >&2; exit 2; }

  init_logging "strata-$cmd"
  info "command: $cmd (dry-run=$DRY_RUN yes=$ASSUME_YES)"
  snapshot

  case "$cmd" in
    status) cmd_status ;;
    apply) for id in "${STEP_IDS[@]}"; do step_apply "$id"; done; echo; cmd_status ;;
    undo)
      info "undo plan: ${STEP_IDS[*]} (only what the installer created)"
      ((DRY_RUN)) || confirm "Remove the Strata Terminal installed by this script?" || die "aborted"
      for id in "${STEP_IDS[@]}"; do step_undo "$id"; done; echo; cmd_status ;;
    update) cmd_update ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}
main "$@"
