# Testing

Two kinds of test, for two different questions.

## 1. Does the setup work? (`tests/run.sh`, seconds, no models)

```bash
bash tests/run.sh
```

Tests `scripts/foreman` against stub `rig`, `claude`, `codex` and `pi` commands, so it needs no
OpenRig daemon, no logins and no API keys: only bash, git and Node. It covers `init`, `check`
(every way a rig or project file can be incomplete), `up`, the git hygiene that keeps OpenRig's
files out of your project, `tracing` on and off, and that every seat in the template has its
role and manifest. It also proves the smoke-test project below is buildable: its acceptance
tests fail on an empty project and pass with a throwaway reference build.

CI runs it on every push and pull request (`.github/workflows/tests.yml`). Run it before you
change anything in `scripts/`, `rig.template.yaml` or `agents/`.

## 2. Does my crew work? (the smoke test, ~15–30 minutes, real models)

`examples/smoke/` is a tiny, dependency-free Node project with a spec (`SPEC.md`: write a
`slugify` function) and eight acceptance tests that fail until someone builds it. Run it once
after setup, and again whenever you change a seat's model.

```bash
cp -r examples/smoke ~/smoke-test
cd ~/smoke-test && git init -q -b main && git add -A && git commit -qm "smoke test"
cd -

scripts/foreman init ~/smoke-test
```

Fill in the rig file with the crew you want to test, and `~/smoke-test/.foreman/project.yaml`
with:

```yaml
base_branch: main
preflight_cmd: none
verify_cmd: node --test
acceptance_tests: test/acceptance
protected_paths: []
banned_cmds: []
```

Then:

```bash
scripts/foreman check ~/smoke-test
scripts/foreman tracing ~/smoke-test      # optional, see observability.md
scripts/foreman up ~/smoke-test
tmux attach -t crew-lead@foreman-smoke-test
```

Tell the lead: `build the job in SPEC.md`.

**What a pass looks like:**

- The lead writes the job up, and every seat takes a turn in order: architect, dissenter,
  Gate 1 (you type `yes`), builder, reviewer, verify, inspector, punch list, Gate 3.
- After you approve Gate 3, `main` has a merge commit, `node --test` passes, and
  `test/acceptance/` is unchanged (`git diff HEAD~1 -- test/acceptance` is empty).
- `.foreman/jobs/<job-id>/` holds the spec, plan, every seat's output and a ledger, and none
  of it is in git.
- No seat asked you anything except the lead.
- With tracing on: traces from every seat that worked, tagged `foreman-smoke-test`.

**What a failure tells you:** a seat that never starts is a runtime, login or model-id problem
([troubleshooting.md](troubleshooting.md)). A seat that starts but stalls is usually a
permission prompt nobody answered. A job that finishes but needed you more than twice is a
model that isn't following its role; try a stronger one in that seat.

Clean up with `scripts/foreman down ~/smoke-test` and delete the folder and its
`rig.smoke-test.yaml`.

## Testing on your own project

The smoke test proves the crew; your own project proves your `verify_cmd`. Before the first
real job, run `verify_cmd` yourself on a clean tree: it must pass. The crew can only be as sure
as that command.
