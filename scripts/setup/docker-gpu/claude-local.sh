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
#   ./claude-local.sh [--dry-run] [--reuse-tunnel] [claude arguments...]
#   e.g.   ./claude-local.sh --resume        ./claude-local.sh -p "explain main.py"
# Options before `--` that the script does not know are passed to claude; `--` stops option parsing.
#
# REMOTE MODE needs the SSH host (an alias from your ~/.ssh/config). It is NOT stored in this repository: set it in
# the environment, or in a private file outside any repository (default ~/.config/ai-workstation/private.env,
# override with AIW_PRIVATE_ENV), for example:
#     LOCAL_LLM_SSH_HOST=my-gpu-host
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
MAXOUT=${LOCAL_LLM_MAX_OUTPUT:-16000}
MODEL=${LOCAL_LLM_MODEL:-local-qwen}
KEY_FILE=${LOCAL_LLM_KEY_FILE:-$HOME/.local/state/ai-workstation/local-llm/api-key}
REMOTE_KEY_FILE=${LOCAL_LLM_REMOTE_KEY_FILE:-'~/.local/state/ai-workstation/local-llm/api-key'}   # expanded by the remote shell

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
    --) shift; CLAUDE_ARGS+=("$@"); break ;;
    *) CLAUDE_ARGS+=("$1") ;;
  esac
  shift
done
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
    if command -v uv >/dev/null; then SEARCH_CMD=(uv run --quiet --no-project --with "$DDGS_PIN" python "$SEARCH_MCP")
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

health() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$1/health" 2>/dev/null || true; }
port_in_use() { local rc=0; curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$1/" 2>/dev/null || rc=$?; ((rc != 7)); }   # curl exit 7 = connection refused

TOKEN=""
if [[ -s $KEY_FILE ]]; then
  # ---- local mode: the server runs on this machine
  MODE=local; BASE="http://127.0.0.1:$PORT"
  TOKEN=$(cat "$KEY_FILE")
else
  # ---- remote mode: tunnel to the GPU machine
  MODE=remote; BASE="http://127.0.0.1:$TUNNEL_PORT"
  command -v ssh >/dev/null || { echo "ssh is required for remote mode" >&2; exit 1; }
  [[ -n $SSH_HOST ]] || { echo "no API key at $KEY_FILE, so this looks like a remote machine, but LOCAL_LLM_SSH_HOST is not set (see the header of this script)" >&2; exit 1; }
  SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=30 -o ServerAliveCountMax=3)
  # The key comes over SSH into a variable; it appears in no argument list.
  TOKEN=$(ssh "${SSH_OPTS[@]}" "$SSH_HOST" "cat $REMOTE_KEY_FILE" 2>/dev/null) || TOKEN=""
  [[ -n $TOKEN ]] || { echo "could not read the API key over ssh from '$SSH_HOST' (is ssh key login working, and is local-llm.sh start done on that machine?)" >&2; exit 1; }
  if port_in_use "$TUNNEL_PORT"; then
    if ((REUSE)); then echo "reusing whatever listens on 127.0.0.1:$TUNNEL_PORT (--reuse-tunnel)" >&2
    else echo "127.0.0.1:$TUNNEL_PORT is already in use. Not sending the API key to an unknown listener. Pick another port (LOCAL_LLM_TUNNEL_PORT), or pass --reuse-tunnel if it is your own tunnel." >&2; exit 1; fi
  else
    ssh "${SSH_OPTS[@]}" -o ExitOnForwardFailure=yes -N -L "127.0.0.1:$TUNNEL_PORT:127.0.0.1:$PORT" "$SSH_HOST" &
    TUNNEL_PID=$!
    for _ in $(seq 1 20); do
      kill -0 "$TUNNEL_PID" 2>/dev/null || { echo "the ssh tunnel exited; check 'ssh $SSH_HOST' works from this machine" >&2; TUNNEL_PID=""; exit 1; }
      [[ $(health "$BASE") == 200 ]] && break
      sleep 1
    done
  fi
fi

[[ $(health "$BASE") == 200 ]] || { echo "server at $BASE is not healthy; on the GPU machine run ./local-llm.sh start (and status)" >&2; exit 1; }

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
  echo "mode: $MODE   endpoint: $BASE"
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
