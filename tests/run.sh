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
  cp -r "$SRC/rig.template.yaml" "$SRC/project.template.yaml" "$SRC/state.template.md" "$SRC/front.template.md" "$SRC/scripts" "$T/foreman/"
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
if [ "\$1" = "up" ] && [ -f "$T/up.fail" ]; then cat "$T/up.fail"; exit 1; fi
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

# --- stall: nudge a builder that sits idle on a task it claimed (CF-28) ---

# rig stub: `queue list` prints $T/queue.json; every call is recorded.
stall_setup() {
  setup
  "$F" init "$P" --coder >/dev/null 2>&1; fill coder=pi:vllm/qwen
  cat > "$T/bin/tmux" <<STUB
#!/bin/sh
case "\$1" in
  capture-pane) t="\$4"; t="\${t#=}"; t="\${t%:}"; [ -f "$T/pane.\$t" ] && cat "$T/pane.\$t" || exit 1 ;;
  send-keys) echo "\$3 \$4" >> "$T/keys" ;;
  has-session) exit 1 ;;
  *) echo "\$*" >> "$T/tmux.calls" ;;
esac
STUB
  cat > "$T/bin/rig" <<STUB
#!/bin/sh
echo "\$*" >> "$T/rig.calls"
[ "\$1 \$2" = "queue list" ] && cat "$T/queue.json" 2>/dev/null
exit 0
STUB
  chmod +x "$T/bin/tmux" "$T/bin/rig"
  export FOREMAN_UNSTICK_IDLE=0 FOREMAN_STALL_IDLE=0
  COD="crew-coder@foreman-my-app"; SD="$OPENRIG_HOME/foreman-unstick/foreman-my-app"
  printf 'reading files\nvllm/qwen · idle\n' > "$T/pane.$COD"
  echo '[{"qitemId":"qitem-1","state":"in-progress"}]' > "$T/queue.json"
}
passes() { local i; for i in $(seq "$1"); do "$F" unstick "$P" --once >/dev/null 2>&1; done; }
sends() { local n; n="$(grep -c "^send $1 " "$T/rig.calls" 2>/dev/null)" || true; echo "${n:-0}"; }

stall_setup
passes 2
[ "$(sends "$COD")" = 1 ] && grep -q "^send $COD .*qitem-1" "$T/rig.calls" \
  && ok "stall: a builder idle on a claimed task is nudged, and the nudge names the task" || bad "stall nudge" "$(cat "$T/rig.calls" 2>/dev/null)"
grep -q "$COD: nudged" "$SD/log" && [ "$(jq -r '.seat + " " + .item + " " + (.nudge|tostring)' "$SD/stalls.jsonl")" = "$COD qitem-1 1" ] \
  && ok "stall: the nudge is logged and recorded" || bad "stall record" "$(cat "$SD/log" "$SD/stalls.jsonl" 2>&1)"
[ ! -s "$T/keys" ] && ok "stall: no key is pressed in the builder's pane" || bad "stall keys" "$(cat "$T/keys")"
teardown

stall_setup
echo '[]' > "$T/queue.json"
passes 3
[ "$(sends "$COD")" = 0 ] && ok "stall: an idle builder with no claimed task is left alone" || bad "stall no task" "$(cat "$T/rig.calls")"
echo '[{"qitemId":"qitem-2","state":"pending"}]' > "$T/queue.json"
passes 3
[ "$(sends "$COD")" = 0 ] && ok "stall: a task not yet claimed is not a stall" || bad "stall pending" "$(cat "$T/rig.calls")"
teardown

stall_setup
export FOREMAN_STALL_IDLE=300
passes 3
[ "$(sends "$COD")" = 0 ] && ok "stall: waits until the pane has been unchanged for the stall time" || bad "stall idle time" "$(cat "$T/rig.calls")"
printf '1\n' > "$SD/$COD.stall"          # seen long ago...
printf 'more output\n' >> "$T/pane.$COD"        # ...but the pane has moved since
passes 1
[ "$(sends "$COD")" = 0 ] && ok "stall: a pane that changed is a working builder" || bad "stall changed pane" "$(cat "$T/rig.calls")"
printf '1\n' > "$SD/$COD.stall"
passes 1
[ "$(sends "$COD")" = 1 ] && ok "stall: the same pane seen long ago is nudged" || bad "stall aged" "$(cat "$T/rig.calls")"
teardown

stall_setup
passes 8
[ "$(sends "$COD")" = 3 ] && [ "$(sends "$OWN")" = 1 ] && grep -q "^send $OWN .*qitem-1" "$T/rig.calls" \
  && ok "stall: after 3 nudges the owner is told once, and the builder is not nudged again" || bad "stall cap" "$(cat "$T/rig.calls")"
grep -q "told the owner" "$SD/log" && ok "stall: telling the owner is logged" || bad "stall owner log" "$(cat "$SD/log")"
echo '[{"qitemId":"qitem-9","state":"in-progress"}]' > "$T/queue.json"
passes 1
[ "$(sends "$COD")" = 4 ] && ok "stall: a new task starts the count over" || bad "stall new task" "$(cat "$T/rig.calls")"
teardown

# The count belongs to the task: another task shown for a while, or a pane that cannot be read
# for a pass, does not hand the first task three more nudges.
stall_setup
passes 5                                                    # A: three nudges, owner told
echo '[{"qitemId":"qitem-B","state":"in-progress"}]' > "$T/queue.json"; passes 1
echo '[{"qitemId":"qitem-1","state":"in-progress"}]' > "$T/queue.json"; passes 2
mv "$T/pane.$COD" "$T/pane.gone"; passes 1; mv "$T/pane.gone" "$T/pane.$COD"; passes 3
[ "$(grep -c "^send $COD .*qitem-1" "$T/rig.calls")" = 3 ] && [ "$(sends "$OWN")" = 1 ] \
  && ok "stall: one task never gets more than 3 nudges, whatever the queue or the pane did in between" || bad "stall cap per task" "$(cat "$T/rig.calls")"
