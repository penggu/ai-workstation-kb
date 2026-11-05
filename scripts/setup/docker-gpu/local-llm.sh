#!/usr/bin/env bash
# local-llm.sh - run a local llama-server (Docker) as an API endpoint for Claude Code and other clients.
# Serves the OpenAI API (/v1/chat/completions) and the Anthropic Messages API (/v1/messages), which is
# what Claude Code speaks. Loopback only, API key required, runs as your normal user, never as root.
#
#   ./local-llm.sh status | start | stop | restart | test | undo
#   After ./sudo-local-llm.sh apply (a root-owned, validating controller) none of these ask for a password.
#   restart = stop, then start with the options given: the way to change --reasoning, --ctx, --kv or --quant
#   (they are fixed at server start; `start` on a running server changes nothing and says so).
#   options: --quant Q (default UD-IQ3_XXS)   --ctx N (default 98304)   --kv f16|q8_0 (default q8_0)
#            --reasoning on|off|auto (default on = the model's own default)   --port N (default 8080)
#            --threads N (default 6)   --no-template-fix   --dry-run   --yes
#
# Chat template: the Qwen3.8 template refuses a system message that comes after the conversation started
# ("System message must be at the beginning", HTTP 500), and Claude Code sends one, so the client retried forever.
# By default the server gets the model's own template with that one line changed (gguf_template.py renders such a
# message as a system turn). --no-template-fix uses the unmodified template.
#
# The defaults come from the measurements in docs/recipes/qwen-27b-quantisation-16gb.md: UD-IQ3_XXS with a
# q8_0 KV cache fits about 101K tokens in 16 GB (1 GiB margin), so 98304 leaves a little headroom. All layers go
# on the GPU (-ngl 99, -fit off): if it does not fit, it fails loudly instead of silently spilling to the CPU.
#
# State: ~/.local/state/ai-workstation/local-llm/   (log, xtrace, last-error.txt, api-key (mode 600),
#        server-logs/server-<time>.log: the server's own log, one file per start, kept after stop or a crash)
# undo: stops the server and deletes only the files this script generated (api-key, chat-template-patched.jinja).
set -Eeuo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AIW_STATE_DIR="${AIW_STATE_DIR:-$HOME/.local/state/ai-workstation/local-llm}"
# shellcheck source=lib.sh
source "$HERE/lib.sh"

MODEL_DIR=${LLAMA_MODEL_DIR:-$HOME/models/gguf/qwen3.8-27b}
IMAGE_STATE=${LLAMA_IMAGE_STATE:-$HOME/.local/state/ai-workstation/llama-image/image-digest.txt}
KEY_FILE="$STATE_DIR/api-key"
SERVER_LOG_DIR="$STATE_DIR/server-logs"                  # one file per start; survives stop/crash (the container is --rm)
TEMPLATE_FILE="$STATE_DIR/chat-template-patched.jinja"   # generated from the model file by gguf_template.py
CONTAINER=aiw-local-llm
ALIAS=local-qwen                      # the model name clients use (claude-local.sh sets the same)
VRAM_BASELINE_MAX_MIB=${VRAM_BASELINE_MAX_MIB:-3500}
READY_TIMEOUT=${READY_TIMEOUT:-900}

d() { sudo docker "$@"; }
# When sudo-local-llm.sh has installed the root-owned controller, ALL privileged work goes through it (validated options,
# no docker access for this user, no password with the sudoers rule). Without it, fall back to `sudo docker`.
CTL=/usr/local/sbin/aiw-llm-ctl
have_ctl() { [[ -x $CTL ]]; }
ctl() { sudo "$CTL" "$@"; }
stop_server() { if have_ctl; then ctl stop >/dev/null; else d stop -t 30 "$CONTAINER" >/dev/null; fi; }
image_ref() { head -1 "$IMAGE_STATE" 2>/dev/null; }

TEMPLATE_FIX=1; DRY_RUN=0; QUANT=UD-IQ3_XXS; CTX=98304; KV=q8_0; REASONING=on; PORT=${LOCAL_LLM_PORT:-8080}; THREADS=6
cmd=${1:-status}; (($#)) && shift
while (($#)); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --no-template-fix) TEMPLATE_FIX=0 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --quant) shift; QUANT=${1:-} ;;
    --ctx) shift; CTX=${1:-} ;;
    --kv) shift; KV=${1:-} ;;
    --reasoning) shift; REASONING=${1:-} ;;
    --port) shift; PORT=${1:-} ;;
    --threads) shift; THREADS=${1:-} ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
