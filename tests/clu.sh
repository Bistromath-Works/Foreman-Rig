#!/usr/bin/env bash
# Tests for scripts/clu. No model call: curl is a stand-in that returns a canned answer.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLU="$ROOT/scripts/clu"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; failn=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { failn=$((failn+1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$3', got '$2'"; fi; }

mkdir -p "$T/bin" "$T/proj/.foreman" "$T/out"
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
out=""; body=""
cat > "$CURL_DIR/config"; echo called >> "$CURL_DIR/calls"
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; --data-binary) body="${2#@}"; shift ;; esac; shift; done
cp "$body" "$CURL_DIR/body.json"
jq -n --rawfile a "$CURL_DIR/answer.json" '{choices:[{message:{content:$a}}]}' > "$out"; printf '%s' "$(cat "$CURL_DIR/status")"
SH
chmod +x "$T/bin/curl"; export CURL_DIR="$T"; echo 200 > "$T/status"
cp "$ROOT/tests/fixtures/habits.sample.jsonl" "$T/proj/.foreman/habits.jsonl"
audit() { PATH="$T/bin:$PATH" OPENROUTER_API_KEY=sk-test CLU_OUT="$T/out" "$CLU" audit "$T/proj" "$@" 2>&1; }
last() { jq -r "$1" "$(ls -t "$T"/out/*.json | head -1)"; }
OLD='   the job does not claim). Add what you did not test. Vague promises waste a round.'
answer() { # answer <file> <old> <new> <jobs json>
  jq -n --arg f "$1" --arg o "$2" --arg n "$3" --argjson j "$4" '{habits:[{habit:"The brief leaves out what was not tested.", about:"owner", jobs:$j}], checks:[],
    proposal:{file:$f, old_text:$o, new_text:$n, habit:"The brief leaves out what was not tested.", jobs:$j, reason:"It cost a round three times."}}' > "$T/answer.json"; }
J3='["fmn-20261101-0900","fmn-20261103-1400","fmn-20261108-1530"]'
before="$(git -C "$ROOT" status --porcelain)"

out="$("$CLU" rulebook 2>&1)" && ok "the rulebook is within its size cap" || bad "the rulebook is within its size cap" "$out"
[ "$(jq -r '.files | length' "$ROOT/rulebook.json")" -ge 9 ] && ok "the rulebook lists the instruction files" || bad "the rulebook lists the instruction files"
missing=""; for f in "$ROOT"/CULTURE.md "$ROOT"/qa/CULTURE.md "$ROOT"/agents/*/guidance/role.md; do jq -e --arg f "${f#"$ROOT"/}" '.files | index($f)' "$ROOT/rulebook.json" >/dev/null || missing="$missing ${f#"$ROOT"/}"; done
[ -z "$missing" ] && ok "every instruction file a seat is given is in the rulebook" || bad "every instruction file a seat is given is in the rulebook" "$missing"

[ "$(jq '[.must_keep[] | length] | add' "$ROOT/rulebook.json")" -ge 20 ] && "$CLU" rulebook 2>&1 | grep -q 'must-keep lines, all present' && ok "every must-keep line is in the rulebook" || bad "every must-keep line is in the rulebook" "$("$CLU" rulebook 2>&1 | tail -3)"
mkdir -p "$T/rb/scripts" "$T/rb/agents" "$T/rb/qa"; cp "$ROOT/scripts/clu" "$T/rb/scripts/"; cp "$ROOT/rulebook.json" "$ROOT/CULTURE.md" "$T/rb/"; cp -R "$ROOT/agents/." "$T/rb/agents/"; cp "$ROOT/qa/CULTURE.md" "$T/rb/qa/"
sed -i 's/\*\*You never approve your own work\.\*\*/You may approve your own work when sure./' "$T/rb/agents/owner/guidance/role.md"
out="$("$T/rb/scripts/clu" rulebook 2>&1)"; [ $? -ne 0 ] && [[ "$out" == *"lost a line it must keep"* && "$out" == *"You never approve your own work"* ]] && ok "rewording that loses a must-keep line fails, and names the line" || bad "rewording that loses a must-keep line fails, and names the line" "$out"
answer agents/owner/guidance/role.md "$OLD" '   the job does not claim). End with a "Not tested" list, or `none`. Vague promises waste a round.' "$J3"
out="$(audit)"; same "a habit seen in three jobs with an exact, same-size edit becomes a proposal" "$(last .status)" "proposed"
p="$(ls -t "$T"/out/*.patch | head -1)"; grep -q '^-   the job does not claim). Add what you did not test' "$p" && grep -q '^+.*Not tested' "$p" && ok "the proposal comes with a patch" || bad "the proposal comes with a patch" "$(cat "$p" 2>&1)"
[[ "$out" == *"Nothing was changed"* ]] && ok "the audit says it changed nothing" || bad "the audit says it changed nothing" "$out"
same "the request holds the lessons and the rulebook, and no evidence paths or numbers" "$(jq -r '.messages[1].content | [test("LESSONS LEDGER"), test("===== FILE: CULTURE.md ====="), (test("\"evidence\":") | not)] | map(tostring) | join(" ")' "$T/body.json")" "true true true"
! grep -q sk-test "$T/body.json" && grep -q sk-test "$T/config" && ok "the key travels in the request header, not the body" || bad "the key travels in the request header, not the body"