teardown

stall_setup
cat > "$T/bin/rig" <<STUB
#!/bin/sh
echo "\$*" >> "$T/rig.calls"
[ "\$1 \$2" = "queue list" ] && cat "$T/queue.json" 2>/dev/null
[ "\$1 \$2" = "send $OWN" ] && [ -f "$T/owner.down" ] && exit 1
exit 0
STUB
touch "$T/owner.down"; passes 6
[ "$(sends "$OWN")" -ge 1 ] && ! grep -q told_owner "$SD/stalls.jsonl" && grep -q "could not be told" "$SD/log" \
  && ok "stall: a message to the owner that fails is not recorded as told" || bad "stall owner send fails" "$(cat "$SD/stalls.jsonl" "$SD/log")"
rm "$T/owner.down"; passes 2
[ "$(grep -c told_owner "$SD/stalls.jsonl")" = 1 ] && ok "stall: the owner is told once the message can be sent" || bad "stall owner retry" "$(cat "$SD/stalls.jsonl")"
teardown

# A pi seat's session record says whether its turn has ended.
stall_setup
SS="$OPENRIG_HOME/state/pi/$COD/sessions"; mkdir -p "$SS"
# An older session that ended its turn, under a name that sorts last: the newest file is the one read.
printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"stop"}}' > "$SS/z-older.jsonl"; touch -d '2 hours ago' "$SS/z-older.jsonl"
printf '%s\n' '{"type":"message","message":{"role":"user"}}' '{"type":"message","message":{"role":"assistant","stopReason":"toolUse"}}' > "$SS/a.jsonl"
export FOREMAN_STALL_IDLE=300
passes 1; printf '%s\n' "$(( $(date +%s) - 400 ))" > "$SD/$COD.stall"; passes 1
[ "$(sends "$COD")" = 0 ] && ok "stall: a quiet pane while a tool is running is work, not a stall" || bad "stall mid-turn" "$(cat "$T/rig.calls")"
printf '%s\n' "$(( $(date +%s) - 1300 ))" > "$SD/$COD.stall"; passes 1
[ "$(sends "$COD")" = 1 ] && ok "stall: a tool that has been silent four times as long is nudged after all" || bad "stall hung tool" "$(cat "$T/rig.calls")"
printf '%s\n' '{"type":"message","message":{"role":"assistant","stopReason":"length"}}' '{"type":"compaction"}' 'not json' >> "$SS/a.jsonl"
printf '%s\n' "$(( $(date +%s) - 400 ))" > "$SD/$COD.stall"; passes 1
[ "$(sends "$COD")" = 2 ] && ok "stall: a reply cut off at its limit has ended the turn, and is nudged at the normal time" || bad "stall length stop" "$(cat "$T/rig.calls")"
teardown

stall_setup
mkdir -p "$SD"; ( exec 9>"$SD/lock"; flock -n 9; "$F" unstick "$P" --once >"$T/second.out" 2>&1 9>&- )
grep -q "another watcher is already running" "$T/second.out" && ok "stall: a second watcher for the same crew does nothing while the first holds the lock" || bad "stall lock" "$(cat "$T/second.out")"
teardown

# A nudge that could not be sent does not use up one of the three.
stall_setup
cat > "$T/bin/rig" <<STUB
#!/bin/sh
echo "\$*" >> "$T/rig.calls"
[ "\$1 \$2" = "queue list" ] && cat "$T/queue.json" 2>/dev/null
[ "\$1 \$2" = "send $COD" ] && [ -f "$T/coder.down" ] && exit 1
exit 0
STUB
touch "$T/coder.down"; passes 4; rm "$T/coder.down"
[ "$(cat "$SD/stall-items/$COD/qitem-1")" = "0 0" ] && grep -q "could not be sent" "$SD/log" && ok "stall: a nudge that fails to send is not counted" || bad "stall failed nudge" "$(cat "$SD/stall-items/$COD/qitem-1" 2>&1)"
: > "$T/rig.calls"; passes 5
[ "$(sends "$COD")" = 3 ] && ok "stall: the task still gets its three nudges once sending works" || bad "stall nudges after failure" "$(cat "$T/rig.calls")"
teardown

# State that cannot be trusted or saved must not turn into nudges without end, or stop the watcher.
stall_setup
mkdir -p "$SD/stall-items/$COD/qitem-1"            # the count for this task cannot be written
passes 6
[ "$(sends "$COD")" = 0 ] && grep -q "cannot be saved" "$SD/log" && ok "stall: a nudge count that cannot be saved means no nudge, not nudges without limit" || bad "stall unsaved count" "$(cat "$T/rig.calls" 2>&1)"
teardown

stall_setup
passes 1; printf 'bad\n123' > "$SD/$COD.stall"; printf 'bad\n1 0' > "$SD/$OWN"
printf '❯%sFrom: x --- ↩ Reply: rig send x\n' "$NB" > "$T/pane.$OWN"; "$F" unstick "$P" --once >/dev/null 2>&1; printf 'bad\n1 0' > "$SD/$OWN"
"$F" unstick "$P" --once >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(cat "$SD/$COD.stall" | wc -l)" = 1 ] && ok "stall: a state record with a stray first line is thrown away, and the watcher carries on" || bad "stall multiline state" "rc=$rc $(cat "$SD/$COD.stall")"
teardown

stall_setup
printf 'waiting for the builder\n' > "$T/pane.$OWN"
passes 3
[ "$(sends "$OWN")" = 0 ] && ok "stall: only the builder seat is watched for stalls" || bad "stall owner seat" "$(cat "$T/rig.calls")"
printf 'garbage here\n' > "$SD/$COD.stall"
"$F" unstick "$P" --once >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && ok "stall: an unreadable state record starts over" || bad "stall garbage state" "rc=$rc"
teardown

