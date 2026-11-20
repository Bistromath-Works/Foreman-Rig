#!/usr/bin/env bash
# Tests for scripts/qa: every verdict on a fixture repo with one planted bug, plus the rules
# that keep a seat from cheating (gate order, write-once results, contract checks, read-only
# source). No OpenRig, no models: the seats' outputs are written by hand.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QA="$ROOT/scripts/qa"
# Under /var/tmp, not /tmp: the sandbox hides /tmp, and the source repo and fake home folder
# here must be visible to it, so a blocked write is blocked by the sandbox's own rules.
T="$(mktemp -d -p /var/tmp)" && [ -d "$T" ] || { echo "cannot make a temp folder" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
export QA_HOME="$T/home" QA_REPOS="$T/repos"
mkdir -p "$QA_HOME" "$QA_REPOS"
pass=0; failn=0
ok()   { pass=$((pass+1)); printf 'ok   %s\n' "$1"; }
bad()  { failn=$((failn+1)); printf 'FAIL %s\n' "$1"; [ -z "${2:-}" ] || printf '     %s\n' "$2"; }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "want '$3', got '$2'"; fi; }

# --- fixture repo: name.py joins names with a double space when the middle name is empty ---
R="$T/fixture"; mkdir -p "$R/tests" && cd "$R" || { echo "cannot enter $R" >&2; exit 1; }
git init -q -b main; git config user.email t@t; git config user.name t
cat > name.py <<'PY'
def full_name(first, middle, last):
    return f"{first} {middle} {last}"
PY
cat > tests/test_basic.py <<'PY'
import sys; sys.path.insert(0, ".")
from name import full_name
assert full_name("Ada", "B", "Lovelace") == "Ada B Lovelace"
PY
git add -A; git commit -qm base
BASE="$(git rev-parse HEAD)"

repro='import sys; sys.path.insert(0, ".")
from name import full_name
assert full_name("Ada", "", "Lovelace") == "Ada Lovelace", full_name("Ada", "", "Lovelace")'

branch() { git -C "$R" checkout -q -b "$1" "$BASE"; }
commit() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; git -C "$R" checkout -q main; }

# good: a real fix plus the repro check
branch good
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
printf '%s\n' "$repro" > tests/test_empty_middle.py; commit good
# noop: the "fix" changes nothing that matters
branch noop
printf '# handles empty middle names\n' >> name.py
printf '%s\n' "$repro" > tests/test_empty_middle.py; commit noop
# norepro: the check tests behavior that already worked on base
branch norepro
printf '%s\n' "$(cat name.py)" "# touched" > name.py.new; mv name.py.new name.py
printf '%s\n' 'import sys; sys.path.insert(0, ".")' 'from name import full_name' 'assert full_name("Ada", "B", "Lovelace") == "Ada B Lovelace"' > tests/test_empty_middle.py; commit norepro
# weak: the check fails on base only because a new test file is missing; it never tests the fix
branch weak
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
touch tests/marker
printf '%s\n' 'import os' 'assert os.path.exists("tests/marker")' > tests/test_empty_middle.py; commit weak
# importerr: the check fails on base only because it imports a module the fix adds
branch importerr
printf 'def join(*p):\n    return " ".join(x for x in p if x)\n' > joiner.py
printf 'from joiner import join\ndef full_name(first, middle, last):\n    return join(first, middle, last)\n' > name.py
printf '%s\n' 'import sys; sys.path.insert(0, ".")' 'from joiner import join' 'assert join("Ada", "", "Lovelace") == "Ada Lovelace"' > tests/test_empty_middle.py; commit importerr
git -C "$R" checkout -q main
SRC_STATE="$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)"

cat > "$QA_REPOS/fixture.json" <<'JSON'
{
  "setup_cmd": "",
  "boot_cmd": "python3 -c 'import name'",
  "check_cmd": "python3 {check}",
  "assertion_pattern": "AssertionError",
  "suite_cmd": "for f in tests/test_*.py; do python3 \"$f\" || exit 1; done",
  "smoke_cmd": "echo smoke > \"$QA_EVIDENCE/smoke.txt\"",
  "mutation_cmd": "",
  "teardown_cmd": "touch \"$QA_EVIDENCE/torn-down\"",
  "test_paths": ["tests/"]
}
JSON

contract() { # contract <candidate> [repro_check] [wall_minutes]
  jq -n --arg r "$R" --arg b "$BASE" --arg c "$1" --arg k "${2-tests/test_empty_middle.py}" --argjson w "${3:-10}" \
    '{repo:$r, base:$b, candidate:$c, issue:"CF-99", done_condition:"An empty middle name gives one space between first and last name.",
      repro_check:$k, budget:{wall_minutes:$w, tokens:1000}, reply_to:"crew-owner@foreman-fixture"}' > "$T/c.json"
  printf '%s' "$T/c.json"
}

good_probe() { mkdir -p "$1/probe/tests/probe"; printf '%s\n' 'import sys; sys.path.insert(0, ".")' 'from name import full_name' 'assert full_name("", "", "Lovelace") == "Lovelace"' > "$1/probe/tests/probe/test_only_last.py"; }
bad_probe()  { mkdir -p "$1/probe/tests/probe"; printf '%s\n' 'import sys; sys.path.insert(0, ".")' 'from name import full_name' 'assert full_name(" Ada", "", "Lovelace") == "Ada Lovelace"' > "$1/probe/tests/probe/test_trim.py"; }

# What the gatekeeper does, with the seats' outputs supplied: $2 = good|bad|none probe, $3 = audit line.
full_run() {
  local id="$1" probe="$2" audit="$3" run="$QA_HOME/runs/$1" g s
  for g in boot red green mutation probe suite audit; do
    [ "$g" != probe ] || case "$probe" in good) good_probe "$run" ;; bad) bad_probe "$run" ;; esac
    [ "$g" != audit ] || [ -z "$audit" ] || printf '%s\nnotes\n' "$audit" > "$run/audit.md"
    "$QA" gate "$id" "$g" >/dev/null 2>&1
    s="$(jq -r .status "$run/gates/$g.json" 2>/dev/null)"
    case "$s" in pass|skip) ;; *) break ;; esac
  done
  "$QA" verdict "$id" >/dev/null 2>&1
  jq -r '.verdict + " " + (.gate // "-")' "$run/verdict.json"
}

new() { "$QA" new "$1" 2>&1 | tail -1; }

