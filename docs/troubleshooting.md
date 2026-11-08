# Troubleshooting

Known snags, each with its fix. Most were found the hard way.

## `foreman check` says SET-ME is left
That is the point of it. Every seat needs a `runtime` and a `model`, and every field in
`.foreman/project.yaml` needs a value (`none` or `[]` are fine where the comment allows them).

## A Pi seat fails to start, or says the model is unknown
- **Custom providers (Ollama, vLLM, LM Studio…):** OpenRig gives every Pi seat its own agent
  folder (`~/.openrig/state/pi/crew-<seat>@<rig>/agent`) and does not copy your
  `~/.pi/agent/models.json` into it. `scripts/foreman up` links it in before launch. If you
  launched with plain `rig up`, run `scripts/foreman up` instead, or link it by hand and relaunch.
- **OpenRouter:** Pi has OpenRouter built in, but the key has to get through. It must be on the
  daemon's allowlist (`rig config get recovery.provider_auth_env_allowlist`, then `set` it with
  `OPENROUTER_API_KEY` appended) **and** exported in the shell that started the daemon. A key in
  your current shell is not enough: seats inherit the daemon's environment, not yours. After a
  reboot, or a daemon restart from another shell, the key is gone again; `scripts/foreman check`
  catches that on Linux.
- Check the model string exactly: `<provider>/<model id>`, e.g. `openrouter/google/gemini-4-argon`.
- Pi may print `Model not found for provider openrouter. Using custom model id`. The id is then
  sent to OpenRouter as written. That has worked for some models and failed for others; if the
  seat then fails, pick an id that `pi --list-models openrouter` shows (with the key exported).

## `check` warns "permission_policy absent; launch_posture=floor"
Expected. No seat sets a permission policy, so each launches at OpenRig's default floor (for
Claude seats, accept-edits mode). See the next entry.

## Claude seats keep stopping to ask permission
They launch in "accept edits" mode. Switch each Claude seat to auto mode in its pane
(`Shift+Tab` cycles the modes), or approve prompts as they come. A seat waiting on a prompt
looks idle to everyone else, so the owner appears stuck.

## A seat approved another seat's permission prompt
When a seat sits at a prompt for a while, OpenRig may ask another seat to "recover" it, and a
seat can do that with `rig send --dangerously-interact`. The crew rules forbid this: permission
prompts are yours. If it happens anyway, tell that seat to stop, and switch the stuck Claude
seats to auto mode (or approve their prompts) so there is nothing to recover.

## A seat asks whether to start fresh
Answer `y`. Pressing Enter alone means No, and the seat stays in an unprimed state.

## `rig up` refuses: name already running
One rig per name. Stop it first (`scripts/foreman down <project>`), or check `rig ps`.

## Two projects with the same folder name
The rig file is named after the project folder (`rig.<name>.yaml`). If two projects share a
folder name, `scripts/foreman` refuses rather than mixing them up. Rename one folder, or keep a
second clone of this repo for it.

## My project's `AGENTS.md` looks unchanged, but seats see extra instructions
OpenRig writes its instruction blocks into `AGENTS.md` for Codex and Pi seats, and into
`CLAUDE.local.md` for Claude seats; runtimes may also write into `.mcp.json`, `.claude/`,
`.codex/`. Untracked ones are kept out of git via `.git/info/exclude`. If your repo tracks any
of them, `scripts/foreman` marks those files `skip-worktree` (it prints each one) so OpenRig's
additions never show in `git status` or get committed. The flip side: while marked, your own
edits to them are hidden from git too. To edit one for real:
`git update-index --no-skip-worktree <file>`, commit, then run `scripts/foreman init` again.

## A seat hangs after starting a server
Seats must never start dev servers or background processes; the crew rules forbid it, because a
background process outlives the turn and blocks on prompts nobody sees. Your `verify_cmd` may
start and stop a server itself. If a seat broke the rule, stop that process and tell the owner.

