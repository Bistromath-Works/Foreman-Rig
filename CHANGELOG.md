# Changelog

## Unreleased

- **Rules gate (CF-2, first part).** The QA rig now refuses a job that touches a protected
  file. New repo settings: `protected_paths` (nothing may be added, changed or deleted) and
  `add_only_paths` (new files are fine, existing ones may not change). The gate runs when a
  run starts, on the list of changed files, and is the first row of every verdict. The golden
  tasks now score 8 of 8.

- **Golden tasks (CF-16).** `scripts/golden` plays nine small jobs, eight with one planted
  defect and one clean, through the real QA gates and prints a score. The prober and test
  auditor are stood in for, so the same run always gives the same score. Baseline: 7 of 8
  defects caught, no false alarm; the miss is a broken rule, which nothing checks yet.
  `--screener` adds the live screener. See `golden/README.md`.

- **Retro step and lessons ledger (CF-13, first part).** After every job the owner runs
  `scripts/foreman retro <project> <job-id>`. It counts how the job went (checker blocks, coder
  tasks, QA verdicts, screener send-backs) and writes a retro task. A cheap seat, the coder when
  there is one, reads the job's records and logs up to three lessons with
  `scripts/foreman lesson`, each tied to a file that shows it. Lessons go to
  `<project>/.foreman/habits.jsonl`; `scripts/foreman habits <project>` lists them. This only
  logs. No rule or prompt changes because of a lesson.

- **Screener, first check (CF-14).** `scripts/qa send` can now ask a fast model (TypeSafe's Jev
  through OpenRouter) whether each done-condition item was worked on at all, and refuses to
  queue a QA run when one looks untouched. It can only send a job back; it never passes one,
  and when it cannot run the job goes to QA as before. Off by default: set
  `"screener": "openrouter"` in a repo's QA settings. Contracts gain an optional `done_items`
  list. `scripts/screen report` shows every call beside what the gates found.

- **QA gates run in a sandbox (CF-11).** Every command from a repo's QA settings, and so all
  candidate code, now runs inside bubblewrap: the disk is read-only, the home folder is hidden,
  the environment is cleared, and only the checkout and the evidence folder are writable.
  Candidate code can no longer write a gate result, push to the source repo or read the
  operator's keys. New repo settings `sandbox_ro` and `sandbox_rw` name the tool and cache
  folders a repo needs. **Upgrade:** install `bwrap`, add each repo's tool folders to
  `sandbox_ro`, and have `teardown_cmd` write to `$QA_EVIDENCE`, not `$QA_RUN`. The seats
  themselves still run as your user; see "The sandbox" in `qa/README.md`. The script's own
  unsandboxed steps (reading the repro check, reversing the fix, copying probe checks) now
  happen before any candidate code has run in a checkout, and unsafe sandbox settings are
  refused when a run starts. The script's own git calls ignore the operator's git settings.
  Also fixed: an assertion early in a very long log was missed, an executable repro check
  lost its executable bit, a fix that renames a file could not be reversed, and a checkout
  the candidate had locked was never deleted. The red gate now runs the same bytes and file
  mode as the green gate, and reversing a fix never removes a test that is meant to stay. The mutation gate
  rebuilds its copy from git, so a fix made of line-ending rules reverses correctly. Only the
  repo's own `<QA home>/env/<repo>.env` is readable inside the sandbox. The red gate never
  deletes a base folder to place the repro check, and a repo with a submodule no longer breaks
  the mutation gate.

- **Optional coder seat (CF-12).** `scripts/foreman init <project> --coder` adds a fourth seat
  for a smaller, cheaper model, usually a local one. The owner hands it small, fully specified
  pieces (files it may change, numbered rules, one command that must pass); the coder writes
  them and never commits; the owner reads the whole diff, checks every rule and commits. The
  checker's gate is unchanged. `docs/models.md` has the measurements we picked our coder with
  and the server flags for a local Qwen3.8-27B.

- **QA rig (CF-9).** A separate rig, `foreman-qa`, that receives a candidate from any build rig
  and tries to break it. It has three seats (gatekeeper, prober, test auditor), and its seven gates
  are in code in `scripts/qa`. The verdict is computed from the gate result files in order: a gate
  runs only after the earlier ones passed, runs once, and a gate never run counts as a failure.
  The wall-clock budget caps every command. Build rigs send a JSON contract with
  `scripts/qa send` and get `pass`, `fail`, `cannot_reproduce`, `narrowed` or `budget_exceeded`
  back with evidence. The QA rig clones read-only and never writes product code.
  `tests/qa.sh` covers every verdict on a fixture repo.
- **Foreman crews can use the QA rig.** A new optional `qa_cmd` in `project.yaml` makes the owner
  send each candidate to the QA rig before the checker, and act on the verdict (owner role,
  step 4b). `scripts/qa hook <repo> on` installs a git merge gate: a `foreman/` branch merges
  only when a QA run passed its exact commit. The gate fails closed.

