# QA rig

A separate OpenRig rig that receives a candidate change from a build rig and tries to break it.
It never writes product code, never retries on its own, and answers to the issue's done
condition, not to the build rig. One QA rig serves every build rig and every repo.

Build makes it, QA tries to break it, the human approves.

## What runs where

| Piece | What it is | Decides |
| --- | --- | --- |
| `scripts/qa` | The gates and the verdict, in code | Every gate result and the verdict |
| Gatekeeper seat | Receives the contract, runs the gates in order, dispatches the other two seats, hands the verdict back | Nothing; it sequences |
| Prober seat | Writes extra checks from the done condition alone, before reading the code, never the diff | Which cases to probe |
| Test Auditor seat | Once per run: do the tests cover what the issue asked? | The one judgment gate, labelled as one |

### Gates, in order

| # | Gate | Passes when | Otherwise |
| --- | --- | --- | --- |
| 1 | boot | The repo's boot command succeeds on the candidate | fail |
| 2 | red | The repro check **fails with an assertion** on base (check copied onto base) | cannot_reproduce if it passes; fail if it only errors |
| 3 | green | The repro check passes on the candidate | fail |
| 4 | mutation | With the fix reversed (tests kept), the repro check fails again; the repo's mutation tool, if set, passes | narrowed |
| 5 | probe | Every prober check passes, each alone on a pristine copy of the candidate; checks may only add files | fail |
| 6 | suite | The repo's suite and smoke commands pass (smoke may record to `$QA_EVIDENCE`) | fail |
| 7 | audit | The auditor's `audit.md` starts `coverage: covered` | narrowed |

The script enforces the rules a prompt can't. Gates run in order, and only after every earlier
gate passed. Each gate runs once and its result file is never overwritten. A gate that never
ran counts as a failure. The verdict is the first gate that did not pass. Every command is
capped by the run's wall-clock budget. Running out gives `budget_exceeded`, never a partial
pass. Gates 2 to 4 are skipped, and say so, when the contract has no repro check (feature work).

## The contract

The build rig's Lead writes one JSON file per candidate. See `contract.example.json`.

| Field | Meaning |
| --- | --- |
| `repo` | Path or URL the QA rig clones from (read only: it drops the remote) |
| `base` | Commit or branch the change was built from |
| `candidate` | Commit or branch under test |
| `issue` | Linear issue id, e.g. `MNS-42` |
| `done_condition` | Plain-English done, as confirmed by the Lead |
| `repro_check` | Repo-relative path of the failing check, or `""` |
| `budget` | `wall_minutes` (enforced) and `tokens` (recorded only in v0.1) |
| `reply_to` | The seat that gets the verdict, e.g. `crew-owner@foreman-magnus-nova-service` |

Verdicts: `pass`, `fail`, `cannot_reproduce`, `narrowed`, `budget_exceeded`. The verdict file
`runs/<run>/verdict.md` holds the gate table, the done condition, evidence paths and the tail
of the failing log. What the Lead does with each verdict:

| Verdict | Lead's next step |
| --- | --- |
| pass | Reviewer checks, then a PR goes to the human |
| fail | Back to the builder; counts against the retry cap |
| narrowed | Back to whoever wrote the check, with the gap named |
| cannot_reproduce | Comment on the issue; ask the human |
| budget_exceeded | Comment on the issue; tell the human |

## Setup

```bash
scripts/qa init                     # writes rig.qa.yaml (gitignored) and ~/.foreman-qa
# edit rig.qa.yaml: runtime + model for each seat (suggested split below)
scripts/qa repo magnus-nova-service # writes qa/repos/magnus-nova-service.json (gitignored)
# edit that file: the repo's commands (below)
scripts/qa up                       # launches the rig "foreman-qa"
```

Suggested seats: the prober and auditor must be different model families from the build rig's
builder, and from each other where you can.

| Seat | Suggested | Why |
| --- | --- | --- |
| gatekeeper | claude-code, a mid model (Sonnet) | Mostly runs commands; needs to be reliable at OpenRig verbs, not clever |
| prober | pi on a local model on the Spark | Most of the rig's tokens; local keeps them free. If the builder is the same local model, see open questions |
| auditor | pi on `openrouter/google/gemini-…` (or codex) | One short frontier call per run, a family the builder isn't |