stall_setup
printf '#!/bin/sh\necho "$*" >> "%s/rig.calls"\n[ "$1 $2" = "queue list" ] && { echo "daemon down" >&2; exit 1; }\nexit 0\n' "$T" > "$T/bin/rig"
"$F" unstick "$P" --once >/dev/null 2>&1; "$F" unstick "$P" --once >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sends "$COD")" = 0 ] && ok "stall: a queue that cannot be read nudges nobody and does not stop the watcher" || bad "stall queue error" "rc=$rc"
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

# --- a seat that needs a person at start ---
setup
"$F" init "$P" >/dev/null; fill checker=codex:gpt-6-astra
printf 'Error: 1 node requires attention before becoming interactive.\n  crew.checker (crew-checker@foreman-my-app): Startup requires attention: Codex is waiting for hook trust approval before the session can become interactive.\n' > "$T/up.fail"
PATH="$PATH:$(dirname "$(command -v jq)")" out="$("$F" up "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && ok "up still reports the failure when a seat needs a person" || bad "up exit code" "$out"
grep -q 'new-session.*foreman-unstick@foreman-my-app' "$T/tmux.calls" 2>/dev/null && ok "up starts the unstick watcher even when a seat needs a person" || bad "unstick watcher after a failed up" "$(cat "$T/tmux.calls" 2>&1)"
echo "$out" | grep -q "tmux attach -t 'crew-checker@foreman-my-app'" && echo "$out" | grep -q "rig seat continue 'crew-checker@foreman-my-app'" && echo "$out" | grep -q 'Trust all and continue' \
  && ok "up names the seat waiting on hook trust and gives the three steps" || bad "hook trust steps" "$out"
