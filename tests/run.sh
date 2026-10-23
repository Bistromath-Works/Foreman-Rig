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
  cp -r "$SRC/rig.template.yaml" "$SRC/project.template.yaml" "$SRC/scripts" "$T/foreman/"
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
grep -qxF .foreman/ "$P/.git/info/exclude" && grep -qxF CLAUDE.local.md "$P/.git/info/exclude" && grep -qxF AGENTS.md "$P/.git/info/exclude" \
  && ok "init keeps OpenRig files out of git" || bad "init exclude" "$(cat "$P/.git/info/exclude")"
[ -z "$(git -C "$P" status --porcelain)" ] && ok "project tree stays clean after init" || bad "tree dirty" "$(git -C "$P" status --porcelain)"
"$F" init "$P" >/dev/null 2>&1; [ "$(grep -c '^\.foreman/$' "$P/.git/info/exclude")" = 1 ] && ok "init is idempotent" || bad "init twice duplicated excludes"
teardown

setup
"$F" init "$P" >/dev/null
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'seat architect: runtime=SET-ME model=SET-ME' && echo "$out" | grep -q "'verify_cmd' is still SET-ME" \
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
! grep -q 'muse' <(grep -v '^#' "$RIG") && ok "init leaves the muse out by default, seat and edge" || bad "default no muse" "$(grep -n muse "$RIG")"
grep -q 'id: punchlist' "$RIG" && grep -q 'to: punchlist' "$RIG" && ok "init without the muse keeps the other seats" || bad "no-muse removed too much"
teardown

setup
"$F" init "$P" --muse >/dev/null
grep -q 'id: muse' "$RIG" && grep -q 'to: muse' "$RIG" && ok "init --muse keeps the muse seat and its edge" || bad "--muse" "$(grep -n muse "$RIG")"
teardown

setup
"$F" init "$P" >/dev/null; fill builder=nonsense:x
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "seat builder: runtime 'nonsense'" && ok "check rejects an unknown runtime" || bad "unknown runtime" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill inspector=codex:gpt-6-astra
rm "$T/bin/codex"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "seat inspector uses runtime 'codex'" && ok "check rejects a runtime that is not installed" || bad "missing runtime" "$out"
teardown

setup
"$F" init "$P" --muse >/dev/null; fill muse=pi:openrouter/google/gemini-4-argon
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'provider_auth_env_allowlist OPENROUTER_API_KEY' && ok "check requires the OpenRouter key allowlist" || bad "openrouter allowlist" "$out"
echo '["OPENROUTER_API_KEY"]' > "$T/allowlist"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "check passes once the key is allowlisted" || bad "openrouter allowlisted" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill builder=pi:ollama/glm-5.3:cloud
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && echo "$out" | grep -q 'no .*models.json; fine only if Pi has it built in' && ok "check warns (not refuses) when a non-OpenRouter pi seat has no models.json" || bad "models.json missing" "$out"
mkdir -p "$HOME/.pi/agent" && echo '{}' > "$HOME/.pi/agent/models.json"
out="$("$F" up "$P" 2>&1)"; rc=$?
link="$OPENRIG_HOME/state/pi/crew-builder@foreman-my-app/agent/models.json"
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
"$F" init "$P" >/dev/null; fill lead=SET-ME:SET-ME
sed -i 's/^verify_cmd: none/verify_cmd: SET-ME/' "$P/.foreman/project.yaml"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q 'seat lead' && echo "$out" | grep -q "'verify_cmd' is still SET-ME" && echo "$out" | grep -q 'fill in every SET-ME' \
  && ok "check reports every problem when only some seats are filled" || bad "partial fill" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
sed -i '/^verify_cmd:/d' "$P/.foreman/project.yaml"
sed -i 's/^base_branch: none/base_branch:   # set me/' "$P/.foreman/project.yaml"
awk '/- id: builder/{b=1} b && /model:/{sub(/model: .*/,"model: \"\""); b=0} {print}' "$RIG" > "$RIG.n" && mv "$RIG.n" "$RIG"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "'verify_cmd' is missing" && echo "$out" | grep -q "'base_branch' has no value" && echo "$out" | grep -q 'seat builder: runtime=claude-code model=-' \
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
awk '/--- muse/{skip=1} !skip{print} /--- end muse/{skip=0}' "$RIG" | grep -v 'id: punchlist' > "$RIG.n"; mv "$RIG.n" "$RIG"
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -ne 0 ] && echo "$out" | grep -q "seat 'punchlist' is missing" && ok "check refuses a rig file missing a required seat" || bad "missing seat" "$out"
teardown