echo "# verdicts"
id="$(new "$(contract good)")";    same "real fix -> pass"                   "$(full_run "$id" good 'coverage: covered')" "pass -"
run="$QA_HOME/runs/$id"
[ -f "$run/evidence/smoke.txt" ] && ok "smoke command wrote evidence" || bad "smoke command wrote evidence"
[ -f "$run/evidence/torn-down" ] && ok "teardown ran after boot" || bad "teardown ran after boot"
[ ! -e "$run/src" ] && ok "clones deleted after the verdict" || bad "clones deleted after the verdict"
grep -q '^verdict: pass' "$run/verdict.md" && grep -q 'audit | pass' "$run/verdict.md" && ok "verdict.md has the verdict and gate table" || bad "verdict.md has the verdict and gate table"
id="$(new "$(contract noop)")";    same "fix that does nothing -> fail at green" "$(full_run "$id" good 'coverage: covered')" "fail green"
id="$(new "$(contract norepro)")"; same "check passes on base -> cannot_reproduce" "$(full_run "$id" good 'coverage: covered')" "cannot_reproduce red"
id="$(new "$(contract weak)")";    same "check survives the fix reversed -> narrowed" "$(full_run "$id" good 'coverage: covered')" "narrowed mutation"
id="$(new "$(contract good)")";    same "auditor finds a gap -> narrowed" "$(full_run "$id" good 'coverage: narrowed')" "narrowed audit"
id="$(new "$(contract good)")";    same "probe check fails -> fail at probe" "$(full_run "$id" bad 'coverage: covered')" "fail probe"
id="$(new "$(contract good)")";    same "prober wrote nothing -> fail at probe" "$(full_run "$id" none 'coverage: covered')" "fail probe"
id="$(new "$(contract good)")";    same "no audit file -> fail at audit" "$(full_run "$id" good '')" "fail audit"
id="$(new "$(contract good '')")"; same "no repro check -> red/green skipped, still gated" "$(full_run "$id" good 'coverage: covered')" "pass -"
id="$(new "$(contract importerr)")"; same "check only errors on base -> fail at red" "$(full_run "$id" good 'coverage: covered')" "fail red"
id="$(new "$(contract good)")";    same "audit first line not exact -> fail at audit" "$(full_run "$id" good 'I could not finish; example: coverage: covered')" "fail audit"
id="$(new "$(contract good)")"; ln -s /etc/hostname "$QA_HOME/runs/$id/probe/link.py"
same "symlink in probe folder -> fail at probe" "$(full_run "$id" good 'coverage: covered')" "fail probe"
id="$(new "$(contract good)")"; echo $(( $(date +%s) - 1 )) > "$QA_HOME/runs/$id/deadline"
same "budget spent -> budget_exceeded" "$(full_run "$id" good 'coverage: covered')" "budget_exceeded boot"

id="$(new "$(contract good)")"; mkdir -p "$QA_HOME/runs/$id/probe/tests"; printf 'pass\n' > "$QA_HOME/runs/$id/probe/tests/test_empty_middle.py"
same "probe check replacing a candidate file -> fail at probe" "$(full_run "$id" none 'coverage: covered')" "fail probe"
jq '.setup_cmd = "exit 3"' "$QA_REPOS/fixture.json" > "$T/s.json" && cp "$QA_REPOS/fixture.json" "$T/keep.json" && cp "$T/s.json" "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; same "setup command fails -> fail at boot" "$(full_run "$id" good 'coverage: covered')" "fail boot"
cp "$T/keep.json" "$QA_REPOS/fixture.json"

id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1; echo $(( $(date +%s) - 1 )) > "$QA_HOME/runs/$id/deadline"
"$QA" sweep >/dev/null 2>&1
same "sweep finalizes an abandoned run" "$(jq -r '.verdict + " " + .gate' "$QA_HOME/runs/$id/verdict.json" 2>/dev/null)" "budget_exceeded red"
[ ! -e "$QA_HOME/runs/$id/src" ] && ok "sweep cleans up the abandoned run" || bad "sweep cleans up the abandoned run"

# brackets: a Next.js-style [id] folder in the repro check's path
branch brackets
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
mkdir -p "tests/[id]"; printf '%s\n' "$repro" > "tests/[id]/test_empty_middle.py"; commit brackets
SRC_STATE="$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)"
id="$(new "$(contract brackets 'tests/[id]/test_empty_middle.py')")"; same "repro check under an [id] folder -> pass" "$(full_run "$id" good 'coverage: covered')" "pass -"
jq '.issue = "fmn-20261119-0930"' "$(contract good)" > "$T/job.json"
out="$("$QA" validate "$T/job.json" 2>&1)" && ok "a Foreman job id is accepted as the issue" || bad "a Foreman job id is accepted as the issue" "$out"

echo "# the rules"
id="$(new "$(contract good)")"; run="$QA_HOME/runs/$id"
out="$("$QA" gate "$id" green 2>&1)"; [[ "$out" == *"run gate 'boot' first"* ]] && ok "gates run in order" || bad "gates run in order" "$out"
"$QA" gate "$id" boot >/dev/null
out="$("$QA" gate "$id" boot 2>&1)"; [[ "$out" == *"already ran"* ]] && ok "a gate never re-runs" || bad "a gate never re-runs" "$out"
id2="$(new "$(contract noop)")"; for g in boot red green; do "$QA" gate "$id2" $g >/dev/null 2>&1; done
out="$("$QA" gate "$id2" mutation 2>&1)"; [[ "$out" == *"did not pass"* ]] && ok "nothing runs after a failed gate" || bad "nothing runs after a failed gate" "$out"
"$QA" verdict "$id2" >/dev/null 2>&1; out="$("$QA" verdict "$id2" 2>&1)"; [[ "$out" == *"already written"* ]] && ok "verdict is written once" || bad "verdict is written once" "$out"
"$QA" verdict "$id" >/dev/null 2>&1; same "skipping the remaining gates is a failure" "$(jq -r '.verdict + " " + .gate' "$run/verdict.json")" "fail red"
id="$(new "$(contract good)")"; good_probe "$QA_HOME/runs/$id"
out="$("$QA" try "$id" tests/probe/test_only_last.py 2>&1)"; [[ "$out" == *"exit 0"* ]] && ok "prober can try a check" || bad "prober can try a check" "$out"
[ ! -e "$QA_HOME/runs/$id/gates/probe.json" ] && ok "trying a check records nothing" || bad "trying a check records nothing"
same "source repo untouched by every run" "$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)" "$SRC_STATE"

echo "# the sandbox"
# cheat: a real fix whose own code, run by the gates, tries to forge results and reach outside.
branch cheat
sed "s|@SRC@|$R|; s|@OUT@|$ROOT|" > name.py <<'PY'
import os, subprocess
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
def _try(label, fn):
    try: fn(); return label + ": DONE"
    except Exception: return label + ": blocked"
