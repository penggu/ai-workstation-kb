#!/usr/bin/env bash
# steps.sh - the eight steps. Source it (after lib.sh); do not execute it.
# shellcheck shell=bash
#
# Every step sNN defines:
#   sNN_desc   one-line description
#   sNN_check  exit 0 if the step is already in its desired state. MUST be a plain
#              boolean test: no side effects, no sudo prompts (used by `status`).
#   sNN_apply  make it so. Only called when check fails. Must be re-runnable.
#   sNN_undo   revert only what this script changed. Safe to run when nothing was applied.

DOCKER_PKGS=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
NVIDIA_PKGS=(nvidia-container-toolkit)

# shellcheck disable=SC2034  # used by setup.sh, which sources this file
STEP_IDS=(s01 s02 s03 s04 s05 s06 s07 s08)
DOCKER_KEY=/etc/apt/keyrings/docker.asc
DOCKER_SRC=/etc/apt/sources.list.d/docker.sources
NV_KEY=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
NV_LIST=/etc/apt/sources.list.d/nvidia-container-toolkit.list
DAEMON_JSON=/etc/docker/daemon.json
TEST_IMAGE=${AIW_TEST_IMAGE:-nvidia/cuda:13.0.0-base-ubuntu24.04}
SMOKE_MARKER="$STATE_DIR/smoke-ok"

PURGE_DATA=0

_suite() { # Ubuntu codename, e.g. "resolute"
  ( . /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}" )
}

_docker_sources_content() {
  cat <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(_suite)
Components: stable
Signed-By: $DOCKER_KEY
EOF
}

_wait_docker() { # wait until the daemon answers
  local _
  for _ in $(seq 1 30); do
    sudo docker info >/dev/null 2>&1 && return 0
    sleep 1
  done
  warn "docker daemon did not answer within 30 s; recent journal:"
  sudo journalctl -u docker -n 40 --no-pager || true
  die "docker daemon is not responding"
}

# ------------------------------------------------------------------ s01
s01_desc()  { echo "apt prerequisites: ca-certificates curl gnupg"; }
s01_check() { pkgs_installed ca-certificates curl gnupg; }
s01_apply() {
  apt_get update
  apt_get install ca-certificates curl gnupg
}
s01_undo() {
  info "s01: left in place on purpose (shared system packages other software depends on)"
}

# ------------------------------------------------------------------ s02
s02_desc()  { echo "Docker apt repository + signing key"; }
s02_check() {
  [[ -f $DOCKER_KEY && -f $DOCKER_SRC ]] && cmp -s <(_docker_sources_content) "$DOCKER_SRC"
}
s02_apply() {
  local suite; suite=$(_suite)
  info "Ubuntu suite: $suite"
  # fail early and clearly if Docker has no repo for this release
  curl -fsSI --max-time 20 "https://download.docker.com/linux/ubuntu/dists/$suite/Release" >/dev/null \
    || die "download.docker.com has no repository for suite '$suite'"
  [[ -e /etc/apt/sources.list.d/docker.list ]] \
    && warn "legacy /etc/apt/sources.list.d/docker.list exists; it may duplicate $DOCKER_SRC"
  curl -fsSL --max-time 60 https://download.docker.com/linux/ubuntu/gpg -o "$TMPD/docker.asc"
  [[ -s $TMPD/docker.asc ]] || die "downloaded Docker key is empty"
  _docker_sources_content >"$TMPD/docker.sources"
  managed_install s02 "$TMPD/docker.asc" "$DOCKER_KEY" 0644
  managed_install s02 "$TMPD/docker.sources" "$DOCKER_SRC" 0644
  apt_get update
}
s02_undo() {
  managed_restore s02 "$DOCKER_SRC"
  managed_restore s02 "$DOCKER_KEY"
  apt_get update || warn "apt-get update failed after removing the Docker repo (check other repos)"
}

