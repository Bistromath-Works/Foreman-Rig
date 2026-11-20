#!/usr/bin/env bash
# Tests for scripts/foreman. No OpenRig daemon needed: rig, claude, codex and pi are stubs.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$(cd "$HERE/.." && pwd)"
pass=0; fail=0
NODE="$(command -v node)" || { echo "tests need node on PATH"; exit 1; }

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/       /'; }

# Fresh sandbox per test: a copy of the setup repo, a project repo, stub binaries.
setup() {
  T="$(mktemp -d)"
  mkdir -p "$T/foreman" "$T/bin" "$T/home"
  cp -r "$SRC/rig.template.yaml" "$SRC/project.template.yaml" "$SRC/state.template.md" "$SRC/scripts" "$T/foreman/"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  mkdir -p "$T/My App" && git -C "$T/My App" init -q && git -C "$T/My App" commit -q --allow-empty -m init
  P="$T/My App"
  printf '#!/bin/sh\nexit 0\n' > "$T/bin/codex"
  # claude lists the Langfuse plugin only once "installed"; pi install records where it installed.
  cat > "$T/bin/claude" <<EOF
#!/bin/sh
[ "\$1 \$2" = "plugin list" ] && [ -f "$T/claude.plugin" ] && echo "langfuse-observability@langfuse-observability"
exit 0
EOF
  cat > "$T/bin/pi" <<EOF
#!/bin/sh
if [ "\$1" = install ]; then echo "\$PI_CODING_AGENT_DIR" >> "$T/pi.installs"; printf '{"packages":["%s"]}' "\$2" > "\$PI_CODING_AGENT_DIR/settings.json"; fi
exit 0
EOF
  chmod +x "$T/bin/codex" "$T/bin/claude" "$T/bin/pi"
  ln -s "$NODE" "$T/bin/node"
  cat > "$T/bin/rig" <<EOF
#!/bin/sh
echo "\$*" >> "$T/rig.calls"
if [ "\$1 \$2" = "config get" ]; then cat "$T/allowlist" 2>/dev/null; fi
if [ "\$1 \$2" = "daemon status" ]; then cat "$T/daemon.status" 2>/dev/null; fi
if [ "\$1 \$2" = "spec validate" ] && [ -f "$T/validate.fail" ]; then echo "bad spec"; exit 1; fi
exit 0
EOF
  chmod +x "$T/bin/rig"
  # tmux is always a stub: no test may start a real session.
  printf '#!/bin/sh\necho "$*" >> "%s/tmux.calls"\n[ "$1" = has-session ] && exit 1\nexit 0\n' "$T" > "$T/bin/tmux"
  chmod +x "$T/bin/tmux"
  export PATH="$T/bin:/usr/bin:/bin" HOME="$T/home" OPENRIG_HOME="$T/home/.openrig"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  unset PI_CODING_AGENT_DIR
  F="$T/foreman/scripts/foreman"
  RIG="$T/foreman/rig.my-app.yaml"
}
teardown() { rm -rf "$T"; }

# Fill every SET-ME: all seats on claude-code except the ones named as id=runtime/model.
fill() {
  sed -i 's/runtime: SET-ME/runtime: claude-code/; s/model: SET-ME/model: claude-sonnet-5-5/' "$RIG"
  local spec id rest rt md
  for spec in "$@"; do
    id="${spec%%=*}"; rest="${spec#*=}"; rt="${rest%%:*}"; md="${rest#*:}"
    awk -v id="$id" -v rt="$rt" -v md="$md" '
      /- id:/ { cur=$3 }
      cur==id && /runtime:/ { sub(/runtime: .*/, "runtime: " rt) }
      cur==id && /model:/   { sub(/model: .*/, "model: " md) }
      { print }' "$RIG" > "$RIG.new" && mv "$RIG.new" "$RIG"
  done
  sed -i 's/^\(base_branch\|preflight_cmd\|verify_cmd\|acceptance_tests\): SET-ME/\1: none/; s/^\(protected_paths\|banned_cmds\): SET-ME/\1: []/' "$P/.foreman/project.yaml"
}

echo "scripts/foreman"

setup
out="$("$F" init "$P" 2>&1)"
grep -q '^name: foreman-my-app$' "$RIG" && ok "init names the rig after the project folder" || bad "init rig name" "$out"
grep -q "^# project: $P\$" "$RIG" && ok "init records the project path" || bad "init project path"
[ -f "$P/.foreman/project.yaml" ] && ok "init writes .foreman/project.yaml" || bad "init project.yaml"
grep -q '^## Human answers' "$P/.foreman/STATE.md" && ok "init writes a STATE.md for the owner" || bad "init STATE.md"
echo "- 2026-01-01 fee: answered" >> "$P/.foreman/STATE.md"; "$F" init "$P" >/dev/null 2>&1
grep -q 'fee: answered' "$P/.foreman/STATE.md" && ok "init never overwrites an existing STATE.md" || bad "STATE.md overwritten"
grep -qxF .foreman/ "$P/.git/info/exclude" && grep -qxF CLAUDE.local.md "$P/.git/info/exclude" && grep -qxF AGENTS.md "$P/.git/info/exclude" \
  && ok "init keeps OpenRig files out of git" || bad "init exclude" "$(cat "$P/.git/info/exclude")"
[ -z "$(git -C "$P" status --porcelain)" ] && ok "project tree stays clean after init" || bad "tree dirty" "$(git -C "$P" status --porcelain)"
"$F" init "$P" >/dev/null 2>&1; [ "$(grep -c '^\.foreman/$' "$P/.git/info/exclude")" = 1 ] && ok "init is idempotent" || bad "init twice duplicated excludes"
teardown

setup
"$F" init "$P" >/dev/null
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'seat owner: runtime=SET-ME model=SET-ME' && echo "$out" | grep -q "'verify_cmd' is still SET-ME" \
  && ok "check refuses and names every blank seat and project field" || bad "check blanks" "$out"