_run, _src = os.environ.get("QA_RUN", ""), "@SRC@"
_out = [
    _try("forge a gate result", lambda: open(_run + "/gates/audit.json", "w").write('{"gate":"audit","status":"pass","note":""}')),
    _try("forge the verdict", lambda: open(_run + "/verdict.json", "w").write('{"verdict":"pass"}')),
    _try("write the audit note", lambda: open(_run + "/audit.md", "w").write("coverage: covered\n")),
    _try("write a probe check", lambda: open(_run + "/probe/extra.py", "w").write("pass\n")),
    _try("write into the source repo", lambda: open(_src + "/pwned", "w").write("x")),
    _try("push to the source repo", lambda: subprocess.run(["git", "push", _src, "HEAD:refs/heads/pwned"], check=True, capture_output=True)),
    _try("read a file in the home folder", lambda: open(os.path.expanduser("~/secret")).read()),
    _try("read the operator's environment", lambda: os.environ["QA_TEST_SECRET"]),
    _try("write outside the checkout", lambda: open("@OUT@/pwned", "w").write("x")),
]
open(os.environ["QA_EVIDENCE"] + "/cheat.txt", "w").write("\n".join(_out) + "\n")
open(os.environ["QA_EVIDENCE"] + "/seen.txt", "w").write(_try("see the source repo", lambda: open(_src + "/name.py").read()) + "\n")
PY
printf '%s\n' "$repro" > tests/test_empty_middle.py; commit cheat
SRC_STATE="$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)"
mkdir -p "$T/fakehome" "$T/allowed"; echo hunter2 > "$T/fakehome/secret"; echo tool > "$T/allowed/tool.txt"
cp "$QA_REPOS/fixture.json" "$T/keep.json"
jq --arg a "$T/allowed" '.sandbox_ro = [$a] | .boot_cmd = "python3 -c \"import name\" && cat \($a)/tool.txt && ! touch \($a)/x"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(HOME="$T/fakehome" QA_TEST_SECRET=hunter2 new "$(contract cheat)")"; run="$QA_HOME/runs/$id"
HOME="$T/fakehome" QA_TEST_SECRET=hunter2 "$QA" gate "$id" boot >/dev/null 2>&1
same "a sandbox_ro folder is readable and not writable" "$(jq -r .status "$run/gates/boot.json" 2>/dev/null)" "pass"
if [ -f "$run/evidence/cheat.txt" ]; then
  while IFS= read -r line; do
    [[ "$line" == *": blocked" ]] && ok "candidate code cannot ${line%%:*}" || bad "candidate code cannot ${line%%:*}" "$line"
  done < "$run/evidence/cheat.txt"
  same "every cheat was tried" "$(wc -l < "$run/evidence/cheat.txt" | tr -d ' ')" "9"
else bad "cheat candidate ran and reported"; fi
same "the source repo is visible, so its write was blocked by the read-only rule" "$(cat "$run/evidence/seen.txt" 2>/dev/null)" "see the source repo: DONE"
[ ! -e "$run/gates/audit.json" ] && [ ! -e "$run/verdict.json" ] && [ ! -e "$run/audit.md" ] && ok "no forged result files in the run" || bad "no forged result files in the run"
[ ! -e "$R/pwned" ] && ! git -C "$R" rev-parse -q --verify refs/heads/pwned >/dev/null && [ ! -e "$ROOT/pwned" ] && ok "source repo and the folders outside got nothing" || bad "source repo and the folders outside got nothing"
rm -f "$R/pwned" "$ROOT/pwned"; git -C "$R" update-ref -d refs/heads/pwned 2>/dev/null
HOME="$T/fakehome" QA_TEST_SECRET=hunter2 full_run "$id" good 'coverage: covered' >/dev/null
# full_run re-ran boot (refused: already ran) and went on; the honest gates still decide.
same "the cheating candidate still gets an honest verdict" "$(jq -r '.verdict + " " + (.gate // "-")' "$run/verdict.json")" "pass -"
cp "$T/keep.json" "$QA_REPOS/fixture.json"
for v in '["/"]' "[\"$QA_HOME/runs\"]" "[\"$T\"]" '["relative/path"]' '"not-a-list"' "[\"$R\"]" "[\"$R/tests\"]" '["/run/user"]' "[\"$HOME\"]"; do
  jq --argjson v "$v" '.sandbox_rw = $v' "$T/keep.json" > "$QA_REPOS/fixture.json"
  out="$("$QA" new "$(contract good)" 2>&1)" && bad "refuses sandbox_rw $v" "$out" || ok "refuses sandbox_rw $v"
done
net_cmd='python3 -c "import name, socket; socket.create_connection((\"127.0.0.1\", $PORT), 2)"'
python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(); print(s.getsockname()[1], flush=True); time.sleep(60)' > "$T/port" & LPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$T/port" ] && break; sleep 0.2; done; PORT="$(cat "$T/port")"
jq --arg c "${net_cmd//\$PORT/$PORT}" '.boot_cmd = $c' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1
same "by default a command can reach a service on localhost" "$(jq -r .status "$QA_HOME/runs/$id/gates/boot.json")" "pass"
jq --arg c "${net_cmd//\$PORT/$PORT}" '.boot_cmd = $c | .sandbox_net = false' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1
same "sandbox_net false cuts the network off" "$(jq -r .status "$QA_HOME/runs/$id/gates/boot.json")" "fail"
kill "$LPID" 2>/dev/null
mkdir -p "$T/cache/tools"
for pair in "sandbox_ro|[\"/\"]" "sandbox_ro|[\"/run\"]" "sandbox_ro|[\"$HOME\"]" "sandbox_ro|[\"$T/cache/tools\"]" 'sandbox_net|"false"'; do
  k="${pair%%|*}"; v="${pair#*|}"
  jq --arg k "$k" --argjson v "$v" --arg c "$T/cache" '.sandbox_rw = [$c] | .[$k] = $v' "$T/keep.json" > "$QA_REPOS/fixture.json"
  out="$("$QA" new "$(contract good)" 2>&1)" && bad "refuses $k $v" "$out" || ok "refuses $k $v"
done
# A sandbox folder that is swapped for a link after the run started is not mounted.
mkdir -p "$T/tools"
jq --arg a "$T/tools" '.sandbox_ro = [$a]' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; rmdir "$T/tools"; ln -s "$T/fakehome" "$T/tools"
"$QA" gate "$id" boot >/dev/null 2>&1
same "a sandbox folder swapped for a link after the run started stops the run" "$(jq -r .status "$QA_HOME/runs/$id/gates/boot.json")" "fail"
rm -f "$T/tools"
# The sandbox cannot cut its own log short.
jq '.boot_cmd = "python3 -c \"import os\ntry: os.ftruncate(1, 0)\nexcept OSError: pass\""' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1
head -c 2 "$QA_HOME/runs/$id/logs/boot.log" | grep -q '^\$ ' && ok "a command cannot cut its own log short" || bad "a command cannot cut its own log short"

