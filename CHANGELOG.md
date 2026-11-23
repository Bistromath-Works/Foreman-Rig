# Changelog

## Unreleased

- **The front seat can start a crew that is down (CF-19).** `scripts/foreman front ...
  --crew-start "<command>"` names one command, run as the crew's login, that starts the crew.
  The front seat is told to use it when `rig ps` shows no lead, and the guard lets that exact
  command through and no other `sudo`. A ban can now carry an `allow` list of whole commands.
- **Front seat for a crew under another login (CF-19).** `scripts/foreman front <project>
  --crew-dir <dir> --rig-url <url>`: job files go to the crew's own copy of the project, `rig`
  in the front folder talks to the crew's own OpenRig, and the merge check runs as the crew's
  login. The human's login never runs git inside a folder the crew can write: git would run
  the crew's git settings and hooks as the human.
- **The front seat closes issues (CF-35).** The rigs have no tracker access and a job ends with
  a local merge the tracker never sees, so finished issues stayed open. The front seat now
  checks the lead's files at the start of a session, and marks an issue done, with the commit,
  when they show the job merged. No merge shown, or something waiting on the human: it stays open.
- **Second review of the unpushed work (CF-22).** 20 findings, none high. Fixed, each with a test:
  - *Guard.* A git ban now sees through a quoted folder (`git -C "My App" push`). A new line ends
    a command, so the "without" words of one line no longer cover the next. Quoted words and a
    redirection glued to a word (`"--offline"`, `--offline>log`) are read as the word. A `&` on
    the line that opens a here-document is seen; several here-documents and a quoted `&` inside
    `bash -c '...'` are not mistaken for one. A ban file holding two lists is refused whole.
  - *Front seat.* The guard reads who a message goes to (the first word after `rig send`, the
    value of `--destination`), not whether the lead is mentioned somewhere in it.
  - *Stall watcher.* The three-nudge limit is kept per task, so it survives a pane that cannot
    be read or another task showing in between. A pi seat is only nudged once its session
    record shows the turn has ended (or the pane has been still four times as long), so a
    quiet long command is left alone. Telling the owner is retried until it is sent. One
    watcher per crew at a time.
  - *Screener.* An empty reply now goes to the fallback. The fallback is asked its own
    questions. The size limit counts characters.
  - *Task files.* `result-check` refuses a task file that changed after `task-check`. Each
    check-by-eye rule needs its own example, written "Rule N:".
  - *Retro.* One verdict per QA run; screener rows from before the job began are not counted.
  - *Audit (clu).* A quoted password inside a lesson is caught before anything is sent. A blank
    job id does not count. A proposal that would remove a must-keep line is rejected. Audits
    started together cannot share a record name.
  - *Golden tasks.* A gate that runs out of time is not credited with a catch.
  - `bans --off` also clears seats that used to run on pi.
- **Third review, of those fixes (CF-22).** 15 findings, none high. Fixed:
  - *Guard, rebuilt.* The guard now reads a command the way a shell splits it, into words and
    operators with quotes and backslashes understood, instead of matching patterns over the
    text. That closes this round's cases together: an apostrophe inside a double-quoted
    string hiding a `&`, an empty here-document, `git -C My\ App push`, `git --config-env`,
    a `--destination` inside a quoted message, `--destination="lead"`, and a word continued
    across a backslash line end. It also now sees a banned command inside `$( )`.
  - *Audit.* The ledger is copied once and that copy is both scanned and sent. A password in
    single quotes is caught as well as one in double quotes.
  - *Stall watcher.* A nudge count is saved before the nudge is sent, and nothing is sent if
    it cannot be saved. A state file with a stray first line no longer stops the watcher.
    With no `flock` on the machine the watcher says so.
  - *Task files.* `task-check` reads one copy of the task for its checks and its digest. A
    bare "Rule N:" label with nothing after it is not an example.
  - Three tests that could pass with their fix removed now fail without it.