[ ! -f "$T/rig.calls" ] && ok "check does not reach OpenRig while blanks remain" || bad "rig called early"
teardown

setup
"$F" init "$P" >/dev/null; fill
sed -i 's/^verify_cmd: none/verify_cmd: SET-ME/' "$P/.foreman/project.yaml"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'verify_cmd' && ! echo "$out" | grep -q 'seat ' \
  && ok "check catches a single blank project field" || bad "single project blank" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && grep -q "spec validate $RIG" "$T/rig.calls" && grep -q "spec preflight $RIG" "$T/rig.calls" \
  && ok "check passes when filled and runs rig spec validate + preflight" || bad "filled check" "$out"
teardown

setup
"$F" init "$P" >/dev/null
! grep -q 'auditor' <(grep -v '^#' "$RIG") && ok "init leaves the auditor out by default, seat and edge" || bad "default no auditor" "$(grep -n auditor "$RIG")"
grep -q 'id: checker' "$RIG" && grep -q 'to: checker' "$RIG" && ok "init without the auditor keeps the other seats" || bad "no-auditor removed too much"
teardown

setup
"$F" init "$P" --auditor >/dev/null
grep -q 'id: auditor' "$RIG" && grep -q 'to: auditor' "$RIG" && ok "init --auditor keeps the auditor seat and its edge" || bad "--auditor" "$(grep -n auditor "$RIG")"
teardown

setup
"$F" init "$P" >/dev/null
! grep -q 'coder' <(grep -v '^#' "$RIG") && ok "init leaves the coder out by default, seat and edge" || bad "default no coder" "$(grep -n coder "$RIG")"
teardown

setup
out="$("$F" init "$P" --coder 2>&1)"
grep -q 'id: coder' "$RIG" && grep -q 'to: coder' "$RIG" && ! grep -q 'id: auditor' "$RIG" && ! grep -q 'to: auditor' "$RIG" \
  && ok "init --coder keeps the coder seat and its edge, and not the auditor" || bad "--coder" "$(grep -n 'coder\|auditor' "$RIG")"
echo "$out" | grep -q 'with the coder' && ok "init --coder says the coder is in" || bad "--coder message" "$out"
fill coder=pi:vllm/qwen3.8-27b
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a crew with a local pi coder passes check" || bad "coder check" "$out"
out="$("$F" init "$P" --coder 2>&1)"
echo "$out" | grep -q 'coder ignored' && ok "init --coder on an existing file says it was ignored" || bad "coder existing" "$out"
teardown

setup
"$F" init "$P" --coder --auditor >/dev/null
grep -q 'id: coder' "$RIG" && grep -q 'to: coder' "$RIG" && grep -q 'id: auditor' "$RIG" && grep -q 'to: auditor' "$RIG" \
  && ok "init --auditor --coder keeps both optional seats" || bad "both optional seats" "$(grep -n 'coder\|auditor' "$RIG")"
[ "$(grep -c 'agent_ref' "$RIG")" = 4 ] && ok "the full crew is four seats" || bad "four seats" "$(grep -n agent_ref "$RIG")"
[ -f "$SRC/agents/coder/agent.yaml" ] && [ -f "$SRC/agents/coder/guidance/role.md" ] \
  && ok "the coder seat the template points at exists" || bad "agents/coder missing"
teardown

setup
"$F" init "$P" >/dev/null; fill checker=nonsense:x
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "seat checker: runtime 'nonsense'" && ok "check rejects an unknown runtime" || bad "unknown runtime" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill owner=codex:gpt-6-astra
rm "$T/bin/codex"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "seat owner uses runtime 'codex'" && ok "check rejects a runtime that is not installed" || bad "missing runtime" "$out"
teardown

setup
"$F" init "$P" --auditor >/dev/null; fill auditor=pi:openrouter/google/gemini-4-argon
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'provider_auth_env_allowlist OPENROUTER_API_KEY' && ok "check requires the OpenRouter key allowlist" || bad "openrouter allowlist" "$out"
echo '["OPENROUTER_API_KEY"]' > "$T/allowlist"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "check passes once the key is allowlisted" || bad "openrouter allowlisted" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill checker=pi:ollama/glm-5.3:cloud
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'no .*models.json; fine only if Pi has it built in' && ok "check warns (not refuses) when a non-OpenRouter pi seat has no models.json" || bad "models.json missing" "$out"
mkdir -p "$HOME/.pi/agent" && echo '{}' > "$HOME/.pi/agent/models.json"
out="$("$F" up "$P" 2>&1)"; rc=$?
link="$OPENRIG_HOME/state/pi/crew-checker@foreman-my-app/agent/models.json"
[ $rc -eq 0 ] && [ -L "$link" ] && [ "$(readlink "$link")" = "$HOME/.pi/agent/models.json" ] \
  && ok "up links models.json into each pi seat before launch" || bad "seed models.json" "$out"
grep -q "^up $RIG --cwd $P\$" "$T/rig.calls" && ok "up launches the project's rig file with --cwd" || bad "up call" "$(cat "$T/rig.calls")"
teardown

setup
printf 'repo rules\n' > "$P/AGENTS.md"; git -C "$P" add AGENTS.md; git -C "$P" commit -qm agents
"$F" init "$P" >/dev/null
git -C "$P" ls-files -v AGENTS.md | grep -q '^S ' && ok "a tracked AGENTS.md is marked skip-worktree" || bad "skip-worktree" "$(git -C "$P" ls-files -v AGENTS.md)"
! grep -qxF AGENTS.md "$P/.git/info/exclude" && ok "a tracked AGENTS.md is not added to exclude" || bad "tracked AGENTS.md excluded"
teardown