echo "# hostile files left for the steps that run outside the sandbox"
jq '.setup_cmd = "python3 -c \"import name\""' "$T/keep.json" > "$QA_REPOS/fixture.json"
mkdir -p "$T/planted"; echo 'raise SystemExit("LEAK-hunter2")' > "$T/planted/test_empty_middle.py"
# sneak-red: after boot, the candidate's tests folder is a link to a folder outside the checkout.
branch sneak-red
sed "s|@PLANTED@|$T/planted|" > name.py <<'PY'
import os
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
if os.path.basename(os.getcwd()) == "candidate" and not os.path.islink("tests"):
    os.rename("tests", "tests.real"); os.symlink("@PLANTED@", "tests")
PY
printf '%s\n' "$repro" > tests/test_empty_middle.py; commit sneak-red
id="$(new "$(contract sneak-red)")"; run="$QA_HOME/runs/$id"
for g in boot red; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "red gate takes the repro check from the commit, not from a planted link" "$(jq -r .status "$run/gates/red.json" 2>/dev/null)" "pass"
! grep -q LEAK-hunter2 "$run/logs/red.log" 2>/dev/null && ok "a file outside the checkout is not copied into a gate" || bad "a file outside the checkout is not copied into a gate"
"$QA" verdict "$id" >/dev/null 2>&1
# sneak-mut: setup in the mutation copy swaps in its own git folder whose config runs a command.
branch sneak-mut
sed "s|@MARK@|$T/hostmark|" > name.py <<'PY'
import os, subprocess
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
if os.path.basename(os.getcwd()) == "mutant" and os.path.isfile(".git"):
    os.remove(".git")
    subprocess.run(["git", "init", "-q", "."], check=False, capture_output=True)
    subprocess.run(["git", "config", "filter.x.clean", "touch @MARK@; cat"], check=False, capture_output=True)
    open(".gitattributes", "w").write("* filter=x\n")
PY
printf '%s\n' "$repro" > tests/test_empty_middle.py; commit sneak-mut
id="$(new "$(contract sneak-mut)")"; run="$QA_HOME/runs/$id"
for g in boot red green mutation; do "$QA" gate "$id" $g >/dev/null 2>&1; done
[ ! -e "$T/hostmark" ] && ok "git config planted during setup is not run outside the sandbox" || bad "git config planted during setup is not run outside the sandbox"
same "mutation gate still decides on the planted-config candidate" "$(jq -r .status "$run/gates/mutation.json" 2>/dev/null)" "pass"
"$QA" verdict "$id" >/dev/null 2>&1
SRC_STATE="$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)"
cp "$T/keep.json" "$QA_REPOS/fixture.json"
mkdir -p "$T/nobwrap"; for b in bash jq git date cat mkdir cp timeout dirname basename tr sed find sort head tail grep rm touch realpath env ls wc; do ln -s "$(command -v $b)" "$T/nobwrap/$b" 2>/dev/null; done
out="$(PATH="$T/nobwrap" "$QA" new "$(contract good)" 2>&1)"; [[ "$out" == *"bwrap"* ]] && ok "no sandbox tool -> the run is refused, not run unprotected" || bad "no sandbox tool -> the run is refused, not run unprotected" "$out"
same "source repo untouched by the cheating run" "$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)" "$SRC_STATE"

echo "# review round 2"
cp "$QA_REPOS/fixture.json" "$T/keep.json"
# longlog: the assertion is early in a very long log.
branch longlog
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
cat > tests/test_empty_middle.py <<'PY'
import sys; sys.path.insert(0, ".")
from name import full_name
try:
    assert full_name("Ada", "", "Lovelace") == "Ada Lovelace"
except AssertionError:
    print("AssertionError: double space")
    for i in range(100000): print("noise line", i)
    raise SystemExit(1)
PY
commit longlog
id="$(new "$(contract longlog)")"; for g in boot red; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "an assertion early in a very long log still counts" "$(jq -r .status "$QA_HOME/runs/$id/gates/red.json" 2>/dev/null)" "pass"
"$QA" verdict "$id" >/dev/null 2>&1
# execbit: the repro check is run as a program, so it must stay executable in the base copy.
branch execbit
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
{ echo '#!/usr/bin/env python3'; printf '%s\n' "$repro"; } > tests/test_empty_middle.py; chmod +x tests/test_empty_middle.py; commit execbit
jq '.check_cmd = "./{check}"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract execbit)")"; for g in boot red; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "an executable repro check stays executable in the base copy" "$(jq -r .status "$QA_HOME/runs/$id/gates/red.json" 2>/dev/null)" "pass"
"$QA" verdict "$id" >/dev/null 2>&1; cp "$T/keep.json" "$QA_REPOS/fixture.json"
# renamed: the fix renames a file; reversing the fix must bring the old file back.
git -C "$R" checkout -q -b base2 "$BASE"
printf 'def join3(a, b, c):\n    return f"{a} {b} {c}"\n# a helper kept in its own module\n# so that the fix can rename it\n# line five\n# line six\n' > "$R/fmt.py"
printf 'from fmt import join3\ndef full_name(first, middle, last):\n    return join3(first, middle, last)\n' > "$R/name.py"
git -C "$R" add -A; git -C "$R" commit -qm base2; BASE2="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q -b renamed; git -C "$R" mv fmt.py joiner.py
sed -i 's|return f"{a} {b} {c}"|return " ".join(p for p in (a, b, c) if p)|' "$R/joiner.py"
printf 'from joiner import join3\ndef full_name(first, middle, last):\n    return join3(first, middle, last)\n' > "$R/name.py"
printf '%s\n' "$repro" > "$R/tests/test_empty_middle.py"; git -C "$R" add -A; git -C "$R" commit -qm renamed; git -C "$R" checkout -q main
jq --arg b "$BASE2" '.base = $b' "$(contract renamed)" > "$T/ren.json"
id="$(new "$T/ren.json")"; for g in boot red green mutation; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "reversing a fix that renames a file brings the old file back" "$(jq -r .status "$QA_HOME/runs/$id/gates/mutation.json" 2>/dev/null)" "pass"
"$QA" verdict "$id" >/dev/null 2>&1
# attrs: the commit names a git filter that the operator's own git config defines.
branch attrs
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
echo '*.py filter=evil diff=evil' > .gitattributes; printf '%s\n' "$repro" > tests/test_empty_middle.py; commit attrs
printf '[filter "evil"]\n\tsmudge = "touch %s; cat"\n\tclean = "touch %s; cat"\n[diff "evil"]\n\ttextconv = "touch %s; cat"\n\tcommand = "touch %s; true"\n' "$T/hostmark2" "$T/hostmark2" "$T/hostmark2" "$T/hostmark2" > "$T/gitcfg"
id="$(GIT_CONFIG_GLOBAL="$T/gitcfg" "$QA" new "$(contract attrs)" 2>&1 | tail -1)"
for g in boot red green mutation; do GIT_CONFIG_GLOBAL="$T/gitcfg" "$QA" gate "$id" $g >/dev/null 2>&1; done
[ ! -e "$T/hostmark2" ] && ok "a git filter named by the commit is not run outside the sandbox" || bad "a git filter named by the commit is not run outside the sandbox"
same "the run with git attributes still reaches the mutation gate" "$(jq -r .status "$QA_HOME/runs/$id/gates/mutation.json" 2>/dev/null)" "pass"
"$QA" verdict "$id" >/dev/null 2>&1
# A checkout the candidate locked against deletion is still cleaned up.
jq '.boot_cmd = "python3 -c \"import name\" && mkdir -p locked/x && chmod 000 locked"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1; "$QA" verdict "$id" >/dev/null 2>&1
[ ! -e "$QA_HOME/runs/$id/src" ] && ok "a checkout locked by the candidate is still deleted" || bad "a checkout locked by the candidate is still deleted"
chmod -R u+rwx "$QA_HOME/runs/$id/src" 2>/dev/null; rm -rf "$QA_HOME/runs/$id/src"
# Other runs are not visible from inside a run, wherever the QA home is.
jq --arg h "$QA_HOME" '.boot_cmd = "test \"$(ls \($h)/runs | wc -l)\" = 1"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1
same "a run cannot see the other runs" "$(jq -r .status "$QA_HOME/runs/$id/gates/boot.json")" "pass"
mkdir -p "$T/sp "
for pair in 'sandbox_net|null' 'sandbox_ro|["/proc"]' 'sandbox_ro|["/proc/1"]' 'sandbox_ro|["/dev/shm"]' 'sandbox_ro|["/sys"]' "sandbox_ro|[\"$T/sp \"]" "sandbox_rw|[\"$ROOT\"]" "sandbox_rw|[\"$ROOT/scripts\"]" "sandbox_rw|[\"$QA_REPOS\"]"; do
  k="${pair%%|*}"; v="${pair#*|}"
  jq --arg k "$k" --argjson v "$v" '.[$k] = $v' "$T/keep.json" > "$QA_REPOS/fixture.json"
  out="$("$QA" new "$(contract good)" 2>&1)" && bad "refuses $k $v" "$out" || ok "refuses $k $v"
