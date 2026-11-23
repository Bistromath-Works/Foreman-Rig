# How Foreman works

## The shape

Foreman is one OpenRig pod called `crew` with two seats, plus an optional auditor and an optional coder. Each
seat is a coding agent in its own terminal session, named `crew-<seat>@foreman-<project>`. The
owner is the hub: it is the only seat that talks to you, and every piece of work goes from the
owner to one seat and back.

Work moves through OpenRig's queue, not chat:

1. The owner writes a task file under `.foreman/jobs/<job-id>/ctx/` and creates a queue item
   pointing at it.
2. The checker (or auditor, or coder) claims the item, reads the files the task names, and writes its
   result to `.foreman/jobs/<job-id>/out/`, starting with a header like `verdict: PASS`.
3. It hands the item back to the owner, which reads the result and decides the next step.

Only one seat works at a time. The checker may review the exact candidate commit in a detached
worktree outside the repo, so it never sees half-edited files.

## Why two seats

Foreman 1 had seven: a lead that never wrote code, an architect, a dissenter, a cheap builder, a
reviewer, an inspector and a punch list. An audit of a real app it built scored it 58/100: dead
code nobody removed, an unsourced fee table that was simply wrong, duplicate helpers, and races
nobody had looked for. The same app was then fixed by two seats, an owner and a checker, over
eleven jobs. What that run showed:

- **The checker that runs real code earned its place.** It found every concurrency defect in the
  run (requests interleaving, a write landing between a check and a use) plus silent fallbacks
  and bad-input bugs, by driving the real handlers against a real local database. All real, no noise.
- **Ownership needs one seat that reads and writes the code.** A lead that never codes owns the
  repo in name only. The owner found problems no audit had flagged because it held the whole
  codebase, and it could change the design mid-job when the checker kept finding holes.
- **The review layers existed to catch a cheap builder.** Put a strong model on building and
  the reviewer, inspector and punch list have little left to do that the checker does not.
- **The human's most valuable moments were domain questions** (which fee schedule applies, which
  categories an AI may pick on its own), not plan approvals.

The dissenter's job (break the plan before the build) lives on as the checker's plan check on
big jobs. The muse's job (fresh eyes when stuck) and a new one (the whole-repo audit) belong to
the optional auditor.

## A job

| Step | Who | Ends when |
|---|---|---|
| Intake | owner | The spec is written; you are asked only if the goal is genuinely open, plus any domain questions, once |
| Measure | owner | It knows the area, what to remove or merge, and the smallest plan |
| Plan check *(big jobs)* | checker | Each objection is fixed or rebutted in `DECISIONS.md` |
| Build | owner | Tests first, verify command green, own diff read once |
| Check | checker | PASS. HIGH and MED block; LOW is advice |
| Fix rounds | owner ⇄ checker | PASS, or a third BLOCK: then redesign (auditor first, if there is one) |
| Merge | owner | Merged locally into `base_branch`, verify green again there |
| Report | owner | You know what shipped, what was caught, net lines, and your steps |

A job is big when it adds a subsystem, changes the database schema, touches money, security,
permissions or stored documents, or changes how data moves between users.

## When you are asked

Three cases only: **big decisions** (a direction you would want to choose), **serious failures**
(a design that will not hold after a redesign, a red baseline, something broken outside the
job), and **domain-specific knowledge** (facts no model can know: your fees, your rules, your
business). Pushes and live-system steps such as database migrations are yours too: the owner
merges locally and tells you what to run and in what order.

## What the crew remembers

Each seat starts with no memory of earlier sessions, and a coding agent's own memory files are
usually stored per folder and per person, so the crew can't rely on them. What carries across
jobs and sessions is `.foreman/STATE.md`, which the owner reads on boot and updates at the end
of every job:

- **Live systems:** what is deployed, and the last migration applied to each live database, with
  who confirmed it. The crew can't see live systems, so without this it has to ask.
- **Human answers:** every domain fact or decision you have given, dated. The owner writes your
  answer there in the same turn, so you are never asked twice.
- **Waiting on the human, not yet verified, open work.**

It outranks older notes in `.foreman/`. The auditor checks it against the code on every audit.
`scripts/foreman init` creates it from a template and never overwrites it.

## The auditor

Optional (`scripts/foreman init <project> --auditor`). Two duties:

- **Audit:** every `audit_every` merged jobs (or `manual`: only when you ask), it reviews the
  whole repository for what per-job checks cannot see: dead and duplicate code, unsourced
  numbers, unvalidated model or user input, silent fallbacks, drift, dependency advisories. It
  scores each area and lists findings; the owner turns them into jobs.
- **Stuck:** after a third BLOCK on one job, the owner hands it the problem before redesigning.
  It returns two or three structurally different approaches and a pick. Advice, never a verdict.