setup
"$F" init "$P" >/dev/null
mkdir -p "$T/other/My App" && git -C "$T/other/My App" init -q
out="$("$F" check "$T/other/My App" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "share the folder name" && ok "two projects with the same folder name are refused" || bad "name collision" "$out"
teardown

setup
mkdir -p "$P/sub"
out="$("$F" init "$P/sub" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'top folder' && ok "init refuses a subfolder of a repo" || bad "subfolder" "$out"
out="$("$F" init "$T/nope" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "init refuses a missing folder" || bad "missing folder" "$out"
teardown


setup
"$F" init "$P" >/dev/null; fill owner=SET-ME:SET-ME
sed -i 's/^verify_cmd: none/verify_cmd: SET-ME/' "$P/.foreman/project.yaml"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'seat owner' && echo "$out" | grep -q "'verify_cmd' is still SET-ME" && echo "$out" | grep -q 'fill in every SET-ME' \
  && ok "check reports every problem when only some seats are filled" || bad "partial fill" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
sed -i '/^verify_cmd:/d' "$P/.foreman/project.yaml"
sed -i 's/^base_branch: none/base_branch:   # set me/' "$P/.foreman/project.yaml"
awk '/- id: checker/{b=1} b && /model:/{sub(/model: .*/,"model: \"\""); b=0} {print}' "$RIG" > "$RIG.n" && mv "$RIG.n" "$RIG"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "'verify_cmd' is missing" && echo "$out" | grep -q "'base_branch' has no value" && echo "$out" | grep -q 'seat checker: runtime=claude-code model=-' \
  && ok "check refuses missing keys, empty values and empty models, not just SET-ME" || bad "missing/empty" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
sed -i 's/^base_branch: none/base_branch: main   # was SET-ME/' "$P/.foreman/project.yaml"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a SET-ME inside a trailing comment is not a blank" || bad "comment false positive" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
awk '/--- auditor/{skip=1} !skip{print} /--- end auditor/{skip=0}' "$RIG" | grep -v 'id: checker' > "$RIG.n"; mv "$RIG.n" "$RIG"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "seat 'checker' is missing" && ok "check refuses a rig file missing a required seat" || bad "missing seat" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a crew without the auditor passes check" || bad "no-auditor check" "$out"
out="$("$F" init "$P" --auditor 2>&1)"
echo "$out" | grep -q 'auditor ignored' && ok "init --auditor on an existing file says it was ignored" || bad "auditor existing" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
grep -q 'id: owner' "$RIG" && grep -q 'to: checker' "$RIG" && [ "$(grep -c '^      - id:' "$RIG")" = 2 ] \
  && ok "plain init is exactly two seats: owner and checker" || bad "two seats" "$(grep -n 'id:' "$RIG")"
for v in 0 five -3 "5 jobs" 2.5 '"0"' "'manual" '""'; do
  sed -i "s/^audit_every:.*/audit_every: $v/" "$P/.foreman/project.yaml"
  out="$("$F" check "$P" 2>&1)"; rc=$?
  [ $rc -ne 0 ] && echo "$out" | grep -q "'audit_every' must be a whole number of jobs or manual" \
    && ok "check rejects audit_every: $v" || bad "audit_every $v" "$out"
done
for v in manual '"manual"' "'manual'" 7 '"7"'; do
  sed -i "s/^audit_every:.*/audit_every: $v/" "$P/.foreman/project.yaml"
  out="$("$F" check "$P" 2>&1)"; rc=$?
  [ $rc -eq 0 ] && ok "audit_every: $v passes check" || bad "audit_every $v" "$out"
done
sed -i "s/^audit_every:.*/audit_every: 5/" "$P/.foreman/project.yaml"
git -C "$P" add -f .foreman/STATE.md && git -C "$P" commit -qm state
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "STATE.md is tracked by git" && echo "$out" | grep -q "rm --cached .foreman/STATE.md" \
  && ok "check refuses a tracked STATE.md and says how to untrack it" || bad "tracked STATE.md" "$out"
git -C "$P" rm -q --cached .foreman/STATE.md && git -C "$P" commit -qm untrack
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "check passes once STATE.md is untracked" || bad "untracked STATE.md" "$out"
sed -i "/^audit_every:/d" "$P/.foreman/project.yaml"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "'audit_every' is missing" && ok "a 1.x project.yaml without audit_every is told what to add" || bad "audit_every missing" "$out"
teardown

setup
out="$("$F" init "$P" "$T" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'one project path' && ok "init refuses two project paths" || bad "two paths" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
touch "$T/validate.fail"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'rig spec validate failed' && ok "check fails when OpenRig validation fails" || bad "validate fail" "$out"
teardown

setup
"$F" init "$P" --auditor >/dev/null; fill auditor=pi:openrouter/google/gemini-4-argon
echo 'SOME_OTHER_KEY' > "$T/allowlist"
out="$("$F" check "$P" 2>&1)"; rc=$?
echo "$out" | grep -q 'allowlist SOME_OTHER_KEY,OPENROUTER_API_KEY' && ok "allowlist advice keeps keys already on the list" || bad "allowlist append" "$out"
echo 'SOME_OTHER_KEY,OPENROUTER_API_KEY' > "$T/allowlist"
sleep 30 & nokey=$!
echo "Daemon running on port 7433 (pid $nokey)" > "$T/daemon.status"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'does not have it in its environment' && ok "check refuses when the daemon lacks the key" || bad "daemon env no" "$out"
env OPENROUTER_API_KEY=x sleep 30 & haskey=$!
echo "Daemon running on port 7433 (pid $haskey)" > "$T/daemon.status"
sleep 0.2
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "check passes when the daemon has the key" || bad "daemon env yes" "$out"
kill $nokey $haskey 2>/dev/null; wait 2>/dev/null
teardown

