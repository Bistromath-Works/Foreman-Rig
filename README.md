# Foreman

### Or: How to Get Eight Artificial Minds to Build Something Without Arguing About It Forever

> **Foreman is an [OpenRig](https://www.openrig.dev) setup, not a skill.** There is nothing to
> install into Claude Code or Codex. You launch it with OpenRig as a team of seven agents (eight
> with the optional Muse), each in its own terminal, pointed at your own git repository, with
> optional [Langfuse](https://langfuse.com) tracing so you can see what every one of them did.

It is a well-established fact that a single AI coding agent, left to its own devices, will
produce code that works. It will also produce code that is structured in a way that makes
perfect sense to it and absolutely no sense to anyone who has to maintain it six months later,
including, somewhat ironically, itself.

It is a less well-established but equally true fact that if you give *two* AI coding agents the
ability to talk to each other, they will immediately begin disagreeing about architecture and
never stop.

Foreman solves this by doing something remarkably similar to what humans have done on
construction sites for thousands of years: putting one person in charge, giving everyone else a
job title that tells them to stay in their lane, and making sure nobody pours concrete until the
owner has signed the plan.

## The crew

| Seat | Job | What they emphatically do not do |
|---|---|---|
| **Lead** | Runs the job, hands out work one seat at a time, talks to you | Write code, ever, under any circumstances |
| **Architect** | Reads the codebase and writes a plan a cheaper model can build from | Touch source code |
| **Dissenter** | Tries, honestly, to break the plan before anyone builds it | Say "looks good" |
| **Builder** | Builds the approved plan, tests first | Argue about architecture (that ship has sailed) |
| **Reviewer** | Reviews each build round by running things, not by reading and nodding | Fix what it finds |
| **Inspector** | Attacks the finished branch as a whole: seams, security, false confidence | Rubber-stamp anything |
| **Punch List** | Re-runs every check and decides ship or no-ship | Care how hard everyone worked |
| **Muse** *(optional, off by default)* | A senior solutions architect on call when the crew is stuck | Decide anything |

**You choose which model sits in each seat.** Foreman works with any model Claude Code, Codex or
[Pi](https://github.com/earendil-works/pi) can run, which is to say nearly all of them: Anthropic,
OpenAI, anything on OpenRouter, local models through Ollama or vLLM. It ships with every model
blank, because the best crew is the one you can actually pay for.
[docs/models.md](docs/models.md) says what each seat needs, what we ran in it and what we saw,
and shows example crews for one subscription, mixed families, or a single OpenRouter key.

## How a job runs

```
you: "build X"  →  Architect plans  →  Dissenter challenges (2 rounds max)
                →  GATE 1: you approve the plan
                →  Builder builds  →  Reviewer reviews (2 rounds max)
                →  verify command must pass
                →  Inspector audits (2 rounds max)  →  Punch List: ship / no-ship
                →  GATE 3: you approve the merge  →  merged locally into your base branch
```

- **You approve twice**: the plan, and the merge. Nothing merges on silence.
- **Every loop is capped.** When a cap is hit, the lead asks you instead of letting two models
  argue until the heat death of the universe.
- **When the crew is stuck**, the lead asks you, or, if you added one, calls the Muse: if the Architect can't find an approach it
  would defend, or a review loop runs out of rounds. The Muse comes back with two or three
  genuinely different approaches and a pick. It advises; the Architect or you decide.
- **Nothing is pushed or deployed.** The crew is instructed never to push, add remotes or deploy
  (see the safety rails in [docs/how-it-works.md](docs/how-it-works.md)); the job ends with a local
  merge you approved, and shipping it anywhere is your call. Your code is, of course, sent to the
  model providers you choose for the seats.
- **Everything is written down** in `.foreman/jobs/<job-id>/` in your project: the spec, the plan,
  every verdict, every decision. It's kept out of git, so your history stays yours.

More detail: [docs/how-it-works.md](docs/how-it-works.md).

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

scripts/foreman init ~/code/my-app            # add --muse for the optional eighth seat
# fill in every SET-ME in the two files it names: rig.my-app.yaml and ~/code/my-app/.foreman/project.yaml
scripts/foreman check ~/code/my-app           # refuses until nothing is SET-ME, then validates with OpenRig
scripts/foreman tracing ~/code/my-app         # optional: Langfuse tracing (keys from env, see below)
scripts/foreman up ~/code/my-app              # launch the crew
tmux attach -t crew-lead@foreman-my-app       # talk to the lead (Ctrl-b d to leave)
scripts/foreman down ~/code/my-app            # stop the crew
```

Then tell the lead what to build: a path to a spec file, or a plain description. SETUP.md has
the full walkthrough, and [docs/troubleshooting.md](docs/troubleshooting.md) has the known snags.

## Seeing what the crew did

Seven agents produce a lot of conversation. Turn on [Langfuse](https://langfuse.com) tracing
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

## Testing

- `bash tests/run.sh` tests the setup script against stub commands: seconds, no models, no keys.
  CI runs it on every push.
- `examples/smoke/` is a tiny project with a spec and failing acceptance tests. Point a new
  crew at it to prove the whole pipeline works with your models before you trust it with your
  own code. [docs/testing.md](docs/testing.md) has the steps and what a pass looks like.

## Security, briefly

- **The rules are instructions, not a sandbox.** The crew is told never to push, deploy or touch
  anything outside the repo, and `project.yaml` lets you ban more. Models can still break rules.
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
rig.template.yaml       the crew: 7 seats + the optional muse, every runtime and model SET-ME
project.template.yaml   per-project settings: base branch, verify command, protected paths, banned commands
CULTURE.md              rules every seat follows
agents/<seat>/          each seat's role prompt and OpenRig manifest
agents/shared/          OpenRig's shared seat resources (vendored, Apache-2.0)
scripts/foreman         init / check / up / down / tracing
docs/                   models, how it works, observability, testing, troubleshooting
examples/smoke/         a tiny job for proving a new crew end to end
tests/run.sh            tests for scripts/foreman (CI runs them)
CHANGELOG.md            what changed
```

Your filled-in `rig.<project>.yaml` files are gitignored; they never leave your machine.

## Limits, honestly stated

- **One job at a time, one checkout.** The crew shares your working tree and takes turns. No
  parallel builders.
- **One machine.** All seats run where OpenRig runs.
- **Tested on Linux.** It should work on macOS; it has not been tested there yet.
- **Your verify command is the floor.** The crew can only be as sure as the command that proves
  your project works. If you don't have one, the Builder writes tests first, but a real test
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

Keep your agents talking. Keep your Dissenter dissenting. Keep your traces where you can read them.
