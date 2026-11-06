#!/usr/bin/env bash
# test-claude-local.sh - offline tests of claude-local.sh's backend choice and its remote (SSH tunnel) mode for Strata.
# Needs no GPU, no real ssh and no real claude: a stand-in `ssh` serves the "tunnel" with a small fake server, a
# stand-in `claude` records what it was given. The script under test is not changed. Run: ./test-claude-local.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/claude-local-test.XXXXXX")
cleanup() { for p in $(jobs -p); do kill "$p" 2>/dev/null; done; rm -rf -- "$T"; }
trap cleanup EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $*"; }
expect() { local what=$1; shift; if "$@"; then ok; else bad "$what"; fi; }   # expect "text" cmd args...

mkdir -p "$T/bin" "$T/home"
listening() { local t; t=$(curl -s -o /dev/null --max-time 2 -w '%{time_connect}' "http://127.0.0.1:$1/" 2>/dev/null) || true; [[ -n ${t//[0.,]/} ]]; }   # same test as the script's port_in_use
KEY="sk-strata-TESTKEY0123456789"
LKEY="llama-TESTKEY0123456789"

# ---- fake server: kinds strata (needs the key on /v1/models), llama (/health only), spy (records headers)
cat >"$T/fake_server.py" <<'PY'
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
port, kind, key, log = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        with open(log, "a") as f: f.write("%s %s auth=%s\n" % (kind, self.path, auth))
        if self.path == "/health":
            self.send(200, {"service": "strata", "status": "ok", "api_key": True} if kind == "strata" else {"status": "ok"})
        elif self.path == "/v1/models" and kind == "strata":
            if auth != "Bearer " + key: self.send(401, {"error": "unauthorized"})
            else: self.send(200, {"data": [{"id": "m-strata", "meta": {"n_ctx": 131072}}]})
        else: self.send(404, {})
HTTPServer(("127.0.0.1", port), H).serve_forever()
PY

# ---- fake ssh. FAKE_REMOTE = space-separated list of what runs on the "GPU machine": strata llama
cat >"$T/bin/ssh" <<'S'
#!/bin/bash
printf '%s\n' "$*" >>"$FAKE_SSH_LOG"
args=("$@"); last="${args[${#args[@]}-1]}"
has() { case " $FAKE_REMOTE " in *" $1 "*) return 0;; esac; return 1; }
for ((i=0;i<${#args[@]};i++)); do
  if [[ ${args[i]} == -L ]]; then
    spec=${args[i+1]}; lp=${spec#*:}; lp=${lp%%:*}; rp=${spec##*:}
    if [[ $rp == "$FAKE_STRATA_PORT" ]] && has strata; then exec python3 -I "$FAKE_SERVER" "$lp" strata "$FAKE_STRATA_KEY" "$FAKE_SERVER_LOG"; fi
    if [[ $rp == "$FAKE_LLAMA_PORT" ]] && has llama; then exec python3 -I "$FAKE_SERVER" "$lp" llama x "$FAKE_SERVER_LOG"; fi
    exit 255
  fi
done
case "$last" in
  *"cat "*strata*) [[ -n ${FAKE_SSH_FAIL:-} ]] && exit 255; [[ -n ${FAKE_NO_STRATA_KEY:-} ]] && exit 1; has strata && printf '%s' "$FAKE_STRATA_KEY"; exit 0 ;;
  *"cat "*) has llama && printf '%s' "$FAKE_LLAMA_KEY"; exit 0 ;;
  curl*"-w"*) if [[ $last == *":$FAKE_LLAMA_PORT/"* ]] && has llama; then printf 200; else printf 000; fi; exit 0 ;;
  curl*) if [[ $last == *":$FAKE_STRATA_PORT/"* ]] && has strata; then printf '{"service": "strata", "status": "ok", "api_key": true}'; fi; exit 0 ;;
esac
exit 255
S
cat >"$T/bin/claude" <<'S'
#!/bin/bash
{ echo "BASE=$ANTHROPIC_BASE_URL"; echo "TOKEN=$ANTHROPIC_AUTH_TOKEN"; echo "ARGS=$*"; } >"$FAKE_CLAUDE_OUT"
exit 7
S
chmod +x "$T/bin/ssh" "$T/bin/claude"

SP=38090; STP=38091; LP=38080; LTP=38081           # strata/llama port on the "GPU machine", and the local tunnel ports
for _p in $SP $STP $LP $LTP; do listening "$_p" && { echo "port $_p is in use; the test needs 127.0.0.1:$SP $STP $LP $LTP free"; exit 1; }; done
export FAKE_SSH_LOG="$T/ssh.log" FAKE_SERVER="$T/fake_server.py" FAKE_SERVER_LOG="$T/server.log" FAKE_CLAUDE_OUT="$T/claude.out"
export FAKE_STRATA_PORT=$SP FAKE_LLAMA_PORT=$LP FAKE_STRATA_KEY=$KEY FAKE_LLAMA_KEY=$LKEY

run() {   # run <FAKE_REMOTE> args...  -> sets OUT, RC; clean slate per call
  local remote=$1 t0=$SECONDS; shift
  : >"$FAKE_SSH_LOG"; : >"$FAKE_SERVER_LOG"; rm -f "$FAKE_CLAUDE_OUT"
  OUT=$(env HOME="$T/home" PATH="$T/bin:$PATH" AIW_PRIVATE_ENV="$T/none.env" LOCAL_LLM_NO_SEARCH=1 \
        LOCAL_LLM_SSH_HOST=gpu FAKE_REMOTE="$remote" STRATA_PORT=$SP STRATA_TUNNEL_PORT=$STP \
        LOCAL_LLM_PORT=$LP LOCAL_LLM_TUNNEL_PORT=$LTP LOCAL_LLM_KEY_FILE="$T/home/nokey" \
        "${EXTRA_ENV[@]}" bash "$HERE/claude-local.sh" "$@" 2>&1); RC=$?
  [[ -z ${TEST_DEBUG:-} ]] || { echo "--- run $remote $*: rc=$RC, $((SECONDS - t0)) s"; echo "$OUT" | cut -c1-300; }
}
EXTRA_ENV=(X=1)
not_listening() { ! listening "$1"; }
claude_got() { grep -q -- "$1" "$FAKE_CLAUDE_OUT" 2>/dev/null; }

# 1. explicit strata, remote: tunnel, key over ssh, exit code passes through, tunnel closed, key on no command line
run strata --backend strata hello
expect "strata remote: exit code of claude passes through (7)" test "$RC" -eq 7
expect "strata remote: claude talks to the tunnel port" claude_got "ARGS=.*\"ANTHROPIC_BASE_URL\": \"http://127.0.0.1:$STP\""
expect "strata remote: claude got the remote key as its token" claude_got "TOKEN=$KEY"
expect "strata remote: prompt argument passed on" claude_got "ARGS=.* hello"
expect "strata remote: key is on no ssh command line" bash -c '! grep -q -- "$0" "$FAKE_SSH_LOG"' "$KEY"
expect "strata remote: key is not in claude's arguments" bash -c '! grep "^ARGS=" "$FAKE_CLAUDE_OUT" | grep -q -- "$0"' "$KEY"
expect "strata remote: tunnel closed after the session" not_listening "$STP"

expect "strata remote: default key file path on the GPU machine" bash -c 'grep -q "strata/api-key" "$FAKE_SSH_LOG"'

# 1b. a wrong token: the probe fails, and the tunnel that was opened is closed again
printf 'wrong\n' >"$T/wrongtok"
EXTRA_ENV=(STRATA_TOKEN_FILE="$T/wrongtok")
run strata --backend strata --dry-run
expect "wrong token: fails with the Strata message" bash -c 'echo "$0" | grep -q "refuses the token"' "$OUT"
expect "wrong token: tunnel closed again" not_listening "$STP"
EXTRA_ENV=(X=1)

# 1c. ssh itself fails while reading the key: a clear message, not a silent constant token
EXTRA_ENV=(FAKE_SSH_FAIL=1)
run strata --backend strata --dry-run
expect "ssh failure on key read: says so" bash -c 'echo "$0" | grep -q "could not read the Strata key over ssh"' "$OUT"
EXTRA_ENV=(X=1)

# 2. auto: only Strata on the GPU machine -> strata
run strata --dry-run
expect "auto, only strata remote: backend strata, mode remote" bash -c 'echo "$0" | grep -q "backend: strata   mode: remote"' "$OUT"
expect "auto, only strata remote: model and context read through the tunnel" bash -c 'echo "$0" | grep -q "model: m-strata   context: 131072"' "$OUT"

# 3. auto: only llama.cpp -> llama (the behaviour that existed before)
run llama --dry-run
expect "auto, only llama remote: backend llama, mode remote" bash -c 'echo "$0" | grep -q "backend: llama   mode: remote"' "$OUT"
expect "auto, only llama remote: llama tunnel port" bash -c 'echo "$0" | grep -q "endpoint: http://127.0.0.1:'"$LTP"'"' "$OUT"

# 4. auto: both -> asks to choose
run "strata llama" --dry-run
expect "auto, both remote: refuses" test "$RC" -ne 0
expect "auto, both remote: says to choose" bash -c 'echo "$0" | grep -q "Choose one"' "$OUT"

# 5. auto: neither -> fails the way it did (llama path), not with a strata message
run "" --dry-run
expect "auto, nothing remote: fails" test "$RC" -ne 0
expect "auto, nothing remote: not a Strata message" bash -c '! echo "$0" | grep -q "Strata does not answer"' "$OUT"

# 6. explicit strata, nothing up remotely
run "" --backend strata --dry-run
expect "strata explicit, nothing remote: fails" test "$RC" -ne 0
expect "strata explicit, nothing remote: says no Strata answers on the GPU machine" bash -c 'echo "$0" | grep -q "no Strata server answers on port"' "$OUT"

# 7. foreign listener on the tunnel port: the key must not be sent to it; no ssh -L
python3 -I "$T/fake_server.py" "$STP" spy x "$T/spy.log" & SPY=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do listening $STP && break; sleep 0.2; done
: >"$T/spy.log"
run strata --backend strata --dry-run
expect "foreign tunnel-port listener: refuses" test "$RC" -ne 0
expect "foreign tunnel-port listener: says it is in use" bash -c 'echo "$0" | grep -q "already in use"' "$OUT"
expect "foreign tunnel-port listener: key never sent to it" bash -c '! grep -q -- "$0" "$1"' "$KEY" "$T/spy.log"
run strata --backend strata --reuse-tunnel --dry-run
expect "--reuse-tunnel: goes ahead only when told (it then fails on the spy, not on the port)" bash -c 'echo "$0" | grep -q "reusing whatever listens"' "$OUT"
kill "$SPY" 2>/dev/null; wait "$SPY" 2>/dev/null

# 8. Strata started without a key: no key file over ssh -> the constant token "strata-local" is what the server wants
export FAKE_STRATA_KEY="strata-local"
EXTRA_ENV=(FAKE_NO_STRATA_KEY=1)
run strata --backend strata --dry-run
expect "strata without key: constant token accepted" bash -c 'echo "$0" | grep -q "mode: remote"' "$OUT"
export FAKE_STRATA_KEY=$KEY
EXTRA_ENV=(X=1)

# 9. a local Strata wins over ssh (the GPU machine itself); token file honoured
python3 -I "$T/fake_server.py" "$SP" strata "$KEY" "$T/local.log" & LOC=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do listening $SP && break; sleep 0.2; done
printf '%s\n' "$KEY" >"$T/tok"; chmod 600 "$T/tok"
EXTRA_ENV=(STRATA_TOKEN_FILE="$T/tok")
run "strata" --dry-run
expect "local strata: mode local" bash -c 'echo "$0" | grep -q "backend: strata   mode: local"' "$OUT"
expect "local strata: no ssh used" bash -c '! test -s "$FAKE_SSH_LOG"'
EXTRA_ENV=(X=1)
kill "$LOC" 2>/dev/null; wait "$LOC" 2>/dev/null

# 10. no ssh host configured and no local strata: the old message
EXTRA_ENV=(LOCAL_LLM_SSH_HOST=)
run "" --backend strata --dry-run
expect "no ssh host: strata message" bash -c 'echo "$0" | grep -q "Strata does not answer"' "$OUT"
EXTRA_ENV=(X=1)

# 11. the new settings are validated (they reach a remote shell command)
EXTRA_ENV=(STRATA_TUNNEL_PORT='18090;id')
run strata --backend strata --dry-run
expect "bad tunnel port: rejected" test "$RC" -eq 2
EXTRA_ENV=(STRATA_PORT='8090;id')
run strata --backend strata --dry-run
expect "bad strata port: rejected" test "$RC" -eq 2
EXTRA_ENV=(LOCAL_LLM_PORT='8080;id')
run llama --dry-run
expect "bad llama port: rejected" test "$RC" -eq 2
EXTRA_ENV=(STRATA_REMOTE_KEY_FILE='~/k;id')
run strata --backend strata --dry-run
expect "bad remote key path: rejected" test "$RC" -eq 2
EXTRA_ENV=(X=1)

echo "claude-local tests: $pass passed, $fail failed"
((fail == 0))
