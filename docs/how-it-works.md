# How Foreman works

## The shape

Foreman is one OpenRig pod called `crew` with up to eight seats. Each seat is a coding agent in
its own terminal session, named `crew-<seat>@foreman-<project>`. The lead is the hub: every
piece of work goes from the lead to one seat and back. Seats never hand work to each other.

Work moves through OpenRig's queue, not chat:

1. The lead writes a task file under `.foreman/jobs/<job-id>/ctx/` and creates a queue item
   pointing at it.
2. The seat claims the item, reads the files the task names, and writes its result to
   `.foreman/jobs/<job-id>/out/<seat>-r<N>.md`, starting with a header like `verdict: PASS`.
3. The seat hands the item back to the lead, which reads the result and decides the next step.

Only one seat works at a time. All seats share one checkout, so this is what keeps them from
stepping on each other.

## The pipeline

| Step | Who | Ends when |
|---|---|---|
| Intake | lead | You confirm the spec (from a file, or written up from your description) |
| Preflight | lead | `preflight_cmd` exits 0 (skipped if `none`) |
| Plan | architect | A phased plan with machine-checkable done conditions |
| Dissent | dissenter ⇄ architect | PASS, or 2 rounds; leftovers go to you at Gate 1 |
| **Gate 1** | **you** | You type yes, changes or abort |
| Build | builder | Tests first, then code, commits on `foreman/<job-id>` |
| Review | reviewer ⇄ builder | APPROVED, or 2 rounds then you |
| Gate 2 | lead | `verify_cmd` is green (one fix round allowed) |
| Inspect | inspector ⇄ builder | CLEAR, or 2 rounds then you |
| Punch list | punchlist | SHIP, or NO_SHIP with one fix round |
| **Gate 3** | **you** | You type yes; the lead merges into `base_branch` locally |

## The muse

The muse is optional and off by default (`scripts/foreman init <project> --muse` adds it).
Without it, every "call the muse" moment goes straight to you. With it, the muse is called in exactly three cases: the architect's plan says `needs_muse: <problem>`;
a dissent, review or inspect loop hits its cap without agreement; or you ask for it. The lead
gives it the problem, what was tried, the hard constraints and the relevant files. It returns
two or three structurally different approaches, each with the assumption it questions, its
trade-off and the cheapest way to test it, plus a pick. That goes to the architect or builder as
input, or to you. One call per problem; if it doesn't help, you decide.

It works best as a different model family from the architect: when the architect is stuck, it
is often stuck on a framing its own family shares.

## What gets written where

| Path | What | In git? |
|---|---|---|
| `PROJECT/.foreman/project.yaml` | Project settings every seat reads | No (excluded locally) |
| `PROJECT/.foreman/jobs/<job-id>/` | Spec, plan, decisions, ledger, every seat's output | No (remove `.foreman/` from `.git/info/exclude` if you want ledgers committed) |
| `foreman/<job-id>` branch | The builder's commits | Yes, merged at Gate 3 |
| `PROJECT/CLAUDE.local.md`, `AGENTS.md` | OpenRig's instruction blocks for the seats | No (excluded or skip-worktree) |
| `FOREMAN/rig.<project>.yaml` | Your filled-in crew | No (gitignored) |
| `PROJECT/.claude/settings.local.json`, `PROJECT/.codex/langfuse.json` | Langfuse keys, if tracing is on (see [observability.md](observability.md)) | No (excluded; the script refuses otherwise) |

## Safety rails

Written in [CULTURE.md](../CULTURE.md), which every seat receives: no pushes or remotes, no
deploy or cloud CLIs, nothing on your `banned_cmds` list, no edits outside the repo, no commits to
the base branch, no background processes or servers, no edits to acceptance tests or protected
paths, and a denied command is final. These are instructions to the models, so the hard
guarantee is the one you control: run Foreman on a machine and checkout where those rules being
broken would be an annoyance, not a disaster.