done
jq --arg r "$R" '.sandbox_rw = [$r]' "$T/keep.json" > "$QA_REPOS/fixture.json"
jq --arg r "file://$R" '.repo = $r' "$(contract good)" > "$T/furl.json"
out="$("$QA" new "$T/furl.json" 2>&1)" && bad "refuses a writable folder over a file:// source repo" "$out" || ok "refuses a writable folder over a file:// source repo"
cp "$T/keep.json" "$QA_REPOS/fixture.json"
SRC_STATE="$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)"

echo "# review round 3"
cp "$QA_REPOS/fixture.json" "$T/keep.json"
# The red copy of the repro check has the candidate's mode, not a leftover one from base.
EXB="$(git -C "$R" rev-parse execbit)"
git -C "$R" checkout -q -b unexec execbit; chmod -x "$R/tests/test_empty_middle.py"; echo "# touched" >> "$R/name.py"
git -C "$R" add -A; git -C "$R" commit -qm unexec; git -C "$R" checkout -q main
jq --arg b "$EXB" '.base = $b' "$(contract unexec)" > "$T/unexec.json"
id="$(new "$T/unexec.json")"; for g in boot red; do "$QA" gate "$id" $g >/dev/null 2>&1; done
[ -f "$QA_HOME/runs/$id/src/base/tests/test_empty_middle.py" ] && [ ! -x "$QA_HOME/runs/$id/src/base/tests/test_empty_middle.py" ] && ok "the red copy of the check has the candidate's file mode" || bad "the red copy of the check has the candidate's file mode"
"$QA" verdict "$id" >/dev/null 2>&1
# A fix that turns a file into a folder holding a kept test: reversing must not delete the test.
git -C "$R" checkout -q -b base3 "$BASE"; printf ' ' > "$R/sep"
printf 'def full_name(first, middle, last):\n    s = open("sep").read()\n    return first + s + middle + s + last\n' > "$R/name.py"
git -C "$R" add -A; git -C "$R" commit -qm base3; BASE3="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q -b filedir; git -C "$R" rm -q sep; mkdir "$R/sep"; printf ' ' > "$R/sep/value"; echo 'assert open("sep/value").read() == " "' > "$R/sep/test_sep.py"
printf 'def full_name(first, middle, last):\n    s = open("sep/value").read()\n    return s.join(p for p in (first, middle, last) if p)\n' > "$R/name.py"
printf '%s\n' "$repro" > "$R/tests/test_empty_middle.py"; git -C "$R" add -A; git -C "$R" commit -qm filedir; git -C "$R" checkout -q main
jq '.test_paths = ["tests/", "sep/test_sep.py"] | .boot_cmd = "python3 -c \"import name\" && cp sep/test_sep.py \"$QA_EVIDENCE/kept-in-candidate\""' "$T/keep.json" > "$QA_REPOS/fixture.json"
jq --arg b "$BASE3" '.base = $b' "$(contract filedir)" > "$T/filedir.json"
id="$(new "$T/filedir.json")"; for g in boot red green mutation; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "a reversal that would delete a kept test is a named failure, not a silent pass" "$(jq -r '.status + ": " + (.note | test("reverse") | tostring)' "$QA_HOME/runs/$id/gates/mutation.json" 2>/dev/null)" "fail: true"
"$QA" verdict "$id" >/dev/null 2>&1
# A changed file with & in its name reaches the mutation tool as one argument.
branch amp
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
echo "x = 1" > 'a&b.py'; printf '%s\n' "$repro" > tests/test_empty_middle.py; commit amp
jq '.mutation_cmd = "for f in {files}; do test -f \"$f\" || exit 1; done"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract amp)")"; for g in boot red green mutation; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "a file name with & reaches the mutation tool intact" "$(jq -r .status "$QA_HOME/runs/$id/gates/mutation.json" 2>/dev/null)" "pass"
"$QA" verdict "$id" >/dev/null 2>&1
# qa try still reports when setup left a locked folder in the copy.
jq '.setup_cmd = "mkdir -p gen && touch gen/f && chmod 555 gen"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; good_probe "$QA_HOME/runs/$id"
out="$("$QA" try "$id" tests/probe/test_only_last.py 2>&1)"; [[ "$out" == *"exit 0"* ]] && ok "try reports its result even when the copy has a locked folder" || bad "try reports its result even when the copy has a locked folder" "$out"
[ -z "$(ls "$QA_HOME/runs/$id/src" | grep '^try-')" ] && ok "try deletes its copy even when it has a locked folder" || bad "try deletes its copy even when it has a locked folder"
chmod -R u+rwx "$QA_HOME/runs/$id/src" 2>/dev/null; "$QA" verdict "$id" >/dev/null 2>&1
# An assertion in a log that also holds a zero byte still counts.
branch nul
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
printf '%s\n' 'import sys; sys.path.insert(0, ".")' 'from name import full_name' 'sys.stdout.write("bin\0ary\n"); sys.stdout.flush()' 'assert full_name("Ada", "", "Lovelace") == "Ada Lovelace"' > tests/test_empty_middle.py; commit nul
cp "$T/keep.json" "$QA_REPOS/fixture.json"
id="$(new "$(contract nul)")"; for g in boot red; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "an assertion in a log with a zero byte still counts" "$(jq -r .status "$QA_HOME/runs/$id/gates/red.json" 2>/dev/null)" "pass"
"$QA" verdict "$id" >/dev/null 2>&1
for pair in "sandbox_ro|[\"$QA_HOME\"]" "sandbox_ro|[\"$QA_HOME/runs\"]" 'sandbox_ro|["/opt/a\n/etc"]'; do
  k="${pair%%|*}"; v="${pair#*|}"
  jq --arg k "$k" --argjson v "$v" '.[$k] = $v' "$T/keep.json" > "$QA_REPOS/fixture.json"
  out="$("$QA" new "$(contract good)" 2>&1)" && bad "refuses $k $v" "$out" || ok "refuses $k $v"