It works best as a different model family from the owner and the checker.

## The coder

Optional (`scripts/foreman init <project> --coder`). A smaller, cheaper model, usually a local
one, that does the building. The owner splits the job into pieces it has fully spelled out,
each with a command that proves it works, and keeps for itself only the pieces that need a
design choice it cannot settle in advance, or that design schema, money, security or permissions.

- The owner writes a task file: the goal, the files the coder may change, the rules as a
  numbered list, and the one command that must pass.
- The coder changes those files, runs the command, checks each rule, and writes a short result
  (`status: done` or `status: stuck`). It never commits and never touches git state.
- The owner reads the whole diff, runs the command itself, checks every rule, and commits. From
  that commit on it is the owner's code. After two failed rounds the owner writes the piece
  itself.

Nothing about the gate changes: the checker still checks the owner's candidate, whoever typed
it. Design, schemas, money, security and anything the task cannot spell out stay with the owner.

## What gets written where

| Path | What | In git? |
|---|---|---|
| `PROJECT/.foreman/project.yaml` | Project settings every seat reads | No (excluded locally) |
| `PROJECT/.foreman/jobs/<job-id>/` | Spec, briefs, verdicts, decisions, `LOG.md`, `RESUME.md` | No, always: the owner writes its ledger while the checker works, so it must never be part of a commit. Files an older setup already tracks under `.foreman/` stay tracked as history and change only on a job branch |
| `PROJECT/.foreman/STATE.md` | What is live, your answers, what waits on you, open work | No |
| `PROJECT/.foreman/audits/` | Auditor reports and the merged-job count | No |
| `PROJECT/.foreman/habits.jsonl` | The lessons ledger: up to three lessons per job from the retro step, each tied to a file in that job's folder. Only logged, never acted on by the crew | No |
| `foreman/<job-id>` branch | The owner's commits | Yes, merged after the checker's PASS |
| `PROJECT/CLAUDE.local.md`, `AGENTS.md` | OpenRig's instruction blocks for the seats | No (excluded or skip-worktree) |
| `FOREMAN/rig.<project>.yaml` | Your filled-in crew | No (gitignored) |
| `PROJECT/.claude/settings.local.json`, `PROJECT/.codex/langfuse.json` | Langfuse keys, if tracing is on (see [observability.md](observability.md)) | No (excluded; the script refuses otherwise) |

## Builder task files

The builder knows only what its task file says, and its typical miss is a rule that nothing
proves, reported as met. Three commands work on that. None of them is in a seat's role yet:
they are built and tested, and the owner's role will point to them after a few jobs have set a
baseline under the builder-first rule.

| Command | What it does |
| --- | --- |
| `scripts/foreman task <project> <job> <n>` | Writes the skeleton of builder task `<n>`: goal, files, rules the command proves, rules checked by eye (at most three, each with an example), the command, and the exact shape of the result |
| `scripts/foreman task-check ...` | Refuses a task file with a blank left, no file, no command, rules out of order, too many check-by-eye rules, or a check-by-eye rule with no example |
| `scripts/foreman result-check ...` | Compares the builder's result with the task and the checkout: every rule answered, a file and line for each check-by-eye rule, the line exists, and nothing changed outside the task's files |

The result format and its rules are written into the task file by the skeleton, so they reach
the builder without adding a line to the rulebook. `result-check` checks the form of the report.
It does not check that a rule is met: the owner still opens each cited line.

## Lessons, the rulebook and the audit