rm -f "$T/up.fail" "$T/tmux.calls"
PATH="$PATH:$(dirname "$(command -v jq)")" out="$("$F" up "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ! echo "$out" | grep -q 'waiting for you to trust' && grep -q 'new-session' "$T/tmux.calls" && ok "a clean start prints no trust steps and exits 0" || bad "clean up" "$out"
teardown

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
2|git -C app push origin main
2|git -c user.name=x --no-pager push
2|git push>push.log
2|git remote rm origin
2|pnpm install --frozen-lockfile --offline=false
2|pnpm install --frozen-lockfile --offline-cache
2|pnpm install --frozen-lockfile && echo --offline
2|sleep 1&echo ready
2|nohup>server.log pnpm dev
2|bash -c 'pnpm dev &'
0|cd web && pnpm install --offline --frozen-lockfile --reporter=silent
0|rg 'foo & bar' src
0|printf '%s\n' 'A & B'
0|git -C app status
0|echo "a && b"
0|ls | grep x || true
0|pnpm install --frozen-lockfile --offline && pnpm test
2|pnpm install --frozen-lockfile --offline && pnpm install left-pad
2|git -C "My App" push origin main
2|git -C 'My App' --no-pager push
2|git --git-dir="My App/.git" push
0|git -C "My App" status
0|pnpm install --frozen-lockfile "--offline"
0|pnpm install --frozen-lockfile --offline>install.log
0|pnpm install '--frozen-lockfile' --offline 2>&1
0|bash -c 'printf "%s\n" "A & B"'
0|bash -c "printf '%s' 'A & B'"
2|bash -c "pnpm dev & echo started"
2|bash -c "printf '%s' \"It's done\"; sleep 1 & echo \"We're ready\""
2|git -C My\ App push
2|git --config-env=core.editor=EDITOR push
2|git --config-env core.editor=EDITOR push origin main
2|sudo bash -c 'pnpm dev &'
2|echo $(git push)
0|pnpm install --frozen-lockfile "--offline">install.log
0|pnpm build |& tee build.log
0|pnpm build &> build.log
0|echo "It's fine & dandy" 'and "so" is this & that'
0|git -C My\ App status
0|grep -c "a;b" notes.txt
2|echo "$(git -C repo push)"
2|bash -c 'git -C repo push'
2|sudo sh -c "cd app && git -C . push"
2|echo `git -C repo push`
2|git 2>err push
2|git &>log push
2|sleep 1 & >log
2|pnpm install # --frozen-lockfile --offline
2|git --icase-pathspecs push
2|pnpm install --frozen-lockfile "\--offline"
0|git status # foreground & diagnostic
0|pnpm test 2>err.log >out.log
0|echo $((1 & 3))
0|printf '%s\n' bash -c 'A & B'
0|bash -c 'pnpm install --frozen-lockfile --offline && pnpm test'
0|case $x in a) echo 1 ;& b) echo 2 ;;& esac
0|for f in *.ts; do wc -l "$f"; done | sort -n | tail -3
0|find . -name '*.ts' -exec grep -l 'a & b' {} \; | xargs -r wc -l
0|awk -F'|' '{ if ($1 && $2) print $1 }' data.txt | sed 's/&/and/g'
0|jq '.a | select(.b and (.c | length) > 0)' file.json > out.json
0|FOO=1 BAR="a b" pnpm test -- --grep "x & y"
0|diff <(sort a.txt) <(sort b.txt) || true
0|cat <<< "one & two"
CASES
[ "$allok" -eq 1 ] && ok "the guard blocks the banned commands and lets look-alikes through (85 cases)"
gcheck 0 "$(printf '%s\n' "cat > notes.md <<'END-OF-FILE'" 'A & B' 'END-OF-FILE')" && ok "a here-document may end with a word that has hyphens in it" || bad "here-document word with hyphens"
gcheck 0 "$(printf '%s\n' 'cat <<EOF' ' EOF' 'sleep 1 &' 'EOF')" && ok "an indented end word does not end a here-document opened with <<: what follows is still its text" || bad "indented end word"
gcheck 2 "$(printf '%s\n' 'cat <<-EOF' '	EOF' 'sleep 1 &')" && ok "after <<- a tab-indented end word does end it, and what follows is a command" || bad "tab-indented end word"
big="$(printf '%s\n' "cat > big.txt <<'EOF'"; i=0; while [ $i -lt 4000 ]; do echo "line $i of a big file with & and ; and | in it"; i=$((i+1)); done; echo EOF)"
start="$(date +%s)"; gcheck 0 "$big"; rc=$?; took=$(( $(date +%s) - start ))
[ "$rc" = 0 ] && [ "$took" -le 5 ] && ok "a 180 KB here-document is checked, and in a few seconds" || bad "big here-document" "rc=$rc took=${took}s"
gcheck 0 "$(printf '%s\n' 'pnpm install --frozen-lockfile --off\' 'line')" && ok "a word continued across a backslash line end is one word, as in the shell" || bad "word continuation"
gcheck 2 "$(printf '%s\n' 'cat <<EOF' 'EOF' 'cat <<EOF &' 'text' 'EOF')" && ok "an empty here-document does not hide a background & after it" || bad "empty here-document"
gcheck 2 "$(printf '%s\n' 'pnpm install --frozen-lockfile --offline' 'pnpm install')" && ok "the 'without' words of one line do not cover a command on the next line" || bad "unless across lines"
gcheck 0 "$(printf '%s\n' 'pnpm install \' '  --frozen-lockfile --offline')" && ok "a command continued with a backslash is still one command" || bad "line continuation"
gcheck 2 "$(printf '%s\n' 'cat <<EOF &' 'some text' 'EOF')" && ok "a background & on the line that opens a here-document is still refused" || bad "background on here-document line"
gcheck 0 "$(printf '%s\n' 'cat > a.ts <<EOF' 'type A = B & C' 'EOF' 'cat > b.ts <<EOF' 'type D = E & F' 'EOF')" && ok "two here-documents with & in their text are both left alone" || bad "two here-documents"
gcheck 0 "$(printf '%s\n' 'cat <<A <<B' 'x & y' 'A' 'p & q' 'B')" && ok "two here-documents on one command are both left alone" || bad "two here-documents on one line"
printf '{"bans":[]}\n{"bans":[{"text":"vercel","source":"x"}]}\n' > "$T/two.json"
printf 'ls' | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$T/two.json" --command 2>/dev/null; [ $? -eq 2 ] && ok "a ban file holding two lists is refused whole, not half read" || bad "two-object ban file"
# A here-document is a file being written. Its text is not read as shell operators.
doc="$(printf '%s\n' "cat > draft.ts <<'EOF'" 'type A = B & C;' 'const f = (x) => { return x & 1 }' 'EOF')"
gcheck 0 "$doc" && ok "text inside a here-document is not taken for a background process" || bad "here-document text allowed"
gcheck 2 "$(printf '%s\n' "$doc" 'pnpm dev &')" && ok "a background process after a here-document is still refused" || bad "background after here-document"
gcheck 2 "$(printf '%s\n' "bash <<'EOF'" 'git push origin main' 'EOF')" && ok "a banned command inside a here-document is still refused" || bad "banned command in here-document"
printf '{"tool_name":"Bash","tool_input":{"command":"ls","run_in_background":true}}' | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$B" 2>/dev/null; [ $? -eq 2 ] && ok "a command started in the background is refused" || bad "background flag"
printf '{"tool_name":"Read","tool_input":{"file_path":"vercel.json"}}' | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$B" 2>/dev/null; [ $? -eq 0 ] && ok "tools that are not a shell are not the guard's business" || bad "non-shell tool"
printf '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | PATH="$PATH:$(dirname "$(command -v jq)")" "$G" "$T/nowhere.json" 2>/dev/null; [ $? -eq 2 ] && ok "with no readable ban list the guard refuses, it does not wave commands through" || bad "guard fails closed"
PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" >/dev/null 2>&1
[ "$(jq '.hooks.PreToolUse | length' "$C")" = 2 ] && ok "running bans twice does not add the hook twice" || bad "bans idempotent" "$(cat "$C")"
# a hook of the operator's own in the same group as ours survives an update
jq '(.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks) |= [{"type":"command","command":"my-custom-bash-hook"}] + .' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" >/dev/null 2>&1
[ "$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("my-custom-bash-hook|foreman-guard")) | if test("foreman-guard") then "guard" else "custom" end] | sort | join(",")' "$C")" = "custom,guard" ] \
  && ok "updating the guard keeps another hook that sits in the same group" || bad "sibling hook kept" "$(cat "$C")"
jq 'del(.hooks.PreToolUse[] | select(.hooks | any(.command == "my-custom-bash-hook")))' "$C" > "$C.tmp" && mv "$C.tmp" "$C"
PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" >/dev/null 2>&1
# a crew that moved off claude-code still gets its old claude hook removed by --off
cp "$RIG" "$T/rig.keep"; sed -i 's/runtime: claude-code/runtime: codex/' "$RIG"
# ...and a seat that used to run on pi still loses its extension
XO="$OPENRIG_HOME/state/pi/crew-owner@foreman-my-app/agent/extensions/foreman-guard.ts"; mkdir -p "${XO%/*}"; cp "$X" "$XO"
XE="$OPENRIG_HOME/state/pi/crew-owner@foreman-elsewhere/agent/extensions/foreman-guard.ts"; mkdir -p "${XE%/*}"; cp "$X" "$XE"
PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" --off >/dev/null 2>&1
[ ! -e "$XO" ] && [ -e "$XE" ] && ok "bans --off also clears a seat that used to run on pi, and no other crew's" || bad "bans off former pi seat" "$(ls "$XO" "$XE" 2>&1)"
[ "$(jq -r '[.hooks.PreToolUse[] | .matcher] | join(",")' "$C")" = "Edit" ] && [ ! -e "$P/.codex/hooks.json" ] && [ ! -e "$X" ] && [ ! -e "$B" ] \
  && ok "bans --off removes the guard everywhere and leaves other hooks alone" || bad "bans off" "$(cat "$C"; ls "$P/.codex" "$X" "$B" 2>&1)"