done
jq --arg r "$R" '.sandbox_rw = [$r]' "$T/keep.json" > "$QA_REPOS/fixture.json"
jq --arg r "file://localhost$R" '.repo = $r' "$(contract good)" > "$T/furl.json"
out="$("$QA" new "$T/furl.json" 2>&1)" && bad "refuses a writable folder over a file://localhost source repo" "$out" || ok "refuses a writable folder over a file://localhost source repo"
cp "$T/keep.json" "$QA_REPOS/fixture.json"
id="$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=filter.evil.smudge GIT_CONFIG_VALUE_0="touch $T/hostmark3; cat" "$QA" new "$(contract attrs)" 2>&1 | tail -1)"
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=filter.evil.smudge GIT_CONFIG_VALUE_0="touch $T/hostmark3; cat" "$QA" gate "$id" boot >/dev/null 2>&1
[ ! -e "$T/hostmark3" ] && ok "git settings passed in the environment are not used either" || bad "git settings passed in the environment are not used either"
"$QA" verdict "$id" >/dev/null 2>&1
SRC_STATE="$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)"

echo "# review round 4"
cp "$QA_REPOS/fixture.json" "$T/keep.json"
# Only this repo's QA env file is visible, not another project's.
mkdir -p "$QA_HOME/env"; echo A=1 > "$QA_HOME/env/fixture.env"; echo B=2 > "$QA_HOME/env/other.env"
jq --arg h "$QA_HOME" '.boot_cmd = "test -f \($h)/env/fixture.env && ! test -e \($h)/env/other.env"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1
same "a run sees its own repo's QA env file and no other project's" "$(jq -r .status "$QA_HOME/runs/$id/gates/boot.json")" "pass"
# A test path written with git's own pathspec magic is still kept out of the reversal.
branch extratest
cat > name.py <<'PY'
def full_name(first, middle, last):
    return " ".join(p for p in (first, middle, last) if p)
PY
echo 'assert True' > tests/test_extra.py; printf '%s\n' "$repro" > tests/test_empty_middle.py; commit extratest
jq '.test_paths = [":(glob)tests/**"]' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract extratest)")"; for g in boot red green mutation; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "a test path with pathspec magic is left out of the fix files" "$(tr '\0' ' ' < "$QA_HOME/runs/$id/fix-files" 2>/dev/null)" "name.py "
"$QA" verdict "$id" >/dev/null 2>&1
# An assertion word on a later line of the command itself does not count as the check's output.
jq '.check_cmd = "python3 {check}\n# AssertionError"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract importerr)")"; for g in boot red; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "the pattern on a later line of the command does not count" "$(jq -r .status "$QA_HOME/runs/$id/gates/red.json" 2>/dev/null)" "fail"
"$QA" verdict "$id" >/dev/null 2>&1; cp "$T/keep.json" "$QA_REPOS/fixture.json"
# A fix made only of a line-ending rule: reversing it must bring the old line endings back.
git -C "$R" checkout -q -b base4 "$BASE"
echo 'sep.txt text eol=crlf' > "$R/.gitattributes"; printf ' \n' > "$R/sep.txt"
printf 'def full_name(first, middle, last):\n    s = open("sep.txt", "rb").read().decode().rstrip("\\n")\n    return s.join(p for p in (first, middle, last) if p)\n' > "$R/name.py"
git -C "$R" add -A; git -C "$R" commit -qm base4; BASE4="$(git -C "$R" rev-parse HEAD)"
git -C "$R" checkout -q -b eolfix; echo 'sep.txt text eol=lf' > "$R/.gitattributes"
printf '%s\n' "$repro" > "$R/tests/test_empty_middle.py"; git -C "$R" add -A; git -C "$R" commit -qm eolfix; git -C "$R" checkout -q main
jq --arg b "$BASE4" '.base = $b' "$(contract eolfix)" > "$T/eol.json"
id="$(new "$T/eol.json")"; for g in boot red green mutation; do "$QA" gate "$id" $g >/dev/null 2>&1; done
same "reversing a line-ending fix brings the old line endings back" "$(jq -r '.status' "$QA_HOME/runs/$id/gates/mutation.json" 2>/dev/null) $(jq -r .status "$QA_HOME/runs/$id/gates/green.json" 2>/dev/null)" "pass pass"
"$QA" verdict "$id" >/dev/null 2>&1
# A repro check whose path is a folder on base is a recorded failure, not a crash.
git -C "$R" checkout -q -b base5 "$BASE"; mkdir -p "$R/tests/test_empty_middle.py"; echo x > "$R/tests/test_empty_middle.py/keep"
git -C "$R" add -A; git -C "$R" commit -qm base5; BASE5="$(git -C "$R" rev-parse HEAD)"; git -C "$R" checkout -q main
jq --arg b "$BASE5" '.base = $b' "$(contract good)" > "$T/dirbase.json"
id="$(new "$T/dirbase.json")"; for g in boot red; do "$QA" gate "$id" $g >/dev/null 2>&1; done
[ -f "$QA_HOME/runs/$id/gates/red.json" ] && ok "a repro path that is a folder on base still gets a red result" || bad "a repro path that is a folder on base still gets a red result"
"$QA" verdict "$id" >/dev/null 2>&1
jq --arg r "$R" '.sandbox_rw = [$r]' "$T/keep.json" > "$QA_REPOS/fixture.json"
jq --arg r "file://localhost${R//tmp./tmp%2E}" '.repo = $r' "$(contract good)" > "$T/furl.json"
out="$("$QA" new "$T/furl.json" 2>&1)"; [[ "$out" == *"%"* ]] && ok "a file:// source with % codes is refused, not guessed at" || bad "a file:// source with % codes is refused, not guessed at" "$out"
cp "$T/keep.json" "$QA_REPOS/fixture.json"
jq '.sandbox_net = false | .boot_cmd = "test -z \"$(find /run -type s 2>/dev/null)\""' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract good)")"; "$QA" gate "$id" boot >/dev/null 2>&1
same "no service socket is visible under /run" "$(jq -r .status "$QA_HOME/runs/$id/gates/boot.json")" "pass"
cp "$T/keep.json" "$QA_REPOS/fixture.json"
SRC_STATE="$(git -C "$R" for-each-ref; git -C "$R" status --porcelain)"