[[ $CTX =~ ^[1-9][0-9]*$ && $PORT =~ ^[1-9][0-9]*$ && $THREADS =~ ^[1-9][0-9]*$ ]] || { echo "--ctx, --port, --threads must be positive integers" >&2; exit 2; }
case "$KV" in f16|q8_0) ;; *) echo "--kv must be f16 or q8_0" >&2; exit 2 ;; esac
case "$REASONING" in on|off|auto) ;; *) echo "--reasoning must be on, off or auto" >&2; exit 2 ;; esac
((EUID == 0)) && { echo "Do not run as root; the script calls sudo itself." >&2; exit 2; }
MODEL_FILE="Qwen3.8-27B-$QUANT.gguf"

server_running() { # a failed docker call is an error, NOT "not running" (it used to report "not running" when sudo had no password)
  local out
  if have_ctl; then out=$(ctl running 2>&1) || die "cannot ask the controller whether the server runs (sudo needs a password? run ./sudo-local-llm.sh apply, or run this from your own terminal): $out"; [[ -n $out ]]; return; fi
  out=$(d ps -q -f "name=^${CONTAINER}$" 2>&1) || die "cannot ask docker whether the server runs (sudo needs a password? run ./sudo-local-llm.sh apply once, or run this from your own terminal): $out"
  [[ -n $out ]]
}

# The key is only read with tracing off, so it does not end up in the xtrace file.
ensure_key() {
  [[ -s $KEY_FILE ]] && return 0
  { set +x; } 2>/dev/null
  (umask 077; python3 -c 'import secrets; print(secrets.token_hex(24))' >"$KEY_FILE")
  set -x
  info "generated an API key: $KEY_FILE (mode 600)"
}

preflight() {
  local ref; ref=$(image_ref)
  [[ -n $ref ]] || die "no pinned image digest at $IMAGE_STATE; run ./llama-image.sh apply first"
  have_ctl || d image inspect "$ref" >/dev/null 2>&1 || die "image $ref is not present locally"   # the controller checks it itself
  [[ -f $MODEL_DIR/$MODEL_FILE ]] || die "model file not found: $MODEL_DIR/$MODEL_FILE"
  local procs; procs=$(running_jobs --no-downloads || true)
  if [[ -n $procs ]]; then echo "$procs" | cut -c1-160; die "a benchmark or another server is running (a GPU job); wait for it to finish"; fi
  local used; used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
  info "GPU memory in use before start: ${used} MiB (limit ${VRAM_BASELINE_MAX_MIB})"
  if ((used > VRAM_BASELINE_MAX_MIB)); then warn "if Ollama holds a model: 'ollama ps' then 'ollama stop <model>'"; die "something else is using the GPU (${used} MiB)"; fi
  if [[ -n $(ss -ltn "sport = :$PORT" 2>/dev/null | tail -n +2) ]]; then die "port $PORT is already in use (use --port)"; fi
}

