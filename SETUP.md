# Setting up Foreman (instructions for the AI agent doing the setup)

You are a coding agent (Claude Code, Codex or similar) helping a person set up Foreman for one of
their git repositories. Foreman is an **OpenRig setup**: a team of seven agent seats (eight with the
optional Muse) that OpenRig
launches in separate terminals. It is not a skill and nothing gets installed into your own runtime.

The person may not be comfortable in a terminal. You run the commands; they make the decisions.

## Ground rules

- **Ask before installing anything** (OpenRig, Claude Code, Codex, Pi, Node). Say what and why.
- **Never write an API key into any file**, including the rig file, `project.yaml`, shell rc
  files or notes. Keys reach seats only through the OpenRig daemon's environment (step 5).
  The one exception is Langfuse tracing (step 5b): the person's own run of
  `scripts/foreman tracing` writes those keys into private, git-ignored files. You never see them.
- **Never push, publish or touch remotes.** Setup is local.
- **Confirm before you launch** (step 7) and before restarting the OpenRig daemon (step 5): other
  rigs may be running on it.
- **Don't guess project facts.** Propose values from what you read in the repo, then confirm
  them with the person. A wrong verify command makes the whole crew wrong.
- Keep messages short and plain. One decision at a time where you can.

Throughout, `FOREMAN` is the folder this file is in and `PROJECT` is the absolute path of the
person's repository.

## 1. Check what is installed

Run, and report the results as a short list:

```bash
rig --version            # OpenRig: needs 0.6.5 or later (see the note below if "not found")
rig daemon status        # must be running; if not: rig daemon start
claude --version         # optional: runtime "claude-code"
codex --version          # optional: runtime "codex"
pi --version             # optional: runtime "pi" (OpenRouter, Ollama, vLLM, any OpenAI-compatible API)
git -C "$PROJECT" status --porcelain   # must be a git repo; should be clean
```

At least one of `claude`, `codex`, `pi` must be installed **and logged in / configured**. Check
logins with `claude auth status` and `codex login status`; for Pi, `pi --list-models` shows the
providers it can reach.