- **Fourth review (CF-22, CF-35).** 14 findings, none high. Taken:
  - *Guard.* Commands inside a script handed to a shell with `-c`, inside `$( )` and inside
    backquotes are read as commands in their own right, so `bash -c 'git -C repo push'` is
    refused and `bash -c 'rig send <lead> ...'` is allowed. A redirection keeps its number
    (`git 2>err push` is git push). A comment is dropped (`pnpm install # --offline` no longer
    counts the comment's words). `;&` in a `case` and `&` inside `$(( ))` are not background
    jobs. A here-document may end with a hyphenated word, and its end word may be indented
    only after `<<-`. A 180 KB here-document is checked in about a second (it took half a
    minute), and a command too long for a command line is still checked.
  - *Front seat.* An issue is marked done only when the lead's record names that issue, gives
    the merge commit, and the commit is on the base branch.
  - *Stall watcher, task files.* A failed write while undoing a nudge count no longer stops a
    one-shot pass. An empty code block is not an example, and the label needs its colon.
  - Not taken, as limits of a guard against mistakes: a `<<EOF` written inside quotes, a
    message whose text is itself `--destination=...`, and `$'...'` quoting.
- **A stalled builder is nudged (CF-28).** On the second real job the builder stopped mid-task
  five times, once for 1 hour 50 minutes, and nothing noticed. The session record shows why:
  each time, the model used its whole reply limit (8,192 tokens) thinking and the turn ended
  with nothing written. The unstick watcher now also watches the builder: pane unchanged for 5
  minutes with a claimed task still open gets a message naming the task, three times at most,
  then the owner is told once. `scripts/foreman retro` counts the nudges. The docs now say to
  give a local model a reply limit of at least 16,384.
- **The front seat (CF-31).** `scripts/foreman front <project>` makes `~/front/<project name>`:
  a folder for the human's own Claude Code session, where jobs are worked out and written up
  as issues. Its settings let that session message the lead and no other seat, and keep the QA
  rig out of reach (its name, its home folder and its command are refused in shell commands;
  reads of its home folder are denied). Jobs are handed over as files in `.foreman/inbox/`.
  `--plugin <id>` turns a Claude Code plugin on in that folder only. One command per project.
- **Guard: "without" words must be on every command in the line.** `pnpm install
  --frozen-lockfile; pnpm install left-pad` used to pass because only the first command was
  read. A ban can also be marked `anywhere`, matching inside a path.

- **Builder task files, and lines the rulebook must keep (CF-26).** `scripts/foreman task`
  writes a builder task skeleton that splits rules into those the command proves and those
  checked by eye (at most three, each with an example) and carries the result format.
  `task-check` refuses a task that is not ready; `result-check` compares the builder's result
  with the task and the checkout. Not yet in any seat's role. `rulebook.json` gains
  `must_keep`: 29 lines that `scripts/clu rulebook` requires to be present. The retro counts
  builder rules, check-by-eye rules and results that did not match their task.

- **The coder builds by default (CF-25).** With the coder seat, the owner now splits every
  build into coder pieces first and builds a piece itself only for a design choice it cannot
  settle in advance, for schema, money, security or permission logic, or for a protected path,
  with one line in `DECISIONS.md` saying why. Before, the owner built everything except small
  pieces that met a list of conditions.

- **Screener size limit raised to 200,000 characters (CF-14).** The first real job was 98,000
  characters and was skipped three times at the old limit of 60,000. Jev answers a change that
  size in about a second. `SCREEN_MAX_DIFF_CHARS` overrides the limit.

- **Fixes from the review of the 2026-11-20 work (CF-22).** No high-severity findings; the
  medium ones are fixed, each with a test.
  - Command guard: sees through git's options (`git -C app push`), redirects (`git push>log`)
    and `git remote rm`; the "without" form checks whole arguments of the same command; an `&`
    inside quotes is no longer taken for a background process, and `sleep 1&echo` is.
    Updating the guard keeps other hooks in the same group, and `bans --off` cleans up after a
    crew that changed runtime.
  - QA gates: a moved submodule pin is seen by the rules gate and the mutation gate even when
    the repo tells git to ignore submodules; a base named by branch is found when the source
    repo sits on another branch.
  - Screener: an unusable answer also goes to the fallback; the hunk splitter no longer drops
    removed lines that look like headers; one bad optional answer no longer erases the other
    flags; a risk outside 0 to 3 is dropped; an override that cannot be logged still queues.
  - Retro: screener rows are counted once per job and only for this project. The count of QA
    contracts is now called `qa_contracts`. Evidence that is a link out of the job folder is
    refused.
  - Audit: exactly one JSON object is accepted; any job not in the ledger rejects the
    proposal; growth is measured on the file after the change; more key formats are caught and
    ordinary sentences with "token:" are not; records never share a name.
  - Golden runner: a gate that crashes before recording is reported broken, not credited; the
    QA result and the screener result are judged apart; a screener that does not answer fails
    the run.

- **A seat that needs a person no longer stops the launch half way (CF-21).** When OpenRig
  reports a seat waiting at start, `scripts/foreman up` still starts the unstick watcher. For a
  Codex seat waiting to trust a hook it prints the three steps to take.

- **The audit and the rulebook cap (CF-13).** `rulebook.json` lists the instruction files the
  seats are given and caps their total size; `scripts/clu rulebook` fails when it is over.
  `scripts/clu audit <project>` has a model outside both rigs read the lessons ledger and
  propose at most one rulebook change, as a patch. Code checks every proposal: three or more
  jobs, an exact single match, no growth, nothing that looks like a key. It never merges.

- **Screener: rule check, risk ranking and a fallback model (CF-14).** In the same request the
  screener now asks whether the change breaks each rule in `qa/screener.rules.json` and how
  risky each changed hunk is. Both are flags for the reviewer, shown by `scripts/qa send` and
  in the verdict; neither sends a job back. Thresholds for Jev and for the fallback
  `liquid/d1.2-ultra` were measured on the golden tasks and are stored per model. A repo turns
  the fallback on with `screener_fallback`. The golden set gains `secret-added`.

- **Banned commands are refused by the runtime (CF-2, second part).** `scripts/foreman up` now
  writes the built-in bans and the project's `banned_cmds` to `.foreman/bans.json` and hooks
  `scripts/foreman-guard` into each seat: a PreToolUse hook for claude-code and codex, an
  extension for pi. Push, remote changes, `gh`, background processes and listed commands are
  refused before they run. Codex needs the hook trusted once per seat, in `/hooks`. **No seat
  pushes any more, the owner included; the human does.** `banned_cmds` must be a one-line list
  of quoted texts. `scripts/foreman bans <project> [--off]` does the same without a launch.

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