setup
"$F" init "$P" >/dev/null; fill checker=pi:ollama/glm-5.3:cloud
mkdir -p "$HOME/.pi/agent" && echo '{}' > "$HOME/.pi/agent/models.json"
link="$OPENRIG_HOME/state/pi/crew-checker@foreman-my-app/agent/models.json"
mkdir -p "$(dirname "$link")" && ln -s "$T/gone.json" "$link"
out="$("$F" up "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(readlink "$link")" = "$HOME/.pi/agent/models.json" ] && ok "up replaces a dangling models.json link" || bad "dangling link" "$out"
out="$("$F" up "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "up can run twice" || bad "up twice" "$out"
teardown

setup
mkdir -p "$P/.claude" && echo '{}' > "$P/.mcp.json" && echo '{}' > "$P/.claude/settings.json"
git -C "$P" add .mcp.json .claude/settings.json && git -C "$P" commit -qm cfg
"$F" init "$P" >/dev/null
git -C "$P" ls-files -v .mcp.json .claude/settings.json | grep -c '^S ' | grep -qx 2 \
  && ok "tracked files OpenRig may write to are marked skip-worktree" || bad "tracked config" "$(git -C "$P" ls-files -v)"
echo changed > "$P/.mcp.json"
[ -z "$(git -C "$P" status --porcelain)" ] && ok "OpenRig edits to them leave the tree clean" || bad "tree dirty" "$(git -C "$P" status --porcelain)"
teardown

setup
ln -s "$P" "$T/linked"
out="$("$F" init "$T/linked" 2>&1)"; rc=$?
[ $rc -eq 0 ] && grep -q "^# project: $(cd "$P" && pwd -P)\$" "$RIG" && ok "a symlinked project path resolves to the real folder" || bad "symlink path" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
sed -i 's/^banned_cmds: \[\]/banned_cmds:\n  # deploys\n  - vercel\n  - "supabase db push"/' "$P/.foreman/project.yaml"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a YAML block list counts as a value" || bad "block list" "$out$(cat "$P/.foreman/project.yaml")"
teardown

# --- tracing ---

LF='LANGFUSE_PUBLIC_KEY=pk-test LANGFUSE_SECRET_KEY=sk-test LANGFUSE_BASE_URL=https://lf.example'

setup
"$F" init "$P" >/dev/null; fill
out="$("$F" tracing "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'export LANGFUSE_PUBLIC_KEY' && ok "tracing refuses without the Langfuse keys in env" || bad "tracing no keys" "$out"
out="$(env $LF "$F" tracing "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'claude plugin install' && ok "tracing says how to install the Claude plugin when it is missing" || bad "claude plugin missing" "$out"
teardown

setup
"$F" init "$P" --auditor >/dev/null; fill auditor=pi:openrouter/google/gemini-4-argon checker=codex:gpt-6-astra
touch "$T/claude.plugin"; mkdir -p "$HOME/.codex"; printf '[plugins."tracing@codex-observability-plugin"]\nenabled = true\n' > "$HOME/.codex/config.toml"
mkdir -p "$P/.claude" && echo '{"permissions":{"allow":["Bash(rig queue *)"]},"env":{"KEEP":"1"}}' > "$P/.claude/settings.local.json"
out="$(env $LF "$F" tracing "$P" 2>&1)"; rc=$?
cs="$P/.claude/settings.local.json"; cx="$P/.codex/langfuse.json"; pj="$OPENRIG_HOME/state/pi/crew-auditor@foreman-my-app/agent/langfuse.json"
[ $rc -eq 0 ] && node -e '
  const fs = require("fs"), [cs, cx, pj] = process.argv.slice(1).map(f => JSON.parse(fs.readFileSync(f, "utf8")));
  const good = cs.env.LANGFUSE_SECRET_KEY === "sk-test" && cs.env.CC_LANGFUSE_TRACE_TAGS === "foreman-my-app" && cs.env.KEEP === "1"
    && cs.permissions.allow.length === 1 && cx.enabled === true && cx.secret_key === "sk-test" && cx.base_url === "https://lf.example"
    && pj.secretKey === "sk-test" && pj.userId === "crew-auditor@foreman-my-app" && pj.environment === "foreman-my-app";
  process.exit(good ? 0 : 1)' "$cs" "$cx" "$pj" \
  && ok "tracing writes keys for claude, codex and each pi seat, keeping other settings" || bad "tracing on" "$out"
[ "$(stat -c %a "$cs" "$cx" "$pj" | sort -u)" = 600 ] && ok "tracing files holding keys are private (600)" || bad "perms" "$(stat -c '%a %n' "$cs" "$cx" "$pj")"
[ -z "$(git -C "$P" status --porcelain)" ] && ok "tracing leaves the project tree clean" || bad "tracing dirty" "$(git -C "$P" status --porcelain)"
grep -q 'crew-auditor@foreman-my-app' "$T/pi.installs" && [ "$(wc -l < "$T/pi.installs")" = 1 ] \
  && ok "tracing installs the Pi plugin into the pi seat's own dir only" || bad "pi install" "$(cat "$T/pi.installs" 2>&1)"
env $LF "$F" tracing "$P" >/dev/null 2>&1
[ "$(wc -l < "$T/pi.installs")" = 1 ] && ok "tracing twice does not reinstall the Pi plugin" || bad "pi reinstall"
out="$("$F" tracing "$P" --off 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ ! -e "$cx" ] && [ ! -e "$pj" ] && ! grep -q LANGFUSE "$cs" && grep -q KEEP "$cs" && grep -q 'rig queue' "$cs" \
  && ok "tracing --off removes the keys and keeps everything else" || bad "tracing off" "$out$(cat "$cs")"
teardown

setup
"$F" init "$P" >/dev/null; fill
touch "$T/claude.plugin"
mkdir -p "$P/.claude" && echo '{}' > "$P/.claude/settings.local.json"
git -C "$P" add -f .claude/settings.local.json && git -C "$P" commit -qm tracked
out="$(env $LF "$F" tracing "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'tracked by git; refusing' && ! grep -q sk-test "$P/.claude/settings.local.json" \
  && ok "tracing refuses to put keys in a file git tracks" || bad "tracked secret file" "$out"