After every job the retro step logs up to three lessons to the project's
`.foreman/habits.jsonl` (see the owner's role, step 8b). Nothing changes because of a lesson.

The **rulebook** is the set of instruction files a seat is given, listed in `rulebook.json`
with a size cap in lines. `scripts/clu rulebook` prints the files and fails when the total is
over the cap, and the tests run it, so a rule can only be added by replacing or merging an old
one. Raising the cap is a decision for the human. `rulebook.json` also lists the lines that
must survive any rewording (`must_keep`): the same command fails if one is gone, so a rule
cannot be lost by tidying the text around it.

`scripts/clu audit <project> [--model <id>]` sends the lessons (one sentence each, no code) and
the rulebook's text to a model outside both rigs, and writes at most one proposal to
`clu/proposals/`, with a patch. It never changes a rule. Code checks the model's answer:

| Check | Why |
| --- | --- |
| The habit is in three or more different jobs, all in the ledger | One bad job is not a habit |
| The text to replace occurs exactly once in one rulebook file | The patch must apply cleanly and mean one thing |
| The new text has no more lines than the old | The rulebook does not grow |
| Neither the ledger nor the new text holds anything that looks like a key | Nothing secret leaves, nothing secret comes back |

A habit a program could catch is listed as "better as a check in code" and gets no rule.
A proposal that fails a check is kept, marked rejected with the reason, so two models can be
compared on the same ledger: run the audit once per model. Taking a proposal means applying
its patch on a branch and opening a pull request for the human.

## Banned commands

`scripts/foreman up` (or `scripts/foreman bans <project>` by itself) writes the project's
`banned_cmds` and Foreman's built-in bans to `.foreman/bans.json`, and makes each seat's runtime
run `scripts/foreman-guard` before every shell command. A banned command is refused before it
starts, and the seat is told why.

| Runtime | How it is hooked | What you do |
| --- | --- | --- |
| claude-code | A PreToolUse hook in the project's `.claude/settings.local.json` | Nothing |
| pi | An extension in the seat's own agent folder | Nothing |
| codex | A PreToolUse hook in the project's `.codex/hooks.json` | Once per codex seat: open it, type `/hooks`, trust the Foreman guard. Until then codex ignores the hook |

Built in: `git push`, `git remote add/set-url/remove/rm/rename`, `gh`, and background processes
(`&`, `nohup`, a tool call started in the background). A `banned_cmds` entry is plain text, or
`"text (without word word)"`, which is banned unless that same command has every one of those
words as a whole argument: `"pnpm install (without --frozen-lockfile --offline)"` lets
`pnpm install --frozen-lockfile --offline` through and stops `--offline=false`.

A ban matches whole words anywhere in the command, so `vercel` stops `npx vercel deploy` and
`bash -c 'vercel'` but not `cat vercel.json`. Git's own options before the subcommand are
looked through, so `git -C app push` is still a push. An `&` inside quotes or inside a
here-document (`<<EOF ... EOF`) is text, not a background process. A banned command inside a
here-document is still refused, since a here-document can be fed to a shell. It also stops `git commit -m "remove vercel"`:
put such a message in a file. The guard stops a seat that forgets or misreads a rule. It does
not stop one that hides the command in a script. If the ban list cannot be read, the guard
refuses every shell command, so a broken setup is loud.


## The front seat

The lead is the only seat that talks to you, in its own terminal. If you would rather work a
job out first, in the app you run Claude Code in, `scripts/foreman front <project>` makes a
folder for that: `~/front/<project name>`. Open it as a project there. Its instructions tell
the session to write the issue (goal, a Done-when list, out of scope), put the job in
`<project>/.foreman/inbox/<issue id>.md`, and tell the lead with one `rig send`.

The folder's settings, not its instructions, keep that session in its lane. The command guard
refuses `rig send` and `rig queue` unless the command names this project's lead, and refuses
any command naming the QA rig, its home folder or `scripts/qa`. A deny rule refuses reading
the QA home. So the build side and the QA side never meet in the front seat's context. Like
the crew's guard, this stops a session that forgets a rule, not one that sets out to get round
it. It covers Claude Code sessions only.

Every project's front seat is made by the same command, so a new project needs nothing rebuilt.
`--plugin <id>` turns a Claude Code plugin on for that folder only (the plugin's marketplace
must already be added on the machine). Running the command again updates the folder and keeps
what you added to its settings.

### A crew under its own login

When the crew runs under another login, with its own copy of the project and its own OpenRig,
make the front folder with both named:

    scripts/foreman front <your copy> --crew-dir <the crew's copy> --rig-url http://127.0.0.1:<port>

Job files then go to the crew's copy, `rig` in the front folder talks to the crew's OpenRig,
and the merge check runs as the crew's login (`sudo -n -u <login> git ...`). Your login needs
to read `<crew's copy>/.foreman` and write `<crew's copy>/.foreman/inbox`, nothing more. As
the crew's login, once:

    setfacl -m u:<you>:--x <folders above the crew's copy that you cannot enter>
    setfacl -R -m u:<you>:rX <crew's copy>/.foreman
    find <crew's copy>/.foreman -type d -exec setfacl -d -m u:<you>:rX {} +
    setfacl -m u:<you>:rwx -m d:u:<you>:rwx <crew's copy>/.foreman/inbox

Never run git inside the crew's copy from your own login, never push to a repository the crew
can write, and never mark either as a git `safe.directory`. Git would run the crew's git
settings and hooks as you, which hands the crew your login. Move commits as bundle files
(`git bundle create`, then `git fetch <file>`).

## Safety rails

Written in [CULTURE.md](../CULTURE.md), which every seat receives: no pushes or remotes, no
deploy or cloud CLIs, nothing on your `banned_cmds` list, no edits outside the repo, no merge into
the base branch without a checker PASS, no background processes or servers, no edits to acceptance tests or protected
paths, and a denied command is final. These are instructions to the models, so the hard
guarantee is the one you control: run Foreman on a machine and checkout where those rules being
broken would be an annoyance, not a disaster.
