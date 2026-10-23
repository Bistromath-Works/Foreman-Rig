# Changelog

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
