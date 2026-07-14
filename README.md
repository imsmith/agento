# Agento

A Phoenix LiveView web UI over [LLMAgent](../llmagent). It gives you a browser
front end for driving LLMAgent's agents, watching their event stream, and
inspecting the runtime — plus zero-config discovery of llama.cpp / Ollama
servers advertised on the LAN.

Agento depends on LLMAgent as a path dependency (`{:LLMAgent, path: "../llmagent"}`)
and Comn flows in transitively. It adds no business logic of its own: every view
is a thin, version-adaptive projection over LLMAgent's public API.

## Views

The app boots at `/`, which redirects to `/chat`.

| Path       | View          | What it does                                                     |
|------------|---------------|-----------------------------------------------------------------|
| `/chat`    | `ChatLive`    | Start/stop agents and chat with them (R1, R2).                  |
| `/events`  | `EventsLive`  | Live event stream with topic/type filters (R3).                |
| `/system`  | `SystemLive`  | Supervision tree, ETS, Comn contexts, DurableLog (R4, R5, R7). |
| `/tools`   | `ToolsLive`   | Tool registry browser and manual invocation (R6).             |

`GET /export/:agent?kind=events|messages` streams an agent's event log or
message history as a JSON download.

## LLM endpoint discovery

When `tclsh` and Avahi are present, LLMAgent browses mDNS (`_llama._tcp`) and
registers each reachable server as a tool ad at coordinate `compute.llm.chat`.
The new-agent form's endpoint dropdown is fed from those ads:

- **Live** — `ChatLive` subscribes to discovery changes, so servers that appear
  or expire while the page is open update the dropdown without a reload.
- **Normalized** — IPv6 literals are bracketed into valid URLs and unroutable
  IPv6 link-local (`fe80::/10`) addresses are dropped.
- **Fallback** — a `llama3.2 @ localhost:11434` option is always present, so the
  form works even before any server is discovered.

Discovery is optional. Without `tclsh`/Avahi the dropdown shows only the
localhost fallback, and you point agents at a server explicitly via the
`LLMAGENT_*` environment variables below.

## Running it

### Prerequisites

- Elixir / Erlang OTP (see `mix.exs` for versions)
- LLMAgent checked out at `../llmagent`
- A running OpenAI-compatible endpoint (Ollama, llama.cpp server, etc.)
- Optional: `tclsh` + Avahi (`avahi-daemon`, `avahi-utils`) for mDNS discovery

### Setup and start

```bash
mix setup                       # deps.get + asset setup/build
PORT=4000 mix phx.server
```

**Set `PORT` explicitly.** Both `config/dev.exs` and `config/runtime.exs`
default the HTTP port to `0`, which binds a random free port. `PORT=4000` pins
it. Then visit <http://localhost:4000>.

### Environment variables

| Variable            | Default                       | Purpose                                        |
|---------------------|-------------------------------|------------------------------------------------|
| `PORT`              | `0` (random)                  | HTTP listen port. Pin it.                      |
| `LLMAGENT_MODEL`    | `llama3.2`                    | Default model for the boot agent and fallback. |
| `LLMAGENT_API_HOST` | `http://localhost:11434/v1`  | Default OpenAI-compatible endpoint.            |
| `LLMAGENT_ROLE`     | `default`                    | Default role prompt for new agents.            |
| `SECRET_KEY_BASE`   | —                             | Required in production.                        |
| `PHX_SERVER`        | —                             | Set to start the endpoint from a release.      |

Point the default agent at a specific server at boot:

```bash
LLMAGENT_MODEL=gemma-4-26B-A4B-it-Q4_K_M.gguf \
LLMAGENT_API_HOST=http://10.10.1.226:8080/v1 \
PORT=4000 mix phx.server
```

## Architecture

- **`AgentoWeb.Discovery.*`** — the boundary layer. `Agents`, `Endpoints`,
  `Tools`, `Events`, and `Behaviours` each wrap a slice of LLMAgent's API so the
  LiveViews never couple to LLMAgent internals and stay version-adaptive.
- **`Agento.EventBusBridge`** — subscribes to every LLMAgent EventBus topic and
  rebroadcasts onto `Phoenix.PubSub` (`agento:events`) so any number of LiveView
  processes see the same events. Polls `LLMAgent.Tools.all/0` to pick up new
  tool topics automatically.
- **`AgentoWeb.WebEvents`** and **`AgentoWeb.Hooks.Observability`** — emit
  `web.*` events and set up Comn tracing contexts so the UI's own actions are
  observable in the same event infrastructure as agent activity.

## Testing

```bash
mix test
```

Integration tests run against the live LLMAgent supervision tree with a
`TestLLMClient` (no mocking of agent internals). Discovery-driven behaviour is
covered by registering fake `compute.llm.chat` ads as the discovery source.