echo "# contracts"
c="$(contract good)"
for pair in 'issue|"cf 9"' 'issue|"../x"' 'repro_check|"tests/x.py; rm -rf ~"' 'repro_check|"../outside.py"' 'candidate|"main; reboot"' 'reply_to|"nobody"' 'repo|"--upload-pack=x"' 'budget|{"wall_minutes":0,"tokens":1}'; do
  k="${pair%%|*}"; v="${pair#*|}"
  jq --arg k "$k" --argjson v "$v" '.[$k] = $v' "$c" > "$T/bad.json"
  out="$("$QA" validate "$T/bad.json" 2>&1)" && bad "refuses bad $k: $v" || ok "refuses bad $k: $v"
done
out="$("$QA" validate "$ROOT/qa/contract.example.json" 2>&1)" && ok "example contract is valid" || bad "example contract is valid" "$out"
jq '.repo = "/nowhere/unknown-repo"' "$c" > "$T/unk.json"
out="$("$QA" new "$T/unk.json" 2>&1)"; [[ "$out" == *"no QA settings"* ]] && ok "unknown repo refused" || bad "unknown repo refused" "$out"
cp "$QA_REPOS/fixture.json" "$T/keep.json"; jq '.suite_cmd = ""' "$T/keep.json" > "$QA_REPOS/fixture.json"
out="$("$QA" new "$c" 2>&1)"; [[ "$out" == *"suite commands are required"* ]] && ok "repo without a suite command refused" || bad "repo without a suite command refused" "$out"
jq '.assertion_pattern = ""' "$T/keep.json" > "$QA_REPOS/fixture.json"
out="$("$QA" new "$(contract good)" 2>&1)"; [[ "$out" == *"no assertion_pattern"* ]] && ok "repro check without an assertion pattern refused" || bad "repro check without an assertion pattern refused" "$out"
jq '.check_cmd = "python3 {check} # AssertionError"' "$T/keep.json" > "$QA_REPOS/fixture.json"
id="$(new "$(contract importerr)")"; same "pattern in the command line does not count" "$(full_run "$id" good 'coverage: covered')" "fail red"
cp "$T/keep.json" "$QA_REPOS/fixture.json"

echo "# merge gate"
"$QA" hook "$R" on >/dev/null
same "hook reports on" "$("$QA" hook "$R" status)" "on"
git -C "$R" branch -q foreman/job-good good; git -C "$R" branch -q foreman/job-noop noop
GOOD="$(git -C "$R" rev-parse good)"
"$QA" passed "$GOOD" >/dev/null && ok "an earlier run passed the good commit" || bad "an earlier run passed the good commit"
out="$(git -C "$R" merge -q --no-ff -m m foreman/job-noop 2>&1)"; [[ "$out" == *"merge refused"* ]] && ok "merge of a foreman/ branch without a QA pass refused" || bad "merge of a foreman/ branch without a QA pass refused" "$out"
git -C "$R" merge --abort 2>/dev/null; git -C "$R" reset -q --hard main
git -C "$R" merge -q --no-ff -m m foreman/job-good 2>/dev/null && ok "merge of a QA-passed foreman/ branch allowed" || bad "merge of a QA-passed foreman/ branch allowed"
git -C "$R" reset -q --hard HEAD~1
git -C "$R" checkout -q -b foreman/job-later good; echo "# later change" >> "$R/name.py"; git -C "$R" commit -qam later; git -C "$R" checkout -q main
out="$(git -C "$R" merge -q --no-ff -m m foreman/job-later 2>&1)"; [[ "$out" == *"merge refused"* ]] && ok "a commit changed after QA needs QA again" || bad "a commit changed after QA needs QA again" "$out"
git -C "$R" merge --abort 2>/dev/null; git -C "$R" reset -q --hard main
git -C "$R" checkout -q -b human main; echo "notes" > "$R/NOTES.md"; git -C "$R" add NOTES.md; git -C "$R" commit -qm notes; git -C "$R" checkout -q main
git -C "$R" merge -q --no-ff -m m human 2>/dev/null && ok "merges of other branches are left alone" || bad "merges of other branches are left alone"
git -C "$R" reset -q --hard main~0 2>/dev/null; git -C "$R" reset -q --hard HEAD^1
out="$(git -C "$R" merge -q --no-ff -m m noop 2>&1)"; [[ "$out" == *"merge refused"* ]] && ok "a foreman/ commit under another branch name is still gated" || bad "a foreman/ commit under another branch name is still gated" "$out"
git -C "$R" merge --abort 2>/dev/null; git -C "$R" reset -q --hard main
"$QA" hook "$R" off >/dev/null; same "hook reports off" "$("$QA" hook "$R" status)" "off"

echo "# sending"
mkdir -p "$T/bin"; cat > "$T/bin/rig" <<'SH'
#!/bin/sh
case "$1" in
  ps) echo '[{"nodes":[{"session":"crew-owner@foreman-fixture"}]}]' ;;
  queue) echo "$@" >> "$QA_HOME/queued.log" ;;
