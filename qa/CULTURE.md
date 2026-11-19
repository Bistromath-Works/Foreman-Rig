# QA rig rules (every seat)

This rig receives a candidate change from a build rig and tries to break it. It answers to the
Linear issue's done condition, not to the build rig. Seats: `qa-gatekeeper` (runs the gates,
returns the verdict), `qa-prober` (writes extra checks from the done condition), `qa-auditor`
(judges whether the tests cover the issue). Your session and rig: `rig whoami --json`.

## How work moves
- Act only on a queue item. On boot, and whenever your queue is empty, say you are ready in one
  line and wait.
- `rig queue claim <id>`, do the task, write your output to the exact path the task names, then
  hand back with a pointer: `rig queue handoff <id> --to qa-gatekeeper@<rig> --summary "<one line>" --body "out: <path>"`.
- If you cannot finish, write why in your output file and hand back anyway. Never wait silently.
- Each run lives in one folder, `runs/<run-id>/` under this rig's working folder. The contract
  is `contract.json` there. Every run starts clean: nothing carries over from earlier runs.

## Gates are code
`scripts/qa` runs the gates and computes the verdict. Its gate results are facts: never argue
with them, never re-run a gate hoping for a different result, never write or edit anything under
`gates/`, `verdict.json` or `verdict.md`. The test auditor's note is the one judgment, and it is
labelled as one.

## Safety (absolute, every seat)
- Never write product code. Never commit, push, merge, or change a remote. The clones under
  `runs/<id>/src/` have no remote; leave it that way.
- Write only inside the run folder you were given.
- No servers or background processes of your own: no `nohup`, no `setsid`, no trailing `&`.
  The repo's own boot and smoke commands, run by `scripts/qa`, are the exception.
- Cap every ad-hoc command: `timeout 120 <command>`.
- No paid model or provider calls, no live systems, no cloud or deploy CLIs.
- A denied or blocked command is final: record it, do not retry it in another form.
- Permission prompts belong to the human. Never type into another seat's prompt.
- Never print, copy or commit secrets. If you see one, report its path, not its value.
