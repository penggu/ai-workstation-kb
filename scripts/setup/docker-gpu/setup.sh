#!/usr/bin/env bash
# setup.sh - install Docker Engine + NVIDIA Container Toolkit inside WSL2 Ubuntu.
# Idempotent (re-run any time), every step is undoable, every run leaves a debug trace.
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
# shellcheck source=steps.sh
source "$HERE/steps.sh"

usage() {
  cat <<EOF
Usage: setup.sh <command> [options] [steps...]

Commands
  status               show which steps are DONE / PENDING (changes nothing)
  plan [steps]         show what apply would do, change nothing (same as: apply --dry-run)
  apply [steps]        apply steps in order; already-done steps are skipped
  undo <steps>         undo the given steps, in reverse order
  undo-all             undo every step, in reverse order (asks for confirmation)
  diag                 write a diagnostics bundle (docker/nvidia/systemd state)
  logs                 print where the latest log, trace and error file are

Steps: 1..8 or s01..s08 (default for apply/status: all). Ranges are not supported;
list them: "apply 1 2 3".

Options
  --dry-run            show what would happen, change nothing
  --yes, -y            do not ask for confirmation
  --purge-data         with undo of step 3: print how to remove /var/lib/docker yourself (the script never deletes it)
  --help, -h

Steps
$(for s in "${STEP_IDS[@]}"; do printf '  %s  %s\n' "${s#s0}" "$("${s}_desc")"; done)

Debug files (state dir: $STATE_DIR)
  logs/latest.log      what you saw on screen
  logs/latest.trace    bash xtrace: every command, with file:line:function
  last-error.txt       written on failure: command, line, call stack, log/trace tails
  summary.tsv          one line per step action ever run
EOF
}

resolve_steps() { # numbers or ids -> ids; empty -> all
  local out=() t id
  if (($# == 0)); then printf '%s\n' "${STEP_IDS[@]}"; return; fi
  for t in "$@"; do
    case "$t" in
      all) printf '%s\n' "${STEP_IDS[@]}"; return ;;
      [1-8]) id="s0$t" ;;
      s0[1-8]) id="$t" ;;
      *) echo "unknown step: $t" >&2; exit 2 ;;
    esac
    out+=("$id")
  done
  printf '%s\n' "${out[@]}"
}

step_apply() { # id
  local id=$1
  CURRENT_STEP=$id; CURRENT_ACTION=check
  if "${id}_check"; then
    ok "$id already done - $("${id}_desc")"
    record "$id" apply skipped
    return 0
  fi
  if ((DRY_RUN)); then info "[dry-run] would apply $id - $("${id}_desc")"; return 0; fi
  info ">>> apply $id - $("${id}_desc")"
  CURRENT_ACTION=apply
  "${id}_apply"
  CURRENT_ACTION=post-check
  if ! "${id}_check"; then
    die "$id: apply finished but the check still fails (the step did not reach its goal)"
  fi
  ok "$id done"
  record "$id" apply "done"
}

step_undo() { # id
  local id=$1
  CURRENT_STEP=$id; CURRENT_ACTION=undo
  if ((DRY_RUN)); then info "[dry-run] would undo $id - $("${id}_desc")"; return 0; fi
  info "<<< undo $id - $("${id}_desc")"
  "${id}_undo"
  ok "$id undone"
  record "$id" undo "done"
}

cmd_status() {
  local id state
  printf '%-5s %-8s %s\n' STEP STATE DESCRIPTION
  for id in "${STEP_IDS[@]}"; do
    CURRENT_STEP=$id; CURRENT_ACTION=check
    if "${id}_check"; then state=DONE; else state=PENDING; fi
    printf '%-5s %-8s %s\n' "${id#s0}" "$state" "$("${id}_desc")"
  done
}