answer agents/owner/guidance/role.md "$OLD" "$OLD" '["fmn-20261101-0900","fmn-20261103-1400"]'
audit >/dev/null; same "a habit seen in only two jobs is rejected" "$(last '.status + ": " + (.problems[0] | test("needs 3") | tostring)')" "rejected: true"
answer agents/owner/guidance/role.md "$OLD" "$OLD" '["fmn-20261101-0900","fmn-20261103-1400","job-that-never-ran"]'
audit >/dev/null; same "a job that is not in the ledger does not count" "$(last .status)" "rejected"
answer agents/owner/guidance/role.md "a sentence that is not in the file at all" "anything" "$J3"
audit >/dev/null; same "old text that is not in the file is rejected" "$(last '.status + ": " + (.problems | join(";") | test("occurs 0") | tostring)')" "rejected: true"
answer agents/owner/guidance/role.md "the owner" "the lead" "$J3"
audit >/dev/null; same "old text that occurs more than once is rejected" "$(last '.problems | join(";") | test("exactly once")')" "true"
answer agents/owner/guidance/role.md "$OLD" "$OLD"$'\n   One more line of rule.' "$J3"
audit >/dev/null; same "an edit that makes the rulebook longer is rejected" "$(last '.problems | join(";") | test("may not grow")')" "true"
answer scripts/qa "$OLD" "$OLD" "$J3"
audit >/dev/null; same "an edit to a file outside the rulebook is rejected" "$(last '.problems | join(";") | test("not a rulebook file")')" "true"
answer agents/owner/guidance/role.md "$OLD" "$OLD" '["fmn-20261101-0900","fmn-20261103-1400",""]'
audit >/dev/null; same "a blank job id does not count as a third job" "$(last .status)" "rejected"
KEEP="$(jq -r '.must_keep["agents/owner/guidance/role.md"][0]' "$ROOT/rulebook.json")"
answer agents/owner/guidance/role.md "$KEEP" "Reworded so the line is gone." "$J3"
audit >/dev/null; same "a change that removes a must-keep line is rejected" "$(last '.status + ": " + (.problems | join(";") | test("must keep") | tostring)')" "rejected: true"
[ -z "$(ls "$T"/out/*.patch 2>/dev/null | sed 1d)" ] && ok "rejected proposals get no patch" || bad "rejected proposals get no patch" "$(ls "$T/out")"
echo '{"habits":[],"checks":[{"habit":"debug prints left in","check":"a lint rule"}],"proposal":null}' > "$T/answer.json"
audit >/dev/null; same "no recurring habit: no proposal, and the code-check suggestions are kept" "$(last '.status + " " + (.checks | length | tostring)')" "no proposal 1"
echo 'I think you should rewrite everything.' > "$T/answer.json"; n="$(ls "$T/out" | wc -l)"
out="$(audit)"; [ $? -ne 0 ] && [ "$(ls "$T/out" | wc -l)" = "$n" ] && ok "an answer that is not the JSON asked for writes nothing" || bad "an answer that is not the JSON asked for writes nothing" "$out"