setup
"$F" init "$P" >/dev/null; fill
out="$("$F" check "$P" 2>&1)"; rc=$?
[ $rc -eq 0 ] && ok "a crew without the muse passes check" || bad "no-muse check" "$out"
out="$("$F" init "$P" --muse 2>&1)"
echo "$out" | grep -q 'muse ignored' && ok "init --muse on an existing file says it was ignored" || bad "muse existing" "$out"
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
"$F" init "$P" --muse >/dev/null; fill muse=pi:openrouter/google/gemini-4-argon
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
"$F" init "$P" >/dev/null; fill builder=pi:ollama/glm-5.3:cloud
mkdir -p "$HOME/.pi/agent" && echo '{}' > "$HOME/.pi/agent/models.json"
link="$OPENRIG_HOME/state/pi/crew-builder@foreman-my-app/agent/models.json"
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
"$F" init "$P" >/dev/null; fill builder=pi:openrouter/qwen/qwen3-coder-next inspector=codex:gpt-6-astra
touch "$T/claude.plugin"; mkdir -p "$HOME/.codex"; printf '[plugins."tracing@codex-observability-plugin"]\nenabled = true\n' > "$HOME/.codex/config.toml"
mkdir -p "$P/.claude" && echo '{"permissions":{"allow":["Bash(rig queue *)"]},"env":{"KEEP":"1"}}' > "$P/.claude/settings.local.json"
out="$(env $LF "$F" tracing "$P" 2>&1)"; rc=$?
cs="$P/.claude/settings.local.json"; cx="$P/.codex/langfuse.json"; pj="$OPENRIG_HOME/state/pi/crew-builder@foreman-my-app/agent/langfuse.json"
[ $rc -eq 0 ] && node -e '
  const fs = require("fs"), [cs, cx, pj] = process.argv.slice(1).map(f => JSON.parse(fs.readFileSync(f, "utf8")));
  const good = cs.env.LANGFUSE_SECRET_KEY === "sk-test" && cs.env.CC_LANGFUSE_TRACE_TAGS === "foreman-my-app" && cs.env.KEEP === "1"
    && cs.permissions.allow.length === 1 && cx.enabled === true && cx.secret_key === "sk-test" && cx.base_url === "https://lf.example"
    && pj.secretKey === "sk-test" && pj.userId === "crew-builder@foreman-my-app" && pj.environment === "foreman-my-app";
  process.exit(good ? 0 : 1)' "$cs" "$cx" "$pj" \
  && ok "tracing writes keys for claude, codex and each pi seat, keeping other settings" || bad "tracing on" "$out"
[ "$(stat -c %a "$cs" "$cx" "$pj" | sort -u)" = 600 ] && ok "tracing files holding keys are private (600)" || bad "perms" "$(stat -c '%a %n' "$cs" "$cx" "$pj")"
[ -z "$(git -C "$P" status --porcelain)" ] && ok "tracing leaves the project tree clean" || bad "tracing dirty" "$(git -C "$P" status --porcelain)"
grep -q 'crew-builder@foreman-my-app' "$T/pi.installs" && [ "$(wc -l < "$T/pi.installs")" = 1 ] \
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

# --- the smoke-test example project ---

S="$(mktemp -d)"; cp -r "$SRC/examples/smoke/." "$S/"
if (cd "$S" && "$NODE" --test >/dev/null 2>&1); then bad "smoke example: acceptance tests should fail before a build"
else ok "smoke example: acceptance tests fail before the crew builds"; fi
cp "$HERE/smoke-reference.js" "$S/src/slugify.js"
(cd "$S" && "$NODE" --test >/dev/null 2>&1) && ok "smoke example: a reference build passes them (the spec is buildable)" \
  || bad "smoke example reference" "$(cd "$S" && "$NODE" --test 2>&1 | tail -20)"
rm -rf "$S"

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
