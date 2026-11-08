# How Foreman works

## The shape

Foreman is one OpenRig pod called `crew` with two seats, three with the optional auditor. Each
seat is a coding agent in its own terminal session, named `crew-<seat>@foreman-<project>`. The
owner is the hub: it is the only seat that talks to you, and every piece of work goes from the
owner to one seat and back.

Work moves through OpenRig's queue, not chat:

1. The owner writes a task file under `.foreman/jobs/<job-id>/ctx/` and creates a queue item
   pointing at it.
2. The checker (or auditor) claims the item, reads the files the task names, and writes its
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

## What gets written where

| Path | What | In git? |
|---|---|---|
| `PROJECT/.foreman/project.yaml` | Project settings every seat reads | No (excluded locally) |
| `PROJECT/.foreman/jobs/<job-id>/` | Spec, briefs, verdicts, decisions, `LOG.md`, `RESUME.md` | No, always: the owner writes its ledger while the checker works, so it must never be part of a commit. Files an older setup already tracks under `.foreman/` stay tracked as history and change only on a job branch |
| `PROJECT/.foreman/STATE.md` | What is live, your answers, what waits on you, open work | No |
| `PROJECT/.foreman/audits/` | Auditor reports and the merged-job count | No |
| `foreman/<job-id>` branch | The owner's commits | Yes, merged after the checker's PASS |
| `PROJECT/CLAUDE.local.md`, `AGENTS.md` | OpenRig's instruction blocks for the seats | No (excluded or skip-worktree) |
| `FOREMAN/rig.<project>.yaml` | Your filled-in crew | No (gitignored) |
| `PROJECT/.claude/settings.local.json`, `PROJECT/.codex/langfuse.json` | Langfuse keys, if tracing is on (see [observability.md](observability.md)) | No (excluded; the script refuses otherwise) |

## Safety rails

Written in [CULTURE.md](../CULTURE.md), which every seat receives: no pushes or remotes, no
deploy or cloud CLIs, nothing on your `banned_cmds` list, no edits outside the repo, no merge into
the base branch without a checker PASS, no background processes or servers, no edits to acceptance tests or protected
paths, and a denied command is final. These are instructions to the models, so the hard
guarantee is the one you control: run Foreman on a machine and checkout where those rules being
broken would be an annoyance, not a disaster.