Repo settings (`qa/repos/<repo>.json`). Every command runs from the repo's top folder in the
QA rig's own clone. `""` means none. `boot_cmd`, `check_cmd` and `suite_cmd` are required.

| Key | Meaning |
| --- | --- |
| `setup_cmd` | Run in every fresh copy (e.g. `pnpm install --frozen-lockfile`) |
| `boot_cmd` | One-command boot on the candidate. Later: start the verification container |
| `check_cmd` | Runs one check file; `{check}` is replaced by its path. Exit 0 = passes |
| `assertion_pattern` | Regex that a real assertion failure prints (Vitest/Jest: `AssertionError\|expect\(`; pytest: `AssertionError`). A failing check counts as red only if its log matches, so an import or runner error is not taken as the bug. `""` counts any failure |
| `suite_cmd` | The full existing suite |
| `smoke_cmd` | End-to-end smoke; save recordings and screenshots to `$QA_EVIDENCE` |
| `mutation_cmd` | Optional; `{files}` = the files the fix changed; must exit non-zero when too many mutants survive (Stryker: `thresholds.break`) |
| `teardown_cmd` | Stops whatever boot started; always runs before the clones are deleted |
| `test_paths` | Git pathspecs for test files, so the mutation gate can reverse the fix and keep the tests |

## Sending work (the build side)

```bash
scripts/qa send contract.json
```

This checks the contract, copies it to `~/.foreman-qa/inbox/` and creates a queue item for
`qa-gatekeeper@foreman-qa`. The gatekeeper hands the verdict back to `reply_to` as a queue item
whose body is `verdict: <path to verdict.md>`. The two rigs stay separate topologies. They
meet only through the contract file and OpenRig's queue, so any build rig on any substrate can
plug in.

## Hooking up a Foreman crew

Three steps per project, for example Magnus:

1. **Teach the QA rig the repo.** Run `scripts/qa repo magnus-nova-service` and fill in its
   commands. The QA clone has no `.env.local`. If the app needs env values to build or test,
   point `setup_cmd` at a QA-only env file holding only non-secret local values (local Supabase
   URL and anon key). Never copy the project's own `.env.local`: it holds real keys.
2. **Tell the owner.** In the project's `.foreman/project.yaml`, set
   `qa_cmd: /path/to/foreman-rig/scripts/qa`. The owner then sends every candidate to the QA rig
   before the checker (owner role, step 4b). A running owner reads its role at startup, so
   restart the owner seat, or tell it to re-read its role, between jobs.
3. **Make it binding.** Run `scripts/qa hook /path/to/project on`. Git then refuses to merge a
   `foreman/` branch unless a QA run passed that exact commit. A fix after QA changes the
   commit, so it needs QA again. Merges of other branches are untouched. The hook fails closed:
   if it cannot tell what is being merged, or `scripts/qa` is gone, the merge is refused. Add
   `--no-verify` to the project's `banned_cmds`, since that flag skips git hooks. A
   fast-forward merge creates no merge commit and runs no hook, so the owner's role always
   merges with `--no-ff`.

Turn the gate off with `scripts/qa hook /path/to/project off`.

## Not a sandbox (yet)

The gates' rules hold against a seat that follows its role and against a weak or wrong test.
They do not hold against a hostile process. The seats, and the candidate's own code that the
gates run, run as your user. Such a process could write a gate result file by hand, or push to
the source path the contract names. The fix is to run the gates under a separate OS user, or
inside the verification container with no write path to the source (CF-11). Until then, point
the QA rig only at code from your own build rigs.

## Not in v0.1

- **Verification container.** Until it exists, `boot_cmd` and `smoke_cmd` are whatever the repo
  can do on the Spark (local Supabase included).
- **Token budget.** Only wall-clock is enforced; tokens are recorded as not measured.
- **Linear posting.** The QA rig has no Linear token. The build Lead posts the verdict on the
  issue.
- **Watchdog seat.** The budget check and the cleanup are in `scripts/qa`. No cron is needed
  until runs outlive their seats.

## Open questions

- Prober and builder on the same local model: do they share blind spots? Measure it by counting
  probe-gate findings per run. A second local model needs the Spark's memory (see CF-6).
- Mutation survivor threshold: set per repo in its mutation tool's config.
- `cannot_reproduce` caused by a wrong ticket: the Lead comments on the issue and asks.
