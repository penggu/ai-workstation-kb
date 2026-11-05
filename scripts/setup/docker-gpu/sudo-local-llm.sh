#!/usr/bin/env bash
# sudo-local-llm.sh - let the normal user start, stop and inspect the local llama-server container WITHOUT docker access
# and without typing a sudo password each time. Idempotent, undoable, every run leaves a debug trace (lib.sh).
#
#   ./sudo-local-llm.sh status | apply | undo | show      [--dry-run] [--yes]     (apply/undo ask for sudo once)
#
# Why not "add the user to the docker group" or "allow docker run in sudoers": either makes every program that runs as
# you root-equivalent (docker run takes any mount and flag). Instead:
#
#   r1  /usr/local/sbin/aiw-llm-ctl  (root:root 0755), generated from aiw-llm-ctl.template with this machine's values
#       baked in (image digest, user, folders). It can only: stop | running | status-line | logs | start <validated options>.
#       Everything it starts is fixed except a few options that are checked against strict patterns. The container
#       runs as YOU, not as root. Read the generated file with:  ./sudo-local-llm.sh show
#       apply installs only from a root-owned staging copy and shows its sha256 and the diff first; it asks before installing
#       (--yes skips the question, not the printout).
#   r2  /etc/sudoers.d/aiw-local-llm  (root:root 0440): NOPASSWD for exactly that one file (and its five subcommands).
#
# local-llm.sh uses the controller automatically when it is installed; without it, it falls back to `sudo docker`.
# If you pin a new llama.cpp image (llama-image.sh) run `apply` again: the image digest is baked into the controller.
# The controller is a root-run program: read it (show), and re-read it after any change.
#
# undo removes both files this script created (and restores earlier versions if there were any).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/sudo-local-llm}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

CTL=/usr/local/sbin/aiw-llm-ctl
SUDOERS=/etc/sudoers.d/aiw-local-llm
TEMPLATE="$HERE/aiw-llm-ctl.template"
LLM_STATE="$HOME/.local/state/ai-workstation/local-llm"
IMAGE_STATE=${LLAMA_IMAGE_STATE:-$HOME/.local/state/ai-workstation/llama-image/image-digest.txt}
MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
STEP_IDS=(r1 r2)

gen_ctl() { # writes the controller for this machine to $1; every baked value is checked first
  local out=$1 ref user path
  ref=$(head -1 "$IMAGE_STATE" 2>/dev/null || true)
  [[ $ref =~ ^[a-z0-9./-]+@sha256:[0-9a-f]{64}$ ]] || die "no valid pinned image digest in $IMAGE_STATE (run ./llama-image.sh apply first)"
  user=$(id -un); [[ $user =~ ^[a-z_][a-z0-9_-]*$ ]] || die "unexpected user name: $user"
  for path in "$MODEL_DIR" "$LLM_STATE/server-logs" "$LLM_STATE/api-key" "$LLM_STATE/chat-template-patched.jinja"; do
    [[ $path =~ ^/[A-Za-z0-9_./-]+$ ]] || die "path has characters this script will not bake into a root program: $path"
  done
  python3 -I - "$TEMPLATE" "$out" "$ref" "$user" "$(id -u)" "$(id -g)" "$MODEL_DIR" "$LLM_STATE/server-logs" "$LLM_STATE/api-key" \
    "$LLM_STATE/chat-template-patched.jinja" <<'PY'
import sys
tpl, out, ref, user, uid, gid, model_dir, log_dir, key, tfile = sys.argv[1:]
vals = {"CONTAINER": "aiw-local-llm", "ALIAS": "local-qwen", "IMAGE_REF": ref, "RUN_USER": user, "RUN_UID": uid,
        "RUN_GID": gid, "MODEL_DIR": model_dir, "LOG_DIR": log_dir, "KEY_FILE": key, "TEMPLATE_FILE": tfile}
s = open(tpl).read()
for k, v in vals.items():
    s = s.replace("@@%s@@" % k, v)
assert "@@" not in s, "unreplaced placeholder"
open(out, "w").write(s)
PY
}

sudoers_text() {
  local u; u=$(id -un)
  cat <<RULES
# Installed by sudo-local-llm.sh (ai-workstation-kb). One root-owned controller, not docker itself.
Defaults!$CTL env_reset, always_set_home, !setenv, secure_path="/usr/sbin:/usr/bin:/sbin:/bin"
$u ALL=(root) NOPASSWD: $CTL stop, \\
    $CTL running, \\
    $CTL status-line, \\
    $CTL logs, \\
    $CTL start *
RULES
}

_check_dirs() { # the controller is only trustworthy if no parent folder is writable by anyone but root
  local d
  for d in /usr /usr/local /usr/local/sbin; do
    [[ -d $d ]] || continue
    [[ $(stat -c '%U' "$d") == root ]] || die "$d is not owned by root"
    [[ $(stat -c '%A' "$d" | cut -c6,9) == -- ]] || die "$d is writable by group or others"
  done
}

