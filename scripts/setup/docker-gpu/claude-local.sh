#!/usr/bin/env bash
# claude-local.sh - start ONE Claude Code session that talks to the local llama-server (local-llm.sh) instead of
# Anthropic's API. Works in two places:
#
#   on the GPU machine (WSL/Linux):  reads the API key file and talks to 127.0.0.1 directly.
#   on another machine (e.g. a Mac): opens an SSH tunnel to the GPU machine, fetches the key over SSH, and
#                                    closes the tunnel when the session ends.
#
# Nothing is written to disk and your normal `claude` is untouched: the settings exist only in the environment of this
# one process. Run it inside the project you want to work on (it does not change directory).
#
#   ./claude-local.sh [--backend llama|strata|auto] [--dry-run] [--reuse-tunnel] [claude arguments...]
#   e.g.   ./claude-local.sh --resume        ./claude-local.sh -p "explain main.py"
# Options before `--` that the script does not know are passed to claude; `--` stops option parsing.
#
# BACKEND (default auto, or LOCAL_LLM_BACKEND): which local server to talk to. Only one of them can hold the GPU, so
# `auto` simply uses the one that answers: a Strata server on STRATA_PORT (default 8090) if one does, otherwise the
# llama.cpp server (local-llm.sh; on a Mac without a key file: through the SSH tunnel below). If both answer, it stops
# and asks you to choose with --backend. `auto` recognises Strata through /health, which needs no credential (also on a Strata started with a key); the llama.cpp
# key is only sent to the llama.cpp backend, the Strata token only to Strata.
#   llama   key file, LOCAL_LLM_PORT (8080), LOCAL_LLM_CTX and LOCAL_LLM_MODEL (must match local-llm.sh), remote tunnel.
#   strata  github.com/Niko1221/Strata (here, or on the GPU machine through an SSH tunnel, see REMOTE MODE): the model name and context are read from the server itself (LOCAL_LLM_CTX and
#           LOCAL_LLM_MODEL are ignored). Without an API key the token is the constant "strata-local". We start Strata with a key
#           (--api-key-env), keep it in a mode-600 file and set STRATA_TOKEN_FILE.
#           Start it e.g.:  strata launch --model q2_0 --data-dir ~/strata-data --context 128k --vision off \
#                                  --drafting mtp --tune skip --access local --port 8090 --api-key-env STRATA_API_KEY --yes --no-tui
#   Max output tokens default to 16000 (llama) / 4096 (strata); LOCAL_LLM_MAX_OUTPUT overrides both.
#
# REMOTE MODE needs the SSH host (an alias from your ~/.ssh/config). It is NOT stored in this repository: set it in
# the environment, or in a private file outside any repository (default ~/.config/ai-workstation/private.env,
# override with AIW_PRIVATE_ENV), for example:
#     LOCAL_LLM_SSH_HOST=my-gpu-host
# Remote mode works for both backends. With --backend strata (or auto, which asks the GPU machine over ssh what runs
# there) it tunnels STRATA_TUNNEL_PORT (18090) to the GPU machine's STRATA_PORT (8090) and reads the key from
# STRATA_REMOTE_KEY_FILE there (default ~/.local/state/ai-workstation/strata/api-key; without a file the constant
# token is used; STRATA_TOKEN_FILE on this machine overrides). Confirmed on a personal Mac (2026-11-05, issue #24).
# Other settings (all optional):
#   LOCAL_LLM_PORT (8080, the server's port on the GPU machine)   LOCAL_LLM_TUNNEL_PORT (18080, local end of the tunnel)
#   LOCAL_LLM_CTX (98304; must equal the server's --ctx)  LOCAL_LLM_MAX_OUTPUT (16000)  LOCAL_LLM_MODEL (local-qwen)
#   LOCAL_LLM_KEY_FILE (local mode)   LOCAL_LLM_REMOTE_KEY_FILE (remote mode; path on the GPU machine)
#
# WEB SEARCH: Anthropic's own WebSearch tool cannot work against a local server, so it is disabled and replaced by a
# small MCP server of ours (scripts/mcp/web_search_mcp.py: Tavily if a key exists, else DuckDuckGo via ddgs). It runs on
# the machine where `claude` runs, is passed with --mcp-config/--strict-mcp-config for this session only, and sends only
# the model's search query to Tavily/DuckDuckGo. Tavily key: ~/.config/ai-workstation/tavily.key (mode 600) or
# TAVILY_API_KEY; without a key it uses DuckDuckGo. LOCAL_LLM_NO_SEARCH=1 turns it off; your own --mcp-config wins.
#
# Privacy: the API key is read into a shell variable and handed to claude through its environment only (never on a
# command line, in a file or in a log). The tunnel is bound to 127.0.0.1 on your machine. If something already listens
# on the tunnel port, the key is NOT sent to it unless you pass --reuse-tunnel (you vouch it is your own tunnel).
#
# Written to run on macOS's old bash 3.2 too. Tested with a stand-in ssh and server on Linux, and confirmed to work
# on a real Mac in remote mode (2026-11-02).
set -euo pipefail