esac
SH
chmod +x "$T/bin/rig"
c="$(contract good)"
out="$(PATH="$T/bin:$PATH" "$QA" send "$c" 2>&1)"; [[ "$out" == *"queued for qa-gatekeeper@"* ]] && grep -q -- '--destination qa-gatekeeper@' "$QA_HOME/queued.log" && ok "send queues a contract for the gatekeeper" || bad "send queues a contract for the gatekeeper" "$out"
jq '.reply_to = "nobody@nowhere"' "$c" > "$T/r.json"
out="$(PATH="$T/bin:$PATH" "$QA" send "$T/r.json" 2>&1)"; [[ "$out" == *"not a seat OpenRig knows"* ]] && ok "send refuses an unknown reply seat" || bad "send refuses an unknown reply seat" "$out"

echo "# the screener"
SCREEN="$ROOT/scripts/screen"
# A stand-in for curl: saves what it was sent, answers with the canned file and status.
cat > "$T/bin/curl" <<'SH'
#!/bin/sh
out=""; body=""
echo "$@" > "$CURL_DIR/argv"; cat > "$CURL_DIR/config"
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; --data-binary) body="${2#@}"; shift ;; esac; shift; done
cp "$body" "$CURL_DIR/body.json"
cat "$CURL_DIR/answer.json" > "$out"; printf '%s' "$(cat "$CURL_DIR/status")"
SH
chmod +x "$T/bin/curl"; mkdir -p "$T/curl"; export CURL_DIR="$T/curl"
answer() { echo "${3:-200}" > "$T/curl/status"; jq -n --argjson a "$1" --argjson b "$2" '{model:"typesafe/jev-1.14-test", answers:{item_0:{type:"noul",noul:$a}, item_1:{type:"noul",noul:$b}}}' > "$T/curl/answer.json"; }
two_items() { jq '.done_items = ["An empty middle name gives one space between first and last name.", "The settings page can export all contacts as CSV."]' "$(contract good)" > "$T/two.json"; printf '%s' "$T/two.json"; }
send() { PATH="$T/bin:$PATH" OPENROUTER_API_KEY=sk-test-key "$QA" send "$@" 2>&1; }
queued() { wc -l < "$QA_HOME/queued.log" | tr -d ' '; }
last_log() { tail -n 1 "$QA_HOME/screener/log.jsonl" 2>/dev/null | jq -r "$1"; }
c2="$(two_items)"; n="$(queued)"
out="$(send "$c2")"; same "screener off for the repo: sent as before" "$(queued)" "$((n+1))"
[ ! -e "$QA_HOME/screener/log.jsonl" ] && ok "screener off: no model call, nothing logged" || bad "screener off: no model call, nothing logged"
cp "$QA_REPOS/fixture.json" "$T/keep.json"; jq '.screener = "openrouter"' "$T/keep.json" > "$QA_REPOS/fixture.json"
answer 0.82 0.02; n="$(queued)"
out="$(send "$c2")"; rc=$?
[ "$rc" -ne 0 ] && [ "$(queued)" = "$n" ] && ok "an untouched done-condition item: sent back, no QA run queued" || bad "an untouched done-condition item: sent back, no QA run queued" "$out"
[[ "$out" == *"export all contacts as CSV"* && "$out" != *"- An empty middle name"* ]] && ok "the send-back names the untouched item only" || bad "the send-back names the untouched item only" "$out"
[[ "$out" == *"not a gate"* ]] && ok "the send-back is labelled a judgment" || bad "the send-back is labelled a judgment" "$out"
same "the call is logged with its decision" "$(last_log '.decision + " " + .kind + " " + (.items | length | tostring)')" "send_back judgment 2"
same "one question per item, about the diff" "$(jq -r '(.questions | keys | join(",")) + " " + (.state.diff | test("name.py") | tostring) + " " + .model' "$T/curl/body.json")" "item_0,item_1 true typesafe/jev-1.14"
! grep -q sk-test-key "$T/curl/argv" && grep -q sk-test-key "$T/curl/config" && ok "the key is not on the command line" || bad "the key is not on the command line"
answer 0.82 0.71; n="$(queued)"
out="$(send "$c2")"; same "every item worked on: goes to QA" "$(queued)" "$((n+1))"
[[ "$out" != *"warning"* ]] && ok "a clean screener call ends without an error" || bad "a clean screener call ends without an error" "$out"
[[ "$out" == *"not a pass"* ]] && ok "no objection is never called a pass" || bad "no objection is never called a pass" "$out"
same "no objection is logged" "$(last_log .decision)" "no_objection"
answer 0.82 0.02 500; n="$(queued)"
out="$(send "$c2")"; same "model service down: goes to QA without the screener" "$(queued) $(last_log .decision)" "$((n+1)) skipped"
echo 200 > "$T/curl/status"; echo '{"answers":{"item_0":{"type":"noul","noul":"high"}}}' > "$T/curl/answer.json"; n="$(queued)"
out="$(send "$c2")"; same "answer in the wrong form: not trusted, goes to QA" "$(queued) $(last_log .decision)" "$((n+1)) skipped"
answer 0.82 0.02; n="$(queued)"
out="$(SCREEN_MODEL=other/model send "$c2")"; same "a model with no stored threshold does not screen" "$(queued) $(last_log .decision)" "$((n+1)) skipped"
out="$(PATH="$T/bin:$PATH" "$QA" send "$c2" 2>&1)"; same "no key: goes to QA without the screener" "$(last_log .reason)" "OPENROUTER_API_KEY is not set"
n="$(queued)"; out="$(send "$c2" --no-screen)"; [ "$?" -ne 0 ] && [ "$(queued)" = "$n" ] && ok "overruling the screener needs a reason" || bad "overruling the screener needs a reason" "$out"
out="$(send "$c2" --no-screen "export button is in settings.py line 40")"; same "the Lead can overrule with a reason, and it is logged" "$(queued) $(last_log '.decision + ": " + .reason')" "$((n+1)) overridden: export button is in settings.py line 40"
answer 0.9 0.9; out="$(send "$(contract good)")"; same "a contract without done_items asks about the done condition" "$(jq -r '.questions | keys | join(",")' "$T/curl/body.json")" "item_0"
out="$(PATH="$T/bin:$PATH" "$SCREEN" report 2>&1)"; [[ "$out" == *"sent back: 1; overruled by the Lead: 1"* && "$out" == *"QA did not pass:"* ]] && ok "report counts the calls beside the QA verdicts" || bad "report counts the calls beside the QA verdicts" "$out"
for v in '[]' '[""]' '"one"' '[1]'; do
  jq --argjson v "$v" '.done_items = $v' "$(contract good)" > "$T/bad.json"
  out="$("$QA" validate "$T/bad.json" 2>&1)" && bad "refuses done_items $v" || ok "refuses done_items $v"
done
cp "$T/keep.json" "$QA_REPOS/fixture.json"

echo
echo "$pass passed, $failn failed"
[ "$failn" -eq 0 ]
