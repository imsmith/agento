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
| `/hub`     | `HubLive`     | The private LLM hub: performers, clients, settings, live turns. |
| `/rules`   | `RulesLive`   | The rules this machine runs: policies, state, trace, deploy, explain. |

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

## Private LLM hub

Agento can run as a long-lived local service that coding clients point at
instead of a vendor: it speaks Anthropic's Messages protocol on
`POST /v1/messages`, and serves each turn from whichever llama host is
advertising on the network. Every turn goes through
`LLMAgent.Tool.Dispatcher.generate` under a per-client policy, and is
recorded.

```text
Claude Code --Messages/SSE--> agento /v1/messages
                                 | token -> client -> policy
                                 | router -> a discovered compute.llm.chat ad
                                 v
                    Dispatcher.generate --OpenAI Chat--> llama-server
```

### Install

```bash
tclsh scripts/install-service.tcl --default-host skynet001.local
```

The hub has no fixed address. Each time it starts it takes a free port and
registers with [busybody](../busybody) as `agento`; clients ask busybody
where it is. Busybody must be running (`http://localhost:5150`, or
`BUSYBODY_URL`).

This builds a release under `~/.local/lib/agento`, and writes
`~/.config/agento/hub.edn` (clients and routing), `~/.config/agento/env`
(the unit's environment) and `~/.config/systemd/user/agento.service`. The
two files under `~/.config/agento` hold secrets, are mode 0600, and are never
overwritten by a later run. `--prefix DIR` installs under another root,
`--name NAME` registers under another name, `--port N` pins a port for
something that cannot look one up, `--dry-run` shows what it would do.

It does not start anything. To run the hub now and at every login:

```bash
systemctl --user daemon-reload
systemctl --user enable --now agento
systemctl --user status agento
```

### Point a client at it

`scripts/hub-url.tcl` asks busybody where the hub is and prints its URL. The
installer prints both lines with the generated token:

```bash
export ANTHROPIC_BASE_URL=$(tclsh scripts/hub-url.tcl)
export ANTHROPIC_AUTH_TOKEN=<the token in ~/.config/agento/hub.edn>
claude
```

The URL is resolved when the client starts. If the hub restarts it comes up
on a different port, and a client started before that needs restarting too.
After the hub stops, busybody keeps its entry until its next health check,
up to half a minute.

From another machine, point the script at this host's busybody:
`tclsh scripts/hub-url.tcl --registry-url http://<this host>:5150`.

With those set, Claude Code talks only to the hub. That session does not use
a Claude subscription, and this build of the hub never forwards to a paid
API: every client's policy admits local mDNS-discovered performers and
nothing else. Unset the two variables to go back to the vendor.

Each program that connects should be its own client with its own token; add
entries to `:clients` in `hub.edn` and restart the unit.
`priv/hub.example.edn` documents every key.

`pi` should work the same way through a custom provider in
`~/.pi/agent/models.json`. This has not been tested:

```text
{"providers": {"agento": {"baseUrl": "<output of scripts/hub-url.tcl>",
                          "api": "anthropic-messages",
                          "apiKey": "<a client token from hub.edn>",
                          "models": [{"id": "local"}]}}}
```

### What to expect

- **Routing.** A request for a model some host is serving goes to that host.
  Anything else, which includes every model name Claude Code uses, goes to
  `:default-host`. The default names a host, never a model: the hub uses
  whatever that host is serving when the turn arrives. With no default host,
  such requests get a 404. `GET /v1/models` lists what is reachable now.
- **The first turn is slow.** Claude Code's opening request is around 18,000
  tokens. A llama host takes a minute or two to read it before the first
  byte; later turns in the session reuse the cached prompt and answer in
  seconds. `:performer-timeout-seconds` (default 900) is how long the hub
  waits.
- **An abandoned request runs until its next write.** The hub notices a
  client has gone only when a write to it fails. Claude Code opens a second,
  small request beside each main one and drops it; that request holds a
  performer slot until the performer produces its first token.
- **Model quality is the model's.** The hub carries tool calls faithfully. A
  small local model may still handle Claude Code's tool set poorly.

### On the network

The service listens on every interface over plain HTTP. Two things follow,
and both are deliberate:

- Tokens and prompts cross the network unencrypted.
- Only the hub's `/v1` routes ask for a token. The rest of agento — the
  harness API and the Chat, Events, System and Tools views — is on the same
  listener and open to anything that can reach it, including tools that act
  on this host.

Erlang distribution and the port mapper stay on loopback regardless.

### Where things are

| What | Where |
| --- | --- |
| Clients, default host, retention | `~/.config/agento/hub.edn` |
| Bind address, busybody name, secrets | `~/.config/agento/env` |
| Where the hub is right now | `tclsh scripts/hub-url.tcl`, or busybody's directory page |
| Turn log (SQLite) | `~/.local/share/agento/hub_turns.sqlite` |
| Service log | `journalctl --user -u agento` |
| The hub at a glance | the Hub view (`/hub`): performers, clients, settings, recent turns, live |
| Raw hub events | the Events view, topic `hub.request` |
| Rules (`.rule` files, deployed on save) | `~/.config/agento/rules`, or `:rules {:dir ...}` in `hub.edn` |
| The rules at a glance | the Rules view (`/rules`): what is loaded, its state, the last events, deploy and explain |

The turn log has one row per turn: client, requested model, performer,
outcome, token counts, duration, and the request and reply exactly as they
crossed the wire. It therefore contains whatever was typed into a prompt. It
is readable by its owner only, and rows older than `:retention-days`
(default 30) are deleted. The `hub.request` events carry the same facts
without either body.

| Variable | Default | Purpose |
| --- | --- | --- |
| `AGENTO_BIND` | `0.0.0.0` | Address the listener binds. Every interface, plain HTTP; set `127.0.0.1` to keep it local. |
| `AGENTO_HUB_CONFIG` | `~/.config/agento/hub.edn` | Hub configuration file. |
| `PORT` | `0` (a free port) | HTTP listen port. Leave it unset; busybody knows where the hub is. |
| `AGENTO_BUSYBODY_NAME` | `agento` | Name the hub registers under. |
| `BUSYBODY_URL` | `http://localhost:5150` | Where busybody is. |

A hub configuration that cannot be trusted stops agento at boot with a
message saying why: a file readable by anyone but its owner, malformed edn,
two clients sharing a token, an unknown key.

## Rules

Agento runs an [Anemos](../anemos) runtime, `:agento`, with the substrate
attached: every substrate event is an event a rule can wait for, named
after its topic (`hub.request` is `HUB_REQUEST`, the topic is the context
path, the data are the `?` facts), and every discovered tool is a module a
rule can call (`resource.net` is `[RESOURCE_NET::ping :host "x"]`).

```text
rule note-turns {
  context "hub" {
    when HUB_REQUEST { log ?client }
  }
}
```

Save that as `~/.config/agento/rules/turns.rule` and it is running; edit it
and it is replaced, with the state of any rule you did not touch kept;
delete it and it is gone. The Rules view shows what is loaded and what the
last events did, deploys a policy typed into it, and explains what an event
would reach.

A rule can call no tool until the hub configuration says which:

```text
:rules {:dir "~/.config/agento/rules" :tools ["resource.*" "function.crypto.*"]}
```

That list is the allow list of the policy every tool call from a rule is
judged by, the same deny-by-default `LLMAgent.Tool.Policy` the hub's
clients get. A rule can always emit onto the event bus and wait on it;
what it may *call* is what this list gives it.

The Rules view can also deploy and unload policies, but not by default:
the web UI has no login, and a policy is code. `:rules {:ui-deploy true}`
turns that on.

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

The hub is tested against a fake performer serving streams recorded from the
live llama-servers, with request bodies captured from a real Claude Code
client (both live in llmagent's `test/fixtures/wire/`). The install script
and the resolver have their own suites:

```bash
tclsh test/tcl/install_service_test.tcl
tclsh test/tcl/hub_url_test.tcl
```