PORT=${LOCAL_LLM_PORT:-8080}
TUNNEL_PORT=${LOCAL_LLM_TUNNEL_PORT:-18080}
CTX=${LOCAL_LLM_CTX:-98304}
MAXOUT=${LOCAL_LLM_MAX_OUTPUT:-}      # default depends on the backend, set below
MODEL=${LOCAL_LLM_MODEL:-local-qwen}
BACKEND=${LOCAL_LLM_BACKEND:-auto}
SPORT=${STRATA_PORT:-8090}                      # Strata's port on the machine that runs it
STUNNEL_PORT=${STRATA_TUNNEL_PORT:-18090}       # local end of the tunnel to a Strata on another machine
STRATA_TOKEN_FILE=${STRATA_TOKEN_FILE:-}
KEY_FILE=${LOCAL_LLM_KEY_FILE:-$HOME/.local/state/ai-workstation/local-llm/api-key}
REMOTE_KEY_FILE=${LOCAL_LLM_REMOTE_KEY_FILE:-'~/.local/state/ai-workstation/local-llm/api-key'}   # expanded by the remote shell
STRATA_REMOTE_KEY_FILE=${STRATA_REMOTE_KEY_FILE:-'~/.local/state/ai-workstation/strata/api-key'}   # same, for Strata