teardown

# --- unstick watcher lifecycle ---
setup
"$F" init "$P" >/dev/null 2>&1; fill
"$F" up "$P" >/dev/null 2>&1
grep -q "new-session -d -s foreman-unstick@foreman-my-app" "$T/tmux.calls" 2>/dev/null \
  && ok "up starts the unstick watcher in its own tmux session" || bad "up starts watcher" "$(cat "$T/tmux.calls" 2>/dev/null)"
"$F" down "$P" >/dev/null 2>&1
grep -q "kill-session -t =foreman-unstick@foreman-my-app" "$T/tmux.calls" \
  && ok "down stops the unstick watcher" || bad "down stops watcher" "$(cat "$T/tmux.calls")"
teardown

# --- unstick: press Enter on OpenRig messages left unsent ---

# Fake tmux: a seat's pane is $T/pane.<session>; send-keys is recorded.
unstick_setup() {
  setup
  "$F" init "$P" >/dev/null 2>&1; fill checker=codex:gpt-6-astra
  cat > "$T/bin/tmux" <<STUB
#!/bin/sh
case "\$1" in
  capture-pane) t="\$4"; t="\${t#=}"; t="\${t%:}"; [ -f "$T/pane.\$t" ] && cat "$T/pane.\$t" || exit 1 ;;
  send-keys) echo "\$3 \$4" >> "$T/keys" ;;
  has-session) exit 1 ;;
  *) echo "\$*" >> "$T/tmux.calls" ;;
esac
STUB
  chmod +x "$T/bin/tmux"
  export FOREMAN_UNSTICK_IDLE=0
  NB="$(printf '\302\240')"
}
pass2() { "$F" unstick "$P" --once >/dev/null 2>&1; "$F" unstick "$P" --once >/dev/null 2>&1; }
OWN="crew-owner@foreman-my-app"; CHK="crew-checker@foreman-my-app"
# Seed the watcher's state as if it had seen this exact pane at time $2 (the copy the script keeps).
seed_state() {
  local d="$OPENRIG_HOME/foreman-unstick/foreman-my-app"
  mkdir -p "$d"; { cat "$T/pane.$1"; printf x; } > "$d/$1.pane"
  printf '%s %s\n' "$2" "${3:-0}" > "$d/$1"
}

unstick_setup
printf 'old\n❯ sent earlier\n─────\n❯%sFrom: crew-checker@x --- ↩ Reply: rig\n  send crew-checker@x "..."   │ side panel\n─────\n' "$NB" > "$T/pane.$OWN"
pass2
[ "$(cat "$T/keys" 2>/dev/null)" = "=$OWN: Enter" ] && ok "unstick: presses Enter once on an unsent message, even when it wraps" \
  || bad "unstick press" "$(cat "$T/keys" 2>/dev/null)"
teardown

unstick_setup
printf '❯ From: crew-checker@x --- ↩ Reply: rig send crew-checker@x\n● done\n─────\n❯%sa draft I am typing\n─────\n' "$NB" > "$T/pane.$OWN"
pass2
[ ! -s "$T/keys" ] && ok "unstick: leaves a human's draft alone, even under an OpenRig message already sent" \
  || bad "unstick draft" "$(cat "$T/keys")"
teardown

unstick_setup
printf '─────\n❯%s[Pasted text #3 +6 lines]\n─────\n' "$NB" > "$T/pane.$OWN"
pass2
printf '#!/bin/sh\n[ "$1 $2" = "queue list" ] && echo %s\nexit 0\n' "'[{\"state\":\"pending\"}]'" > "$T/bin/rig"
pass2
[ ! -s "$T/keys" ] && ok "unstick: a folded paste is never pressed, even with a pending queue item (it may be the human's)" \
  || bad "unstick fold" "$(cat "$T/keys")"
teardown

unstick_setup
printf '› From: crew-owner@x --- ↩ Reply: rig send crew-owner@x "..."\n  model line\n' > "$T/pane.$CHK"
for i in 1 2 3 4 5 6; do "$F" unstick "$P" --once >/dev/null 2>&1; done
[ "$(wc -l < "$T/keys" 2>/dev/null)" = 3 ] && grep -q "leaving it for a human" "$OPENRIG_HOME/foreman-unstick/foreman-my-app/log" \
  && ok "unstick: Codex prompt; stops after 3 presses on the same pane and logs it" || bad "unstick cap" "$(cat "$T/keys" 2>/dev/null)"
teardown

unstick_setup
printf '❯%sFrom: x --- ↩ Reply: rig send x\n' "$NB" > "$T/pane.$OWN"
FOREMAN_UNSTICK_IDLE=3600 pass2
[ ! -s "$T/keys" ] && ok "unstick: waits until the pane has been unchanged for the idle time" || bad "unstick idle" "$(cat "$T/keys")"
teardown

unstick_setup
printf '› a draft about the [OpenRig watchdog config\n  model line\n' > "$T/pane.$CHK"
pass2
[ ! -s "$T/keys" ] && ok "unstick: a draft that merely mentions the watchdog is left alone" || bad "unstick watchdog word" "$(cat "$T/keys")"
teardown

unstick_setup
printf '› From: crew-owner@x --- ↩ Reply: rig send crew-owner@x "..."\n• done\n›\n  model line\n' > "$T/pane.$CHK"
pass2
[ ! -s "$T/keys" ] && ok "unstick: an empty Codex prompt (bare ›) under a sent message is left alone" || bad "unstick codex empty" "$(cat "$T/keys")"
teardown