# F1/F2: nothing is installed from a file this user can still write. The content goes straight into a root-owned, 0700
# staging folder; it is checked, shown (sha256 + diff) and installed FROM THERE. A same-uid process that swaps a file in
# $TMPD after the check cannot change what root installs.
STAGE=""
stage_new()   { [[ -n $STAGE ]] || STAGE=$(sudo mktemp -d /var/tmp/aiw-stage.XXXXXX) || die "cannot create a root-owned staging folder"; }
stage_clean() { [[ -z $STAGE ]] || sudo rm -rf -- "$STAGE" || true; STAGE=""; }
review_root_file() { # STAGED_FILE DEST LABEL : show what root is about to install, ask before going on
  local h; h=$(sudo sha256sum -- "$1" | cut -d' ' -f1)
  info "$3: sha256 $h (the exact bytes that will be installed as root)"
  if sudo test -f "$2"; then
    info "difference to the installed $2 (empty = identical):"; { sudo diff -u "$2" "$1" || true; } | sed 's/^/    /'
  else
    info "new file, full content:"; sudo cat -- "$1" | sed 's/^/    /'
  fi
  confirm "Install this $3 as root?" || die "aborted; nothing was installed"
}

# F4: the backup of a file that existed before us, and the "created by us" marker, live in a ROOT-owned folder. The
# generic managed_install/managed_restore (lib.sh) keep them in the user's state folder, so a same-uid process could
# replace the backup and have `undo` install it as root (for the sudoers file: a root shell).
ROOT_BK=/var/lib/aiw-local-llm-backup
root_install() { # STEP SRC DEST MODE  (SRC must already be root-owned)
  local step=$1 src=$2 dest=$3 mode=$4
  if sudo test -f "$dest" && sudo cmp -s "$src" "$dest"; then info "unchanged: $dest"; return 0; fi
  sudo install -d -m 0700 -o root -g root "$ROOT_BK"
  if ! sudo test -e "$ROOT_BK/$step.orig" && ! sudo test -e "$ROOT_BK/$step.created"; then
    if sudo test -e "$dest"; then sudo cp -a -- "$dest" "$ROOT_BK/$step.orig"; info "backed up original $dest -> $ROOT_BK/$step.orig (root-owned)"
    else sudo touch "$ROOT_BK/$step.created"; info "$dest did not exist; marked as created by $step"; fi
  fi
  sudo mkdir -p "$(dirname "$dest")"
  sudo install -m "$mode" -o root -g root "$src" "$dest"
  info "installed: $dest"
}
root_restore() { # STEP DEST
  local step=$1 dest=$2 legacy_bk legacy_cr
  legacy_bk=$(_backup_path "$step" "$dest"); legacy_cr=$(_created_path "$step" "$dest")   # older versions kept these in the user's folder
  if sudo test -e "$ROOT_BK/$step.orig"; then
    sudo install -m "$(sudo stat -c %a "$ROOT_BK/$step.orig")" -o root -g root "$ROOT_BK/$step.orig" "$dest"; sudo rm -f "$ROOT_BK/$step.orig"
    info "restored original: $dest"
  elif sudo test -e "$ROOT_BK/$step.created" || [[ -e $legacy_cr ]]; then   # removing our own file is safe even if a marker was forged
    sudo rm -f "$dest"; sudo rm -f "$ROOT_BK/$step.created"; rm -f "$legacy_cr"; info "removed (was created by $step): $dest"
  elif [[ -e $legacy_bk ]]; then
    warn "$dest has an old user-owned backup ($legacy_bk). It is NOT restored automatically (a user-writable file must not be installed as root). Inspect it, then copy it by hand with sudo if you want it."
  else info "not managed by $step, left alone: $dest"; fi
}

r1_desc()  { echo "controller $CTL (root-owned, validated start/stop of the container)"; }
r1_check() { gen_ctl "$TMPD/ctl.expected" 2>/dev/null && sudo -n test -f "$CTL" 2>/dev/null && sudo -n cmp -s "$TMPD/ctl.expected" "$CTL" 2>/dev/null; }
r1_apply() {
  [[ -f $TEMPLATE ]] || die "missing $TEMPLATE"
  _check_dirs
  stage_new
  gen_ctl /dev/stdout | sudo tee "$STAGE/ctl" >/dev/null || die "could not generate the controller; nothing was installed"
  sudo chmod 0755 "$STAGE/ctl"
  sudo bash -n "$STAGE/ctl" || die "the generated controller has a syntax error; nothing was installed"
  review_root_file "$STAGE/ctl" "$CTL" "controller"
  mkdir -p "$LLM_STATE/server-logs"
  root_install r1 "$STAGE/ctl" "$CTL" 0755
}
r1_undo() { root_restore r1 "$CTL"; }

