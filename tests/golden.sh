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
# A gate that crashes before it records anything must not be counted as a catch. The task's
# expectation is left alone; the gate itself is broken in a scratch copy.
rm -rf "$T/scripts" "$T/qa" "$T/golden"; mkdir -p "$T/scripts"; cp "$ROOT"/scripts/* "$T/scripts/"; cp -R "$ROOT/qa" "$T/qa"; cp -R "$ROOT/golden" "$T/golden"
sed -i 's/^gate_green() {$/gate_green() { return 1/' "$T/scripts/qa"
"$T/scripts/golden" --json "$T/broken.json" noop-fix >"$T/brokengate.txt" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'BROKEN: gate green gave no result' "$T/brokengate.txt" && [ "$(jq -r '.[0].caught_by' "$T/broken.json")" = "" ] \
  && ok "a gate that stops without recording a result is reported broken, not credited with a catch" || bad "a gate that stops without recording a result is reported broken, not credited with a catch" "$(cat "$T/brokengate.txt")"
# Asked for the screener and it cannot answer: the run is not as expected.
mkdir -p "$T/bin"; printf '#!/bin/sh\ncat >/dev/null\nwhile [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done\necho "{}" > "$out"; printf 503\n' > "$T/bin/curl"; chmod +x "$T/bin/curl"
PATH="$T/bin:$PATH" OPENROUTER_API_KEY=sk-test "$ROOT/scripts/golden" --screener rule-broken secret-added >"$T/noscreen.txt" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'screener did not answer' "$T/noscreen.txt" && ok "asked for the screener and it does not answer: the run fails" || bad "asked for the screener and it does not answer: the run fails" "$(cat "$T/noscreen.txt")"
# The screener sends a job back but the QA gate that should also catch it is broken: still a failure.
printf '#!/bin/sh\ncat >/dev/null\nwhile [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done\necho "{\\"answers\\":{\\"item_0\\":{\\"type\\":\\"noul\\",\\"noul\\":0.9},\\"item_1\\":{\\"type\\":\\"noul\\",\\"noul\\":0.02}}}" > "$out"; printf 200\n' > "$T/bin/curl"
cp "$ROOT/scripts/qa" "$T/scripts/qa"; sed -i 's/^gate_probe() {$/gate_probe() { record "$1" probe pass "forced"; return 0/' "$T/scripts/qa"
PATH="$T/bin:$PATH" OPENROUTER_API_KEY=sk-test "$T/scripts/golden" --screener --json "$T/sb.json" untouched-item >"$T/sb.txt" 2>&1; rc=$?
[ "$rc" -ne 0 ] && [ "$(jq -r '.[0] | (.screener_as_expected | tostring) + " " + (.qa_as_expected | tostring)' "$T/sb.json")" = "true false" ] \
  && ok "a screener send-back does not hide a QA gate that stopped catching the defect" || bad "a screener send-back does not hide a QA gate that stopped catching the defect" "$(cat "$T/sb.txt")"
echo; echo "$pass passed, $failn failed"; [ "$failn" -eq 0 ]