unstick_setup
printf '❯%sFrom: x --- ↩%sReply:%srig%ssend x\n' "$NB" "$NB" "$NB" "$NB" > "$T/pane.$OWN"
pass2
[ -s "$T/keys" ] && ok "unstick: no-break spaces inside the message still match" || bad "unstick nbsp marker"
teardown

unstick_setup
printf '❯%sFrom: x --- ↩ Reply: rig send x\n' "$NB" > "$T/pane.$OWN"
seed_state "$OWN" 08 0
out="$("$F" unstick "$P" --once 2>&1)"; rc=$?
[ "$rc" = 0 ] && [ -s "$T/keys" ] && ok "unstick: a state record with a leading zero neither crashes nor blocks" || bad "unstick corrupt state" "rc=$rc $out"
printf 'garbage\n' > "$OPENRIG_HOME/foreman-unstick/foreman-my-app/$OWN"
"$F" unstick "$P" --once >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "unstick: an unreadable state record starts over" || bad "unstick garbage state" "rc=$rc"
teardown

unstick_setup
printf '❯%sFrom: x --- ↩ Reply: rig send x\n' "$NB" > "$T/pane.$OWN"
FOREMAN_UNSTICK_IDLE=3600 "$F" unstick "$P" --once >/dev/null 2>&1   # the script records its own hash
st="$OPENRIG_HOME/foreman-unstick/foreman-my-app/$OWN"
printf '1 0\n' > "$st"   # ...then age it: seen long ago
printf '\n\n' >> "$T/pane.$OWN"
FOREMAN_UNSTICK_IDLE=60 "$F" unstick "$P" --once >/dev/null 2>&1
[ ! -s "$T/keys" ] && ok "unstick: a change in trailing blank rows counts as a change" || bad "unstick trailing rows" "$(cat "$T/keys")"
teardown

unstick_setup
printf '❯%sFrom: x --- ↩ Reply: rig\342\200\257send x\n' "$NB" > "$T/pane.$OWN"
pass2
[ -s "$T/keys" ] && ok "unstick: any width of space inside the message still matches" || bad "unstick narrow nbsp"
teardown

unstick_setup
printf '❯%sFrom: x --- ↩ Reply: rig send x\n' "$NB" > "$T/pane.$OWN"
seed_state "$OWN" 18446744073709551616
FOREMAN_UNSTICK_IDLE=60 "$F" unstick "$P" --once >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/keys" ] && ok "unstick: an out-of-range timestamp starts the timer over instead of pressing" \
  || bad "unstick huge since" "rc=$rc $(cat "$T/keys" 2>/dev/null)"
teardown

unstick_setup
rm -f "$RIG"; "$F" init "$P" --auditor >/dev/null 2>&1; fill auditor=pi:m
"$F" unstick "$P" --once >/dev/null 2>&1   # sanity: the rig file now has a pi auditor
grep -q "id: auditor" "$RIG" && grep -q "runtime: pi" "$RIG" || bad "pi test setup: no pi auditor in rig file"
printf 'From: crew-owner@x --- ↩ Reply: rig send crew-owner@x "..."\na draft\n' > "$T/pane.crew-auditor@foreman-my-app"
pass2
[ ! -s "$T/keys" ] && ok "unstick: pi seats are never pressed (no prompt marker to go by)" || bad "unstick pi" "$(cat "$T/keys")"
teardown

unstick_setup
printf '❯%s[Pasted text #2 +4 lines][OpenRig watchdog scheduler · policy: x] You are parked\n' "$NB" > "$T/pane.$OWN"
pass2
[ ! -s "$T/keys" ] && ok "unstick: a human's folded paste with a watchdog wake appended is left alone" || bad "unstick fold+wake" "$(cat "$T/keys")"
teardown

unstick_setup
printf '❯%smy draft From: crew-checker@x --- ↩ Reply: rig send crew-checker@x "..."\n' "$NB" > "$T/pane.$OWN"
pass2
[ ! -s "$T/keys" ] && ok "unstick: a human's typed draft with an OpenRig message appended is left alone" || bad "unstick draft+msg" "$(cat "$T/keys")"
teardown

unstick_setup
printf '❯%sFrom: crew-checker@x\n  ---\n  ↩ Reply: rig send crew-checker@x "..."[OpenRig watchdog scheduler · policy: p] You are parked\n' "$NB" > "$T/pane.$OWN"
pass2
[ -s "$T/keys" ] && ok "unstick: the real stuck shape (handoff plus watchdog wake on one unsent prompt) is pressed" || bad "unstick real shape"
teardown

unstick_setup
printf '❯%sFrom: x --- ↩ Reply: rig send x\n' "$NB" > "$T/pane.$OWN"
seed_state "$OWN" 1
printf '1 0 corrupt trailing fields\n' > "$OPENRIG_HOME/foreman-unstick/foreman-my-app/$OWN"
FOREMAN_UNSTICK_IDLE=60 "$F" unstick "$P" --once >/dev/null 2>&1
[ ! -s "$T/keys" ] && ok "unstick: a state record with extra fields restarts the timer" || bad "unstick extra fields" "$(cat "$T/keys")"
printf '1 0\n\n' > "$OPENRIG_HOME/foreman-unstick/foreman-my-app/$OWN"
FOREMAN_UNSTICK_IDLE=60 "$F" unstick "$P" --once >/dev/null 2>&1
[ ! -s "$T/keys" ] && ok "unstick: a state record with trailing blank lines restarts the timer" || bad "unstick blank lines" "$(cat "$T/keys")"
teardown

# --- the smoke-test example project ---

S="$(mktemp -d)"; cp -r "$SRC/examples/smoke/." "$S/"
if (cd "$S" && "$NODE" --test >/dev/null 2>&1); then bad "smoke example: acceptance tests should fail before a build"
else ok "smoke example: acceptance tests fail before the crew builds"; fi
cp "$HERE/smoke-reference.js" "$S/src/slugify.js"
(cd "$S" && "$NODE" --test >/dev/null 2>&1) && ok "smoke example: a reference build passes them (the spec is buildable)" \
  || bad "smoke example reference" "$(cd "$S" && "$NODE" --test 2>&1 | tail -20)"