If `rig` is "not found", look before offering to install: OpenRig is a Node package, and a
non-interactive shell may not load the Node version manager it was installed under. Try
`source ~/.nvm/nvm.sh && nvm use --lts` (or the person's version manager) and `npm ls -g @openrig/cli`.
Only if it really is missing, point to https://www.openrig.dev and offer to install it. If `PROJECT` has
uncommitted changes, ask the person to commit or stash them first; the crew needs a clean tree.

## 2. Create the files

Ask: **"Do you want the optional Muse seat?"** (default: no). Explain in one line: a senior
solutions architect the lead calls only when the crew is stuck; it should be your strongest
model from a different family than your Architect, and it costs little because it is rarely
called. Without it, the lead brings stuck problems to the person instead.

```bash
"$FOREMAN/scripts/foreman" init "$PROJECT"            # add --muse if they want it
```

This writes `FOREMAN/rig.<name>.yaml` (the crew) and `PROJECT/.foreman/project.yaml` (project
settings), both full of `SET-ME`, and keeps OpenRig's files out of the project's git status.

## 3. Choose the models (fills the rig file)

Read `FOREMAN/docs/models.md` first. Then ask which of these the person can use:
an Anthropic subscription (Claude Code), an OpenAI subscription (Codex), an OpenRouter key,
Ollama (local or cloud), another OpenAI-compatible endpoint.

Propose one `runtime` + `model` per seat as a table, following models.md: spend on the Architect
and save on the Builder, and mix model families across the checking seats: the Dissenter
differs from the Architect, the Reviewer and Inspector differ from the Builder, and the Muse
differs from the Architect.

Check every model id before writing it:
- **OpenRouter:** `curl -s https://openrouter.ai/api/v1/models` lists every id (no key needed).
  `pi --list-models` can't see OpenRouter models unless the key is in your own shell.
- **Pi with other providers:** `pi --list-models <name>` must find it.
- **Claude Code / Codex:** use an id the person's runtime offers. Codex's default is the
  `model` line in `~/.codex/config.toml`; Claude ids look like `claude-opus-5-5`. If unsure, ask
  the person which models their plan includes.

When they agree, replace every `runtime: SET-ME` and `model: SET-ME` in the rig file. Change
nothing else in it (the one exception is an optional `permission_policy`, see
docs/troubleshooting.md).

## 4. Fill in the project settings (fills `.foreman/project.yaml`)

Read the repo to propose each value: `package.json` scripts, `Makefile`, `pyproject.toml`,
`Cargo.toml`, CI workflow files, `README`, `AGENTS.md`/`CLAUDE.md`, the test folders, the
default branch (`git -C "$PROJECT" symbolic-ref --short HEAD`).

| Field | What to propose |
|---|---|
| `base_branch` | The branch jobs start from and merge back into, usually `main` |
| `preflight_cmd` | A safety check script if the repo has one, otherwise `none` |
| `verify_cmd` | The single command CI would run: tests, then typecheck/lint/build if they exist, joined with `&&`. It must exit 0 on a healthy tree and must not leave a server running |
| `acceptance_tests` | A folder of pre-written tests the builder must pass but never edit, or `none` |
| `protected_paths` | Paths no seat may edit (safety scripts, CI config, vendored code), or `[]` |
| `banned_cmds` | Anything that reaches outside the repo: deploy CLIs, production database tools, infra tools. `[]` if none |

`protected_paths` and `banned_cmds` are read by the crew, not by a program, so plain-language
qualifiers work: `"supabase/migrations/ (existing files only; adding new migrations is fine)"`,
or `"anything with --project-ref"`. Say so to the person, and say plainly that these are
instructions to the models, not a sandbox.

**Running `verify_cmd` once.** The crew runs it at every job's Gate 2, so it has to pass now.
Before running it, read what it does and tell the person if it is destructive or needs services
(for example, it resets a local database, or needs Docker running). Ask before running anything
destructive. If it fails on the current tree, stop and tell them: the crew cannot prove anything
against a red baseline.

Show the person your proposal with one line of reasoning per field, take their corrections,
then write the file.

If the project already has a `.foreman/` folder with tracked files (an older Foreman setup),
tell the person: those stay tracked, but `init` keeps new job files out of git. If they want
job ledgers committed, remove `.foreman/` from `.git/info/exclude`.

## 5. Keys and providers

Only needed for `pi` seats.

- **OpenRouter seats** (`model: openrouter/...`): seats get their environment from the OpenRig
  daemon, not from any shell. The key must be on the daemon's allowlist **and** in the daemon's
  environment. `scripts/foreman check` checks both (the second only on Linux).
  1. **You** add it to the allowlist, with permission. Read the current value first and keep it:
     ```bash
     rig config get recovery.provider_auth_env_allowlist
     rig config set recovery.provider_auth_env_allowlist <existing,>OPENROUTER_API_KEY
     ```
  2. **The person** restarts the daemon from their own terminal, because the key must never
     pass through you. Run `rig ps` first and tell them which rigs the restart will interrupt.
     Give them these lines to run (`read -rs` keeps the key out of their shell history):
     ```bash
     read -rs OPENROUTER_API_KEY && export OPENROUTER_API_KEY
     rig daemon stop && rig daemon start
     ```
     If they keep keys in a password manager CLI, they can export it from there instead. If the
     daemon is started by a service manager (systemd, launchd), the key belongs in that service's
     environment instead; point them to their service configuration.
- **Other Pi providers** (Ollama, vLLM, LM Studio, …): the provider must be configured in the
  person's `~/.pi/agent/models.json`. `scripts/foreman up` links that file into each Pi seat.
  Check `pi --list-models <name>` finds each model you chose.

## 5b. Tracing (optional)

Ask: **"Do you want to see every agent's calls, tokens and cost in Langfuse?"** If no, skip this.
If yes, read `FOREMAN/docs/observability.md` and:

1. Ask whether they use Langfuse Cloud (which region) or a self-hosted Langfuse, and say plainly
   that the crew's prompts and code will be sent there. If the repo holds client or personal
   data, recommend self-hosted or no tracing.
2. Install the plugin for each runtime the crew uses (docs/observability.md step 2), with
   permission. Pi seats need nothing; the script installs it per seat.
3. **The person** runs the `export`/`read -rs` lines and `scripts/foreman tracing "$PROJECT"` in
   their own terminal, because the keys must never pass through you. Give them the exact lines
   from docs/observability.md step 3 with their base URL filled in.
4. After launch (step 7), remind them that Codex seats need the Langfuse hook trusted once in
   `/hooks`.

## 6. Check

```bash
"$FOREMAN/scripts/foreman" check "$PROJECT"
```

It refuses while any `SET-ME` is left and names each one, then checks runtimes are installed,
Pi keys and providers, and runs OpenRig's own `rig spec validate` and `rig spec preflight`. Fix
whatever it reports and run it again until it says `check passed`.

## 7. Launch

Ask: **"Ready to launch the crew? Seven agents (eight with the Muse) will start in the background."** Then:

```bash
"$FOREMAN/scripts/foreman" up "$PROJECT"
```

## 8. Hand over to the person

Tell them, plainly:

1. **Open the lead** to talk to it: `tmux attach -t crew-lead@foreman-<name>` (press `Ctrl-b`
   then `d` to leave without stopping it), or run `rig tui` to see every seat.
2. **Permission mode for Claude seats.** Claude seats start in "accept edits" mode and will stop
   to ask before running commands. For an unattended crew, switch each Claude seat to auto mode
   in its pane (`Shift+Tab` until the footer shows auto mode), or be ready to approve prompts.
3. **If a seat asks whether to start fresh, answer `y`.** Enter alone means No.
4. **Approve any hook or folder-trust prompt** a seat shows on first start.
5. **Start a job** by telling the lead what to build: a path to a spec file, or a plain
   description (the lead writes it up and asks them to confirm). The lead will stop twice for
   their approval: the plan (Gate 1) and the merge (Gate 3).
6. **Prove it works** before a real job, if they have 20 minutes: the smoke test in
   `FOREMAN/docs/testing.md` runs the whole pipeline on a tiny throwaway project.
7. **Stop the crew** when done: `scripts/foreman down "$PROJECT"` (or ask you to).

## 9. Report

Finish with a short summary: the crew table (seat, runtime, model), the project settings you
wrote, whether tracing is on and where it goes, anything you could not check (for example, whether a login is valid), and the one
command to open the lead.

If something fails that this file doesn't cover, read `FOREMAN/docs/troubleshooting.md` before
improvising.
