#!/usr/bin/env bash
# lib.sh - shared helpers for the docker-gpu setup scripts. Source it; do not execute it.
# shellcheck shell=bash
#
# Provides:
#   * logging to terminal + a per-run log file, and a separate xtrace file
#   * an ERR trap that writes last-error.txt (failing command, line, call stack, log tail)
#   * "managed" file installs that remember the original, so undo is exact:
#       - file existed before  -> original is backed up once, restored on undo
#       - file did not exist   -> a "created" marker is kept, file is removed on undo
#       - file not touched by us -> left alone on undo

STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/docker-setup}"
LOG_DIR="$STATE_DIR/logs"
BACKUP_DIR="$STATE_DIR/backups"
CREATED_DIR="$STATE_DIR/created"
SUMMARY="$STATE_DIR/summary.tsv"
ERROR_FILE="$STATE_DIR/last-error.txt"
mkdir -p "$LOG_DIR" "$BACKUP_DIR" "$CREATED_DIR"

# AIW_TEST_MODE=1 lets the unit tests run without root (sudo becomes a no-op wrapper).
if [[ ${AIW_TEST_MODE:-0} == 1 ]]; then
  sudo() { "$@"; }
  OWNER_ARGS=()
else
  OWNER_ARGS=(-o root -g root)
fi

