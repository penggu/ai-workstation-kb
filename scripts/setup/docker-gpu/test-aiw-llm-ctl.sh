#!/usr/bin/env bash
# test-aiw-llm-ctl.sh - offline tests of the root-run controller's argument checking. Needs no sudo, no docker, no GPU.
# It builds a test copy of the controller from the template (placeholders filled with temp paths, the two root/sudo
# guards and the runuser call replaced, docker replaced by a stub that records what it was asked to run). The
# shipped template is not changed. Run: ./test-aiw-llm-ctl.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d "${TMPDIR:-/tmp}/aiw-ctl-test.XXXXXX"); trap 'rm -rf -- "$T"' EXIT
pass=0; fail=0
ok()   { pass=$((pass+1)); }
bad()  { fail=$((fail+1)); echo "FAIL: $*"; }

[[ $(grep -c 'AIW-GUARD' "$HERE/aiw-llm-ctl.template") -eq 2 ]] || bad "the template must have exactly two AIW-GUARD lines (root check, user check)"
grep -q 'AIW-RUNUSER' "$HERE/aiw-llm-ctl.template" || bad "the template lost its runuser line"

mkdir -p "$T/models" "$T/logs" "$T/bin"; : >"$T/models/M.gguf"; : >"$T/tpl.jinja"
printf '%s' "0123456789abcdef0123456789abcdef0123456789abcdef" >"$T/key"
cat >"$T/bin/docker" <<'S'
#!/bin/bash
printf '%s\n' "$*" >>"$AIW_TEST_CALLS"
printf 'ENVKEY=%s\n' "${LLAMA_API_KEY:-}" >>"$AIW_TEST_CALLS"
exit 0
S
chmod +x "$T/bin/docker"
python3 -I - "$HERE/aiw-llm-ctl.template" "$T/ctl" "$T" <<'PY'
import sys,re
tpl,out,t=sys.argv[1:]
s=open(tpl).read()
for k,v in {"CONTAINER":"aiw-local-llm","ALIAS":"local-qwen","IMAGE_REF":"img@sha256:"+"a"*64,"RUN_USER":"tester","RUN_UID":"1000","RUN_GID":"1000",
            "MODEL_DIR":t+"/models","LOG_DIR":t+"/logs","KEY_FILE":t+"/key","TEMPLATE_FILE":t+"/tpl.jinja"}.items():
    s=s.replace("@@%s@@"%k,v)
s="\n".join(l for l in s.split("\n") if "AIW-GUARD" not in l)
s=s.replace("DOCKER=/usr/bin/docker","DOCKER="+t+"/bin/docker")
s=re.sub(r"runuser -u \"\$RUN_USER\" -- ","",s)
open(out,"w").write(s)
PY
chmod +x "$T/ctl"; bash -n "$T/ctl" || bad "test copy has a syntax error"
export AIW_TEST_CALLS="$T/calls"

GOOD=(--model-file M.gguf --ctx 98304 --kv q8_0 --reasoning off --threads 6 --port 8080 --log-name server-20261104-011548.log)
run() { : >"$AIW_TEST_CALLS"; out=$("$T/ctl" "$@" 2>&1); rc=$?; }
refused() { # DESCRIPTION args...  : must exit 2 and never reach docker run
  local d=$1; shift; run "$@"
  if [[ $rc -eq 2 ]] && ! grep -q '^run ' "$AIW_TEST_CALLS"; then ok; else bad "$d (rc=$rc) $out"; fi
}

run start "${GOOD[@]}" --template
[[ $rc -eq 0 ]] && ok || bad "valid start failed: $out"
runline=$(grep '^run ' "$AIW_TEST_CALLS" | head -1)
for want in "--name aiw-local-llm" "--gpus all" "--user 1000:1000" "--entrypoint /app/llama-server" "-p 127.0.0.1:8080:8080" \
            "-v $T/models:/models:ro" "-v $T/logs:/logs" "-v $T/tpl.jinja:/chat-template.jinja:ro" "--reasoning off" "-c 98304" \
            "-ctk q8_0" "--chat-template-file /chat-template.jinja" "--log-file /logs/server-20261104-011548.log" "-e LLAMA_API_KEY" "-m /models/M.gguf" \
            "--cap-drop ALL" "--security-opt no-new-privileges" "--read-only" "--pids-limit"; do
  [[ $runline == *"$want"* ]] && ok || bad "docker run line lacks: $want  (got: $runline)"
done
[[ $runline != *0123456789abcdef* ]] && ok || bad "the API key appears on the docker command line"
grep -q 'ENVKEY=0123456789abcdef0123456789abcdef0123456789abcdef' "$AIW_TEST_CALLS" && ok || bad "the API key did not reach docker's environment"
[[ $runline != *"--privileged"* && $runline != *" -v /:"* ]] && ok || bad "privileged or root mount in the run line"

run start "${GOOD[@]}"; [[ $rc -eq 0 && $(grep '^run ' "$AIW_TEST_CALLS") != *chat-template* ]] && ok || bad "start without --template must not mount a template"

