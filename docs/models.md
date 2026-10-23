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

1. **Spend on the architect, save on the builder.** A precise plan lets a cheap builder succeed;
   a vague plan makes an expensive builder guess.
2. **Mix model families across the checking seats.** A reviewer from the same family as the
   builder tends to approve the same mistakes. Different weights, different blind spots.

## Seat by seat

"What we ran" is what this crew was developed and tested on, up to October 2026. Treat it as
one data point. Model names change fast; use whatever is current when you read this.

| Seat | What it needs | Spend | What we ran, and what we saw |
|---|---|---|---|
| **lead** | Follows a long procedure exactly and never improvises code. Reliability over brilliance. Runs on every step, so its context grows the most. | Mid–high | `claude-code` Opus 5.5. Never wrote code, never skipped a gate. |
| **architect** | The strongest reasoning you can afford. The plan is where the leverage is. | Highest | `claude-code` Fable 5.1 (and Opus 5.5 in earlier runs). Plans detailed enough for a cheap builder. |
| **dissenter** | A **different family from the architect**, willing to run small checks instead of only reading. | Mid | `pi` DeepSeek V4 Pro. Caught a blocking library-version bug in a plan by running a two-line check. A poor reviewer, though: keep it here. |
| **builder** | A strong coder that is cheap per token. It writes the most tokens of any seat. | Low–mid | `pi` GLM 5.3 (shipped a ~2,400-line feature with 175 passing tests), then Qwen3 Coder Next. |
| **reviewer** | A careful, literal reader that runs commands instead of trusting the diff. A **different family from the builder**. | Mid | `pi` Kimi K3: caught 7 of 8 planted bugs in a bake-off, but was the biggest token spender; now Kimi K2.7 Code. GPT-6 Astra caught 6 of 8 with the best severity calls and no noise. |
| **inspector** | A different family again from the builder, with strong security and systems sense. Looks at the whole branch, not one round. | Mid–high | `codex` GPT-6 Astra. Found two real race conditions the reviewer had approved. |
| **punchlist** | Fast, cheap, methodical. It runs a checklist. | Lowest | `claude-code` Haiku 5.5 (a local 27B model worked but was slow). |
| **muse** *(optional)* | Deep architectural knowledge **and** a different family from the architect. Rarely called, so it can be your most expensive model. | Highest, rarely | `pi` Gemini 4 Argon via OpenRouter. Smoke-tested only; no real job needed it yet. |

## Example crews

These are shapes that work, not vendor recommendations.

**One subscription (Anthropic only)**: simplest to set up.

| Seat | runtime | model |
|---|---|---|
| lead | claude-code | claude-opus-5-5 |
| architect | claude-code | claude-fable-5-1 |
| dissenter | claude-code | claude-sonnet-5-5 |
| builder | claude-code | claude-sonnet-5-5 |
| reviewer | claude-code | claude-sonnet-5-5 |
| inspector | claude-code | claude-opus-5-5 |
| punchlist | claude-code | claude-haiku-5-5 |

The weakness: one family everywhere. If you can add even one other provider, put it on the
dissenter or inspector first.

**Mixed families**: the crew Foreman runs on today.

| Seat | runtime | model |
|---|---|---|
| lead | claude-code | claude-opus-5-5 |
| architect | claude-code | claude-fable-5-1 |
| dissenter | pi | openrouter/deepseek/deepseek-v4-pro |
| builder | pi | openrouter/qwen/qwen3-coder-next |
| reviewer | pi | openrouter/moonshotai/kimi-k2.7-code |
| inspector | codex | gpt-6-astra |
| punchlist | claude-code | claude-haiku-5-5 |
| muse *(with `--muse`)* | pi | openrouter/google/gemini-4-argon |

**One API key (OpenRouter only)**: every seat on `pi`.

| Seat | runtime | model |
|---|---|---|
| lead | pi | openrouter/anthropic/claude-opus-5.5 |
| architect | pi | openrouter/anthropic/claude-fable-5.1 |
| dissenter | pi | openrouter/deepseek/deepseek-v4-pro |
| builder | pi | openrouter/qwen/qwen3-coder-next |
| reviewer | pi | openrouter/moonshotai/kimi-k2.7-code |
| inspector | pi | openrouter/openai/gpt-6-astra |
| punchlist | pi | openrouter/anthropic/claude-haiku-5.5 |

Check exact ids on [openrouter.ai/models](https://openrouter.ai/models) before you paste them;
providers rename models often. Prefer ids that Pi's built-in OpenRouter list knows
(`pi --list-models openrouter` with the key exported): an id Pi doesn't know has worked for
some models and failed for others.

## Cost

- **The builder and the reviewer spend the most tokens**, then the lead. Put your cheap-per-token
  models there. The architect and muse run rarely; an expensive model there costs little.
- **Set a spending cap with your provider** before the first job. OpenRouter lets you cap each
  API key per month; a key just for Foreman, with a small cap, turns a runaway loop into an
  error message instead of a bill.
- Every loop in Foreman is capped at two rounds, so a stuck job stops and asks you rather than
  burning tokens. [observability.md](observability.md) shows how to see exactly what each seat
  spent.

## The muse

The muse is off unless you ask for it: `scripts/foreman init <project> --muse`. Without it, the
lead sends stuck problems straight to you. To add it to an existing rig file, delete the file
and run `init --muse` again (the file holds only your model choices).
