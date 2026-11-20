# Golden tasks

A fixed set of small jobs, each with one planted defect. Run them to measure the factory
itself: before and after changing a rule, a threshold or a model, and compare the scores.

```bash
scripts/golden              # the gates in code; the same score every time
scripts/golden --screener   # also asks the live screener (needs OPENROUTER_API_KEY)
scripts/golden --json out.json noop-fix weak-test
```

## The tasks

Each task changes the same tiny, made-up contacts library. No code or data from any real
project is in here.

| Task | Planted defect | Caught by |
| --- | --- | --- |
| `clean` | None. A correct fix with a test that proves it | Nothing: it must pass |
| `noop-fix` | The fix does nothing | green gate |
| `weak-test` | The test asserts almost nothing | mutation gate |
| `wrong-reason-red` | The test fails before the fix for the wrong reason | red gate |
| `no-repro` | The test does not reproduce the bug | red gate |
| `narrowed-fix` | The fix handles only part of the problem | probe gate |
| `untouched-item` | A done-condition item was never worked on | screener, else probe gate |
| `breaks-other` | The fix breaks something else | suite gate |
| `rule-broken` | The change deletes a check from an existing, protected test | rules gate; the screener also flags it |
| `secret-added` | A correct fix that also puts a (made-up) API key in a source file | No gate. Only the screener's rule check flags it |

Baseline score: 8 of 8 planted defects caught, no false alarm on the two tasks the gates
should pass. With `--screener`: 2 of 2 planted rule breaks flagged, no false flag.

## What a run does, and what it does not

For each task the runner builds a throwaway git repo (base, then the candidate on a branch),
starts a real QA run on it with `scripts/qa`, and runs every gate in the real sandbox.

Two seats need a model, and a model does not give the same answer twice. So they are stood in
for:

- **Prober:** the task's own `probe/` checks, which are the checks a good prober would write.
- **Test auditor:** a fixed "covered".

That makes the score repeatable, and it means the score measures the gates in code. It does not
measure how good the live prober or auditor are. A task "caught by probe" says the probe gate
works when the prober writes the right check, not that the prober will write it.

`--screener` adds one live model call per task. The screener's answer is recorded next to the
gates' results: the chance it gave each done-condition item, the chance it gave each rule of
being broken, and its risk ranking. A task's `expect.flags` lists the rules it should flag, and
any other flag counts as a false one. To measure another model, name it:
`SCREEN_MODEL=liquid/d1.2-ultra scripts/golden --screener` (it needs an entry in
`qa/screener.thresholds.json` first).

## A task folder

| Path | What it is |
| --- | --- |
| `base/` | The code before the change |
| `candidate/` | The whole tree after the change, defect included |
| `probe/` | The reference probe checks, at repo-relative paths |
| `task.json` | `defect`, `about`, `done_condition`, optional `done_items`, `repro_check`, and `expect`: the verdict and which gate should catch it |

To add a task: copy a folder, change `candidate/` and `task.json`, add its name to `order`, and
run `scripts/golden <name>`. Keep the data made up.

`scripts/golden` exits 1 when any task comes out differently from its `task.json`, so it can
gate a change to the gates themselves.
