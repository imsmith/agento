# Plumbing busybody into llmagent_web

**Date:** 2026-04-27
**Status:** Approved

## Problem

`llmagent_web` runs in dev with `port: 0` (see `llmagent_web/config/runtime.exs:30`),
so the OS picks a random free port at startup. That avoids collisions with
sibling Phoenix apps, but it makes the running app hard to find — you have to
scan logs or run `lsof` to discover the port.

Busybody (`/home/imsmith/github/busybody`) is a local dev service directory at
`http://localhost:5150` that solves exactly this. Apps register with it on
startup and appear as clickable cards in a LiveView directory.

## Solution

Wire `Busybody.Client` into `llmagent_web`'s supervision tree, dev-only, so the
app self-registers as `agento` at boot and heartbeats every 60s.

## Changes

### 1. `llmagent_web/mix.exs`

Add to `deps/0`:

```elixir
{:busybody, path: "../../busybody", only: :dev}
```

The relative path is `../../busybody` because `llmagent_web` is nested one
level deeper than the umbrella default (`agento/llmagent_web/` → up two →
`/home/imsmith/github/busybody`).

### 2. `llmagent_web/lib/llmagent_web/application.ex`

Append a guarded `busybody_children/0` to the children list and define the
helper:

```elixir
children = [
  LlmagentWebWeb.Telemetry,
  {DNSCluster, query: Application.get_env(:llmagent_web, :dns_cluster_query) || :ignore},
  {Phoenix.PubSub, name: LlmagentWeb.PubSub},
  LlmagentWebWeb.Discovery.Events,
  LlmagentWeb.EventBusBridge,
  LlmagentWebWeb.Endpoint
] ++ busybody_children()
```

```elixir
defp busybody_children do
  if Code.ensure_loaded?(Busybody.Client) do
    [{Busybody.Client, name: "agento", endpoint: LlmagentWebWeb.Endpoint}]
  else
    []
  end
end
```

The `Code.ensure_loaded?/1` guard makes prod/test/release builds (where the
dev-only dep is absent) a no-op rather than a crash.

### 3. `mix deps.get`

To fetch the new path dep.

## Constraints

- **Children order matters.** `Busybody.Client` must start *after*
  `LlmagentWebWeb.Endpoint` so that `Endpoint.server_info(:http)` can return
  the actual bound port. The 2-second startup delay inside `Busybody.Client`
  gives the endpoint time to bind, but ordering still matters because the
  client only schedules the registration after `init/1` returns. The `++
  busybody_children()` placement above satisfies this.

- **Naming oddity.** App is `:llmagent_web` but the web namespace is
  `LlmagentWebWeb` (note the doubled `Web`). The endpoint module is
  `LlmagentWebWeb.Endpoint`. Hand-editing — not the install task — to be sure
  this is right.

## Out of scope

- No changes to `config/runtime.exs`. The existing `port: 0` is correct.
- No prod/test wiring. Dev-only.
- No test additions. `Busybody.Client` is best-effort with `Logger.warning`
  on failure; nothing to assert on.
- Not running `mix busybody.install`. Its regex-based patching is fragile,
  and the `LlmagentWeb`/`LlmagentWebWeb` split is exactly the kind of edge
  case that breaks heuristic codemods.

## Verification

After changes:

1. `cd /home/imsmith/github/busybody && mix phx.server` — start the directory.
2. `cd /home/imsmith/github/agento/llmagent_web && mix phx.server` — start the app.
3. Open `http://localhost:5150` — `agento` card appears within ~2s.
4. Stop the app with Ctrl-C — within 30s the card disappears (busybody's
   health checker prunes dead entries).
