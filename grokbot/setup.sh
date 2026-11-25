#!/usr/bin/env bash
# Grok Bot experiment (CF-44): prepare the Bots' shared computer, and prove the gates run there.
#
#   grokbot/setup.sh             make the practice project and the QA home (safe to run again)
#   grokbot/setup.sh --selftest  run one whole QA pass on a throwaway copy, with no Bot involved
#
# Run it again after a computer update, Recover or Reset: installed packages are wiped then,
# and this says which ones are missing. It never uses sudo and never touches a remote.
#
# What it must never do: write outside $WS, or leave the practice project with a remote.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WS="${WS:-/workspace}"
PROJECT="$WS/smoke"
QA_HOME_DIR="$WS/foreman-qa"

say() { printf '%s\n' "$*"; }
die() { printf 'setup: %s\n' "$*" >&2; exit 1; }

# --- what the computer needs ---------------------------------------------------------------
missing=()
for t in git jq node bwrap; do command -v "$t" >/dev/null 2>&1 || missing+=("$t"); done
if [ "${#missing[@]}" -gt 0 ]; then
  say "Missing: ${missing[*]}"
  say "Install them (this needs the human's approval), then run this script again:"
  say "  sudo apt-get update && sudo apt-get install -y git jq bubblewrap nodejs"
  exit 1
fi
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' \
  || die "node $(node -v) is too old; the practice project needs node 20 or newer"
bwrap --ro-bind / / --unshare-pid true 2>/dev/null \
  || die "bwrap is installed but cannot start a sandbox here. The QA gates refuse to run without it, so the QA half of the experiment stops here. Write that down as the finding."
