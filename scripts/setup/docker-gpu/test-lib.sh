#!/usr/bin/env bash
# test-lib.sh - unit tests for the managed-file undo logic. Needs no root, touches no system files.
#   ./test-lib.sh        (exit 0 = all passed)
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
W=$(mktemp -d)
trap '[[ $W == "${TMPDIR:-/tmp}"/tmp.* ]] && rm -rf -- "$W"' EXIT   # only the mktemp dir created above
export AIW_TEST_MODE=1 AIW_STATE_DIR="$W/state"
# shellcheck source=lib.sh
source "$HERE/lib.sh"
info() { :; }   # quiet

pass=0; fail=0
t() { # description, then a command string that must succeed
  if eval "$2"; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1"; fi
}

echo "A) destination does not exist: install -> idempotent -> undo removes it"
printf 'new\n' >"$W/src"
D="$W/etc/a.conf"
managed_install T1 "$W/src" "$D" 0644
t "file created with content"          '[[ $(cat "$D") == new ]]'
t "created-marker recorded"            '[[ -e $(_created_path T1 "$D") ]]'
managed_install T1 "$W/src" "$D" 0644
t "second install leaves it unchanged" '[[ $(cat "$D") == new ]]'
t "no backup was invented"             '[[ ! -e $(_backup_path T1 "$D") ]]'
managed_restore T1 "$D"
t "undo removes the file we created"   '[[ ! -e $D ]]'
t "marker cleaned up"                  '[[ ! -e $(_created_path T1 "$D") ]]'
managed_restore T1 "$D"
t "undo twice is harmless"             '[[ ! -e $D ]]'

echo "B) destination exists with the user's content: backup once, restore exactly"
D="$W/etc/b.conf"; mkdir -p "$W/etc"; printf 'ORIGINAL\n' >"$D"; chmod 0640 "$D"
printf 'v1\n' >"$W/src"; managed_install T2 "$W/src" "$D" 0644
t "overwritten with v1"                '[[ $(cat "$D") == v1 ]]'
t "original backed up"                 '[[ $(cat "$(_backup_path T2 "$D")") == ORIGINAL ]]'
printf 'v2\n' >"$W/src"; managed_install T2 "$W/src" "$D" 0644
t "updated to v2"                      '[[ $(cat "$D") == v2 ]]'
t "backup still the ORIGINAL (not v1)" '[[ $(cat "$(_backup_path T2 "$D")") == ORIGINAL ]]'
managed_restore T2 "$D"
t "undo restores the original"         '[[ $(cat "$D") == ORIGINAL ]]'
t "original mode (640) restored"       '[[ $(stat -c %a "$D") == 640 ]]'
t "backup removed after restore"       '[[ ! -e $(_backup_path T2 "$D") ]]'

echo "C) destination already identical and not ours: never touched"
D="$W/etc/c.conf"; printf 'same\n' >"$D"; printf 'same\n' >"$W/src"
managed_install T3 "$W/src" "$D" 0644
t "no backup, no marker"               '[[ ! -e $(_backup_path T3 "$D") && ! -e $(_created_path T3 "$D") ]]'
managed_restore T3 "$D"
t "undo leaves a file that is not ours" '[[ $(cat "$D") == same ]]'

echo "D) track_original (used before an external tool edits a file)"
D="$W/etc/d.json"; printf '{"mine":1}\n' >"$D"
track_original T4 "$D"; printf '{"mine":1,"nvidia":2}\n' >"$D"   # simulate nvidia-ctk editing it
track_original T4 "$D"                                           # second call must NOT re-snapshot
managed_restore T4 "$D"
t "tool edit rolled back to the first snapshot" '[[ $(cat "$D") == "{\"mine\":1}" ]]'
D="$W/etc/e.json"; track_original T5 "$D"; printf '{}\n' >"$D"
managed_restore T5 "$D"
t "file created by external tool is removed"    '[[ ! -e $D ]]'

echo "E) write_key_envfile: mode-600 env file, and the key never reaches the xtrace file"
SECRET=s3cr3t-key-0123456789abcdef
E="$W/llama.env"; TR="$W/xtrace.out"
exec 8>"$TR"
( BASH_XTRACEFD=8; set -x; write_key_envfile "$E" SECRET; [[ $- == *x* ]] ) && traced_after=yes || traced_after=no
( BASH_XTRACEFD=8; set +x; write_key_envfile "$E" SECRET; [[ $- != *x* ]] ) && off_stays_off=yes || off_stays_off=no
exec 8>&-
t "file holds LLAMA_API_KEY=<key>"       '[[ $(cat "$E") == "LLAMA_API_KEY=$SECRET" ]]'
t "file mode is 600"                     '[[ $(stat -c %a "$E") == 600 ]]'
t "tracing restored when it was on"      '[[ $traced_after == yes ]]'
t "tracing stays off when it was off"    '[[ $off_stays_off == yes ]]'
t "trace shows the call, not the key"    'grep -q write_key_envfile "$TR" && ! grep -qF "$SECRET" "$TR"'

echo
echo "passed: $pass  failed: $fail"
((fail == 0))