rm -rf "$S"

# --- banned commands refused by the runtime ---
setup
"$F" init "$P" --coder >/dev/null; fill checker=codex:gpt-6-astra coder=pi:vllm/qwen3.8-27b
sed -i 's|^banned_cmds: .*|banned_cmds: ["vercel", "supabase db push", "pnpm install (without --frozen-lockfile --offline)"]|' "$P/.foreman/project.yaml"
echo '{"permissions":{"allow":["Bash(rig queue *)"]},"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"my-own-hook"}]}]}}' > "$P/.claude.tmp"; mkdir -p "$P/.claude"; mv "$P/.claude.tmp" "$P/.claude/settings.local.json"
PATH="$PATH:$(dirname "$(command -v jq)")" out="$("$F" bans "$P" 2>&1)"; rc=$?
B="$P/.foreman/bans.json"; G="$T/foreman/scripts/foreman-guard"
[ $rc -eq 0 ] && [ "$(jq -c '[.bans[] | select(.source == "banned_cmds") | [.text, (.unless // [])]]' "$B")" = '[["vercel",[]],["supabase db push",[]],["pnpm install",["--frozen-lockfile","--offline"]]]' ] \
  && jq -e '[.bans[].text] | index("git push") != null and index("gh") != null' "$B" >/dev/null \
  && ok "bans writes the list: built-in bans plus banned_cmds, with the 'without' form read" || bad "bans list" "$out $(cat "$B" 2>&1)"
C="$P/.claude/settings.local.json"
[ "$(jq -r '[.hooks.PreToolUse[] | .matcher] | join(",")' "$C")" = "Edit,Bash" ] && jq -e '.permissions.allow[0] == "Bash(rig queue *)"' "$C" >/dev/null \
  && jq -r '.hooks.PreToolUse[1].hooks[0].command' "$C" | grep -q 'foreman-guard.*bans.json' && ok "claude-code gets the guard hook; its other settings and hooks are kept" || bad "claude hook" "$(cat "$C")"
