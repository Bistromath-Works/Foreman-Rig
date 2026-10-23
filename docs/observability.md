# Seeing what the crew did: Langfuse

[Langfuse](https://langfuse.com) records every model call each seat makes: the prompt, the
reply, tool calls, tokens and cost, grouped by seat and session. With a crew of seven or eight
agents, it is the only way to answer "who spent what, and where did that job go sideways?"
without reading eight terminal scrollbacks.

Tracing is **optional** and **off** until you turn it on, and it is scoped to one project's
crew, so nothing else you run on the machine gets traced.

## What gets sent

Everything the seats see and say: your code, diffs, test output, plans. Choose where it goes
accordingly:

- **Langfuse Cloud** (EU, US, Japan or HIPAA region): nothing to run, a free tier to start.
- **Self-hosted Langfuse**: your traces never leave your machines. Run it with Langfuse's own
  [self-hosting guide](https://langfuse.com/self-hosting) (Docker Compose is the quick start);
  Foreman doesn't ship its own copy.

Don't turn tracing on for repositories holding client or personal data unless your Langfuse is
somewhere that data is allowed to be.

## 1. Get keys

Create a project in Langfuse, then **Settings → API Keys → Create**. You get a public key
(`pk-lf-…`), a secret key (`sk-lf-…`) and a host:

| Where | `LANGFUSE_BASE_URL` |
|---|---|
| Cloud EU | `https://cloud.langfuse.com` |
| Cloud US | `https://us.cloud.langfuse.com` |
| Cloud Japan | `https://jp.cloud.langfuse.com` |
| Cloud HIPAA | `https://hipaa.cloud.langfuse.com` |
| Self-hosted | Your server, e.g. `http://localhost:3000` |

## 2. Install each runtime's plugin (once per machine)

Only for the runtimes your crew uses. These install the plugins **without** keys; Foreman adds
keys per project, so the plugins stay silent everywhere else.

**Claude Code** ([plugin](https://github.com/langfuse/Claude-Observability-Plugin)); also needs
[uv](https://docs.astral.sh/uv/) on `PATH`, or Python 3.10+ with the `langfuse` package:

```bash
claude plugin marketplace add langfuse/Claude-Observability-Plugin
claude plugin install langfuse-observability@langfuse-observability
```

**Codex** ([plugin](https://github.com/langfuse/codex-observability-plugin)):

```bash
codex plugin marketplace add langfuse/codex-observability-plugin
```

then add to `~/.codex/config.toml`:

```toml
[features]
hooks = true

[plugins."tracing@codex-observability-plugin"]
enabled = true
```

**Pi**: nothing to do. OpenRig gives every Pi seat its own folder and strips environment
variables from it, so `scripts/foreman tracing` installs
[the Pi plugin](https://www.npmjs.com/package/@langfuse/pi-observability-plugin) into each Pi
seat's folder itself.

## 3. Turn it on for a crew

In your own terminal (`read -rs` keeps the secret out of your shell history and away from any
agent helping you):

```bash
export LANGFUSE_PUBLIC_KEY=pk-lf-...
export LANGFUSE_BASE_URL=https://cloud.langfuse.com
read -rs LANGFUSE_SECRET_KEY && export LANGFUSE_SECRET_KEY

scripts/foreman tracing ~/code/my-app
scripts/foreman down ~/code/my-app && scripts/foreman up ~/code/my-app   # seats read keys at start
```

What it writes, all private (mode 600) and all kept out of git:

| Seats | File |
|---|---|
| claude-code | `env` block in `<project>/.claude/settings.local.json` (other settings kept) |
| codex | `<project>/.codex/langfuse.json` |
| pi | `~/.openrig/state/pi/crew-<seat>@foreman-<project>/agent/langfuse.json` |

It refuses to write a key into any file git tracks or doesn't ignore. Every trace is tagged
with the rig name (`foreman-<project>`); Pi traces also carry the seat as the user id.

**Codex, once:** open each Codex seat's pane, run `/hooks` and trust the Langfuse `Stop` hook.
No Codex traces are sent until you do, and a plugin update can ask again.

To turn it off: `scripts/foreman tracing ~/code/my-app --off`, then restart the crew.

If you use a password manager CLI, export the keys from it instead of typing them.

## Is it working?

Give the lead a small job (the [smoke test](testing.md) is ideal), then open your Langfuse
project's **Tracing** page: you should see traces from each seat that has worked. Or ask the API:

```bash
curl -s -u "$LANGFUSE_PUBLIC_KEY:$LANGFUSE_SECRET_KEY" \
  "$LANGFUSE_BASE_URL/api/public/v2/observations?limit=5&fields=core,basic,model,usage"
```

Current Langfuse (v4) reads observations through `/api/public/v2/observations`; the older
`/api/public/traces` list is gone on Cloud. Ask for `fields=`, or the list leaves out the model
and token usage.

## When traces don't show up

- **Claude seats:** read `~/.claude/state/langfuse_hook.log` after a seat's turn. No new lines
  means the hook never ran: check `claude plugin list` and that `uv` is on the `PATH` of the
  shell that started the OpenRig daemon.
- **Codex seats:** the hook is not trusted yet (see above).
- **Pi seats:** check `~/.openrig/state/pi/crew-<seat>@<rig>/agent/settings.json` lists the
  plugin and `langfuse.json` sits next to it. If you deleted and recreated the rig, run
  `scripts/foreman tracing` again: the seat folders are new.
- **All seats:** keys are read when a seat starts. Restart the crew after turning tracing on.
- **Wrong region:** keys only work on the host they were created on. A US key against the EU
  host fails quietly.