refused "model file with a path"            start --model-file ../M.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log
mkdir -p "$T/models/sub"; : >"$T/models/sub/M2.gguf"
refused "traversal to a file that EXISTS"   start --model-file ../models/M.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log
refused "subfolder file that EXISTS"        start --model-file sub/M2.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log
refused "model file with a slash"           start --model-file sub/M.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log
refused "model file, shell metacharacters"  start --model-file 'M.gguf;id' --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log
refused "model file that does not exist"    start --model-file Nope.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log
refused "model file without .gguf"          start --model-file M --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log
for v in 1 511 2097153 abc 1e5 -5 '' '99 --privileged'; do refused "ctx '$v'" start --model-file M.gguf --ctx "$v" --kv f16 --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log; done
for v in 0 65 x ''; do refused "threads '$v'" start --model-file M.gguf --ctx 4096 --kv f16 --reasoning on --threads "$v" --port 8080 --log-name server-20260101-000000.log; done
for v in 80 1023 65536 8o80 ''; do refused "port '$v'" start --model-file M.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port "$v" --log-name server-20260101-000000.log; done
for v in fp16 q4_0 '' 'f16 --privileged'; do refused "kv '$v'" start --model-file M.gguf --ctx 4096 --kv "$v" --reasoning on --threads 1 --port 8080 --log-name server-20260101-000000.log; done
for v in yes ON '' 'on;id'; do refused "reasoning '$v'" start --model-file M.gguf --ctx 4096 --kv f16 --reasoning "$v" --threads 1 --port 8080 --log-name server-20260101-000000.log; done
for v in ../x.log server-1.log /etc/passwd 'server-20260101-000000.log/../x' ''; do refused "log-name '$v'" start --model-file M.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --port 8080 --log-name "$v"; done
refused "missing option (no --port)"        start --model-file M.gguf --ctx 4096 --kv f16 --reasoning on --threads 1 --log-name server-20260101-000000.log
refused "unknown option"                    start "${GOOD[@]}" --privileged
refused "unknown option with value"         start "${GOOD[@]}" --volume /:/host
refused "option without a value"            start --model-file
refused "no subcommand"
refused "unknown subcommand"                exec
refused "stop with an argument"             stop --force
refused "running with an argument"          running x
refused "logs with an argument"             logs -f
refused "status-line with an argument"      status-line x

# a key that is not a plain alphanumeric string is refused (no newline/option injection through the key file)
printf '%s' 'abc def' >"$T/key"; refused "key with a space" start "${GOOD[@]}"
printf '%s' 'short' >"$T/key"; refused "short key" start "${GOOD[@]}"
printf '%s' "0123456789abcdef0123456789abcdef0123456789abcdef" >"$T/key"
rm -f "$T/tpl.jinja"; refused "--template without the template file" start "${GOOD[@]}" --template

# a symlink in the PARENT path of the log folder is refused (the last-component check alone would miss it)
mkdir -p "$T/real/logs"; ln -s "$T/real" "$T/pl"
sed "s#LOG_DIR='$T/logs'#LOG_DIR='$T/pl/logs'#" "$T/ctl" >"$T/ctl2"; chmod +x "$T/ctl2"
: >"$AIW_TEST_CALLS"; out=$("$T/ctl2" start "${GOOD[@]}" 2>&1); rc=$?
[[ $rc -eq 2 && $out == *symlink* ]] && ! grep -q '^run ' "$AIW_TEST_CALLS" && ok || bad "symlink in the log folder path was not refused (rc=$rc) $out"

# the environment sudo should have reset: leftovers are refused, nothing reaches docker
for v in BASH_ENV LD_PRELOAD DOCKER_HOST DOCKER_CONTEXT; do
  : >"$AIW_TEST_CALLS"; out=$(env "$v=/x" "$T/ctl" start "${GOOD[@]}" 2>&1); rc=$?
  [[ $rc -eq 2 && $out == *"not reset"* ]] && ! grep -q '^run ' "$AIW_TEST_CALLS" && ok || bad "$v set was not refused (rc=$rc) $out"
done
# a symlink in the model folder path is refused
ln -s "$T/models" "$T/ml"; sed "s#MODEL_DIR='$T/models'#MODEL_DIR='$T/ml'#" "$T/ctl" >"$T/ctl3"; chmod +x "$T/ctl3"
: >"$AIW_TEST_CALLS"; out=$("$T/ctl3" start "${GOOD[@]}" 2>&1); rc=$?
[[ $rc -eq 2 && $out == *symlink* ]] && ! grep -q '^run ' "$AIW_TEST_CALLS" && ok || bad "symlinked model folder was not refused (rc=$rc) $out"

run stop;        [[ $rc -eq 0 && $(head -1 "$AIW_TEST_CALLS") == "stop -t 30 aiw-local-llm" ]] && ok || bad "stop: $(head -1 "$AIW_TEST_CALLS")"
run running;     [[ $rc -eq 0 && $(head -1 "$AIW_TEST_CALLS") == 'ps -q -f name=^aiw-local-llm$' ]] && ok || bad "running: $(head -1 "$AIW_TEST_CALLS")"
run status-line; [[ $rc -eq 0 && $(head -1 "$AIW_TEST_CALLS") == 'ps --filter name=^aiw-local-llm$ --format {{.Status}}' ]] && ok || bad "status-line: $(head -1 "$AIW_TEST_CALLS")"
run logs;        [[ $rc -eq 0 && $(head -1 "$AIW_TEST_CALLS") == "logs --tail 40 aiw-local-llm" ]] && ok || bad "logs: $(head -1 "$AIW_TEST_CALLS")"

echo "passed: $pass   failed: $fail"; ((fail == 0))
