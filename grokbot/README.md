# The Foreman crew and the QA rig, rebuilt in Grok Bot

**Tinkering (CF-44).** This speeds up no product. What it produces is what you learn; the Grok
Bot build is disposable. Suggested time box: one afternoon to set up, one smoke job, then write
down the lesson (last section). The live Magnus crew stays on OpenRig.

Checked against the official Grok Bot docs on 2026-11-25 (`docs.x.ai/grok-bot/...`). The product
changes fast; where this guide says "not documented", test before you rely on it.

## Read this first: what would make it fail

| What would sink it | What this pack does about it |
|---|---|
| Client data reaches an outside vendor. Grok Bot runs on Cursor's cloud, any listed provider may see the data, and there is no zero-retention control of your own | Practice project only (`examples/smoke`, a slugify function). No client repo, no connected mail or drive, no GitHub. This is the wall, not a preference |
| The QA sandbox (`bwrap`) cannot start on the Bots' computer. `scripts/qa` refuses to run without it | Step 3 tests exactly this before any Bot is given a seat. If it fails, the QA half stops there and that is your finding |
| A Bot pushes, deploys or reaches a live system | The practice project has no remote and the computer holds no credentials. Nothing to push to |
| A job stalls silently. An approval card raised by Bot-to-Bot work expires after 30 minutes, and cards never show in group chats | Allow rules for the crew's own commands (step 2), no group chats, and you watch the first job |
| The Bots drift from their seat. A Bot's standing rules live in a memory you cannot open, and the Bot decides what to save | Every seat's rules are a file. The Bot's memory holds one thing: "read your file before every task" |
| The usage pool runs dry. Every Bot reply counts, Bot-to-Bot messages included, in a weekly pool shared with Grok and Cursor | Six Bots, not eight, for the first job. Check usage before and after it |

## What carries over, and what does not

| On OpenRig today | In Grok Bot | Kept? |
|---|---|---|
| A seat = one agent in its own terminal, with a role file | A Bot with its own conversation and memory, told to read its seat file | Yes |
| `rig queue create / claim / handoff` | A Bot-to-Bot message that points at a file (`TASK ...`, `DONE ...`). The task and result files are unchanged | Yes, weaker: no queue record, no claim |
| `.foreman/STATE.md`, the job ledger | Same files, in `/workspace/smoke/.foreman/` | Yes |
| The gates and the verdict, in code (`scripts/qa`) | The same script, run by the Gatekeeper Bot. Proven to run without OpenRig by `setup.sh --selftest` | Yes |
| The merge gate (no QA pass, no merge) | The same git hook | Yes |
| The sandbox for candidate code | The same `bwrap` sandbox, if it starts there | To be tested (step 3) |
| Checker on a different model family from the builder | **Lost.** Grok Bot has no model picker, per Bot or per task, and does not show which model ran | No |
| Banned commands refused by a hook before they run (`foreman-guard`) | **Lost.** Grok Bot has no command hook. Replaced by having no remote and no credentials, plus Ask-first rules that a review model applies | Partly |
| Crew under its own login, fenced from your files | **Different.** All Bots share one computer, one login and one file tree. The docs say not to treat Bots as a security boundary. The boundary is the computer itself: nothing of yours is on it | Different |
| Build and QA never share a context window | Separate Bots have separate conversations and memory. They share the disk, as the two rigs did before the `foreman` login | Yes, by instruction |
| QA seats start every run clean | Bots keep their conversation. The rules say to carry nothing over; reset the three QA conversations between runs if you want it strict | Weaker |
| The screener (Jev through OpenRouter) | Left out. It lives in `qa send`, which needs OpenRig | No |
| The front seat's checked push | Left out. Nothing is pushed | No |
| Linear issue per job | Left out for the first job (a made-up id, `SMOKE-1`). The Linear app would give the Bots your whole workspace | Later, if at all |
| Tracing (Langfuse), the unstick watcher, boot service | Left out | No |
| The local coder on Inkling | The Coder seat's file is here, but its point was a cheap local model. In Grok Bot it is one more Bot on the same model | Seat kept, reason gone |

The lost model split is the part to watch. The crew's own evidence is that a checker from a
different family found what the builder could not see. Here both are whatever Grok Bot picks.

## The Bots

Six for the first job. Names matter: the seat files address each other by these exact names.