[ "$(jq -r '.hooks.PreToolUse[0].matcher + " " + .hooks.PreToolUse[0].hooks[0].type' "$P/.codex/hooks.json")" = '^Bash$ command' ] && ok "codex gets the guard hook in .codex/hooks.json" || bad "codex hook" "$(cat "$P/.codex/hooks.json" 2>&1)"
X="$OPENRIG_HOME/state/pi/crew-coder@foreman-my-app/agent/extensions/foreman-guard.ts"
grep -q 'pi.on("tool_call"' "$X" && grep -qF "$B" "$X" && ok "the pi seat gets the guard extension in its own agent folder" || bad "pi extension" "$(cat "$X" 2>&1)"
echo "$out" | grep -q 'ONCE YOU TRUST IT' && echo "$out" | grep -q 'seat coder (pi)' && ok "bans says which seats are covered and what the human still has to do" || bad "bans message" "$out"
hookcmd="$(jq -r '.hooks.PreToolUse[1].hooks[0].command' "$C")"
guard() { printf '%s' "$1" | PATH="$PATH:$(dirname "$(command -v jq)")" bash -c "$hookcmd" 2>"$T/guard.err"; }
guard '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}'; [ $? -eq 2 ] && grep -q 'Blocked by Foreman' "$T/guard.err" && ok "the installed hook refuses git push, from a project path with a space" || bad "hook refuses push" "$(cat "$T/guard.err")"
guard '{"tool_name":"Bash","tool_input":{"command":"pnpm test"}}'; [ $? -eq 0 ] && ok "the installed hook lets an ordinary command through" || bad "hook allows" "$(cat "$T/guard.err")"
gcheck() { printf '%s' "$2" | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$B" --command 2>/dev/null; [ $? -eq "$1" ]; }
allok=1
while IFS='|' read -r want cmd; do gcheck "$want" "$cmd" || { allok=0; bad "guard: want $want for: $cmd"; }; done <<'CASES'
2|git push
2|bash -lc 'git   push --force'
2|git remote add up https://example.invalid/x.git
2|gh pr create
2|/usr/bin/gh auth status
2|npx vercel deploy
2|supabase db push
2|pnpm install
2|pnpm install --frozen-lockfile
2|pnpm dev &
2|nohup pnpm dev
2|(sleep 9 &)
0|git status
0|git log --grep=push
0|echo though it is high enough
0|cat vercel.json
0|supabase db diff
0|pnpm install --frozen-lockfile --offline
0|pnpm test 2>&1 | tail -5
0|pnpm lint && pnpm typecheck
0|curl -s "http://localhost:3000/api?a=1&b=2"
0|echo done >&2
CASES
[ "$allok" -eq 1 ] && ok "the guard blocks the banned commands and lets look-alikes through (22 cases)"
printf '{"tool_name":"Bash","tool_input":{"command":"ls","run_in_background":true}}' | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$B" 2>/dev/null; [ $? -eq 2 ] && ok "a command started in the background is refused" || bad "background flag"
printf '{"tool_name":"Read","tool_input":{"file_path":"vercel.json"}}' | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$B" 2>/dev/null; [ $? -eq 0 ] && ok "tools that are not a shell are not the guard's business" || bad "non-shell tool"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$T/nowhere.json" 2>/dev/null; [ $? -eq 2 ] && ok "with no readable ban list the guard refuses, it does not wave commands through" || bad "guard fails closed"
PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" >/dev/null 2>&1
[ "$(jq '.hooks.PreToolUse | length' "$C")" = 2 ] && ok "running bans twice does not add the hook twice" || bad "bans idempotent" "$(cat "$C")"
PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" --off >/dev/null 2>&1
[ "$(jq -r '[.hooks.PreToolUse[] | .matcher] | join(",")' "$C")" = "Edit" ] && [ ! -e "$P/.codex/hooks.json" ] && [ ! -e "$X" ] && [ ! -e "$B" ] \
  && ok "bans --off removes the guard everywhere and leaves other hooks alone" || bad "bans off" "$(cat "$C"; ls "$P/.codex" "$X" "$B" 2>&1)"
sed -i 's|^banned_cmds: .*|banned_cmds: vercel, supabase|' "$P/.foreman/project.yaml"
out="$(PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'must be a list' && ok "a banned_cmds the program cannot read is refused with the right form shown" || bad "bad banned_cmds" "$out"
teardown

# --- retro and the lessons ledger ---
setup
J="$P/.foreman/jobs/fmn-20261120-0900"; mkdir -p "$J/ctx" "$J/out" "$T/qa/runs/r1" "$T/qa/screener"
printf 'verdict: BLOCK\nround: 1\n' > "$J/out/check-r1.md"; printf 'verdict: PASS\nround: 2\n' > "$J/out/check-r2.md"
printf 'status: stuck\n' > "$J/out/code-1.md"; printf 'status: done\n' > "$J/out/code-2.md"; echo "r1 blocked" > "$J/LOG.md"
echo '{"issue":"fmn-20261120-0900","candidate":"abc"}' > "$J/ctx/qa-r1.json"
echo '{"issue":"fmn-20261120-0900","candidate":"abc"}' > "$T/qa/runs/r1/contract.json"; echo '{"verdict":"fail","gate":"green"}' > "$T/qa/runs/r1/verdict.json"
echo '{"issue":"fmn-20261120-0900","decision":"send_back"}' > "$T/qa/screener/log.jsonl"
out="$(QA_HOME="$T/qa" "$F" retro "$P" fmn-20261120-0900 2>&1)"
[ "$(jq -c '[.checker_blocks,.checker_passes,.coder_tasks,.coder_stuck,.qa_sends,.qa_verdicts[0],.screener_send_backs]' "$J/retro.json")" = '[1,1,2,1,1,"fail at green",1]' ] \
  && ok "retro counts the job's rounds, coder tasks, QA verdicts and screener send-backs" || bad "retro numbers" "$(cat "$J/retro.json") $out"
grep -q 'checker blocks: 1' "$J/ctx/retro.task.md" && grep -q "lesson \"$P\" fmn-20261120-0900" "$J/ctx/retro.task.md" \
  && ok "retro writes a task file with the numbers and the exact command" || bad "retro task" "$(cat "$J/ctx/retro.task.md")"
L="$P/.foreman/habits.jsonl"
out="$(OPENRIG_SESSION_NAME=crew-coder@x "$F" lesson "$P" fmn-20261120-0900 owner out/check-r1.md "The owner briefed the checker without listing what was untested." 2>&1)"
[ "$(jq -r '.job + " " + .about + " " + .evidence + " " + .by + " " + (.numbers.checker_blocks|tostring)' "$L")" = "fmn-20261120-0900 owner out/check-r1.md crew-coder@x 1" ] \
  && ok "a lesson is logged with its job, seat, evidence, author and the job's numbers" || bad "lesson logged" "$out $(cat "$L" 2>&1)"
for bad_args in "nobody|out/check-r1.md|A lesson about a seat that does not exist here." "owner|out/missing.md|The evidence file for this lesson does not exist." "owner|../../project.yaml|The evidence file is outside the job folder here." "owner|out/check-r1.md|too short" "owner|out/check-r1.md|The owner briefed the checker without listing what was untested."; do
  IFS='|' read -r a e t <<<"$bad_args"
  "$F" lesson "$P" fmn-20261120-0900 "$a" "$e" "$t" >/dev/null 2>&1 && bad "lesson refused: $a $e" || ok "lesson refused: $a / $e / ${t:0:28}"
done
"$F" lesson "$P" fmn-20261120-0900 coder out/code-1.md "The coder stopped and said it was stuck after three tries, as told." >/dev/null 2>&1
"$F" lesson "$P" fmn-20261120-0900 checker out/check-r1.md "The checker ran the verify command before reading any code." >/dev/null 2>&1
out="$("$F" lesson "$P" fmn-20261120-0900 crew LOG.md "A fourth lesson for the same job, which is over the cap of three." 2>&1)"
[ "$(wc -l < "$L")" -eq 3 ] && echo "$out" | grep -q 'cap' && ok "a fourth lesson for one job is refused" || bad "lesson cap" "$out"
out="$("$F" habits "$P" 2>&1)"; echo "$out" | grep -q '3 lessons from 1 jobs' && ok "habits lists the ledger" || bad "habits" "$out"
[ -z "$(git -C "$P" status --porcelain 2>/dev/null | grep -v '^?? .foreman')" ] && ok "retro and lessons change nothing in the repo outside .foreman" || bad "retro touched the repo" "$(git -C "$P" status --porcelain)"
teardown

# Static: every agent ref, role file and skill named in the repo exists.
missing=""
for seat in $(sed -n 's/.*agent_ref: "local:agents\/\([a-z]*\)".*/\1/p' "$SRC/rig.template.yaml"); do
  [ -f "$SRC/agents/$seat/agent.yaml" ] && [ -f "$SRC/agents/$seat/guidance/role.md" ] || missing="$missing $seat"
  for skill in $(sed -n 's/.*skills: \[\(.*\)\].*/\1/p' "$SRC/agents/$seat/agent.yaml" | tr ',' ' '); do
    grep -q "id: $skill\$" "$SRC/agents/shared/agent.yaml" || missing="$missing $seat:$skill"
  done
done
[ -z "$missing" ] && ok "every seat in the template has its manifest, role and skills" || bad "static refs" "$missing"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
