#!/usr/bin/env bash
# tailscale.sh - install Tailscale inside WSL2 Ubuntu so another machine can reach this one at a stable address.
# Idempotent, every step undoable, every run leaves a debug trace. Uses the shared helpers in ../docker-gpu/lib.sh.
#
#   ./tailscale.sh status | apply | undo | update | diag | logs      [--dry-run] [--yes]
#
# Steps (apply runs them in order, skipping the ones already done):
#   1  apt repository + signing key from pkgs.tailscale.com (same files the official install.sh writes)
#   2  packages: tailscale, tailscale-archive-keyring
#   3  service: tailscaled enabled and running
#   4  login:  `tailscale up` - you open the printed URL in a browser and approve this machine (the script cannot do that)
#
# Deliberately NOT done (each changes behaviour beyond "this machine joins your network"):
#   * --ssh: Tailscale SSH would replace the existing key-only sshd on port 2222. Not enabled.
#   * DNS: `--accept-dns=false`, so WSL's /etc/resolv.conf is not rewritten (MagicDNS names are resolved on the
#     OTHER machine, which has its own Tailscale client).
#   * routes / exit node: not accepted, not offered.
#   * auto-update: not enabled. Updating is an explicit command (`update`), see below.
#
# `update` is separate from `apply` on purpose: an install script should do the same thing every time, while updates
# are a decision. `update` shows installed and candidate versions and upgrades only the tailscale packages after asking.
#
# undo: logs out of the tailnet and stops the service, purges the packages, removes the repository files this script
# created. The machine stays listed in the Tailscale admin console until YOU delete it there.
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/tailscale}"
# shellcheck source=../docker-gpu/lib.sh
source "$HERE/../docker-gpu/lib.sh"

TRACK=stable
TS_KEY=/usr/share/keyrings/tailscale-archive-keyring.gpg
TS_LIST=/etc/apt/sources.list.d/tailscale.list
TS_PKGS=(tailscale tailscale-archive-keyring)
UP_ARGS=(--accept-dns=false --accept-routes=false --ssh=false)
STEP_IDS=(t1 t2 t3 t4)