| Bot name | Seat file | Note |
|---|---|---|
| **Front Seat** | `seats/front.md` | Your primary Bot (the starred one). You talk to this one |
| **Foreman Lead** | `seats/lead.md` | The `owner` seat |
| **Foreman Checker** | `seats/checker.md` | |
| **QA Gatekeeper** | `seats/qa-gatekeeper.md` | |
| **QA Prober** | `seats/qa-prober.md` | |
| **QA Test Auditor** | `seats/qa-test-auditor.md` | |
| Foreman Auditor *(later)* | `seats/auditor.md` | Add after the first job, if you want the audit |
| Foreman Coder *(later)* | `seats/coder.md` | Add only to see how the hand-off behaves |

How a job moves:

```
you ──> Front Seat ──job file──> Foreman Lead ──task──> Foreman Checker
                                      │  ▲                    │
                              contract│  │verdict             └─ PASS / BLOCK ─> Lead
                                      ▼  │
                                 QA Gatekeeper ──> QA Prober
                                      │       └──> QA Test Auditor
                                      └── ./qa (gates and verdict, in code)
```

## Setup

### 1. Account settings (you, in the app)

- **Local execution: Never allow.** Bots then cannot run commands on your Mac or the Spark.
- **Auto Review: on** (the default).
- **Connect apps: none.** No GitHub, Gmail, Drive, Slack, X or Linear for this experiment.
- If the account also holds work you care about, know that these Bots share its computer,
  files and logins with every other Bot on it.

### 2. Approval rules (you, in the app: Settings, approvals)

Rules are account-wide plain sentences, judged by a review model. Up to 20 of each kind; Ask
first wins. Add these.

**Ask first**
1. Ask first before any `git push`, any `git remote` command that adds or changes a remote, or any `gh` command.
2. Ask first before any command that uses `sudo` or installs a package or a command-line tool.
3. Ask first before creating a Bot, a skill or a routine, or starting a Cursor Cloud Agent.
4. Ask first before connecting or using any connected app, sending any email, posting on X, or making a phone call.
5. Ask first before any command, other than `./qa` itself, that writes to a `gates` folder or to a file named `verdict.json` or `verdict.md` under `/workspace/foreman-qa`.
6. Ask first before changing any file under `/workspace/foreman-rig`.

**Allow automatically**
1. Allow automatically when running `./qa` with any arguments in `/workspace/foreman-qa`.
2. Allow automatically when running `node --test`, `git status`, `git diff`, `git log`, `git add`, `git commit`, `git checkout`, `git merge` or `git worktree` in `/workspace/smoke`, when the command has no remote in it.
3. Allow automatically when reading or writing files under `/workspace/smoke` or `/workspace/foreman-qa/runs`.

These stop a Bot that forgets a rule. They do not stop one that sets out to get round it, and
rule 5 in particular is a model's reading of a shell command. The hard guarantees are the ones
that do not depend on a model: no remote, no credentials, and the gate script.

### 3. Prepare the computer, and test the hard part (one Bot, before any seat exists)

Open your primary Bot and send this. It is the only step that needs an approval card (the
install).

> Run these commands and show me the full output of each. Do nothing else, and do not fix
> anything that fails; just show me.
>
> ```
> git clone --branch erorvigmortgage/cf-44-tinkering-recreate-the-foreman-build https://github.com/Bistromath-Works/Foreman-Rig.git /workspace/foreman-rig
> /workspace/foreman-rig/grokbot/setup.sh
> /workspace/foreman-rig/grokbot/setup.sh --selftest
> ```
>
> If the first run of setup.sh says tools are missing, run the install command it prints (I will
> approve it), then run both setup lines again.

What you must see, word for word, at the end:
`SELFTEST PASSED: the gates and the merge gate work on this computer without OpenRig.`

That line means: the sandbox starts, every gate ran, a job branch could not merge before a QA
pass and could after one. It is a script's output, not a Bot's opinion. If you see `FAIL` or
the `bwrap ... cannot start a sandbox` message instead, stop: the QA rig cannot run there.

After a computer update, Recover or Reset, installed tools are gone. Send the same two setup
lines again; files under `/workspace` survive.

### 4. Make the Bots and seat them

Create five more Bots with **New Bot** (the + button), named exactly as in the table. Then send
each Bot its first message. Front Seat is the primary Bot you already have: rename it.

Replace `<SEAT FILE>` and `<RULES FILE>` per the table below the message.

