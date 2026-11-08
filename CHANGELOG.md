# Changelog

## 2.0.1 (2026-11-08)

- **`.foreman/STATE.md`: the crew's memory across jobs and sessions.** On its first real use the
  new owner asked the human things already settled the day before (which migrations were live,
  a fee schedule already decided), because those answers lived only in a chat and in another
  session's private notes. STATE.md holds what is live, every answer the human has given
  (dated), what waits on the human, what is unverified and open work. The owner reads it on
  boot, writes the human's answers into it the same turn, and updates it after every job; it
  outranks older notes. The auditor checks it against the code.
- `scripts/foreman init` creates it from `state.template.md` and never overwrites it.
- The owner no longer asks "Is this the job?" on every description: it says what it understood
  and starts, and asks only when the goal or scope is genuinely open (a big decision). Writing
  to its `.foreman/` ledger never waits on the checkout lock.

## 2.0.0 (2026-11-07)

Two seats instead of seven. Built from a real run: a Foreman 1 app audited at 58/100 was fixed
by an owner and a checker alone over eleven jobs; see docs/how-it-works.md, "Why two seats".

- **Owner** replaces the lead, architect and builder: one seat that plans, removes before
  adding, builds test-first, merges and talks to the human. It never approves its own work.
- **Checker** replaces the reviewer, inspector and punch list: an independent gate that runs the
  real code against real local services and tries to break a numbered list of promises. HIGH
  and MED block. On big jobs it also checks the plan before code (the dissenter's old job).
- **Auditor** (optional, `init --auditor`) replaces the muse: a whole-repo audit every
  `audit_every` merged jobs, and fresh eyes after a third BLOCK on one job.
- The human is asked only about big decisions, serious failures and domain-specific knowledge.
  Plan and merge gates are gone; pushes and live-system steps (migrations) stay the human's.
- New crew rules: outside facts carry their source and a pinning test; model output is
  validated in code; no push before the migrations a change needs are live; net lines reported
  per job; `RESUME.md` so a fresh session can continue a job.
- `project.yaml` gains `audit_every` (a whole number, or `manual`); `check` asks for it.
- `init --muse` is now `init --auditor`. A 1.x crew can't be resumed: see
  docs/troubleshooting.md, "Upgrading a 1.x crew".

## 1.0.1 (2026-10-27)

- Seats now wait for a queue item from the lead. In the first smoke test, three seats built
  `SPEC.md` on boot and one committed straight to the base branch (the lead caught it).
  `CULTURE.md` now says: on boot, and whenever the queue is empty, do nothing and wait.

## 1.0.0 (2026-10-23)

First release as an [OpenRig](https://www.openrig.dev) setup. Tested with OpenRig 0.6.5 on Linux.

- Seven-seat crew (lead, architect, dissenter, builder, reviewer, inspector, punch list) plus an
  optional muse, off by default (`init --muse`).
- Works with any model: every seat's runtime (`claude-code`, `codex`, `pi`) and model start blank,
  with per-seat advice and example crews in `docs/models.md`.
- `scripts/foreman init | check | up | down | tracing`.
- Optional Langfuse tracing for every seat, Cloud or self-hosted, scoped to one crew
  (`docs/observability.md`).
- `examples/smoke/`: a tiny job for proving a new crew end to end (`docs/testing.md`).

The earlier Claude Relay version of Foreman is archived at
[Bistromath-Works/Code-Foreman](https://github.com/Bistromath-Works/Code-Foreman).