sed -i 's|^banned_cmds: .*|banned_cmds: vercel, supabase|' "$P/.foreman/project.yaml"
out="$(PATH="$PATH:$(dirname "$(command -v jq)")" "$F" bans "$P" 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'must be a list' && ok "a banned_cmds the program cannot read is refused with the right form shown" || bad "bad banned_cmds" "$out"
teardown

# --- builder task files ---
setup
J="$P/.foreman/jobs/fmn-20261121-0900"; mkdir -p "$J"; mkdir -p "$P/src"; printf '.foreman/\n' >> "$P/.git/info/exclude"
out="$("$F" task "$P" fmn-20261121-0900 1 2>&1)"; TF="$J/ctx/code-1.task.md"
[ -f "$TF" ] && grep -q '^## Rules you check by eye$' "$TF" && grep -q 'rule 2: path/to/file.ts:14' "$TF" && ok "task writes a skeleton with both rule lists and the result format" || bad "task skeleton" "$out"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'FILL-ME left' && ok "an unfilled task file is not ready" || bad "unfilled task" "$out"
fill_task() { # fill_task <by-eye lines> <examples>
  awk -v eye="$1" -v ex="$2" '
    /^# code-/ { print "# code-1: screen files (job x)"; next }
    /^FILL-ME: two or three/ { print "Sort each picked file into accepted or rejected."; next }
    /^- `FILL-ME`/ { print "- `src/batch.ts`"; next }
    /^1\. FILL-ME/ { print "1. Export NOT_PDF."; print "2. A file that is not a PDF gets NOT_PDF."; next }
    /^## Rules you check by eye/ { print; sec="eye"; next }
    /^## Examples/ { print; sec="ex"; next }
    /^## / { sec="" }
    $0 == "FILL-ME" && sec == "eye" { print eye; next }
    $0 == "FILL-ME" && sec == "ex" { print ex; next }
    /^`FILL-ME`/ { print "`timeout 120 true`"; next }
    { print }' "$TF" > "$TF.new" && mv "$TF.new" "$TF"; }
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "3. screenFiles has a block doc comment." "none"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'needs its own example' && ok "a check-by-eye rule without an example is refused" || bad "by-eye needs example" "$out"
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "$(printf '3. a\n4. b\n5. c\n6. d')" "Rule 3: x Rule 4: x Rule 5: x Rule 6: x"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'at most 3' && ok "more than three check-by-eye rules are refused" || bad "by-eye cap" "$out"
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "4. numbered wrong." "Rule 4: /** like this */"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'numbered 1, 2, 3' && ok "rules that skip a number are refused" || bad "rule numbering" "$out"
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "$(printf '3. a\n4. b')" "Rule 3: /** like this */"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'rule 4 needs its own example' && ok "each check-by-eye rule needs its own example, not one for all" || bad "example per rule" "$out"
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "3. screenFiles has a block doc comment." "Rule 3:"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'rule 3 needs its own example' && ok "a bare 'Rule 3:' label with nothing after it is not an example" || bad "bare label" "$out"
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "3. screenFiles has a block doc comment." "$(printf 'Rule 3:\n```ts\n```')"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'rule 3 needs its own example' && ok "an empty code block is not an example" || bad "empty fence" "$out"
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "$(printf '3. a\n4. b')" "$(printf 'Rule 3:\nRule 4:\n/** like this */')"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -ne 0 ] && echo "$out" | grep -q 'rule 3 needs its own example' && ! echo "$out" | grep -q 'rule 4 needs' && ok "an example on the lines under its label counts; a label followed straight by the next label does not" || bad "label then label" "$out"
rm -f "$TF"; "$F" task "$P" fmn-20261121-0900 1 >/dev/null; fill_task "3. screenFiles has a block doc comment." "Rule 3: /** Sorts picked files. */"
out="$("$F" task-check "$P" fmn-20261121-0900 1 2>&1)"; [ $? -eq 0 ] && [ "$(jq -c '[.rules,.by_eye,.proved,.eye,.files]' "$J/ctx/code-1.check.json")" = '[3,1,[1,2],[3],["src/batch.ts"]]' ] \
  && ok "a filled task file is ready, and its rules are recorded" || bad "task ready" "$out"
R="$J/out/code-1.md"; printf '/** Sorts picked files. */\nexport const NOT_PDF = 1\n' > "$P/src/batch.ts"
res() { printf 'kind: code\nstatus: %s\ncommand: x\nresult: ok\nfiles: src/batch.ts\n' "$1" > "$R"; shift; printf '%s\n' "$@" >> "$R"; "$F" result-check "$P" fmn-20261121-0900 1 2>&1; }
out="$(res done 'rule 1: command' 'rule 2: command' 'rule 3: src/batch.ts:1')"; [ $? -eq 0 ] && echo "$out" | grep -q 'still yours to check' && ok "a result with evidence for every rule passes, and says the rules are still the owner's to check" || bad "good result" "$out"
out="$(res done 'rule 1: command' 'rule 2: command' 'rule 3: command')"; [ $? -ne 0 ] && echo "$out" | grep -q 'rule 3:.*needs a file and line' && ok "a check-by-eye rule answered with 'command' is refused" || bad "eye rule needs a line" "$out"
out="$(res done 'rule 1: command' 'rule 3: src/batch.ts:1')"; [ $? -ne 0 ] && echo "$out" | grep -q "rule 2: no 'rule 2:' line" && ok "a rule with no answer is refused" || bad "missing rule" "$out"
out="$(res done 'rule 1: command' 'rule 2: command' 'rule 3: src/batch.ts:99')"; [ $? -ne 0 ] && echo "$out" | grep -q 'has no line 99' && ok "a cited line that does not exist is refused" || bad "bad line" "$out"
out="$(res done 'rule 1: command' 'rule 2: command' 'rule 3: src/other.ts:1')"; [ $? -ne 0 ] && echo "$out" | grep -q "not one of the task's files" && ok "evidence in a file outside the task is refused" || bad "outside file evidence" "$out"
echo stray > "$P/src/stray.ts"
out="$(res done 'rule 1: command' 'rule 2: command' 'rule 3: src/batch.ts:1')"; [ $? -ne 0 ] && echo "$out" | grep -q "changed outside the task's files: src/stray.ts" && ok "a file changed outside the task's list is named" || bad "stray file" "$out"
rm "$P/src/stray.ts"
out="$(res stuck 'notes: rule 3 is unclear')"; [ $? -eq 0 ] && echo "$out" | grep -q 'stuck' && [ "$(jq -r .status "$J/out/code-1.check.json")" = stuck ] && ok "a stuck result is accepted as stuck" || bad "stuck result" "$out"
teardown

