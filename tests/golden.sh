#!/usr/bin/env bash
# Tests for scripts/golden: the set runs with one command, gives the same score twice, and every
# task comes out the way its task.json says. No model call (the screener is not asked).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()  { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad() { failn=$((failn+1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }

"$ROOT/scripts/golden" --json "$T/a.json" >"$T/a.txt" 2>&1; rc=$?
[ "$rc" -eq 0 ] && ok "the whole set runs with one command and every task is as expected" || bad "the whole set runs with one command and every task is as expected" "$(tail -5 "$T/a.txt")"
"$ROOT/scripts/golden" --json "$T/b.json" >"$T/b.txt" 2>&1
cmp -s "$T/a.txt" "$T/b.txt" && ok "a second run prints exactly the same" || bad "a second run prints exactly the same" "$(diff "$T/a.txt" "$T/b.txt" | head -5)"
[ "$(jq -c '[.[] | [.task, .verdict, .caught_by]]' "$T/a.json")" = "$(jq -c '[.[] | [.task, .verdict, .caught_by]]' "$T/b.json")" ] \
  && ok "a second run records the same verdicts" || bad "a second run records the same verdicts"
grep -q '^score: caught 8 of 8 planted defects; 0 false alarms on 2 tasks the gates should pass$' "$T/a.txt" && ok "the score line is the known baseline" || bad "the score line is the known baseline" "$(grep '^score' "$T/a.txt")"
n="$(wc -l <"$ROOT/golden/order" | tr -d ' ')"
[ "$n" -ge 5 ] && [ "$n" -le 10 ] && [ "$(jq length "$T/a.json")" = "$n" ] && ok "five to ten tasks, all played ($n)" || bad "five to ten tasks, all played" "$n"
for d in "$ROOT"/golden/tasks/*/; do
  name="$(basename "$d")"
  { grep -qx "$name" "$ROOT/golden/order" && jq -e '.defect and .done_condition and (.expect.verdict | IN("pass","fail","narrowed","cannot_reproduce")) and (.expect.caught_by | type == "array")' "$d/task.json" >/dev/null \
      && [ -d "$d/base" ] && [ -d "$d/candidate" ] && [ -n "$(ls "$d/probe" 2>/dev/null)" ]; } \
    && ok "task $name is complete and listed" || bad "task $name is complete and listed"
done
[ "$(jq -r '[.[] | select(.expected.verdict == "pass")] | length' "$T/a.json")" -ge 1 ] && ok "the set has a clean control task" || bad "the set has a clean control task"
"$ROOT/scripts/golden" noop-fix >"$T/one.txt" 2>&1; grep -q 'caught 1 of 1' "$T/one.txt" && ok "one task can be run by name" || bad "one task can be run by name" "$(cat "$T/one.txt")"
# A gate that stops catching its defect makes the run fail: break a task's expectation and check.
cp -R "$ROOT/golden" "$T/golden"; mkdir -p "$T/scripts"; cp "$ROOT"/scripts/* "$T/scripts/"; cp -R "$ROOT/qa" "$T/qa"
jq '.expect.caught_by = ["suite"]' "$ROOT/golden/tasks/noop-fix/task.json" > "$T/golden/tasks/noop-fix/task.json"
"$T/scripts/golden" noop-fix >"$T/broken.txt" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'not as expected: noop-fix' "$T/broken.txt" && ok "a task that comes out differently fails the run and is named" || bad "a task that comes out differently fails the run and is named" "$(cat "$T/broken.txt")"
echo; echo "$pass passed, $failn failed"; [ "$failn" -eq 0 ]
