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
| `done_items` | Optional. The done condition as a list, one checkable item per line. The screener asks about each one |
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
| `teardown_cmd` | Cleans up after the run; always runs before the clones are deleted. `$QA_RUN` is read-only, so write to `$QA_EVIDENCE` |
| `test_paths` | Git pathspecs for test files, in any form git accepts, so the mutation gate can reverse the fix and keep the tests. If reversing would drop a file that is not part of the fix, the gate fails |
| `sandbox_ro` | Folders under your home folder the commands may read, e.g. where node or pnpm live. See "The sandbox" |
| `sandbox_rw` | Folders the commands may write, for a QA-only cache. See "The sandbox" |
| `sandbox_net` | `false` cuts the network off for every command. Default `true` |
| `screener` | `"openrouter"` turns the screener on for this repo. Default `"off"`. See "The screener" |

## Sending work (the build side)

```bash
scripts/qa send contract.json
```

This checks the contract, runs the screener if the repo has it on (below), copies the contract
to `~/.foreman-qa/inbox/` and creates a queue item for
`qa-gatekeeper@foreman-qa`. The gatekeeper hands the verdict back to `reply_to` as a queue item
whose body is `verdict: <path to verdict.md>`. The two rigs stay separate topologies. They
meet only through the contract file and OpenRig's queue, so any build rig on any substrate can
plug in.

## The screener

A fast model check that runs inside `scripts/qa send`, before anything is queued. It exists to
save QA compute on a job that is plainly unfinished. It asks one yes/no question per item in
`done_items` (or about `done_condition` if there are none): was this item worked on at all in
the candidate's diff? If an item looks untouched, the send is refused and the item is named.

| Rule | How it is kept |
| --- | --- |
| It can only send back. It never grants a pass and never replaces a gate | `scripts/screen` has two outcomes, "send back" and "no objection"; the gates run either way after "no objection" |
| Its answer is a judgment | Every line it prints and logs says so |
| The model's answer is checked in code | An answer that is not a number from 0 to 1 for every item is thrown away |
| If it cannot run, the job goes on | Off, no key, no threshold, service down, diff over 60,000 characters: logged as skipped, sent to QA |
| Thresholds are stored per model | `qa/screener.thresholds.json`; a model with no entry does not screen |
| The Lead can overrule it, with a reason | `scripts/qa send <contract> --no-screen "<where the item is done>"`, logged |

It is a direct call to TypeSafe's Jev through OpenRouter (`typesafe/jev-1.14`, pinned). The
candidate's diff, its changed file names and the done-condition items leave the machine. It is
off unless a repo's settings say `"screener": "openrouter"`. Leave it off for any repo whose
code may not leave the machine. The key is `OPENROUTER_API_KEY` in the environment of the seat
that runs `scripts/qa send`.

The threshold (an item is "untouched" below a 30% chance it was worked on) was checked on the
golden tasks (`scripts/golden --screener`). The set has only one untouched item so far, so
treat it as a first reading.

`scripts/screen report` lists every screener call beside the verdict of the QA run on the same
commit, and counts how often QA failed a job the screener had no objection to.

Not built yet: the rulebook check, the risk ranking of changed hunks, a local model for
repos whose code stays on the machine, and the hosted fallback model.

## Hooking up a Foreman crew

Three steps per project, for example Magnus:

1. **Teach the QA rig the repo.** Run `scripts/qa repo magnus-nova-service` and fill in its
   commands. The QA clone has no `.env.local`. If the app needs env values to build or test,
   point `setup_cmd` at a QA-only env file named `~/.foreman-qa/env/<repo>.env` holding only
   non-secret local values (local Supabase URL and anon key). That one file is readable inside
   the sandbox; other projects' env files are not. Never copy the project's own `.env.local`: it holds real keys.
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

## The sandbox

Every command from a repo's settings runs inside a [bubblewrap](https://github.com/containers/bubblewrap)
sandbox, and so does all candidate code, since those commands are what run it. Inside it:

| What | Inside the sandbox |
| --- | --- |
| The checkout being tested | Writable |
| `$QA_EVIDENCE` | Writable |
| The run folder `$QA_RUN` (gate results, verdict, contract, probe checks, audit note) | Read-only |
| The rest of the QA home, other runs included | Hidden |
| The rest of the disk | Read-only |
| Your home folder, `/tmp`, `/run` | Empty scratch space, thrown away after each command |
| Folders in `sandbox_ro`, and the repo's own `<QA home>/env/<repo>.env` | Read-only |
| Folders in `sandbox_rw` | Writable |
| Environment variables | Cleared, except `PATH`, `HOME`, `USER`, `LANG`, `QA_RUN`, `QA_EVIDENCE` |
| Processes | Its own list; anything a command leaves running is stopped when the command ends |

So candidate code cannot write a gate result or the verdict, and cannot write to or push to the
source repo. Of your own files it sees only the folders you name in `sandbox_ro` and
`sandbox_rw`, so name tool folders, never a folder that holds keys or tokens. `tests/qa.sh` has
candidates that try each of these and checks that every one is blocked.

`scripts/qa new` refuses to start a run if `bwrap` is missing or cannot start a sandbox. There
is no switch to run without it.

Because the home folder is hidden, name the tools a repo needs in `sandbox_ro`, for example
`["~/.nvm", "~/.local/bin"]`. A missing tool shows up as "command not found" in the setup log.
Use `sandbox_rw` only for a cache kept for the QA rig alone, such as a pnpm store at
`~/.cache/foreman-qa/pnpm-store`, never for a folder your own work uses.

`scripts/qa new` refuses sandbox settings that would open a hole:

- a folder that is, or holds, the home folder, `/run`, `/tmp`, `/proc`, `/dev` or `/sys`, or
  lies inside `/run`, `/proc`, `/dev` or `/sys`
- any folder that overlaps the QA home
- a writable folder that overlaps this repo's own folder, the repo settings or the source repo
- a path that ends in a space
- any folder inside a writable one
- a `sandbox_net` that is not `true` or `false`

The folders are resolved once, when the run starts. If one has become a link to somewhere else
by the time a later gate runs, that gate's command is refused.

Outside the sandbox, the script runs git without your own git settings, so a filter, diff
driver or hook you have defined is never run on the candidate's files because its
`.gitattributes` names it. Only the first clone uses your settings, since it may need your
credentials, and it checks nothing out.

Outside the sandbox, the script itself only touches a checkout before any candidate code has
run in it. The repro check is read from the candidate commit, the fix is reversed for the
mutation gate, and probe checks are copied in, all before the repo's setup command runs. After
setup a checkout may hold anything, and only sandboxed commands run in it.

Inside the sandbox a checkout's files are writable but its git index is not, so a command that
runs `git add` or `git commit` in the checkout fails. Tests that need git should make their own
repo in a temp folder.

What the sandbox does not cover:

- **The seats.** The gatekeeper, prober and auditor run as your user, outside the sandbox. A
  seat that ignored its role could still write a gate file by hand. Closing that needs the
  seats under a separate OS user.
- **The network.** It is shared by default, so candidate code can reach the internet and
  services on `localhost` (a local Supabase, for example). Set `"sandbox_net": false` in a
  repo's settings to cut the network off for every command. The repo's setup must then work
  offline (`pnpm install --offline` from the QA cache). Otherwise give QA its own local
  database, not one you use.
- **Files anyone on the machine can read.** The disk outside your home folder, `/tmp` and
  `/run` is visible, read-only. That includes the source repo if it lives outside your home
  folder, and any service socket kept outside those folders.
- **Two runs at once.** The checks on sandbox folders assume one run at a time, which is the
  gatekeeper's rule. Two runs with different settings could weaken each other's.
- **A long-lived boot.** A server started by `boot_cmd` stops when that command ends. Start
  what a check needs inside the command that runs it, until the verification container exists.
- **The shared cache.** A `sandbox_rw` cache is shared between runs, so one run could leave
  bad files in it for the next.

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