# A task changed after task-check: the stored facts no longer describe it.
setup
"$F" init "$P" >/dev/null 2>&1; fill
mkdir -p "$P/.foreman/jobs/fmn-1/ctx" "$P/.foreman/jobs/fmn-1/out"
"$F" task "$P" fmn-1 1 >/dev/null; TF="$P/.foreman/jobs/fmn-1/ctx/code-1.task.md"
fill_task "none" "none"; "$F" task-check "$P" fmn-1 1 >/dev/null 2>&1; rc1=$?
printf 'kind: code\nstatus: done\nrule 1: command\nrule 2: command\n' > "$P/.foreman/jobs/fmn-1/out/code-1.md"
sed -i 's|`src/batch.ts`|`src/other.ts`|' "$TF"
out="$("$F" result-check "$P" fmn-1 1 2>&1)"; rc=$?
[ "$rc1" = 0 ] && [ "$rc" -ne 0 ] && echo "$out" | grep -q 'changed after task-check' && ok "result-check refuses a task file that changed after task-check" || bad "stale task" "rc1=$rc1 rc=$rc $out"
teardown

# --- retro and the lessons ledger ---
setup
J="$P/.foreman/jobs/fmn-20261120-0900"; mkdir -p "$J/ctx" "$J/out" "$T/qa/runs/r1" "$T/qa/screener"
printf 'verdict: BLOCK\nround: 1\n' > "$J/out/check-r1.md"; printf 'verdict: PASS\nround: 2\n' > "$J/out/check-r2.md"
printf 'status: stuck\n' > "$J/out/code-1.md"; printf 'status: done\n' > "$J/out/code-2.md"; echo "r1 blocked" > "$J/LOG.md"
echo '{"issue":"fmn-20261120-0900","candidate":"abc"}' > "$J/ctx/qa-r1.json"
echo '{"issue":"fmn-20261120-0900","candidate":"abc"}' > "$T/qa/runs/r1/contract.json"; echo '{"verdict":"fail","gate":"green"}' > "$T/qa/runs/r1/verdict.json"
echo '{"issue":"fmn-20261120-0900","candidate":"abc"}' > "$J/ctx/qa-r2.json"   # a second round, same issue
NOWISH="$(date -u -d '+1 minute' +%FT%TZ)"
printf '%s\n' "{\"at\":\"$NOWISH\",\"issue\":\"fmn-20261120-0900\",\"repo\":\"my-app\",\"decision\":\"send_back\"}" "{\"at\":\"$NOWISH\",\"issue\":\"fmn-20261120-0900\",\"repo\":\"other-project\",\"decision\":\"send_back\"}" "{\"at\":\"$NOWISH\",\"issue\":\"fmn-20261120-0900\",\"repo\":\"my-app\",\"decision\":\"overridden\"}" \
  '{"at":"2020-01-01T00:00:00Z","issue":"fmn-20261120-0900","repo":"my-app","decision":"send_back"}' '{"at":"2020-01-01T00:00:00Z","issue":"fmn-20261120-0900","repo":"my-app","decision":"overridden"}' > "$T/qa/screener/log.jsonl"
# Builder nudges: the watcher's records made since this job's folder began count, older ones do not.
mkdir -p "$OPENRIG_HOME/foreman-unstick/foreman-my-app"
printf '%s\n' '{"at":"2020-01-01T00:00:00Z","seat":"crew-coder@foreman-my-app","item":"q0","nudge":1}' \
  "{\"at\":\"$(date -u -d '+1 minute' +%FT%TZ)\",\"seat\":\"crew-coder@foreman-my-app\",\"item\":\"q1\",\"nudge\":1}" \
  "{\"at\":\"$(date -u -d '+1 minute' +%FT%TZ)\",\"seat\":\"crew-coder@foreman-my-app\",\"item\":\"q1\",\"nudge\":2}" \
  "{\"at\":\"$(date -u -d '+1 minute' +%FT%TZ)\",\"seat\":\"crew-coder@foreman-my-app\",\"item\":\"q1\",\"told_owner\":true}" \
  > "$OPENRIG_HOME/foreman-unstick/foreman-my-app/stalls.jsonl"
out="$(QA_HOME="$T/qa" "$F" retro "$P" fmn-20261120-0900 2>&1)"
[ "$(jq -c '[.coder_nudges,.coder_gave_up]' "$J/retro.json")" = '[2,1]' ] \
  && ok "retro counts the watcher's builder nudges made during the job" || bad "retro nudges" "$(cat "$J/retro.json")"