[ -d "$WS" ] && [ -w "$WS" ] || die "$WS is not a writable folder (set WS=<folder> to use another)"
case "$(realpath -m "$WS")/" in "$(realpath -m "$HOME")"/*) die "$WS is inside the home folder $HOME; the sandbox hides the home folder, so the gates could not see the project" ;; esac
say "ok: git, jq, node $(node -v), bwrap sandbox"

# Folders under the home folder are hidden from sandboxed commands. If node lives there, the
# QA settings must name its folder.
node_ro="[]"
node_dir="$(dirname "$(dirname "$(realpath "$(command -v node)")")")"
case "$node_dir/" in "$(realpath -m "$HOME")"/*) node_ro="$(jq -cn --arg d "$node_dir" '[$d]')" ;; esac

# make_project <folder>: the practice project, with the crew's settings, and no remote.
make_project() {
  local p="$1"
  if [ ! -d "$p/.git" ]; then
    mkdir -p "$p"; cp -r "$ROOT/examples/smoke/." "$p/"
    git -C "$p" init -q -b main
    git -C "$p" -c user.name="Foreman setup" -c user.email="setup@invalid" add -A
    git -C "$p" -c user.name="Foreman setup" -c user.email="setup@invalid" commit -qm "practice project"
    git -C "$p" config user.name "Foreman Lead"; git -C "$p" config user.email "lead@invalid"
  fi
  [ -z "$(git -C "$p" remote)" ] || die "$p has a remote; the practice project must have none"
  mkdir -p "$p/.foreman/inbox" "$p/.foreman/jobs"
  grep -qx '.foreman/' "$p/.git/info/exclude" 2>/dev/null || echo '.foreman/' >>"$p/.git/info/exclude"
  [ -f "$p/.foreman/STATE.md" ] || cp "$ROOT/state.template.md" "$p/.foreman/STATE.md"
  # The Bots that exist. Add "Foreman Auditor" or "Foreman Coder" on its own line if you make one.
  [ -f "$p/.foreman/CREW" ] || printf 'Foreman Lead\nForeman Checker\n' >"$p/.foreman/CREW"
  [ -f "$p/.foreman/project.yaml" ] || cat >"$p/.foreman/project.yaml" <<EOF
base_branch: main
preflight_cmd: none
verify_cmd: node --test
acceptance_tests: test/acceptance
protected_paths: []
banned_cmds: []
audit_every: manual
qa_cmd: $2/qa
EOF
}

# make_qa <qa home> <repo settings folder>: the QA home and the practice project's QA settings.
make_qa() {
  mkdir -p "$1"/{runs,inbox} "$2"
  printf '#!/bin/sh\nQA_HOME=%q QA_REPOS=%q exec %q "$@"\n' "$1" "$2" "$ROOT/scripts/qa" >"$1/qa"
  chmod +x "$1/qa"
  [ -f "$2/smoke.json" ] || jq -n --argjson ro "$node_ro" '{
    setup_cmd: "", boot_cmd: "node -e \"require(\\\"./src/slugify.js\\\")\"",
    check_cmd: "node --test {check}", assertion_pattern: "AssertionError",
    suite_cmd: "node --test", smoke_cmd: "", mutation_cmd: "", teardown_cmd: "",
    test_paths: ["test/"], protected_paths: ["test/acceptance"], add_only_paths: [],
    sandbox_ro: $ro, sandbox_rw: [], screener: "off" }' >"$2/smoke.json"
}

if [ "${1:-}" != "--selftest" ]; then
  make_qa "$QA_HOME_DIR" "$ROOT/qa/repos"
  make_project "$PROJECT" "$QA_HOME_DIR"
  "$QA_HOME_DIR/qa" hook "$PROJECT" on
  say "ok: practice project $PROJECT (no remote), QA home $QA_HOME_DIR"
  say "Next: grokbot/setup.sh --selftest"
  exit 0
fi

# --- self-test: one whole QA pass, no Bot involved ------------------------------------------
T="$WS/selftest-$$"; trap 'rm -rf "$T"' EXIT
P="$T/smoke"; Q="$T/qa-home"
make_qa "$Q" "$T/repos"; make_project "$P" "$Q"; "$Q/qa" hook "$P" on >/dev/null
git -C "$P" checkout -q -b foreman/selftest
mkdir -p "$P/src"; cp "$ROOT/tests/smoke-reference.js" "$P/src/slugify.js"
git -C "$P" add -A; git -C "$P" commit -qm "reference build"
cand="$(git -C "$P" rev-parse HEAD)"; git -C "$P" checkout -q main

if git -C "$P" merge -q --no-ff foreman/selftest -m x >/dev/null 2>&1; then
  die "FAIL: the merge gate let a job branch merge before any QA pass"
fi
git -C "$P" merge --abort 2>/dev/null || true
say "ok: merge refused before QA"

jq -n --arg r "$P" --arg c "$cand" '{repo: $r, base: "main", candidate: $c, issue: "SELFTEST-1",
  done_condition: "slugify turns a title into a URL slug.", done_items: ["slugify(\"Hello World\") is \"hello-world\"."],
  repro_check: "", budget: {wall_minutes: 15, tokens: 1}, reply_to: "lead@grokbot"}' >"$T/contract.json"
run="$("$Q/qa" new "$T/contract.json" | grep -o 'SELFTEST-1-[0-9-]*' | head -1)"
[ -n "$run" ] || die "FAIL: qa new printed no run id"
for g in boot red green mutation; do "$Q/qa" gate "$run" "$g" >/dev/null || true; done
mkdir -p "$Q/runs/$run/probe/test/probe"
cat >"$Q/runs/$run/probe/test/probe/hello.test.js" <<'EOF'
const test = require("node:test"); const assert = require("node:assert");
const { slugify } = require("../../src/slugify.js");
test("hello world", () => assert.strictEqual(slugify("Hello World"), "hello-world"));
EOF
"$Q/qa" gate "$run" probe >/dev/null || true
"$Q/qa" gate "$run" suite >/dev/null || true
printf 'coverage: covered\n\nSelf-test note, written by setup.sh, not by a Bot.\n' >"$Q/runs/$run/audit.md"
"$Q/qa" gate "$run" audit >/dev/null || true
"$Q/qa" verdict "$run" >/dev/null || true
v="$(jq -r .verdict "$Q/runs/$run/verdict.json" 2>/dev/null || echo none)"
[ "$v" = pass ] || { sed -n 1,40p "$Q/runs/$run/verdict.md" 2>/dev/null; die "FAIL: verdict is '$v', expected pass"; }
say "ok: all gates ran in the sandbox, verdict pass"
git -C "$P" merge -q --no-ff foreman/selftest -m "merge selftest" || die "FAIL: merge refused after a QA pass"
say "ok: merge allowed after the QA pass"
say "SELFTEST PASSED: the gates and the merge gate work on this computer without OpenRig."