## A Codex seat can't reach a local database or service
Codex runs commands in its own sandbox, which may block local network access. Either give that
seat a less restrictive permission policy in your rig file (`permission_policy: builtin:open` or
`builtin:yolo`, at your own risk: read OpenRig's docs on what each allows), or put a different
runtime in that seat.

## The owner started without me
It shouldn't: on boot it says it's ready and waits for a job. If it does start, tell it to stop
and re-read its role.

## The checker or auditor started work on its own
They act only on a queue item from the owner (`CULTURE.md`, "How work moves"). If one starts on
a `SPEC.md` it found in the repo, tell it to stop; the owner's intake check (clean tree, on the
base branch) catches any stray commits.

## A seat sits idle with a message in its prompt
OpenRig hands a message to a seat by pasting it into the prompt, waiting 200 ms and pressing
Enter once. It does not check that the message went in, and sometimes the Enter is lost: the
message sits unsent (often with the watchdog's wake added on the same line) until someone
presses Enter. The crew stalls with nothing waiting on you.

`scripts/foreman up` starts a watcher for this in its own tmux session,
`foreman-unstick@foreman-<project>`. It presses Enter only when the seat's unsent prompt holds an
OpenRig message (the `↩ Reply: rig send` line or the watchdog header; a folded
`[Pasted text #N]` counts only while OpenRig's queue has a pending item for that seat) and the
pane has not changed for 60 seconds. It tries at most three times per stuck message, then
leaves it for you. Every press is logged in `~/.openrig/foreman-unstick/foreman-<project>/log`.
Text you type yourself never carries those markers, so it is left alone.

Not running? Start it with `scripts/foreman unstick <project>` in any terminal, or press Enter
in the seat's pane yourself; that is always safe.

## The owner asks me something I already answered
The answer isn't in `.foreman/STATE.md`, or the owner didn't read it. Answer once more and tell
it to record the answer under "Human answers". A crew launched before 2.0.1 doesn't have the
STATE.md rule: update Foreman, `rig down foreman-<project> --delete`, `scripts/foreman up <project>`
(the ledger and STATE.md stay). Facts only you know, like which migrations are live, belong in
its "Live systems" table.

## Upgrading a 1.x crew
Foreman 2 has different seats, so a 1.x crew can't be resumed. `rig down foreman-<project>
--delete`, delete `rig.<project>.yaml`, run `scripts/foreman init <project>` (add `--auditor` if
you want it), fill in the models, and add `audit_every:` to `.foreman/project.yaml` (`check`
tells you). Old job ledgers in `.foreman/jobs/` stay as they are.

## I changed a model in the rig file and nothing changed
OpenRig reads the rig file only when it first creates the rig. After that, `rig up` resumes the
crew from OpenRig's own records, and edits to `rig.<project>.yaml` are ignored. Two ways out:
- **Start the crew over** (seats lose their conversation, the `.foreman/` ledger stays):
  `rig down foreman-<project> --delete`, then `scripts/foreman up <project>`. If tracing is on,
  run `scripts/foreman tracing <project>` again before `up`: Pi seats get new folders.
- **Swap one seat on a running crew**: `rig seat set-model <session> --model <id> --reason "..."`,
  then `rig snapshot <rig id>`, then `rig seat stop <session> --reason "..."` and
  `rig launch <rig id> crew.<seat> --snapshot-id <that snapshot>`. `rig launch` needs the rig's
  id from `rig ps`, not its name, and the `--snapshot-id` matters: without it OpenRig may pick an
  older automatic snapshot with the old model.

## Traces don't show up in Langfuse
See [observability.md](observability.md), "When traces don't show up".

## `rig` is "not found" in a script or agent shell, but works in my terminal
OpenRig is a Node package. Shells that don't load your Node version manager (nvm, fnm, asdf)
won't find it. Load it first, e.g. `source ~/.nvm/nvm.sh && nvm use <version>`.