[ "$(jq -c '[.checker_blocks,.checker_passes,.coder_tasks,.coder_stuck,.qa_contracts,.qa_verdicts,.screener_send_backs,.screener_overruled]' "$J/retro.json")" = '[1,1,2,1,2,["fail at green"],1,1]' ] \
  && ok "retro counts rounds and coder tasks, one verdict per QA run, and screener rows only for this project and since the job began" || bad "retro numbers" "$(cat "$J/retro.json") $out"
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
ln -s "$P/.foreman/project.yaml" "$J/out/link.md"
"$F" lesson "$P" fmn-20261120-0900 owner out/link.md "The evidence for this lesson is a link out of the job folder." >/dev/null 2>&1 && bad "lesson refused: evidence that is a link out of the job folder" || ok "lesson refused: evidence that is a link out of the job folder"
"$F" lesson "$P" fmn-20261120-0900 coder out/code-1.md "The coder stopped and said it was stuck after three tries, as told." >/dev/null 2>&1
"$F" lesson "$P" fmn-20261120-0900 checker out/check-r1.md "The checker ran the verify command before reading any code." >/dev/null 2>&1
out="$("$F" lesson "$P" fmn-20261120-0900 crew LOG.md "A fourth lesson for the same job, which is over the cap of three." 2>&1)"
[ "$(wc -l < "$L")" -eq 3 ] && echo "$out" | grep -q 'cap' && ok "a fourth lesson for one job is refused" || bad "lesson cap" "$out"
out="$("$F" habits "$P" 2>&1)"; echo "$out" | grep -q '3 lessons from 1 jobs' && ok "habits lists the ledger" || bad "habits" "$out"
[ -z "$(git -C "$P" status --porcelain 2>/dev/null | grep -v '^?? .foreman')" ] && ok "retro and lessons change nothing in the repo outside .foreman" || bad "retro touched the repo" "$(git -C "$P" status --porcelain)"
teardown

# --- the front seat: the human's own session, which may reach the lead and nothing else ---
setup
JQP="$PATH:$(dirname "$(command -v jq)")"
"$F" init "$P" >/dev/null; fill
D="$HOME/front/my-app"; mkdir -p "$D/.claude"
echo '{"enabledPlugins":{"mine@me":true},"hooks":{"PreToolUse":[{"matcher":"Edit","hooks":[{"type":"command","command":"my-own-hook"}]}]}}' > "$D/.claude/settings.json"
out="$(PATH="$JQP" "$F" front "$P" --plugin rpi@hl 2>&1)"; rc=$?
S="$D/.claude/settings.json"; B="$D/.foreman-front/bans.json"; G="$T/foreman/scripts/foreman-guard"
[ $rc -eq 0 ] && [ "$(jq -r '.permissions.deny[0]' "$S")" = "Read(/$HOME/.foreman-qa/**)" ] && [ "$(jq -r '.permissions.additionalDirectories[0]' "$S")" = "$P" ] \
  && ok "front writes a folder per project that may read the project and may not read the QA home" || bad "front settings" "$out $(cat "$S" 2>&1)"
[ "$(jq -c '.enabledPlugins' "$S")" = '{"mine@me":true,"rpi@hl":true}' ] && jq -e '[.hooks.PreToolUse[].hooks[].command] | index("my-own-hook") != null' "$S" >/dev/null \
  && ok "front turns the named plugin on and keeps the folder's own settings" || bad "front plugins" "$(cat "$S")"
grep -q 'rig send crew-owner@foreman-my-app "New job' "$D/CLAUDE.md" && grep -qF "$P/.foreman/inbox/" "$D/CLAUDE.md" && ! grep -q '{{' "$D/CLAUDE.md" && [ -d "$P/.foreman/inbox" ] \
  && ok "the front seat's instructions name this project's lead and inbox" || bad "front CLAUDE.md" "$(cat "$D/CLAUDE.md" 2>&1)"
grep -q 'mark its issue done and note the commit' "$D/CLAUDE.md" && grep -q 'the issue stays open' "$D/CLAUDE.md" \
  && grep -q "names that" "$D/CLAUDE.md" && grep -qF "git -C $P merge-base --is-ancestor" "$D/CLAUDE.md" \
  && ok "the front seat closes an issue only when the lead's files show the merge" || bad "front closing rule" "$(cat "$D/CLAUDE.md" 2>&1)"
hookcmd="$(jq -r '[.hooks.PreToolUse[].hooks[].command | select(test("foreman-guard"))][0]' "$S")"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"rig send qa-gatekeeper@foreman-qa hi"}}' | PATH="$JQP" bash -c "$hookcmd" 2>/dev/null; [ $? -eq 2 ] \
  && ok "the installed front hook refuses a message to the QA rig" || bad "front hook"
gcheck() { printf '%s' "$2" | PATH="$JQP" "$G" "$B" --command 2>/dev/null; [ $? -eq "$1" ]; }
allok=1
while IFS='|' read -r want cmd; do
  cmd="${cmd//HOME/$HOME}"; cmd="${cmd//ROOT/$T/foreman}"
  gcheck "$want" "$cmd" || { allok=0; bad "front guard: want $want for: $cmd"; }