cp "$T/proj/.foreman/habits.jsonl" "$T/keep.jsonl"; : > "$T/calls"
echo '{"at":"x","job":"fmn-20261110-0930","about":"owner","lesson":"The owner pasted api_key=k9Xw2LmQ7RtYp4VbN8sZc3Hd into the brief."}' >> "$T/proj/.foreman/habits.jsonl"
out="$(audit)"; [ $? -ne 0 ] && [[ "$out" == *"Nothing was sent"* ]] && [ ! -s "$T/calls" ] && ok "a ledger holding something that looks like a key is never sent" || bad "a ledger holding something that looks like a key is never sent" "$out"
cp "$T/keep.jsonl" "$T/proj/.foreman/habits.jsonl"
answer agents/owner/guidance/role.md "$OLD" '   the job does not claim). token: k9Xw2LmQ7RtYp4VbN8sZc3HdJ6fG waste a round.' "$J3"
audit >/dev/null; same "a proposed rule that holds something like a key is rejected" "$(last '.problems | join(";") | test("looks like a key")')" "true"
audit --model moonshotai/kimi-k3 >/dev/null; same "the model can be named, for the bake-off" "$(jq -r .model "$T/body.json") $(last .model)" "moonshotai/kimi-k3 moonshotai/kimi-k3"
# --- CF-22 review fixes ---
answer agents/owner/guidance/role.md "a sentence that is not in the file at all" "anything" '[]'; printf '\n{"proposal":null}\n' >> "$T/answer.json"; n="$(ls "$T/out" | wc -l)"
out="$(audit)"; [ $? -ne 0 ] && [ "$(ls "$T/out" | wc -l)" = "$n" ] && ok "two JSON objects in one answer are refused; nothing is written" || bad "two JSON objects in one answer are refused; nothing is written" "$out"
answer agents/owner/guidance/role.md "$OLD" '   the job does not claim). End with a "Not tested" list, or `none`. Vague promises waste a round.' '["fmn-20261101-0900","fmn-20261103-1400","fmn-20261108-1530","invented-job"]'
audit >/dev/null; same "a proposal that names a job not in the ledger is rejected, even with three real ones" "$(last '.status + ": " + (.problems | join(";") | test("invented-job") | tostring)')" "rejected: true"
answer agents/owner/guidance/role.md "$OLD" "$OLD"$'\n' "$J3"
audit >/dev/null; same "a trailing newline that would add a line to the file is rejected" "$(last '.status + ": " + (.problems | join(";") | test("more lines after") | tostring)')" "rejected: true"
answer agents/owner/guidance/role.md "$OLD" "$OLD" "$J3"
audit >/dev/null; same "a proposal that changes nothing is rejected" "$(last '.problems | join(";") | test("changes nothing")')" "true"
jq -n --arg f agents/owner/guidance/role.md --arg o "$OLD" '{habits:[{habit:"x", about:"owner", jobs:[{}]}], checks:[], proposal:{file:$f, old_text:$o, new_text:"y", habit:"h", jobs:[{}], reason:"r"}}' > "$T/answer.json"
out="$(audit)"; rc=$?; [ $rc -eq 0 ] && [ "$(last .status)" = rejected ] && ok "a proposal with malformed job entries is rejected without crashing the report" || bad "a proposal with malformed job entries is rejected without crashing the report" "rc=$rc $out"
cp "$T/proj/.foreman/habits.jsonl" "$T/keep.jsonl"
for key in 'sk_test_'"4eC39HqLyjWDarjtT1zdp7dc" 'xoxb-'"1234567890-abcdefghij" 'password = hunter2hunter2hunter2'; do
  cp "$T/keep.jsonl" "$T/proj/.foreman/habits.jsonl"; : > "$T/calls"
  jq -cn --arg l "The owner pasted $key into the brief by mistake." '{at:"x", job:"fmn-20261110-0930", about:"owner", lesson:$l}' >> "$T/proj/.foreman/habits.jsonl"
  out="$(audit)"; [ $? -ne 0 ] && [ ! -s "$T/calls" ] && ok "a ledger holding '${key%%[0-9=]*}...' is never sent" || bad "a ledger holding '${key%%[0-9=]*}...' is never sent" "$out"