AIW_PRIVATE_ENV=${AIW_PRIVATE_ENV:-$HOME/.config/ai-workstation/private.env}
# shellcheck disable=SC1090
[[ -f $AIW_PRIVATE_ENV ]] && source "$AIW_PRIVATE_ENV"
SSH_HOST=${LOCAL_LLM_SSH_HOST:-}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH_MCP="$HERE/../../mcp/web_search_mcp.py"
DDGS_PIN="ddgs==9.16.0"
DRY=0; REUSE=0; CLAUDE_ARGS=()
while (($#)); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --reuse-tunnel) REUSE=1 ;;
    --backend) (($# >= 2)) || { echo "--backend needs a value: llama, strata or auto" >&2; exit 2; }; BACKEND=$2; shift ;;
    --backend=*) BACKEND=${1#--backend=} ;;
    --) shift; CLAUDE_ARGS+=("$@"); break ;;
    *) CLAUDE_ARGS+=("$1") ;;
  esac
  shift
done
case "$BACKEND" in auto|llama|strata) ;; *) echo "--backend must be llama, strata or auto (got: $BACKEND)" >&2; exit 2 ;; esac
# these end up in a command run by the remote shell (ports; key file paths are left unquoted so ~ expands there),
# so they must be plain numbers / plain paths
for _v in PORT SPORT STUNNEL_PORT TUNNEL_PORT; do [[ ${!_v} =~ ^[0-9]{1,5}$ ]] || { echo "$_v must be a port number (got: ${!_v})" >&2; exit 2; }; done
for _v in REMOTE_KEY_FILE STRATA_REMOTE_KEY_FILE; do [[ ${!_v} =~ ^[~A-Za-z0-9_./-]+$ ]] || { echo "$_v may only contain letters, digits and ~ _ . / - (got: ${!_v})" >&2; exit 2; }; done
[[ -z $MAXOUT || $MAXOUT =~ ^[0-9]{1,6}$ ]] || { echo "LOCAL_LLM_MAX_OUTPUT must be a number" >&2; exit 2; }
if ((${#CLAUDE_ARGS[@]})); then
  for a in "${CLAUDE_ARGS[@]}"; do
    case "$a" in --permission-mode*) echo "note: the permission mode is forced back to 'default' while CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set (measured earlier)." >&2 ;; esac
  done
fi

# WebSearch is an Anthropic server-side tool: against this local server it always reports "Did 0 searches" and the model
# then guesses URLs. It is disabled unless you pass your own --disallowedTools (then yours is used as given).
HAVE_DISALLOW=0
if ((${#CLAUDE_ARGS[@]})); then
  for a in "${CLAUDE_ARGS[@]}"; do case "$a" in --disallowedTools*|--disallowed-tools*) HAVE_DISALLOW=1 ;; esac; done
fi
((HAVE_DISALLOW)) || CLAUDE_ARGS+=(--disallowedTools WebSearch)

# Our search MCP server for this session (no secrets in the config: the key is read by the server from its own file).
HAVE_MCP=0
if ((${#CLAUDE_ARGS[@]})); then
  for a in "${CLAUDE_ARGS[@]}"; do case "$a" in --mcp-config*|--strict-mcp-config*) HAVE_MCP=1 ;; esac; done
fi
SEARCH_STATE="off"
if [[ ${LOCAL_LLM_NO_SEARCH:-0} != 1 ]] && ((!HAVE_MCP)); then
  if [[ -f $SEARCH_MCP ]]; then
    if command -v uv >/dev/null; then SEARCH_CMD=(uv run --quiet --no-project --python ">=3.10" --with "$DDGS_PIN" python "$SEARCH_MCP")
    else SEARCH_CMD=(python3 "$SEARCH_MCP"); fi
    MCP_JSON=$(python3 -I -c 'import json,sys; print(json.dumps({"mcpServers":{"websearch":{"type":"stdio","command":sys.argv[1],"args":sys.argv[2:]}}}))' "${SEARCH_CMD[@]}")
    CLAUDE_ARGS+=(--mcp-config "$MCP_JSON" --strict-mcp-config)
    if [[ -n ${TAVILY_API_KEY:-} || -s ${AIW_TAVILY_KEY_FILE:-$HOME/.config/ai-workstation/tavily.key} ]]; then SEARCH_STATE="on (Tavily key found, DuckDuckGo as fallback)"
    else SEARCH_STATE="on (no Tavily key: DuckDuckGo only)"; fi
    [[ ${SEARCH_CMD[0]} == uv ]] || SEARCH_STATE="$SEARCH_STATE; uv not found, so ddgs is not installed: Tavily only"
  else
    SEARCH_STATE="off (not found: $SEARCH_MCP)"
  fi
fi

command -v claude >/dev/null || { echo "claude is not on PATH" >&2; exit 1; }
command -v curl >/dev/null || { echo "curl is required" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 is required (it builds the settings JSON)" >&2; exit 1; }

TUNNEL_PID=""
cleanup() { if [[ -n $TUNNEL_PID ]]; then kill "$TUNNEL_PID" 2>/dev/null || true; wait "$TUNNEL_PID" 2>/dev/null || true; TUNNEL_PID=""; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Every curl below talks to 127.0.0.1 (here or on the GPU machine): it connects within milliseconds or there is no
# server. --connect-timeout keeps a silently dropped connection (some firewalls and sandboxes) from costing --max-time.
health() { curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 "$1/health" 2>/dev/null || true; }
# Does something accept connections on 127.0.0.1:$1? A connection that is refused, and also one that is silently dropped
# (some firewalls and sandboxes do that), never connects, so curl reports time_connect 0.
port_in_use() { local t; t=$(curl -s -o /dev/null --connect-timeout 1 --max-time 2 -w '%{time_connect}' "http://127.0.0.1:$1/" 2>/dev/null) || true; [[ -n ${t//[0.,]/} ]]; }

# Does a Strata server answer on $SPORT? Prints "MODEL CTX" (read from the server, checked against strict patterns).
# $1 = the token; it goes in through stdin, never on a command line. $2 = the port to ask.
strata_probe() {
  local body
  body=$(printf 'Authorization: Bearer %s\n' "$1" | curl -s --noproxy '*' --connect-timeout 2 --max-time 5 -H @- "http://127.0.0.1:$2/v1/models" 2>/dev/null) || return 1
  printf '%s' "$body" | python3 -I -c '
import json, re, sys
try:
    d = json.load(sys.stdin)["data"][0]
    m = d["id"]; c = int(d.get("meta", {}).get("n_ctx", 0))
except Exception:
    sys.exit(1)
if not re.fullmatch(r"[A-Za-z0-9._:-]{1,100}", m) or not 2048 <= c <= 4194304:
    sys.exit(1)
print(m, c)
'
}

STRATA_TOKEN="strata-local"
[[ -n $STRATA_TOKEN_FILE && -s $STRATA_TOKEN_FILE ]] && STRATA_TOKEN=$(head -c 300 "$STRATA_TOKEN_FILE" | tr -d '\r\n')
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
# /health needs no credential, also on a Strata server started with a key, and names the service.
strata_up() {
  curl -s --noproxy '*' --connect-timeout 2 --max-time 5 "http://127.0.0.1:$SPORT/health" 2>/dev/null |
    python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("service") == "strata" else 1)' 2>/dev/null
}
# The same two checks on the GPU machine, through ssh (remote mode): no tunnel is needed to find out what runs there.
remote_strata_up() {
  ssh "${SSH_OPTS[@]}" "$SSH_HOST" "curl -s --connect-timeout 2 --max-time 5 http://127.0.0.1:$SPORT/health" 2>/dev/null |
    python3 -I -c 'import json,sys; sys.exit(0 if json.load(sys.stdin).get("service") == "strata" else 1)' 2>/dev/null
}
remote_llama_up() { [[ $(ssh "${SSH_OPTS[@]}" "$SSH_HOST" "curl -s -o /dev/null -w '%{http_code}' --connect-timeout 2 --max-time 5 http://127.0.0.1:$PORT/health" 2>/dev/null) == 200 ]]; }

STRATA_REMOTE=0; REMOTE_CHECKED=0
if [[ $BACKEND == auto ]]; then
  S_UP=0; strata_up && S_UP=1
  L_UP=0; [[ -s $KEY_FILE && $(health "http://127.0.0.1:$PORT") == 200 ]] && L_UP=1
  if [[ $S_UP == 1 && $L_UP == 1 ]]; then
    echo "both a Strata server (port $SPORT) and the llama.cpp server (port $PORT) answer. Choose one: --backend strata or --backend llama." >&2; exit 1
  elif [[ $S_UP == 1 ]]; then BACKEND=strata
  elif [[ -s $KEY_FILE || -z $SSH_HOST ]]; then BACKEND=llama     # this is the GPU machine (or nothing is configured)
  else
    # another machine: ask the GPU machine which server runs there
    RS=0; remote_strata_up && RS=1
    RL=0; remote_llama_up && RL=1
    if [[ $RS == 1 && $RL == 1 ]]; then
      echo "both a Strata server (port $SPORT) and the llama.cpp server (port $PORT) answer on the GPU machine. Choose one: --backend strata or --backend llama." >&2; exit 1
    elif [[ $RS == 1 ]]; then BACKEND=strata; STRATA_REMOTE=1; REMOTE_CHECKED=1
    else BACKEND=llama; fi
  fi
fi

# open_tunnel LOCAL_PORT REMOTE_PORT: ssh -N -L in the background (TUNNEL_PID); refuses to use a port someone else holds.
open_tunnel() {
  if port_in_use "$1"; then
    if ((REUSE)); then echo "reusing whatever listens on 127.0.0.1:$1 (--reuse-tunnel)" >&2; return 0; fi
    echo "127.0.0.1:$1 is already in use. Not sending the API key to an unknown listener. Pick another port (LOCAL_LLM_TUNNEL_PORT, STRATA_TUNNEL_PORT), or pass --reuse-tunnel if it is your own tunnel." >&2; exit 1
  fi
  ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -N -L "127.0.0.1:$1:127.0.0.1:$2" "$SSH_HOST" &
  TUNNEL_PID=$!
  for _ in $(seq 1 20); do
    kill -0 "$TUNNEL_PID" 2>/dev/null || { echo "the ssh tunnel exited; check 'ssh $SSH_HOST' works from this machine" >&2; TUNNEL_PID=""; exit 1; }
    [[ $(health "http://127.0.0.1:$1") == 200 ]] && break
    sleep 1
  done
}

S_INFO=""
S_BASE_PORT=$SPORT
if [[ $BACKEND == strata ]]; then
  if ((!STRATA_REMOTE)) && [[ -n $SSH_HOST ]] && ! strata_up; then
    command -v ssh >/dev/null || { echo "ssh is required for remote mode" >&2; exit 1; }
    STRATA_REMOTE=1
  fi
  if ((STRATA_REMOTE)); then
    ((REMOTE_CHECKED)) || remote_strata_up || { echo "no Strata server answers on port $SPORT of '$SSH_HOST' (is it running there? is ssh key login working?). Not on this machine either (port $SPORT). For llama.cpp use --backend llama." >&2; exit 1; }
    # remote Strata: the token is the key file on the GPU machine (or STRATA_TOKEN_FILE here); without one, Strata
    # was started without a key and the constant token is right.
    if [[ -z $STRATA_TOKEN_FILE ]]; then
      # exit 255 = ssh itself failed; exit 1 = no key file there (Strata runs without a key): the constant token stays
      rc=0; RT=$(ssh "${SSH_OPTS[@]}" "$SSH_HOST" "test -e $STRATA_REMOTE_KEY_FILE && cat $STRATA_REMOTE_KEY_FILE" 2>/dev/null) || rc=$?
      ((rc != 255)) || { echo "could not read the Strata key over ssh from '$SSH_HOST' (is ssh key login working?)" >&2; exit 1; }
      [[ -z $RT ]] || STRATA_TOKEN=$RT
      unset RT rc
    fi
    open_tunnel "$STUNNEL_PORT" "$SPORT"
    S_BASE_PORT=$STUNNEL_PORT
  fi
  S_INFO=$(strata_probe "$STRATA_TOKEN" "$S_BASE_PORT" 2>/dev/null) || S_INFO=""
  [[ -n $S_INFO ]] || { echo "Strata does not answer on http://127.0.0.1:$S_BASE_PORT, refuses the token (if it was started with an API key, set STRATA_TOKEN_FILE to the file holding it), or its answer has no model name and context. Start it first (example in the header of this script). For llama.cpp use --backend llama." >&2; exit 1; }
fi

TOKEN=""
if [[ $BACKEND == strata ]]; then
  # ---- Strata: model name and context come from the server (here, or through the tunnel to the GPU machine)
  MODE=local; ((!STRATA_REMOTE)) || MODE=remote
  BASE="http://127.0.0.1:$S_BASE_PORT"
  read -r MODEL CTX <<<"$S_INFO"
  TOKEN=$STRATA_TOKEN
  [[ -n $MAXOUT ]] || MAXOUT=4096
elif [[ -s $KEY_FILE ]]; then
  # ---- llama.cpp, local mode: the server runs on this machine
  MODE=local; BASE="http://127.0.0.1:$PORT"
  TOKEN=$(cat "$KEY_FILE")
else
  # ---- remote mode: tunnel to the GPU machine
  MODE=remote; BASE="http://127.0.0.1:$TUNNEL_PORT"
  command -v ssh >/dev/null || { echo "ssh is required for remote mode" >&2; exit 1; }
  [[ -n $SSH_HOST ]] || { echo "no API key at $KEY_FILE, so this looks like a remote machine, but LOCAL_LLM_SSH_HOST is not set (see the header of this script)" >&2; exit 1; }
  # The key comes over SSH into a variable; it appears in no argument list.
  TOKEN=$(ssh "${SSH_OPTS[@]}" "$SSH_HOST" "cat $REMOTE_KEY_FILE" 2>/dev/null) || TOKEN=""
  [[ -n $TOKEN ]] || { echo "could not read the API key over ssh from '$SSH_HOST' (is ssh key login working, and is local-llm.sh start done on that machine?)" >&2; exit 1; }
  open_tunnel "$TUNNEL_PORT" "$PORT"
fi

[[ -n $MAXOUT ]] || MAXOUT=16000
# (a Strata server was already checked by the probe above)
[[ $BACKEND == strata || $(health "$BASE") == 200 ]] || { echo "server at $BASE is not healthy; on the GPU machine run ./local-llm.sh start (and status)" >&2; exit 1; }

# Non-secret settings also go through --settings, because a settings file's `env` block (yours or the project's)
# overrides the shell environment; this keeps a project file from redirecting the requests. The token cannot go
# there (command lines are visible to every process), so it stays in the environment only.
SETTINGS=$(python3 -I - "$BASE" "$MODEL" "$CTX" "$MAXOUT" <<'PY'
import json, os, sys
base, model, ctx, maxout = sys.argv[1:5]
no_proxy = ",".join(x for x in [os.environ.get("NO_PROXY", ""), "127.0.0.1", "localhost", "::1"] if x)
env = {
  "ANTHROPIC_BASE_URL": base,
  "ANTHROPIC_MODEL": model,
  "ANTHROPIC_DEFAULT_HAIKU_MODEL": model, "ANTHROPIC_DEFAULT_SONNET_MODEL": model,
  "ANTHROPIC_DEFAULT_OPUS_MODEL": model, "CLAUDE_CODE_SUBAGENT_MODEL": model,
  "CLAUDE_CODE_SUBAGENT_MODEL_FORCE": "1",
  "CLAUDE_CODE_MAX_CONTEXT_TOKENS": ctx,
  "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE": "50",
  "CLAUDE_CODE_MAX_OUTPUT_TOKENS": maxout,
  "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
  "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB": "1",
  "NO_PROXY": no_proxy, "no_proxy": no_proxy,
  # no switching to a cloud provider
  "CLAUDE_CODE_USE_BEDROCK": "", "CLAUDE_CODE_USE_VERTEX": "", "CLAUDE_CODE_USE_FOUNDRY": "",
}
print(json.dumps({"env": env}))
PY
)

if ((DRY)); then
  echo "backend: $BACKEND   mode: $MODE   endpoint: $BASE   model: $MODEL   context: $CTX"
  echo "would run: claude --permission-mode default --settings '<json below>' ${CLAUDE_ARGS[*]:-}"
  echo "token: obtained ($MODE), kept in the environment only, not shown"
  echo "web search MCP: $SEARCH_STATE"
  python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), indent=2))' "$SETTINGS"
  exit 0
fi

# The compaction window variable has a floor (100000) above our context, so only the percentage is used.
# ANTHROPIC_API_KEY is removed so two credentials do not compete. The token is exported (not given as `env VAR=...`)
# so it is never part of a command line.
unset ANTHROPIC_API_KEY CLAUDE_CODE_AUTO_COMPACT_WINDOW
export ANTHROPIC_AUTH_TOKEN="$TOKEN"
unset TOKEN
rc=0
claude --permission-mode default --settings "$SETTINGS" ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"} || rc=$?
exit "$rc"