start_server() {
  local ref; ref=$(image_ref)
  ensure_key
  { set +x; } 2>/dev/null
  local KEY
  # shellcheck disable=SC2034  # KEY is read by name (indirect expansion) in write_key_envfile
  KEY=$(cat "$KEY_FILE")
  set -x
  mkdir -p "$SERVER_LOG_DIR"
  local srv_log; srv_log="server-$(date +%Y%m%d-%H%M%S).log"
  info "server log (kept after stop): $SERVER_LOG_DIR/$srv_log"
  local tpl_args=() tpl_mount=()
  if ((TEMPLATE_FIX)); then
    python3 -I "$HERE/gguf_template.py" "$MODEL_DIR/$MODEL_FILE" "$TEMPLATE_FILE" || die "could not build the patched chat template (use --no-template-fix to skip)"
    tpl_args=(--chat-template-file /chat-template.jinja); tpl_mount=(-v "$TEMPLATE_FILE":/chat-template.jinja:ro)
  fi
  local args=(-m "/models/$MODEL_FILE" --alias "$ALIAS" -c "$CTX" -np 1 -fa on -ctk "$KV" -ctv "$KV" -t "$THREADS"
              -ngl 99 -fit off --jinja --reasoning "$REASONING" "${tpl_args[@]}" --log-file "/logs/$srv_log" --log-timestamps --no-webui --host 0.0.0.0 --port 8080)
  info "llama-server ${args[*]}"
  # The key goes in through --env-file (a mode-600 file in this run's private temp dir, deleted right after docker reads
  # it): not on any command line, not in the trace. NOT through the environment: `sudo` resets it, so an exported
  # LLAMA_API_KEY never reaches docker and the server started WITHOUT a key (found in its log, 2026-11-03).
  if have_ctl; then
    # privileged path: the controller validates every option, reads the key file itself and starts the container
    local ctl_args=(start --model-file "$MODEL_FILE" --ctx "$CTX" --kv "$KV" --reasoning "$REASONING" --threads "$THREADS" --port "$PORT" --log-name "$srv_log")
    ((TEMPLATE_FIX)) && ctl_args+=(--template)
    ctl "${ctl_args[@]}" >/dev/null || die "the controller refused or failed to start the server (message above)"
    start_wait; return 0
  fi
  local envf="$TMPD/llama.env"
  write_key_envfile "$envf" KEY
  { set +x; } 2>/dev/null
  d run -d --rm --name "$CONTAINER" --gpus all --user "$(id -u):$(id -g)" -e HOME=/tmp --env-file "$envf" \
      -v "$MODEL_DIR":/models:ro -v "$SERVER_LOG_DIR":/logs "${tpl_mount[@]}" -p "127.0.0.1:$PORT:8080" --entrypoint /app/llama-server "$ref" "${args[@]}" >/dev/null
  rm -f -- "$envf"
  set -x
  start_wait
}

start_wait() {
  local t0=$SECONDS code
  while :; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$PORT/health" || true)
    [[ $code == 200 ]] && break
    if ! server_running; then
      warn "the server container exited early; last log lines:"; if have_ctl; then ctl logs 2>&1 || true; else d logs --tail 40 "$CONTAINER" 2>&1 || true; fi
      die "llama-server did not start (see above; a CUDA out-of-memory here means --ctx is too large)"
    fi
    ((SECONDS - t0 < READY_TIMEOUT)) || die "llama-server not ready after ${READY_TIMEOUT}s (health code '$code')"
    sleep 2
  done
  ok "server ready after $((SECONDS - t0)) s"
}

# Checks that both APIs answer. The key stays in a curl config on stdin, never on a command line or in the trace.
api_test() {
  local url="http://127.0.0.1:$PORT" key out
  { set +x; } 2>/dev/null
  key=$(cat "$KEY_FILE")
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -s --max-time 120 -K - -H 'content-type: application/json' \
        -d "{\"model\":\"$ALIAS\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word READY.\"}]}" \
        "$url/v1/messages" || true)
  set -x
  info "POST /v1/messages -> $(printf '%s' "$out" | cut -c1-300)"
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); assert d.get("type")=="message", d' "$out" \
    && ok "/v1/messages answers in the Anthropic format" || die "/v1/messages did not return an Anthropic message"
  { set +x; } 2>/dev/null
  out=$(printf 'header = "Authorization: Bearer %s"\n' "$key" | curl -s --max-time 60 -K - -H 'content-type: application/json' \
        -d "{\"model\":\"$ALIAS\",\"messages\":[{\"role\":\"user\",\"content\":\"hello\"}]}" "$url/v1/messages/count_tokens" || true)
  set -x
  info "POST /v1/messages/count_tokens -> $(printf '%s' "$out" | cut -c1-200)"
  # The key must be ENFORCED: a request with no key and one with a wrong key must both be refused.
  local code_nokey code_wrong
  code_nokey=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H 'content-type: application/json' -d '{}' "$url/v1/messages" || true)
  code_wrong=$(printf 'header = "Authorization: Bearer not-the-key"\n' | curl -s -o /dev/null -w '%{http_code}' --max-time 20 -K - -H 'content-type: application/json' -d '{}' "$url/v1/messages" || true)
  info "without a key -> HTTP $code_nokey; with a wrong key -> HTTP $code_wrong (both must be refused: 401/403)"
  [[ $code_nokey =~ ^40[13]$ && $code_wrong =~ ^40[13]$ ]] && ok "the API key is enforced" \
    || die "the API key is NOT enforced (no key -> HTTP $code_nokey, wrong key -> HTTP $code_wrong): stop the server (./local-llm.sh stop)"
}

