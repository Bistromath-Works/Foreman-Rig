# Foreman

### Or: How to Get Two Artificial Minds to Build Something Without Diffusing the Blame

> **Foreman is an [OpenRig](https://www.openrig.dev) setup, not a skill.** There is nothing to
> install into Claude Code or Codex. You launch it with OpenRig as two agents (plus an optional
> auditor and an optional coder), each in its own terminal, pointed at your own git repository, with optional
> [Langfuse](https://langfuse.com) tracing so you can see what each of them did.

Foreman 1 put seven agents on a job site: a lead who never touched the work, an architect who
planned it, a cheap builder who built it, and four more seats to catch what the builder got
wrong. Every seat did its job. Nobody owned the result. Code piled up that nothing removed,
numbers appeared that nobody could source, and the problems that grew *between* jobs were
nobody's job at all.

Foreman 2 keeps the part that worked (a strong, independent checker that runs the real code and
tries to break it) and gives everything else to one seat that owns the whole repository.

## The crew

| Seat | Job | What it emphatically does not do |
|---|---|---|
| **Owner** | Owns the repo. Plans, removes before adding, builds test-first, writes the checker a numbered list of promises, merges, talks to you | Approve its own work |
| **Checker** | Runs the real code against your real local services and tries to break each promise: races, silent fallbacks, bad input, half-finished retries. Also challenges the plan on big jobs | Fix what it finds |
| **Auditor** *(optional)* | Audits the whole repo every few jobs (dead code, duplicates, unsourced numbers, drift), and gives fresh eyes when a job is stuck | Decide anything |

**You are asked about three things only: big decisions, serious failures, and domain-specific
knowledge.** A fee schedule, a legal rule, how your business actually works: the owner asks
rather than guesses. Everything else it decides and tells you what it decided.

**You choose which model sits in each seat.** Foreman works with any model Claude Code, Codex or
[Pi](https://github.com/earendil-works/pi) can run. It ships with every model blank.
[docs/models.md](docs/models.md) says what each seat needs and what we ran.

## How a job runs

```
you: "build X"  →  owner reads the area, lists what to remove, plans
                →  (big jobs) checker tries to break the plan
                →  owner builds, test-first, verify command green
                →  owner writes numbered promises  →  checker: PASS or BLOCK
                →  BLOCK: fix, re-check (after a 3rd BLOCK: redesign, not patch)
                →  PASS: owner merges locally, re-runs verify on the base branch
                →  owner reports: what shipped, what was caught, net lines, your steps
```

- **Nothing merges without the checker's PASS.** HIGH and MED findings block; LOW is advice.
- **Outside facts carry their source.** A rate or fee the code uses gets a comment naming where
  it came from and a test that pins it. No source: the owner asks you.
- **Nothing is pushed or deployed without you.** The job ends with a local merge. No seat
  pushes: each seat's runtime refuses it. You push, after any database migration the change
  needs is live.
- **Everything is written down** in `.foreman/jobs/<job-id>/`: the spec, every brief, every
  verdict, every decision, and a `RESUME.md` a fresh session can pick the job up from.
- **You answer once.** `.foreman/STATE.md` is the crew's memory across jobs and sessions: what is
  live, every answer you have given, what waits on you. The owner reads it on boot and writes
  your answers into it the turn you give them.

More detail: [docs/how-it-works.md](docs/how-it-works.md). Why it changed:
[CHANGELOG.md](CHANGELOG.md).

## Setting it up

### The easy way: ask your agent

Open Claude Code or Codex in any terminal and paste this, with your project's path:

> Set up Foreman from https://github.com/Bistromath-Works/Foreman-Rig for my project at
> `~/code/my-app`. Clone it to `~/foreman` if it isn't there yet, then follow its SETUP.md.

The agent checks what you have installed, asks which AI providers you use, proposes a model for
each seat, works out your project's test command with you, and launches the crew. It asks before
installing anything and never writes API keys into files. A few steps need your hands (switching
a seat's permission mode, approving a prompt), and it will tell you exactly when.

### The hands-on way

You need [OpenRig](https://www.openrig.dev) with its daemon running (tested on 0.6.5), Node 20+,
tmux, and at least one of [Claude Code](https://docs.anthropic.com/en/docs/claude-code), [Codex](https://github.com/openai/codex)
or [Pi](https://github.com/earendil-works/pi), logged in.

```bash
git clone https://github.com/Bistromath-Works/Foreman-Rig ~/foreman
cd ~/foreman

scripts/foreman init ~/code/my-app            # optional seats: --auditor, --coder
# fill in every SET-ME in the two files it names: rig.my-app.yaml and ~/code/my-app/.foreman/project.yaml
scripts/foreman check ~/code/my-app           # refuses until nothing is SET-ME, then validates with OpenRig
scripts/foreman tracing ~/code/my-app         # optional: Langfuse tracing (keys from env, see below)
scripts/foreman up ~/code/my-app              # launch the crew (and the unstick watcher)
tmux attach -t crew-owner@foreman-my-app      # talk to the owner (Ctrl-b d to leave)
scripts/foreman down ~/code/my-app            # stop the crew
```

Then tell the owner what to build: a path to a spec file, or a plain description. SETUP.md has
the full walkthrough, and [docs/troubleshooting.md](docs/troubleshooting.md) has the known snags.

## Seeing what the crew did

Turn on [Langfuse](https://langfuse.com) tracing
and every seat's model calls, tool calls, tokens and cost land in one place, tagged by crew and
seat. Langfuse Cloud or your own self-hosted Langfuse both work.

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-... LANGFUSE_BASE_URL=https://cloud.langfuse.com
read -rs LANGFUSE_SECRET_KEY && export LANGFUSE_SECRET_KEY
scripts/foreman tracing ~/code/my-app         # then restart the crew
```

It is scoped to that one crew, the keys go only into private files git ignores, and
`--off` takes it all out again. Setup for each runtime's plugin, privacy and "is it working?":
[docs/observability.md](docs/observability.md).

## The QA rig (optional)

`qa/` is a second, separate rig that receives a candidate from a build rig and tries to break it:
boot, red on base, green on candidate, mutation, probe, suite, audit. The gates and the verdict
are code (`scripts/qa`), so no seat can skip a gate or argue a red one green. Build rigs hand it
a contract file and get a verdict back. See [qa/README.md](qa/README.md).

## Testing

- `bash tests/run.sh` tests the setup script against stub commands: seconds, no models, no keys.
  CI runs it on every push.
- `bash tests/qa.sh` tests the QA rig's gates and verdicts on a fixture repo with a planted bug.
  CI runs it too.
- `examples/smoke/` is a tiny project with a spec and failing acceptance tests. Point a new
  crew at it to prove the whole flow works with your models before you trust it with your
  own code. [docs/testing.md](docs/testing.md) has the steps and what a pass looks like.

## Security, briefly

- **Banned commands are refused, but this is not a sandbox.** `scripts/foreman up` makes each
  seat's runtime ask a guard before every shell command: push, remote changes, `gh`,
  background processes and everything on `banned_cmds` are refused before they run (see
  "Banned commands" in docs/how-it-works.md). That stops a seat that forgets a rule, not one
  that sets out to get round it. The other rules are instructions, and models can break them.
  Run Foreman where a broken rule is an annoyance, not a disaster: a machine and a checkout
  without production credentials.
- **Keys never go in this repo or your project's git.** Model keys reach seats through the
  OpenRig daemon's environment; Langfuse keys go into private, git-ignored files, and
  `scripts/foreman` refuses to write them anywhere git could commit them.
- **Your code goes to the providers you choose**, and to Langfuse if you turn tracing on.
- **OpenRig's daemon has no login.** Keep it on loopback or a private network you trust (see
  OpenRig's docs on `daemon.host`); never expose its port to the internet.

## What's in this repo

```
README.md               you are here
SETUP.md                setup instructions written for an AI agent to follow
rig.template.yaml       the crew: owner, checker, the optional auditor and coder, every runtime and model SET-ME
project.template.yaml   per-project settings: base branch, verify command, protected paths, banned commands, audit cadence
state.template.md       the starting STATE.md: the crew's memory across jobs (live systems, your answers, open work)
CULTURE.md              rules every seat follows
agents/<seat>/          each seat's role prompt and OpenRig manifest
agents/shared/          OpenRig's shared seat resources (vendored, Apache-2.0)
scripts/foreman         init / check / up / down / tracing
docs/                   models, how it works, observability, testing, troubleshooting
examples/smoke/         a tiny job for proving a new crew end to end
tests/run.sh            tests for scripts/foreman (CI runs them)
qa/                     the QA rig: a separate rig that tries to break a candidate (qa/README.md)
agents/qa-*/            the QA rig's seats: gatekeeper, prober, test auditor
scripts/qa              the QA rig's gates and verdict, in code
tests/qa.sh             tests for scripts/qa (CI runs them)
CHANGELOG.md            what changed
```

Your filled-in `rig.<project>.yaml` files are gitignored; they never leave your machine.

## Limits, honestly stated

- **One job at a time, one checkout.** The crew shares your working tree and takes turns.
- **One machine.** All seats run where OpenRig runs.
- **Tested on Linux.** It should work on macOS; it has not been tested there yet.
- **Your verify command is the floor.** The crew can only be as sure as the command that proves
  your project works. If you don't have one, the owner writes tests first, but a real test
  suite beats an improvised one.

## Earlier versions

Foreman began as a Claude Code skill built on [Claude Relay](https://github.com/innestic/claude-relay)
by [Innestic](https://github.com/innestic), which let headless Claude Code sessions talk to each
other. That version lives on, archived, at
[Bistromath-Works/Code-Foreman](https://github.com/Bistromath-Works/Code-Foreman). OpenRig now
does the talking, remembering and supervising, and Foreman gets to be just the job site.

## License

MIT, © 2026 Bistromath Works. The vendored OpenRig files in `agents/shared/` are Apache-2.0.
Do with it what you will. If you build something wonderful with it, that is its own reward. If
you build something terrible, we would prefer not to know, but we acknowledge your right to do so.

---

*"The major difference between a thing that might go wrong and a thing that cannot possibly go
wrong is that when a thing that cannot possibly go wrong goes wrong it usually turns out to be
impossible to get at or repair."*

Keep one agent owning it. Keep the other one trying to break it. Keep your traces where you can read them.