cmd_diag() {
  local f; f="$STATE_DIR/diag-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "== docker version"; docker --version 2>&1 || true
    echo "== docker info (runtimes etc.)"; sudo docker info 2>&1 | grep -iE 'version|runtimes|default runtime|storage driver|cgroup|root dir' || true
    echo "== $DAEMON_JSON"; sudo cat "$DAEMON_JSON" 2>&1 || true
    echo "== systemctl status docker"; systemctl status docker --no-pager -l 2>&1 | head -30 || true
    echo "== journal (docker, last 40)"; sudo journalctl -u docker -n 40 --no-pager 2>&1 || true
    echo "== packages"; dpkg -l 2>/dev/null | awk '/docker|containerd|nvidia-container/{print $1,$2,$3}'
    echo "== apt sources (docker/nvidia)"; ls -l /etc/apt/sources.list.d/ 2>&1; cat "$DOCKER_SRC" "$NV_LIST" 2>&1 || true
    echo "== nvidia-ctk"; nvidia-ctk --version 2>&1 || true
    echo "== host GPU"; nvidia-smi 2>&1 | head -15 || true
    echo "== /usr/lib/wsl/lib"; ls -l /usr/lib/wsl/lib 2>&1 | head -20
    echo "== iptables backend"; update-alternatives --display iptables 2>&1 | head -4 || true
    echo "== state dir"; ls -lR "$BACKUP_DIR" "$CREATED_DIR" 2>&1; cat "$SUMMARY" 2>&1 | tail -20
  } >"$f" 2>&1
  info "diagnostics written to: $f"
}

cmd_logs() {
  echo "state dir:    $STATE_DIR"
  echo "latest log:   $(readlink -f "$LOG_DIR/latest.log" 2>/dev/null || echo none)"
  echo "latest trace: $(readlink -f "$LOG_DIR/latest.trace" 2>/dev/null || echo none)"
  echo "last error:   $ERROR_FILE $([[ -f $ERROR_FILE ]] || echo '(none)')"
  [[ -f $ERROR_FILE ]] && { echo; head -12 "$ERROR_FILE"; }
}

_selftest_fail() { # hidden: proves the error capture works
  CURRENT_STEP=selftest; CURRENT_ACTION=fail
  info "selftest: about to fail on purpose"
  false
}

main() {
  DRY_RUN=0
  local cmd=${1:-help}
  (($#)) && shift
  local args=()
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --purge-data) PURGE_DATA=1 ;;
      --help|-h) usage; exit 0 ;;
      -*) echo "unknown option: $1" >&2; exit 2 ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  case "$cmd" in
    help|--help|-h) usage; exit 0 ;;
    logs) cmd_logs; exit 0 ;;
    plan) cmd=apply; DRY_RUN=1 ;;   # alias for: apply --dry-run
    status|apply|undo|undo-all|diag|_selftest_fail) ;;
    *) usage >&2; echo "unknown command: $cmd" >&2; exit 2 ;;   # before logging and sudo
  esac

  if ((EUID == 0)); then
    echo "Do not run this as root (or with sudo). Run it as your normal user; it calls sudo itself." >&2
    exit 2
  fi

  local ids=()
  mapfile -t ids < <(resolve_steps "${args[@]}")

  init_logging "$cmd"
  info "command: $cmd ${args[*]:-} (dry-run=$DRY_RUN yes=$ASSUME_YES purge-data=$PURGE_DATA)"
  snapshot
  if [[ ${SKIP_SUDO_V:-0} != 1 && ${AIW_TEST_MODE:-0} != 1 ]] && ((!DRY_RUN)) && [[ $cmd != status ]]; then
    info "asking for sudo once (password prompt)"
    sudo -v
  fi

  local id i
  case "$cmd" in
    status) cmd_status ;;
    apply)
      for id in "${ids[@]}"; do step_apply "$id"; done
      echo; cmd_status
      ;;
    undo)
      ((${#args[@]})) || die "undo needs explicit steps, e.g. 'undo 8 7'; use undo-all for everything"
      info "undo plan (reverse order): $(printf '%s ' "${ids[@]}" | tr ' ' '\n' | sort -r | tr '\n' ' ')"
      ((DRY_RUN)) || confirm "Undo these steps?" || die "aborted"
      mapfile -t ids < <(printf '%s\n' "${ids[@]}" | sort -r)
      for id in "${ids[@]}"; do step_undo "$id"; done
      echo; cmd_status
      ;;
    undo-all)
      mapfile -t ids < <(printf '%s\n' "${STEP_IDS[@]}" | sort -r)
      info "undo-all plan: ${ids[*]}"
      ((PURGE_DATA)) && warn "--purge-data is set: /var/lib/docker will NOT be deleted; step 3 will print how to remove it yourself"
      ((DRY_RUN)) || confirm "Undo ALL steps?" || die "aborted"
      for id in "${ids[@]}"; do step_undo "$id"; done
      echo; cmd_status
      ;;
    diag) cmd_diag ;;
    _selftest_fail) _selftest_fail ;;
  esac
}

main "$@"