show_status() {
  if server_running; then
    ok "server container '$CONTAINER' is running; http://127.0.0.1:$PORT (key: $KEY_FILE)"
    # exact command line, so the optional no-password rule in sudo-local-llm.sh matches it
    if have_ctl; then echo "  $(ctl status-line)  image: $(image_ref | cut -c1-80)"; else echo "  $(d ps --filter "name=^${CONTAINER}$" --format '{{.Status}}')  image: $(image_ref | cut -c1-80)"; fi
  else
    info "server is not running"
  fi
  [[ -s $KEY_FILE ]] && info "api-key file exists: $KEY_FILE" || info "no api-key file yet"
}

init_logging "localllm-$cmd"
# shellcheck disable=SC2154  # _rc is assigned inside the single-quoted trap string
trap '_rc=$?; _cleanup "$_rc"' EXIT
info "command: $cmd quant=$QUANT ctx=$CTX kv=$KV reasoning=$REASONING port=$PORT threads=$THREADS dry-run=$DRY_RUN"
snapshot
# Without the controller (sudo-local-llm.sh apply) start/restart ask for the sudo password up front (docker run).
# With it, nothing here needs a password, and nothing needs docker access.
[[ $cmd == start || $cmd == restart ]] && ((!DRY_RUN)) && [[ ${SKIP_SUDO_V:-0} != 1 ]] && ! have_ctl && { info "asking for sudo once"; sudo -v; }

case "$cmd" in
  status) CURRENT_STEP=status; show_status ;;
  start)
    CURRENT_STEP=start
    if server_running; then ok "already running; start does not change its settings (use: restart with the new options)"; show_status; exit 0; fi
    if ((DRY_RUN)); then info "[dry-run] would start $MODEL_FILE (ctx $CTX, KV $KV, reasoning $REASONING) on 127.0.0.1:$PORT"; exit 0; fi
    preflight; CURRENT_ACTION=run
    start_server; api_test; record start localllm started
    echo; ok "ready. In another terminal: ./claude-local.sh   (stop with: ./local-llm.sh stop)"
    ;;
  restart)
    CURRENT_STEP=restart
    if ((DRY_RUN)); then info "[dry-run] would stop the server if running, then start $MODEL_FILE (ctx $CTX, KV $KV, reasoning $REASONING) on 127.0.0.1:$PORT"; exit 0; fi
    if server_running; then stop_server; ok "stopped"; record stop localllm stopped; fi
    preflight; CURRENT_ACTION=run
    start_server; api_test; record start localllm started
    echo; ok "ready with reasoning $REASONING, ctx $CTX, KV $KV. In another terminal: ./claude-local.sh"
    ;;
  test) CURRENT_STEP="test"; server_running || die "server is not running"; api_test ;;
  stop)
    CURRENT_STEP=stop
    if ! server_running; then ok "not running"; exit 0; fi
    if ((DRY_RUN)); then info "[dry-run] would stop $CONTAINER"; exit 0; fi
    stop_server; ok "stopped"; record stop localllm stopped
    ;;
  undo)
    CURRENT_STEP=undo
    if ((DRY_RUN)); then info "[dry-run] would stop the server and delete $KEY_FILE"; exit 0; fi
    server_running && { stop_server; ok "stopped"; }
    [[ -f $TEMPLATE_FILE ]] && rm -f -- "$TEMPLATE_FILE" && ok "deleted the generated chat template"
    if [[ -f $KEY_FILE ]]; then confirm "Delete the API key file $KEY_FILE (generated by this script)?" && rm -f -- "$KEY_FILE" && ok "deleted the api-key file"; fi
    record undo localllm undone
    ;;
  *) echo "usage: $0 status|start|stop|restart|test|undo [--quant Q] [--ctx N] [--kv KV] [--reasoning on|off|auto] [--port N] [--threads N] [--dry-run] [--yes]" >&2; exit 2 ;;
esac