r2_desc()  { echo "sudoers rule $SUDOERS (NOPASSWD for the controller only)"; }
r2_check() { sudoers_text >"$TMPD/sudoers.expected"; sudo -n test -f "$SUDOERS" 2>/dev/null && sudo -n cmp -s "$TMPD/sudoers.expected" "$SUDOERS" 2>/dev/null; }
r2_apply() {
  stage_new
  sudoers_text | sudo tee "$STAGE/sudoers" >/dev/null || die "could not write the sudoers file; nothing was installed"
  sudo chmod 0440 "$STAGE/sudoers"
  sudo visudo -c -f "$STAGE/sudoers" || die "visudo rejected the file; nothing was installed"
  review_root_file "$STAGE/sudoers" "$SUDOERS" "sudoers rule"
  root_install r2 "$STAGE/sudoers" "$SUDOERS" 0440
  sudo visudo -c || die "visudo rejects the system sudoers configuration after the install; run undo"
}
r2_undo() { root_restore r2 "$SUDOERS"; sudo visudo -c || warn "visudo reports a problem; check /etc/sudoers.d"; }

selftest() { # never starts or stops anything; bad requests must be refused before docker is reached
  local out rc
  out=$(sudo -k -n "$CTL" running 2>&1) && ok "no-password '$CTL running' works" || { err "controller did not run without a password: $out"; return 1; }
  rc=0; out=$(sudo -k -n "$CTL" start --model-file ../x.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log 2>&1) || rc=$?
  [[ $rc -eq 2 && $out == *"--model-file"* ]] && ok "a path in --model-file is refused" || { err "bad --model-file was not refused (rc=$rc): $out"; return 1; }
  rc=0; out=$(sudo -k -n "$CTL" start --bogus 2>&1) || rc=$?
  [[ $rc -eq 2 && $out == *"unknown option"* ]] && ok "an unknown option is refused" || { err "unknown option was not refused (rc=$rc): $out"; return 1; }
  local rl; rl=$(sysctl -n net.ipv4.conf.all.route_localnet 2>/dev/null || echo ?)
  [[ $rl == 1 ]] && warn "net.ipv4.conf.all.route_localnet=1: with some Docker versions a port published on 127.0.0.1 is reachable from the LAN. Check the API from another machine, and update Docker if it answers." \
                 || ok "route_localnet is not set ($rl): a loopback-published port stays on the loopback"
  # `sudo -l` only says whether a command is ALLOWED (sudo-group members may run anything after a password), not whether
  # it needs one, so actually try a harmless docker command: it must be refused for lack of a password.
  if sudo -k -n /usr/bin/docker --version >/dev/null 2>&1; then err "docker runs without a password: the rule is too broad"; return 1; fi
  ok "docker itself still needs a password (as intended)"
}

usage() { sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
main() {
  DRY_RUN=0
  local cmd=${1:-help} id; (($#)) && shift
  while (($#)); do case "$1" in --dry-run) DRY_RUN=1 ;; --yes|-y) ASSUME_YES=1 ;; -h|--help) usage; exit 0 ;; *) echo "unknown option: $1" >&2; exit 2 ;; esac; shift; done
  case "$cmd" in help|-h|--help) usage; exit 0 ;; esac
  ((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }
  init_logging "sudo-local-llm-$cmd"; trap '_rc=$?; stage_clean; _cleanup "$_rc"' EXIT; info "command: $cmd (dry-run=$DRY_RUN)"; snapshot
  case "$cmd" in
    show) CURRENT_STEP=show; gen_ctl "$TMPD/ctl.show"; echo "===== $CTL (as it would be installed) ====="; cat "$TMPD/ctl.show"
          echo; echo "===== $SUDOERS ====="; sudoers_text ;;
    status)
      CURRENT_STEP=status
      if ! sudo -n true 2>/dev/null; then echo "UNKNOWN: reading /etc needs sudo; run 'sudo -v' first (or run apply: it skips what is done)"
      else for id in "${STEP_IDS[@]}"; do if "${id}_check"; then echo "$id DONE    $("${id}_desc")"; else echo "$id PENDING $("${id}_desc")"; fi; done; fi ;;
    apply)
      if ((DRY_RUN)); then CURRENT_STEP=dry-run; gen_ctl "$TMPD/ctl.dry"; bash -n "$TMPD/ctl.dry"; info "[dry-run] would install $CTL (generated file passes bash -n) and $SUDOERS:"; sudoers_text | sed 's/^/    /'; exit 0; fi
      info "asking for sudo once"; sudo -v
      for id in "${STEP_IDS[@]}"; do
        CURRENT_STEP=$id; CURRENT_ACTION=check
        if "${id}_check"; then ok "$id already done"; record "$id" apply skipped
        else CURRENT_ACTION=apply; "${id}_apply"; "${id}_check" || die "$id: applied but the check still fails"; ok "$id done"; record "$id" apply "done"; fi
      done
      CURRENT_STEP=selftest; CURRENT_ACTION=selftest; selftest ;;
    undo)
      if ((DRY_RUN)); then info "[dry-run] would remove $SUDOERS and $CTL"; exit 0; fi
      confirm "Remove $SUDOERS and $CTL (start/stop will ask for a password again)?" || die "aborted"
      info "asking for sudo once"; sudo -v
      for id in r2 r1; do CURRENT_STEP=$id; CURRENT_ACTION=undo; info "<<< undo $id"; "${id}_undo"; ok "$id undone"; record "$id" undo "done"; done ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}
main "$@"