done
cp "$T/keep.jsonl" "$T/proj/.foreman/habits.jsonl"; : > "$T/calls"
jq -cn '{at:"x", job:"fmn-20261110-0930", about:"checker", lesson:"The checker missed the pagination token: subsequent requests repeated the first page."}' >> "$T/proj/.foreman/habits.jsonl"
echo '{"habits":[],"checks":[],"proposal":null}' > "$T/answer.json"
out="$(audit)"; [ $? -eq 0 ] && [ -s "$T/calls" ] && ok "an ordinary lesson that uses the word token is not mistaken for a secret" || bad "an ordinary lesson that uses the word token is not mistaken for a secret" "$out"
cp "$T/keep.jsonl" "$T/proj/.foreman/habits.jsonl"; : > "$T/calls"
jq -cn '{at:"x", job:"fmn-20261110-0930", about:"owner", lesson:"The owner wrote password=\"TestPassword123456!\" into the brief."}' >> "$T/proj/.foreman/habits.jsonl"
out="$(audit)"; [ $? -ne 0 ] && [ ! -s "$T/calls" ] && ok "a quoted password inside a lesson is never sent" || bad "a quoted password inside a lesson is never sent" "$out"
cp "$T/keep.jsonl" "$T/proj/.foreman/habits.jsonl"
# two audits in the same second get two records, and a rejected one never shows another's patch
mkdir -p "$T/fakedate"; printf '#!/bin/sh\ncase "$*" in *%%Y%%m%%d-%%H%%M%%S*) echo 20261120-000000 ;; *) exec /usr/bin/date "$@" ;; esac\n' > "$T/fakedate/date"; chmod +x "$T/fakedate/date"
rm -f "$T"/out/*
answer agents/owner/guidance/role.md "$OLD" '   the job does not claim). End with a "Not tested" list, or `none`. Vague promises waste a round.' "$J3"
PATH="$T/fakedate:$T/bin:$PATH" OPENROUTER_API_KEY=sk-test CLU_OUT="$T/out" "$CLU" audit "$T/proj" >/dev/null 2>&1
answer agents/owner/guidance/role.md "not in the file" "x" "$J3"
out="$(PATH="$T/fakedate:$T/bin:$PATH" OPENROUTER_API_KEY=sk-test CLU_OUT="$T/out" "$CLU" audit "$T/proj" 2>&1)"
[ "$(ls "$T"/out/*.json | wc -l)" = 2 ] && [ "$(ls "$T"/out/*.patch | wc -l)" = 1 ] && [[ "$out" == *"REJECTED"* && "$out" != *"Nothing was changed. To take it"* ]] \
  && ok "two audits in the same second get their own records; a rejected one shows no patch" || bad "two audits in the same second get their own records; a rejected one shows no patch" "$(ls "$T/out"); $out"
rm -f "$T"/out/*; answer agents/owner/guidance/role.md "not in the file" "x" "$J3"
for i in 1 2 3 4; do PATH="$T/fakedate:$T/bin:$PATH" OPENROUTER_API_KEY=sk-test CLU_OUT="$T/out" "$CLU" audit "$T/proj" >/dev/null 2>&1 & done; wait
[ "$(ls "$T"/out/*.json | wc -l)" = 4 ] && [ "$(cat "$T"/out/*.json | jq -s 'length')" = 4 ] && ok "four audits started together in the same second each get their own whole record" || bad "audits started together" "$(ls -la "$T/out")"
same "an audit never changes a file in the repo" "$(git -C "$ROOT" status --porcelain)" "$before"
echo; echo "$pass passed, $failn failed"; [ "$failn" -eq 0 ]