- **The owner closes the class, not only the case (CF-1).** A BLOCK used to end with a fix and a
  regression test for that one bug, so the same kind of mistake could be made elsewhere and the
  checker had to catch it again. In fix rounds the owner now asks, for each HIGH and MED, whether
  an exact check (a lint rule, a type, a test over every caller, a narrower API) can catch the
  whole class, adds it where the verify command runs it, and lists it as a promise so the checker
  tries to get past it. No exact check: one line in `DECISIONS.md` saying why, never a prompt
  rule or a comment in its place. The report names the check.

## 2.0.2 (2026-11-08)

- **Unstick watcher.** OpenRig 0.6.5 delivers a message by pasting it, waiting 200 ms and
  pressing Enter once, without checking that it was sent. On Magnus a checker's PASS sat unsent
  in the owner's prompt for 43 minutes (the watchdog's wake landed on the same unsent line)
  until the human pressed Enter. `scripts/foreman up` now starts `scripts/foreman unstick`, which
  presses Enter for a seat only when its unsent prompt holds an OpenRig message and the pane has
  been still for 60 seconds and the unsent text starts as OpenRig's own (never a human draft, a
  folded paste or a Pi seat); three tries per message, every press logged. `down` stops it. See
  docs/troubleshooting.md, "A seat sits idle with a message in its prompt".

## 2.0.1 (2026-11-08)

- **`.foreman/STATE.md`: the crew's memory across jobs and sessions.** On its first real use the
  new owner asked the human things already settled the day before (which migrations were live,
  a fee schedule already decided), because those answers lived only in a chat and in another
  session's private notes. STATE.md holds what is live, every answer the human has given
  (dated), what waits on the human, what is unverified and open work. The owner reads it on
  boot, writes the human's answers into it the same turn, and updates it after every job; it
  outranks older notes. The auditor checks it against the code.
- `scripts/foreman init` creates it from `state.template.md` and never overwrites it.
- The owner no longer asks "Is this the job?" on every description: it says what it understood
  and starts, and asks only when the goal or scope is genuinely open (a big decision). Writing
  to its `.foreman/` ledger never waits on the checkout lock.

## 2.0.0 (2026-11-07)

Two seats instead of seven. Built from a real run: a Foreman 1 app audited at 58/100 was fixed
by an owner and a checker alone over eleven jobs; see docs/how-it-works.md, "Why two seats".

- **Owner** replaces the lead, architect and builder: one seat that plans, removes before
  adding, builds test-first, merges and talks to the human. It never approves its own work.
- **Checker** replaces the reviewer, inspector and punch list: an independent gate that runs the
  real code against real local services and tries to break a numbered list of promises. HIGH
  and MED block. On big jobs it also checks the plan before code (the dissenter's old job).
- **Auditor** (optional, `init --auditor`) replaces the muse: a whole-repo audit every
  `audit_every` merged jobs, and fresh eyes after a third BLOCK on one job.
- The human is asked only about big decisions, serious failures and domain-specific knowledge.
  Plan and merge gates are gone; pushes and live-system steps (migrations) stay the human's.
- New crew rules: outside facts carry their source and a pinning test; model output is
  validated in code; no push before the migrations a change needs are live; net lines reported
  per job; `RESUME.md` so a fresh session can continue a job.
- `project.yaml` gains `audit_every` (a whole number, or `manual`); `check` asks for it.
- `init --muse` is now `init --auditor`. A 1.x crew can't be resumed: see
  docs/troubleshooting.md, "Upgrading a 1.x crew".

## 1.0.1 (2026-10-27)

- Seats now wait for a queue item from the lead. In the first smoke test, three seats built
  `SPEC.md` on boot and one committed straight to the base branch (the lead caught it).
  `CULTURE.md` now says: on boot, and whenever the queue is empty, do nothing and wait.

## 1.0.0 (2026-10-23)

First release as an [OpenRig](https://www.openrig.dev) setup. Tested with OpenRig 0.6.5 on Linux.

- Seven-seat crew (lead, architect, dissenter, builder, reviewer, inspector, punch list) plus an
  optional muse, off by default (`init --muse`).
- Works with any model: every seat's runtime (`claude-code`, `codex`, `pi`) and model start blank,
  with per-seat advice and example crews in `docs/models.md`.
- `scripts/foreman init | check | up | down | tracing`.
- Optional Langfuse tracing for every seat, Cloud or self-hosted, scoped to one crew
  (`docs/observability.md`).
- `examples/smoke/`: a tiny job for proving a new crew end to end (`docs/testing.md`).

The earlier Claude Relay version of Foreman is archived at
[Bistromath-Works/Code-Foreman](https://github.com/Bistromath-Works/Code-Foreman).
