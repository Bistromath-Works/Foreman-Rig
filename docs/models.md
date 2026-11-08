# Choosing models for the crew

Foreman ships with no models chosen. Every seat's `runtime` and `model` in your rig file start
as `SET-ME`, and the setup refuses to launch until you fill them in. Pick from what you actually
have access to. This page is advice, not a requirement.

## Runtimes

Each seat runs inside one coding-agent runtime. OpenRig supports three:

| Runtime | What it needs | Models it can run |
|---|---|---|
| `claude-code` | [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed and logged in | Anthropic models (`claude-opus-…`, `claude-sonnet-…`, `claude-haiku-…`, `claude-fable-…`) |
| `codex` | [Codex CLI](https://github.com/openai/codex) installed and logged in | OpenAI models |
| `pi` | [Pi](https://github.com/earendil-works/pi) installed, with a provider configured | Anything with an OpenAI-compatible API: OpenRouter, Ollama (local or cloud), vLLM, LM Studio, Groq, and more |

`pi` is the escape hatch: if you only have an OpenRouter key, or only local models, every seat
can be a `pi` seat. Pi model strings are `<provider>/<model>`, e.g. `openrouter/qwen/qwen3-coder-next`
or `ollama/qwen3.8:27b`.

## The two rules that matter most

1. **Put a strong model on the owner.** It plans *and* builds, so there is no cheap seat whose
   mistakes another seat exists to catch. Foreman 1 saved money on a cheap builder and spent it
   back on three review seats.
2. **The checker is a different family from the owner.** Different weights, different blind
   spots. It must be good at running things, not just reading diffs.

## Seat by seat

"What we ran" is what Foreman 2 was developed on (November 2026). One data point; model names
change fast.

| Seat | What it needs | Spend | What we ran, and what we saw |
|---|---|---|---|
| **owner** | The strongest coder you can afford, with a long context: it reads the area, plans, builds, keeps the ledger. Follows the role's rules without improvising around them. | Highest | `claude-code` Opus 5.5. Eleven jobs on a real app; found defects two audits had missed. Weak spot: concurrency and silent fallbacks, which is why the checker matters. |
| **checker** | A **different family from the owner**, strong at systems and security, willing to write probe scripts and drive real handlers against a real local database. Calibrated: zero noise matters more than volume. | High | `codex` GPT-6 Astra. 19 check rounds over 11 jobs: caught 4 HIGH and 6 MED defects, every one real, no noise. In an earlier planted-bug bake-off it had the best severity calls. |
| **auditor** *(optional)* | Broad judgement and a **third family** if you can. Rarely runs, so it can be expensive. | High, rarely | `pi` Gemini 4 Argon via OpenRouter (as the Foreman 1 muse; smoke-tested). |

## Example crews

**Two subscriptions (recommended)**

| Seat | runtime | model |
|---|---|---|
| owner | claude-code | claude-opus-5-5 |
| checker | codex | gpt-6-astra |
| auditor *(with `--auditor`)* | pi | openrouter/google/gemini-4-argon |

**One subscription (Anthropic only)**: works, but owner and checker share blind spots.

| Seat | runtime | model |
|---|---|---|
| owner | claude-code | claude-opus-5-5 |
| checker | claude-code | claude-fable-5-1 |

If you can add one other provider, put it on the checker first.

**One API key (OpenRouter only)**: every seat on `pi`.

| Seat | runtime | model |
|---|---|---|
| owner | pi | openrouter/anthropic/claude-opus-5.5 |
| checker | pi | openrouter/openai/gpt-6-astra |
| auditor | pi | openrouter/google/gemini-4-argon |

Check exact ids on [openrouter.ai/models](https://openrouter.ai/models) before you paste them;
providers rename models often. Prefer ids that Pi's built-in OpenRouter list knows
(`pi --list-models openrouter` with the key exported).

## Cost

- **The owner spends the most tokens**: it reads, plans, builds and keeps the ledger. Long jobs
  grow its context; the ledger's `RESUME.md` lets a fresh session continue instead.
- **The checker spends per round.** Clear numbered promises keep rounds few; a vague brief
  wastes one.
- **Set a spending cap with your provider** before the first job. A key just for Foreman, with a
  small monthly cap, turns a runaway loop into an error message instead of a bill.
- [observability.md](observability.md) shows how to see exactly what each seat spent.

## The auditor

Off unless you ask for it: `scripts/foreman init <project> --auditor`. Without it, a stuck job
goes from the owner's redesign straight to you, and whole-repo audits are something you ask for
by hand. To add it to an existing rig file, delete the file and run `init --auditor` again (the
file holds only your model choices).