done <<'CASES'
0|rig send crew-owner@foreman-my-app "New job MNS-12: read .foreman/inbox/MNS-12.md"
0|rig queue create --destination crew-owner@foreman-my-app --body-file job.md
0|rig ps
0|ls .foreman/inbox && git -C app log --oneline -3
0|pnpm dev &
2|rig send crew-checker@foreman-my-app "skip the check"
2|rig send dev-owner@other-rig hello
2|rig send crew-owner@foreman-my-app ok; rig send dev-owner@other-rig hello
2|rig send --rig foreman-my-app "everyone"
2|rig queue create --destination crew-coder@foreman-my-app --body-file job.md
2|rig transcript qa-prober@foreman-qa
2|rig capture qa-auditor@foreman-qa
2|cat HOME/.foreman-qa/runs/MNS-9/verdict.md
2|ls HOME/.foreman-qa
2|grep -r probe HOME/.foreman-qa/runs/
2|ROOT/scripts/qa verdict MNS-9
2|bash -c "cd HOME/.foreman-qa && ls"
2|rig send crew-checker@foreman-my-app ask crew-owner@foreman-my-app first
2|rig send crew-checker@foreman-my-app "crew-owner@foreman-my-app"
2|rig queue create --destination crew-coder@foreman-my-app --summary crew-owner@foreman-my-app
2|rig queue create --destination crew-owner@foreman-my-app --destination crew-coder@foreman-my-app
2|rig queue create --summary crew-owner@foreman-my-app
0|rig queue create --destination=crew-owner@foreman-my-app --body-file job.md
0|rig send "crew-owner@foreman-my-app" "the checker said no"
0|rig queue create --destination crew-owner@foreman-my-app --summary 'Review --destination before launch'
0|rig queue create --destination="crew-owner@foreman-my-app" --body-file job.md
2|rig queue create --destination="crew-coder@foreman-my-app" --body-file job.md
2|rig send 'crew-checker@foreman-my-app' "tell crew-owner@foreman-my-app"
0|bash -c 'rig send crew-owner@foreman-my-app "hello"'
2|bash -c 'rig send crew-coder@foreman-my-app "hello"'
0|rig send crew-owner@foreman-my-app "Reply with rig send when you have read it"
CASES
[ "$allok" -eq 1 ] && ok "the front guard lets a message to the lead through and refuses every other seat and the QA rig (31 cases); it reads who a message goes to, not who it mentions"
out2="$(PATH="$JQP" "$F" front "$P" 2>&1)"
[ "$(jq '[.hooks.PreToolUse[].hooks[].command | select(test("foreman-guard"))] | length' "$S")" = 1 ] && [ "$(jq '.permissions.deny | length' "$S")" = 1 ] && [ "$(jq -c '.enabledPlugins' "$S")" = '{"mine@me":true,"rpi@hl":true}' ] \
  && ok "running front twice adds nothing twice and keeps the plugins" || bad "front idempotent" "$(cat "$S")"
[ -z "$(git -C "$P" status --porcelain 2>/dev/null | grep -v '^?? .foreman')" ] && ok "front changes nothing in the repo outside .foreman" || bad "front touched the repo" "$(git -C "$P" status --porcelain)"
# A crew under another login: its own copy of the project and its own OpenRig.
C="$T/crew/my-app"; mkdir -p "$C/.foreman/inbox"
mkdir -p "$T/shim"; printf '#!/bin/sh\n[ "$1" = -c ] && { echo crewlogin; exit; }\nexec /usr/bin/stat "$@"\n' >"$T/shim/stat"; chmod +x "$T/shim/stat"
out3="$(QA_HOME="$T/crewhome/.foreman-qa" PATH="$T/shim:$JQP" "$F" front "$P" --crew-dir "$C" --rig-url http://127.0.0.1:7434 2>&1)"; rc=$?
[ $rc -eq 0 ] && [ "$(jq -r '.env.OPENRIG_URL' "$S")" = "http://127.0.0.1:7434" ] && jq -e --arg c "$C/.foreman" '.permissions.additionalDirectories | index($c) != null' "$S" >/dev/null \
  && grep -qF "Write \`$C/.foreman/inbox/<issue id>.md\`" "$D/CLAUDE.md" && grep -qF "$C/.foreman/STATE.md" "$D/CLAUDE.md" \
  && grep -qF "sudo -n -u crewlogin git -C $C merge-base --is-ancestor" "$D/CLAUDE.md" && ! grep -qF "git -C $P merge-base" "$D/CLAUDE.md" \
  && ok "front for a crew under another login: job files go to the crew's copy, rig talks to the crew's OpenRig, and git in the crew's copy runs as the crew's login" || bad "front --crew-dir" "$out3 $(cat "$S" 2>&1)"
ST="sudo -n -u crewlogin /opt/crew/start.sh start"
out3="$(QA_HOME="$T/crewhome/.foreman-qa" PATH="$T/shim:$JQP" "$F" front "$P" --crew-dir "$C" --rig-url http://127.0.0.1:7434 --crew-start "$ST" 2>&1)"
grep -qF "    $ST" "$D/CLAUDE.md" && gcheck 0 "$ST" && gcheck 2 "$ST --force" && gcheck 2 "sudo -n -u crewlogin /opt/crew/start.sh stop" && gcheck 2 "$ST; sudo -u crewlogin bash" \
  && ok "with --crew-start the front seat may run that exact command to start the crew, and no variation of it" || bad "front --crew-start" "$out3 $(cat "$B")"
gcheck 0 "sudo -n -u crewlogin git -C $C merge-base --is-ancestor abc123 main" && gcheck 2 "sudo -n -u crewlogin cat $C/secret" && gcheck 2 "sudo -u crewlogin bash" \
  && ok "with a crew under another login the front guard lets sudo through for the merge check only" || bad "front sudo ban"
out3="$(PATH="$JQP" "$F" front "$P" --crew-dir "$C" 2>&1)"; [ $? -ne 0 ] && grep -q -- "--rig-url" <<<"$out3" && ok "front refuses --crew-dir without --rig-url" || bad "front --crew-dir alone" "$out3"
out3="$(PATH="$JQP" "$F" front "$P" --crew-dir "$C" --rig-url http://127.0.0.1:7434 2>&1)"; [ $? -ne 0 ] && grep -q "belongs to this login" <<<"$out3" && ok "front refuses a crew folder that belongs to the same login" || bad "front same login" "$out3"
out3="$(PATH="$JQP" "$F" front "$P" --crew-dir "$T/nowhere" --rig-url http://127.0.0.1:7434 2>&1)"; [ $? -ne 0 ] && grep -q "must be able to read" <<<"$out3" && ok "front refuses a crew folder it cannot write job files to" || bad "front unreadable crew" "$out3"
PATH="$JQP" "$F" front "$P" >/dev/null 2>&1; [ "$(jq -r '.env.OPENRIG_URL // "none"' "$S")" = none ] && grep -qF "git -C $P merge-base --is-ancestor" "$D/CLAUDE.md" \
  && grep -q "do not try to start it" "$D/CLAUDE.md" && ok "front without --crew-dir goes back to one login" || bad "front back to one login" "$(cat "$S")"
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