# ---------------------------------------------------------------- logging
_ts()  { date +%H:%M:%S; }
info() { printf '[%s] [INFO] %s\n' "$(_ts)" "$*"; }
ok()   { printf '[%s] [ OK ] %s\n' "$(_ts)" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(_ts)" "$*" >&2; }
err()  { printf '[%s] [FAIL] %s\n' "$(_ts)" "$*" >&2; }

RUN_LOG=""
RUN_TRACE=""
TMPD=""
CURRENT_STEP=""
CURRENT_ACTION=""

# init_logging LABEL - from here on stdout/stderr go to the terminal AND the log;
# bash xtrace goes to its own file with timestamps-by-seconds, file:line:function.
init_logging() {
  local ts; ts=$(date +%Y%m%d-%H%M%S)
  RUN_LOG="$LOG_DIR/$ts-$1.log"
  RUN_TRACE="$LOG_DIR/$ts-$1.trace"
  : >"$RUN_LOG"; : >"$RUN_TRACE"
  ln -sfn "$RUN_LOG" "$LOG_DIR/latest.log"
  ln -sfn "$RUN_TRACE" "$LOG_DIR/latest.trace"
  TMPD=$(mktemp -d)
  exec > >(tee -a "$RUN_LOG") 2>&1
  exec 9>>"$RUN_TRACE"
  BASH_XTRACEFD=9
  PS4='+ [${SECONDS}s] ${BASH_SOURCE[0]##*/}:${LINENO}:${FUNCNAME[0]:-main}: '
  set -x
  trap '_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
  trap '_cleanup' EXIT
}

snapshot() {
  info "---- environment snapshot ----"
  info "date:     $(date -Is)"
  info "user:     $(id -un) (uid $(id -u)); groups: $(id -Gn)"
  info "kernel:   $(uname -r)"
  info "os:       $(. /etc/os-release && echo "$PRETTY_NAME ($VERSION_CODENAME)")"
  info "systemd:  $(systemctl is-system-running 2>&1 || true)"
  info "disk /:   $(df -h / | awk 'NR==2{print $4" free of "$2}')"
  info "mem:      $(free -g | awk 'NR==2{print $2" GB total, "$7" GB available"}')"
  # "|| true" matters: with set -E the ERR trap is inherited by $(...) subshells, so an
  # expected failure here (e.g. docker not installed yet) would write a bogus last-error.txt
  info "gpu:      $( { nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1 || true; } | head -1)"
  if command -v docker >/dev/null 2>&1; then
    info "docker:   $(docker --version 2>&1 | head -1)"
  else
    info "docker:   (not installed)"
  fi
  info "------------------------------"
}

_write_error_file() { # rc line cmd
  {
    echo "time:    $(date -Is)"
    echo "exit:    $1"
    echo "line:    $2"
    echo "command: $3"
    echo "step:    ${CURRENT_STEP:-?} (${CURRENT_ACTION:-?})"
    echo "stack:"
    local i
    for ((i = 2; i < ${#FUNCNAME[@]}; i++)); do
      echo "  ${FUNCNAME[$i]} (${BASH_SOURCE[$i]##*/}:${BASH_LINENO[$((i - 1))]})"
    done
    echo "log:     $RUN_LOG"
    echo "trace:   $RUN_TRACE"
    echo "--- last 30 log lines ---"
    tail -n 30 "$RUN_LOG" 2>/dev/null
    echo "--- last 30 trace lines ---"
    tail -n 30 "$RUN_TRACE" 2>/dev/null
  } >"$ERROR_FILE" 2>&1
}

_on_err() {
  { set +x; } 2>/dev/null
  _write_error_file "$1" "$2" "$3"
  err "exit $1 at line $2: $3"
  err "details written to: $ERROR_FILE"
}

die() {
  { set +x; } 2>/dev/null
  err "$*"
  _write_error_file 1 "${BASH_LINENO[0]}" "die: $*"
  err "details written to: $ERROR_FILE"
  exit 1
}

_cleanup() {
  local rc=${1:-$?}
  { set +x; } 2>/dev/null
  if [[ -n $TMPD && -d $TMPD && $TMPD == "${TMPDIR:-/tmp}"/tmp.* ]]; then   # only the mktemp dir this run created
    rm -f -- "$TMPD"/* "$TMPD"/.[!.]* 2>/dev/null || true                  # its files, not a recursive delete
    rmdir "$TMPD" 2>/dev/null || true                                       # removes it only if it is empty
  fi
  if [[ -n $RUN_LOG ]]; then
    ((rc == 0)) || err "finished with exit code $rc"
    info "log:   $RUN_LOG"
    info "trace: $RUN_TRACE"
    ((rc == 0)) || info "error: $ERROR_FILE"
  fi
  sleep 0.3 # let tee flush before the shell prompt returns
}

record() { # step action result
  printf '%s\t%s\t%s\t%s\n' "$(date -Is)" "$1" "$2" "$3" >>"$SUMMARY"
}

ASSUME_YES=0
confirm() { # prompt
  ((ASSUME_YES)) && return 0
  local a
  read -r -p "$1 [type yes to continue] " a </dev/tty || return 1
  [[ $a == yes ]]
}

# ------------------------------------------------------ package helpers
apt_get() { sudo env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=120 -y "$@"; }

pkg_installed() { # exactly one package name
  [[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]
}

pkgs_installed() { # all packages installed?
  local p
  for p in "$@"; do pkg_installed "$p" || return 1; done
}

# ------------------------------------------------- managed file handling
_key() { local k=${1//\//%}; echo "$k"; }
_backup_path()  { echo "$BACKUP_DIR/$1/$(_key "$2")"; }
_created_path() { echo "$CREATED_DIR/$1__$(_key "$2")"; }

# track_original STEP DEST - call BEFORE anything modifies DEST. Idempotent:
# the first call records the original state, later calls change nothing.
track_original() {
  local step=$1 dest=$2 bk cr
  bk=$(_backup_path "$step" "$dest"); cr=$(_created_path "$step" "$dest")
  [[ -e $bk || -e $cr ]] && return 0
  if sudo test -e "$dest"; then
    mkdir -p "$(dirname "$bk")"
    sudo cp -a "$dest" "$bk"
    sudo chown "$(id -u):$(id -g)" "$bk"
    info "backed up original $dest -> $bk"
  else
    : >"$cr"
    info "$dest did not exist; marked as created by $step"
  fi
}

# managed_install STEP SRC DEST MODE
managed_install() {
  local step=$1 src=$2 dest=$3 mode=$4
  if sudo test -f "$dest" && sudo cmp -s "$src" "$dest"; then
    info "unchanged: $dest"
    return 0
  fi
  track_original "$step" "$dest"
  sudo mkdir -p "$(dirname "$dest")"
  sudo install -m "$mode" "${OWNER_ARGS[@]}" "$src" "$dest"
  info "installed: $dest"
}

# managed_restore STEP DEST - exact inverse of track_original + managed_install
managed_restore() {
  local step=$1 dest=$2 bk cr mode
  bk=$(_backup_path "$step" "$dest"); cr=$(_created_path "$step" "$dest")
  if [[ -e $bk ]]; then
    mode=$(stat -c %a "$bk")
    sudo install -m "$mode" "${OWNER_ARGS[@]}" "$bk" "$dest"
    rm -f "$bk"
    info "restored original: $dest"
  elif [[ -e $cr ]]; then
    sudo rm -f "$dest"
    rm -f "$cr"
    info "removed (was created by $step): $dest"
  else
    info "not managed by $step, left alone: $dest"
  fi
}

# ------------------------------------------------- "is something else running?" checks
# pgrep -f matches the WHOLE command line, so a wrapper shell that merely mentions a name
# (e.g. `bash -c "... llama-bench ..."`) would match. These checks therefore match
#   * the program name itself (llama-bench, llama-fit-params), or
#   * a command line that STARTS with bash running one of our scripts, or with uvx/hf/python running `hf download`,
# and never report this process or anything it started.
_descends_from_me() { # pid -> 0 if pid is gone, is this shell, or is one of its descendants
  local p=$1
  [[ -d /proc/$p ]] || return 0          # already exited (e.g. a short-lived pgrep subshell): not "running"
  while [[ -n $p && $p -gt 1 ]]; do
    [[ $p -eq $$ ]] && return 0
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [[ -n $p ]] || return 0              # vanished while walking up the tree
  done
  return 1
}

_DL_PAT_HF='^([^ ]*/)?(uv|uvx|hf|python[0-9.]*)( [^ ]+)* ([^ ]*/)?hf download'
_DL_PAT_SCRIPT='^([^ ]*/)?bash( -[A-Za-z]+)* [^ ]*download-gguf\.sh (apply|undo)'

running_jobs() { # prints "pid command" for each other benchmark/measurement process (and downloads, unless --no-downloads)
  local with_dl=1 line pid
  [[ ${1:-} == --no-downloads ]] && with_dl=0
  {
    pgrep -ax 'llama-bench'
    pgrep -ax 'llama-fit-param'    # kernel truncates process names to 15 characters
    pgrep -ax 'llama-perplexit'
    pgrep -ax 'llama-server'
    pgrep -af '^([^ ]*/)?bash( -[A-Za-z]+)* [^ ]*(bench-ladder|fit-memory|diag-spill|llama-image|setup|eval-short|eval-kl)\.sh (apply|undo)'
    if ((with_dl)); then pgrep -af "$_DL_PAT_HF"; pgrep -af "$_DL_PAT_SCRIPT"; fi
  } 2>/dev/null | sort -u | while read -r line; do
    pid=${line%% *}
    _descends_from_me "$pid" || echo "$line"
  done
}

# a download is "running" while hf downloads OR while download-gguf.sh runs (its sha256 pass is also heavy)
download_running() { [[ -n $({ pgrep -af "$_DL_PAT_HF"; pgrep -af "$_DL_PAT_SCRIPT"; } 2>/dev/null || true) ]]; }
