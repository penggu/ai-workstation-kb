#!/usr/bin/env bash
# check.sh - the one command that runs every offline check: bash -n and shellcheck on all shell scripts, the two
# shell test scripts, and the MCP Python unit tests. Needs no sudo, docker, GPU or network. Run: make check
# The linter step is skipped with a warning when shellcheck is not installed, unless CI=true or REQUIRE_SHELLCHECK=1 (then it fails).
# It fails only on error severity for now: the older scripts still carry warning/info findings (tracked separately).
# CI pins shellcheck v0.11.0 (see .github/workflows/check.yml); to match it locally without sudo:
#   uvx --from shellcheck-py==0.11.0.1 shellcheck -x <files>   (ships the same v0.11.0 binary)
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1
rc=0
step() { printf '\n== %s\n' "$*"; }
run()  { "$@" || { echo "FAILED: $*"; rc=1; }; }

# Shell scripts: every tracked *.sh plus the controller template.
mapfile -t SH < <(git ls-files '*.sh' 'scripts/setup/docker-gpu/aiw-llm-ctl.template')

step "bash -n (${#SH[@]} files)"
for f in "${SH[@]}"; do run bash -n "$f"; done

step "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  run shellcheck -x -P SCRIPTDIR -S error "${SH[@]}"
elif [[ ${CI:-} == true || ${REQUIRE_SHELLCHECK:-0} == 1 ]]; then
  echo "FAILED: shellcheck is required here but not installed"; rc=1
else
  echo "WARNING: shellcheck not installed, skipping (set REQUIRE_SHELLCHECK=1 to make this an error)"
fi

step "shell tests"
run env AIW_TEST_MODE=1 bash scripts/setup/docker-gpu/test-lib.sh
run env AIW_TEST_MODE=1 bash scripts/setup/docker-gpu/test-aiw-llm-ctl.sh

step "python tests (scripts/mcp)"
run python3 -I -m unittest discover -s scripts/mcp -p 'test_*.py'

echo
((rc == 0)) && echo "check: all passed" || echo "check: FAILED"
exit "$rc"