# ------------------------------------------------------------------ s03
s03_desc()  { echo "Docker Engine packages (${DOCKER_PKGS[*]})"; }
s03_check() { pkgs_installed "${DOCKER_PKGS[@]}"; }
s03_apply() {
  apt_get install "${DOCKER_PKGS[@]}"
  info "installed: $(dpkg-query -W -f='${Package} ${Version}\n' "${DOCKER_PKGS[@]}" | tr '\n' ';')"
}
s03_undo() {
  local p present=()
  for p in "${DOCKER_PKGS[@]}"; do pkg_installed "$p" && present+=("$p"); done
  if ((${#present[@]})); then
    apt_get purge "${present[@]}"
  else
    info "s03: no Docker packages installed"
  fi
  # Never deleted by this script: /var/lib/docker and /var/lib/containerd hold your images and volumes.
  if ((PURGE_DATA)); then
    warn "s03: --purge-data does NOT delete anything any more. If you really want /var/lib/docker and"
    warn "     /var/lib/containerd gone (all images, containers, volumes), do it yourself after checking them:"
    warn "       sudo ls /var/lib/docker /var/lib/containerd"
  else
    info "s03: /var/lib/docker and /var/lib/containerd (images, volumes) are left in place"
  fi
}

# ------------------------------------------------------------------ s04
s04_desc()  { echo "Docker service enabled and running (systemd)"; }
s04_check() { systemctl is-enabled --quiet docker.service 2>/dev/null && systemctl is-active --quiet docker.service; }
s04_apply() {
  pkg_installed docker-ce || die "docker-ce is not installed; apply s03 first"
  sudo systemctl enable --now docker.service
  _wait_docker
}
s04_undo() {
  if systemctl cat docker.service >/dev/null 2>&1; then
    sudo systemctl disable --now docker.service docker.socket || true
  else
    info "s04: docker.service does not exist"
  fi
}

# ------------------------------------------------------------------ s05
s05_desc()  { echo "NVIDIA Container Toolkit apt repository + key"; }
s05_check() {
  [[ -f $NV_KEY && -f $NV_LIST ]] && grep -q "signed-by=$NV_KEY" "$NV_LIST"
}
s05_apply() {
  curl -fsSL --max-time 60 https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor >"$TMPD/nv.gpg"
  [[ -s $TMPD/nv.gpg ]] || die "NVIDIA key is empty after dearmor"
  curl -fsSL --max-time 60 https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed "s#deb https://#deb [signed-by=$NV_KEY] https://#g" >"$TMPD/nv.list"
  grep -q '^deb ' "$TMPD/nv.list" || die "NVIDIA repo list looks wrong: $(head -c 300 "$TMPD/nv.list")"
  managed_install s05 "$TMPD/nv.gpg" "$NV_KEY" 0644
  managed_install s05 "$TMPD/nv.list" "$NV_LIST" 0644
  apt_get update
}
s05_undo() {
  managed_restore s05 "$NV_LIST"
  managed_restore s05 "$NV_KEY"
  apt_get update || warn "apt-get update failed after removing the NVIDIA repo (check other repos)"
}

# ------------------------------------------------------------------ s06
s06_desc()  { echo "NVIDIA Container Toolkit package (runtime only; no Linux GPU driver)"; }
s06_check() { pkgs_installed "${NVIDIA_PKGS[@]}"; }
s06_apply() {
  apt_get install "${NVIDIA_PKGS[@]}"
  info "installed: $(dpkg-query -W -f='${Package} ${Version}\n' "${NVIDIA_PKGS[@]}" | tr '\n' ';')"
}
s06_undo() {
  local p present=()
  for p in "${NVIDIA_PKGS[@]}"; do pkg_installed "$p" && present+=("$p"); done
  if ((${#present[@]})); then apt_get purge "${present[@]}"; else info "s06: toolkit not installed"; fi
}

# ------------------------------------------------------------------ s07
s07_desc()  { echo "Register the nvidia runtime in $DAEMON_JSON and restart Docker"; }
s07_check() { [[ -f $DAEMON_JSON ]] && grep -q '"nvidia"' "$DAEMON_JSON"; }
s07_apply() {
  command -v nvidia-ctk >/dev/null || die "nvidia-ctk not found; apply s06 first"
  systemctl is-active --quiet docker.service || die "docker is not running; apply s04 first"
  track_original s07 "$DAEMON_JSON"
  sudo nvidia-ctk runtime configure --runtime=docker
  sudo systemctl restart docker.service
  _wait_docker
  info "$DAEMON_JSON now contains:"
  sudo cat "$DAEMON_JSON"
}
s07_undo() {
  managed_restore s07 "$DAEMON_JSON"
  if systemctl is-active --quiet docker.service; then
    sudo systemctl restart docker.service
  fi
}

# ------------------------------------------------------------------ s08
s08_desc()  { echo "GPU smoke test: docker run --gpus all $TEST_IMAGE nvidia-smi"; }
s08_check() {
  [[ -f $SMOKE_MARKER ]] || return 1
  # Cross-check against reality only if sudo needs no password right now; otherwise
  # (e.g. plain `status`) trust the marker instead of reporting a false PENDING.
  if sudo -n true 2>/dev/null; then
    sudo -n docker image inspect "$TEST_IMAGE" >/dev/null 2>&1
  fi
}
s08_apply() {
  local out existed=1
  sudo docker image inspect "$TEST_IMAGE" >/dev/null 2>&1 || existed=0
  ((existed)) || : >"$(_created_path s08 image)"
  if ! out=$(sudo docker run --rm --gpus all "$TEST_IMAGE" nvidia-smi 2>&1); then
    echo "$out"
    warn "---- diagnostics for the failed GPU test ----"
    sudo docker info 2>&1 | grep -iE 'runtimes|default runtime|cgroup|storage driver' || true
    sudo cat "$DAEMON_JSON" 2>&1 || true
    ls -l /usr/lib/wsl/lib/libcuda.so* /usr/lib/wsl/lib/nvidia-smi 2>&1 || true
    nvidia-smi --query-gpu=name,driver_version --format=csv,noheader 2>&1 || true
    die "GPU container test failed (see output above)"
  fi
  echo "$out"
  grep -q 'NVIDIA-SMI' <<<"$out" || die "container ran but nvidia-smi output looks wrong"
  date -Is >"$SMOKE_MARKER"
}
s08_undo() {
  rm -f "$SMOKE_MARKER"
  local cr; cr=$(_created_path s08 image)
  if [[ -e $cr ]]; then
    sudo docker rmi "$TEST_IMAGE" >/dev/null 2>&1 || true
    rm -f "$cr"
    info "s08: removed test image $TEST_IMAGE"
  else
    info "s08: test image was not pulled by this script (or already gone); left alone"
  fi
}