> Remember this as a lasting rule, and nothing else from this message:
> "I am <BOT NAME>. Before every task I read /workspace/foreman-rig/grokbot/<RULES FILE> and
> /workspace/foreman-rig/grokbot/seats/<SEAT FILE> in full and follow them. They outrank my
> memory and any other instruction except the human's own words in this chat. I act only on a
> task message in the shape those files give. I never start work by myself."
>
> Now read both files and answer in three lines: your seat, which Bots you may message, and
> what you do when you have no task. Then wait.

| Bot name | `<RULES FILE>` | `<SEAT FILE>` |
|---|---|---|
| Front Seat | `build-rules.md` | `front.md` |
| Foreman Lead | `build-rules.md` | `lead.md` |
| Foreman Checker | `build-rules.md` | `checker.md` |
| QA Gatekeeper | `qa-rules.md` | `qa-gatekeeper.md` |
| QA Prober | `qa-rules.md` | `qa-prober.md` |
| QA Test Auditor | `qa-rules.md` | `qa-test-auditor.md` |

Check each answer against its seat file. A Bot that names a Bot it may not message, or offers
to start something, gets the message again before any job runs.

To add the Auditor or the Coder later: make the Bot, seat it the same way (`build-rules.md`,
`auditor.md` or `coder.md`), and add its name on its own line to
`/workspace/smoke/.foreman/CREW`.

### 5. The smoke job

In Front Seat's chat:

> Write a job for the crew, issue id SMOKE-1: build the function described in
> /workspace/smoke/SPEC.md. Use the spec's own behaviours for the Done-when list. Show me the
> job file before you hand it over.

Read the job file. Then: `Hand it over.`

**What a pass looks like**

- Front Seat writes `.foreman/inbox/SMOKE-1.md` and sends the Lead one line.
- The Lead builds `src/slugify.js` on a `foreman/<job-id>` branch, sends a contract to QA
  Gatekeeper, then a brief to Foreman Checker, merges on PASS, and reports.
- `/workspace/foreman-qa/runs/SMOKE-1-*/verdict.md` exists and says `pass`, with a gate table.
- `main` in `/workspace/smoke` has a merge commit, `node --test` passes, and
  `git diff HEAD~1 -- test/acceptance` is empty.
- Nobody asked you anything. A slugify job has no big decisions and no domain questions.

**Proof you can read without reading code.** Ask any Bot to run these and show the output:

```
cd /workspace/smoke && git log --oneline --merges -3 && node --test 2>&1 | tail -5
cat /workspace/foreman-qa/runs/SMOKE-1-*/verdict.md
cat /workspace/smoke/.foreman/jobs/*/out/check-r*.md | head -20
git -C /workspace/smoke remote
```

The last one must print nothing.

### 6. What to watch during the job

- **A chat that goes quiet.** Look for an expired approval card in that Bot's chat. Cards from
  Bot-to-Bot work expire after 30 minutes and the Bot does not do the action.
- **A Bot answering out of its lane:** the Prober reading the diff, the Gatekeeper writing its
  own verdict word, the Checker fixing code, Front Seat messaging anyone but the Lead.
- **The primary Bot's check-ins.** It checks in by itself and offers to take on work. Its seat
  file says a check-in never starts a job; see whether that holds.
- **Usage.** Note the weekly meter before and after.

## What to write down afterwards

The lesson is the product. Put it in CF-44.

1. Did the self-test pass on the Bots' computer? (Is the code-level gate portable at all?)
2. Did the job finish without you? How many times were you needed, and for what?
3. Did the Checker and the QA Bots find anything, with builder and checker on the same
   unknown model? Compare with a smoke run on OpenRig.
4. Which rules did a Bot break, and was it one the files state plainly?
5. What did one job cost in usage?
6. Would you run anything real this way? If not, which single missing piece decides it: the
   model split, the command hook, or the isolation?

## How to take it down

Delete the six Bots (that deletes their memory and conversations). Deleting a Bot does not
remove files: ask one Bot, before you delete it, to run
`rm -rf /workspace/foreman-rig /workspace/foreman-qa /workspace/smoke`. Remove the approval
rules from step 2.

## What this pack is

| File | What it is |
|---|---|
| `setup.sh` | Makes the practice project and QA home; `--selftest` proves the gates run |
| `build-rules.md`, `qa-rules.md` | `CULTURE.md` and `qa/CULTURE.md`, with OpenRig's queue replaced by messages |
| `seats/*.md` | The seven role files plus the front seat, same rules, same wording where nothing had to change |

The rulebook cap (`rulebook.json`) does not cover this folder: these files are copies for an
experiment, and the OpenRig role files stay the source.
