#!/usr/bin/env bash
# claude-local.sh - start ONE Claude Code session that talks to the local llama-server (local-llm.sh) instead of
# Anthropic's API. Nothing is written to disk and your normal `claude` is untouched: the settings exist only in the
# environment of this one process. Run it inside the project you want to work on (it does not change directory).
#
#   ./claude-local.sh [--dry-run] [-- claude args...]       e.g.  ./claude-local.sh -- -p "explain main.py"
#
# Based on the settings measured in a private earlier project (Claude Code 2.1.309 on Windows); not yet re-verified
# on this machine, so treat the first sessions as a test. Environment variables you can set:
#   LOCAL_LLM_PORT (8080)  LOCAL_LLM_CTX (98304; must equal the server's --ctx)  LOCAL_LLM_MAX_OUTPUT (16000)
#   LOCAL_LLM_MODEL (local-qwen; the --alias of the server)
set -euo pipefail
PORT=${LOCAL_LLM_PORT:-8080}
CTX=${LOCAL_LLM_CTX:-98304}
MAXOUT=${LOCAL_LLM_MAX_OUTPUT:-16000}
MODEL=${LOCAL_LLM_MODEL:-local-qwen}
KEY_FILE=${LOCAL_LLM_KEY_FILE:-$HOME/.local/state/ai-workstation/local-llm/api-key}
BASE="http://127.0.0.1:$PORT"

DRY=0; CLAUDE_ARGS=()
while (($#)); do
  case "$1" in
    --dry-run) DRY=1 ;;
    --) shift; CLAUDE_ARGS=("$@"); break ;;
    *) echo "unknown option: $1 (pass Claude Code arguments after --)" >&2; exit 2 ;;
  esac
  shift
done
((${#CLAUDE_ARGS[@]})) && for a in "${CLAUDE_ARGS[@]}"; do
  case "$a" in --permission-mode*) echo "note: the permission mode is forced back to 'default' while CLAUDE_CODE_SUBPROCESS_ENV_SCRUB is set (measured earlier)." >&2 ;; esac
done

command -v claude >/dev/null || { echo "claude is not on PATH" >&2; exit 1; }
[[ -s $KEY_FILE ]] || { echo "no API key at $KEY_FILE; run ./local-llm.sh start first" >&2; exit 1; }
[[ -z $(ss -ltn "sport = :$PORT" 2>/dev/null | tail -n +2) ]] && { echo "nothing is listening on 127.0.0.1:$PORT; run ./local-llm.sh start" >&2; exit 1; }
[[ $(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BASE/health" || true) == 200 ]] || { echo "server on $BASE is not healthy" >&2; exit 1; }

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
  echo "would run: claude --permission-mode default --settings '<json below>' ${CLAUDE_ARGS[*]:-}"
  echo "token: from $KEY_FILE (environment only, not shown)"
  python3 -I -c 'import json,sys; print(json.dumps(json.loads(sys.argv[1]), indent=2))' "$SETTINGS"
  exit 0
fi

# The compaction window variable has a floor (100000) above our context, so only the percentage is used.
# ANTHROPIC_API_KEY is removed so two credentials do not compete.
TOKEN=$(cat "$KEY_FILE")
exec env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_AUTO_COMPACT_WINDOW \
  ANTHROPIC_AUTH_TOKEN="$TOKEN" \
  claude --permission-mode default --settings "$SETTINGS" "${CLAUDE_ARGS[@]}"
