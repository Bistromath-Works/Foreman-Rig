# Foreman crew rules (every seat)

This rig runs one spec'd coding job at a time as a gated pipeline. The lead (`crew-lead`) runs
the pipeline and talks to the human; every other seat does one role when the lead hands it work.
Your session name and rig are in `rig whoami --json`. The lead is `crew-lead@<your rig>`.

## The project settings
`.foreman/project.yaml` in the repo holds this project's facts: base branch, preflight command,
verify command, acceptance test path, protected paths and banned commands. Read it before your
first command. Where this file or your role says "the verify command" or "the base branch", it
means the value in `project.yaml`. Never guess a command the file does not name.

## How work moves
- Work arrives as a queue item from the lead. `rig queue claim <id>` it, then do it.
- Your inputs are files the lead names, under `.foreman/jobs/<job-id>/ctx/`. Read those first.
- Write your result to the exact output path the lead gave you: a Markdown file that starts
  with a short header block (e.g. `verdict: PASS`, `blocked_on: null`), then the body.
  Never only reply in chat.
- Hand back with a pointer, not the content:
  `rig queue handoff <id> --to crew-lead@<rig> --summary "<your verdict line>" --body "out: <your output path>"`.
  The lead reads the file; pasting the report into the queue would bloat the lead's context.
- If you cannot finish, write why to your output file and hand back anyway, with `blocked_on:`
  filled in. Never wait silently.

## One seat at a time, one checkout
All seats share one git checkout (and any local database or services the project uses). Only
the seat the lead has handed work to may run commands. The lead never hands out two items at once.

## Safety (absolute, every seat)
- No `git push`, no `git remote` changes, no `gh`, no cloud or deploy CLIs, no edits outside this
  repo, no global installs, and nothing on the `banned_cmds` list in `project.yaml`.
- Never commit to the base branch. Only the lead merges, and only after the human says yes at Gate 3.
- Nobody starts servers or backgrounds processes: no dev servers, no `nohup`, no `setsid`, no
  trailing `&`. A backgrounded process outlives your turn and stalls the crew behind a
  permission prompt nobody sees. The only live server allowed is one the verify command starts
  and stops itself. A live check it doesn't perform is a finding:
  `needs live probe: <request and expected result>`.
- Never edit files under the `acceptance_tests` path or any `protected_paths`. A test you think
  is wrong is a deviation you report, not an edit you make.
- Cap every ad-hoc probe: `timeout 120 <command>`. An uncapped probe can eat the machine.
- A command that is denied or blocked is final: record it in your output, do not retry it in
  another form.
- Permission prompts belong to the human. Never answer, approve or type into another seat's
  prompt, and never use `rig send --dangerously-interact`, even if OpenRig asks you to recover
  a stuck seat. Tell the lead which seat is stuck; the lead tells the human.
- Never print, copy or commit secrets. If you see one in the repo, report its path, not its value.