_codename() { ( . /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}" ); }
_ts_state() { # BackendState of the daemon, empty if it cannot be read. Tries without sudo, then `sudo -n` (never prompts).
  local out=""
  out=$(tailscale status --json 2>/dev/null || true)
  [[ -n $out ]] || out=$(sudo -n tailscale status --json 2>/dev/null || true)
  [[ -n $out ]] || return 0
  printf '%s' "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
}

# ---------------------------------------------------------------- t1
t1_desc()  { echo "apt repository and signing key (pkgs.tailscale.com/$TRACK/ubuntu/$(_codename))"; }
t1_check() { [[ -s $TS_KEY && -f $TS_LIST ]] && grep -q "pkgs.tailscale.com/$TRACK/ubuntu" "$TS_LIST" && grep -q "$(_codename)" "$TS_LIST"; }
t1_apply() {
  local suite base; suite=$(_codename); base="https://pkgs.tailscale.com/$TRACK/ubuntu/$suite"
  info "Ubuntu suite: $suite"
  [[ $(curl -fsS --max-time 20 "https://pkgs.tailscale.com/$TRACK/ubuntu/$suite/installer-supported" 2>/dev/null || true) == *OK* ]] \
    || die "pkgs.tailscale.com does not list '$suite' as supported"
  curl -fsSL --max-time 60 "$base.noarmor.gpg" -o "$TMPD/ts.gpg";  [[ -s $TMPD/ts.gpg ]] || die "downloaded key is empty"
  curl -fsSL --max-time 60 "$base.tailscale-keyring.list" -o "$TMPD/ts.list"; [[ -s $TMPD/ts.list ]] || die "downloaded repository list is empty"
  grep -q '^deb ' "$TMPD/ts.list" || die "the repository list does not look like an apt list: $(head -c 200 "$TMPD/ts.list")"
  info "repository list from the server:"; sed 's/^/    /' "$TMPD/ts.list"
  managed_install t1 "$TMPD/ts.gpg"  "$TS_KEY"  0644
  managed_install t1 "$TMPD/ts.list" "$TS_LIST" 0644
  apt_get update
}
t1_undo() {
  managed_restore t1 "$TS_LIST"
  managed_restore t1 "$TS_KEY"
  apt_get update || warn "apt-get update failed after removing the Tailscale repo (check other repos)"
}

# ---------------------------------------------------------------- t2
t2_desc()  { echo "packages (${TS_PKGS[*]})"; }
t2_check() { pkgs_installed "${TS_PKGS[@]}"; }
t2_apply() {
  apt_get install "${TS_PKGS[@]}"
  info "installed: $(dpkg-query -W -f='${Package} ${Version}\n' "${TS_PKGS[@]}" | tr '\n' ';')"
}
t2_undo() {
  local p present=()
  for p in "${TS_PKGS[@]}"; do pkg_installed "$p" && present+=("$p"); done
  if ((${#present[@]})); then apt_get purge "${present[@]}"; else info "t2: no Tailscale packages installed"; fi
}

# ---------------------------------------------------------------- t3
t3_desc()  { echo "service tailscaled enabled and running"; }
t3_check() { systemctl is-enabled --quiet tailscaled.service 2>/dev/null && systemctl is-active --quiet tailscaled.service; }
t3_apply() {
  [[ -c /dev/net/tun ]] || warn "/dev/net/tun is missing; tailscaled may fall back to userspace networking"
  sudo systemctl enable --now tailscaled.service
  local i; for i in $(seq 1 20); do sudo tailscale status >/dev/null 2>&1 && return 0; sleep 1; done
  # "Logged out" also makes `status` exit non-zero, so only warn: the next step is the login
  warn "tailscale status did not answer cleanly within 20 s (expected before the first login)"
}
t3_undo() {
  if systemctl list-unit-files tailscaled.service >/dev/null 2>&1; then sudo systemctl disable --now tailscaled.service || true; else info "t3: no tailscaled unit"; fi
}

# ---------------------------------------------------------------- t4
t4_desc()  { echo "login to your tailnet (tailscale up ${UP_ARGS[*]}; you approve in a browser)"; }
t4_check() { [[ $(_ts_state) == Running ]]; }
t4_apply() {
  info "A URL will be printed. Open it in a browser on any device, sign in, and approve this machine."
  info "(this step waits until you do; Ctrl+C cancels, and re-running apply resumes)"
  sudo tailscale up "${UP_ARGS[@]}"
  info "tailnet addresses: $(tailscale ip 2>/dev/null | tr '\n' ' ')"
}
t4_undo() {
  if sudo tailscale status >/dev/null 2>&1; then sudo tailscale logout || true; else info "t4: not logged in"; fi
  info "t4: delete the machine in the Tailscale admin console too if you want it gone from the list"
}

# ---------------------------------------------------------------- driver
usage() { sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

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
}
cmd_update() {
  pkg_installed tailscale || die "tailscale is not installed; run apply first"
  CURRENT_STEP=update; CURRENT_ACTION=check
  local cur cand
  cur=$(dpkg-query -W -f='${Version}' tailscale)
  if ((DRY_RUN)); then info "[dry-run] installed: $cur; would refresh apt and compare with the candidate version"; return 0; fi
  apt_get update >/dev/null
  cand=$(apt-cache policy tailscale | awk '/Candidate:/{print $2}')
  info "installed: $cur   candidate: $cand"
  if [[ $cur == "$cand" ]]; then ok "already the newest version"; record update check current; return 0; fi
  confirm "Upgrade tailscale $cur -> $cand? (the tunnel drops for a moment)" || die "aborted"
  CURRENT_ACTION=apply
  apt_get install --only-upgrade tailscale tailscale-archive-keyring
  ok "now: $(dpkg-query -W -f='${Version}' tailscale); state: $(_ts_state)"
  record update apply "$cur->$cand"
}
cmd_diag() {
  local f; f="$STATE_DIR/diag-$(date +%Y%m%d-%H%M%S).txt"
  {
    echo "== version"; tailscale version 2>&1 || true
    echo "== status"; tailscale status 2>&1 | sed 's/^\([0-9.]*\) *\([^ ]*\)/\1 <name>/' | head -20 || true
    echo "== service"; systemctl status tailscaled --no-pager -l 2>&1 | head -20 || true
    echo "== journal (last 40)"; sudo journalctl -u tailscaled -n 40 --no-pager 2>&1 || true
    echo "== /dev/net/tun"; ls -l /dev/net/tun 2>&1
    echo "== interfaces"; ip -br addr 2>&1 | sed 's/[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+/<ipv4>/g'
    echo "== resolv.conf (should not mention tailscale)"; grep -ci tailscale /etc/resolv.conf 2>&1 || true
    echo "== sshd listening"; ss -ltn 2>&1 | grep -E ':2222\b' || true
    echo "== apt"; cat "$TS_LIST" 2>&1 || true; apt-cache policy tailscale 2>&1 | head -6
  } >"$f" 2>&1
  info "diagnostics written to: $f   (addresses and machine names are masked; still read it before sharing)"
}
cmd_logs() {
  echo "state dir:    $STATE_DIR"
  echo "latest log:   $(readlink -f "$LOG_DIR/latest.log" 2>/dev/null || echo none)"
  echo "latest trace: $(readlink -f "$LOG_DIR/latest.trace" 2>/dev/null || echo none)"
  echo "last error:   $ERROR_FILE $([[ -f $ERROR_FILE ]] || echo '(none)')"
  [[ -f $ERROR_FILE ]] && { echo; head -12 "$ERROR_FILE"; }
}

main() {
  DRY_RUN=0
  local cmd=${1:-help}; (($#)) && shift
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --help|-h) usage; exit 0 ;;
      *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
  done
  case "$cmd" in help|--help|-h) usage; exit 0 ;; logs) cmd_logs; exit 0 ;; esac
  ((EUID == 0)) && { echo "Do not run this as root (or with sudo). Run it as your normal user; it calls sudo itself." >&2; exit 2; }

  init_logging "$cmd"
  info "command: $cmd (dry-run=$DRY_RUN yes=$ASSUME_YES)"
  snapshot
  if [[ ${SKIP_SUDO_V:-0} != 1 && ${AIW_TEST_MODE:-0} != 1 ]] && ((!DRY_RUN)) && [[ $cmd != status ]]; then
    info "asking for sudo once (password prompt)"; sudo -v
  fi

  local id ids
  case "$cmd" in
    status) cmd_status ;;
    apply) for id in "${STEP_IDS[@]}"; do step_apply "$id"; done; echo; cmd_status ;;
    undo)
      mapfile -t ids < <(printf '%s\n' "${STEP_IDS[@]}" | sort -r)
      info "undo plan (reverse order): ${ids[*]}"
      ((DRY_RUN)) || confirm "Undo ALL Tailscale steps (this machine leaves your tailnet)?" || die "aborted"
      for id in "${ids[@]}"; do step_undo "$id"; done; echo; cmd_status ;;
    update) cmd_update ;;
    diag) cmd_diag ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}
main "$@"
