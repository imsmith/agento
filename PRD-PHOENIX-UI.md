# PRD: LLMAgent Phoenix Web Interface

## Overview

A Phoenix LiveView application that provides a web interface for interacting with LLMAgent and inspecting the Comn infrastructure it runs on. The UI must adapt to LLMAgent versions and features without requiring new code — it discovers capabilities at runtime through introspection of behaviours, registries, and supervision trees.

The web application is a separate Elixir project that depends on both `llmagent` and `comn` as libraries. It uses Comn's own infrastructure (events, errors, contexts) for its own operations.

**Name:** `agento`

**License:** AGPL-3.0

---

## Background

### What LLMAgent Is

A GenServer-based framework for autonomous AI agents. Each agent connects to an OpenAI-compatible LLM API, parses tool-call JSON from responses, dispatches to tool modules, and loops results back to the LLM. Agents run under a DynamicSupervisor and can be started/stopped at runtime.

The agent emits structured events at every step. Every conversation message is emitted as an `agent.message` event, making the event stream the single source of truth for history. A DETS-backed DurableLog persists all events to disk.

### What Comn Is

A shared infrastructure library providing: structured errors (`ErrorStruct`), structured events (`EventStruct`, `EventLog`, `EventBus`), request contexts (`ContextStruct`, process-dictionary-scoped), secrets management (encrypt/decrypt with Ed25519+ChaCha20-Poly1305 or HashiCorp Vault), and repository abstractions (ETS tables, local/NFS/IPFS files, directed graphs).

Comn is a pure library — it starts no processes. Consumers start `EventLog`, `EventBus` (Registry), and any adapters in their own supervision trees.

### Key Architectural Constraint

LLMAgent's `prompt/2` is fire-and-forget. It returns `:ok` immediately; the LLM response arrives asynchronously via a Task, and tool dispatch happens inside the GenServer's `handle_info`. There is no request-response API that returns the LLM's answer. The UI must subscribe to events (via EventBus) or poll state (via `:sys.get_state`) to observe results.

---

## Dependency Inventory

The implementing team needs to understand two libraries. Full API surfaces are documented here so the team does not need to reverse-engineer them from source.

### Comn v0.4.0

**No supervision tree.** Pure library. The web app will use Comn types directly but does not need to start Comn processes — LLMAgent already starts EventLog, EventBus, etc.

#### Errors

| Module | Purpose |
|--------|---------|
| `Comn.Errors.ErrorStruct` | Struct: `reason`, `field`, `message`, `suggestion` |
| `Comn.Errors` | Facade: `wrap/1`, `new/3`, `new/4`, `categorize/1`, `categories/0` |
| `Comn.Error` | Protocol: `to_error/1` — implementations for Map, BitString, Atom, Tuple, ErrorStruct |

Categories: `:validation`, `:persistence`, `:network`, `:auth`, `:internal`, `:unknown`

#### Events

| Module | Purpose |
|--------|---------|
| `Comn.Events.EventStruct` | Struct: `timestamp` (ISO 8601), `source`, `type` (atom), `topic` (string), `data` (map) |
| `Comn.Event` | Protocol: `to_event/1` — implementations for Map, Tuple, EventStruct |
| `Comn.EventLog` | Agent-backed in-memory log: `record/1`, `all/0`, `for_topic/1`, `for_type/1`, `since/1`, `clear/0` |
| `Comn.EventBus` | Registry-based pub/sub: `subscribe/1`, `broadcast/2`. Messages arrive as `{:event, topic, payload}` |
| `Comn.Events.NATS` | GenServer: NATS-to-local bridge. `start_link/1`, `subscribe/2`, `broadcast/3` |

#### Contexts

| Module | Purpose |
|--------|---------|
| `Comn.Contexts.ContextStruct` | Struct: `request_id`, `trace_id`, `correlation_id`, `user_id`, `actor`, `env`, `zone`, `parent_event_id`, `metadata` |
| `Comn.Contexts` | Process-dictionary facade: `new/0`, `new/1`, `get/0`, `set/1`, `put/2`, `fetch/1`, `with_context/2` |
| `Comn.Context` | Protocol: `to_context/1` — implementations for Map, List, ContextStruct |

#### Secrets

| Module | Purpose |
|--------|---------|
| `Comn.Secrets.Key` | Struct: `id`, `algorithm` (`:ed25519`, `:rsa_4096`, `:ecdsa_p256`), `public`, `private`, `metadata`. Functions: `fingerprint/1`, `algorithm_from_fingerprint/1` |
| `Comn.Secrets.LockedBlob` | Struct: `cipher`, `encrypted`, `tag`, `key_hint`, `nonce`, `metadata` |
| `Comn.Secrets.Container` | Struct: `id` (UUID), `blobs`, `metadata` |
| `Comn.Secrets.Local` | Ed25519+ChaCha20-Poly1305: `lock/2`, `unlock/2`, `wrap/2`, `unwrap/2` |
| `Comn.Secrets.Vault` | HashiCorp Vault Transit: same interface. Config via `Key.metadata` |

#### Repo

| Module | Purpose |
|--------|---------|
| `Comn.Repo.Table.ETS` | ETS-backed table: `create/1`, `drop/1`, `get/2`, `set/2`, `delete/2`, `keys/1`, `count/1`, `describe/1`, `observe/2` |
| `Comn.Repo.File.Local` | File lifecycle state machine (`:init` -> `:open` -> `:loaded` -> `:closed`): `open/1`, `load/1`, `read/1`, `write/2`, `stream/1`, `cast/1`, `close/1` |
| `Comn.Repo.File.NFS` | Wraps Local with mount-point resolution |
| `Comn.Repo.File.IPFS` | IPFS daemon backend via HTTP API |
| `Comn.Repo.Graphs.Graph` | libgraph-backed directed graphs: `create/0`, `link/3`, `unlink/3`, `traverse/2` (shortest_path, reachable, neighbors, vertices, edges) |

#### The `Comn` Behaviour

Every Comn module implements a universal behaviour with four callbacks:
- `look/0` — human-readable summary string
- `recon/0` — technical introspection map (types, capabilities, latency, idempotency)
- `choices/0` — explorable options map (for TUI/CLI/orchestration)
- `act/1` — execute primary action with input map

**This is the key to version-adaptive UI.** The web app should use `look/0`, `recon/0`, and `choices/0` to dynamically render module capabilities rather than hardcoding them.

### LLMAgent v0.3.0

#### Supervision Tree (started by `LLMAgent.Application`)

```
LLMAgent.Supervisor (one_for_one)
├── Task.Supervisor              name: LLMAgent.TaskSup
├── Inotify.Watcher              GenServer
├── DynamicSupervisor            name: LLMAgent.AgentSupervisor
│   └── LLMAgent                 default agent (name from config)
├── Registry                     name: LLMAgent.EventBus
├── LLMAgent.EventLog            Agent (in-memory)
└── LLMAgent.DurableLog          GenServer (DETS)
```

#### Agent API

| Function | Signature | Notes |
|----------|-----------|-------|
| `LLMAgent.start_link/1` | `(opts) -> {:ok, pid}` | opts: `name`, `role`, `model`, `api_host`, `llm_client`, `memory` |
| `LLMAgent.prompt/2` | `(agent, content) -> :ok` | Async — no return value for LLM response |
| `LLMAgent.AgentSupervisor.start_agent/1` | `(opts) -> {:ok, pid}` | Starts under DynamicSupervisor |
| `LLMAgent.AgentSupervisor.stop_agent/1` | `(name) -> :ok \| {:error, :not_found}` | |
| `LLMAgent.AgentSupervisor.list_agents/0` | `() -> [pid]` | PIDs only |

Agent state (via `:sys.get_state({:global, name})`): `%{name, role, model, api_host, llm_client, memory, history}`

#### DurableLog API

| Function | Returns |
|----------|---------|
| `DurableLog.messages_for(agent_id)` | `[%{role, content}]` — only `agent.message` events |
| `DurableLog.events_for(agent_id)` | `[EventStruct]` — all events, sorted by timestamp |
| `DurableLog.events_for(agent_id, since: iso_ts)` | `[EventStruct]` — filtered |
| `DurableLog.clear(agent_id)` | `:ok` — one agent |
| `DurableLog.clear()` | `:ok` — all |

#### EventLog API (in-memory, not durable)

| Function | Returns |
|----------|---------|
| `EventLog.all()` | `[EventStruct]` |
| `EventLog.for_topic(topic)` | `[EventStruct]` |
| `EventLog.for_type(type)` | `[EventStruct]` |
| `EventLog.since(iso_ts)` | `[EventStruct]` |
| `EventLog.clear()` | `:ok` |

#### EventBus

`LLMAgent.EventBus.subscribe(topic)` — calling process receives `{:event, topic, %EventStruct{}}`.

Known topics: `agent.prompt`, `agent.llm_response`, `agent.tool_dispatch`, `agent.message`, `agent.error`, `tool.<name>`, `tool.inotify`, `tool.inotify.event`.

#### Events emitted by agents

| Topic | Type | Data fields |
|-------|------|-------------|
| `agent.prompt` | `:prompt` | `content`, `role`, `context` |
| `agent.llm_response` | `:llm_response` | `content_length`, `is_tool_call` |
| `agent.tool_dispatch` | `:tool_dispatch` | `tool`, `action` |
| `agent.message` | `:message` | `agent_id`, `role`, `content` |
| `agent.error` | `:error` | `reason`, `source` |
| `tool.<name>` | `:invocation` | `action`, `args`, `result` (:ok/:error), `duration_ms` |

#### Tool Registry

`LLMAgent.Tools.all/0` returns `[{atom, module}]` — the canonical list of registered tools. Each module implements `LLMAgent.Tool`:
- `describe/0` — human-readable string
- `perform/2` — `(action, args) -> {:ok, %{output, metadata}} | {:error, ErrorStruct}`

The web app should call `Tools.all/0` at runtime to discover available tools, not hardcode the list.

#### Memory

`LLMAgent.Memory` behaviour: `init/2`, `store/3`, `fetch/2`, `delete/2`, `list/1`, `teardown/1`.

Default: `LLMAgent.Memory.ETS` — table name `:"llmagent_mem_#{agent_id}"`. The web app can inspect these tables via `Comn.Repo.Table.ETS.describe/1` and `observe/2`.

#### LLM Client

`LLMAgent.LLMClient` behaviour: `chat/2 :: (messages, opts) -> {:ok, content} | {:error, reason}`.

Default: `LLMAgent.LLMClient.OpenAI` — posts to `#{api_host}/chat/completions`. No auth header.

---

## Requirements

### R1: Agent Chat Interface

A real-time conversational UI for interacting with agents.

**R1.1** — Display a list of running agents with their name, role, and model. Derived from `AgentSupervisor.list_agents/0` + `:sys.get_state/1` for each PID.

**R1.2** — Select an agent to open a chat view. The chat view shows the agent's full message history, reconstructed from `DurableLog.messages_for(agent_id)`.

**R1.3** — Send prompts to the selected agent via `LLMAgent.prompt/2`. The input is a text field; submission calls `prompt/2` and the UI waits for events.

**R1.4** — New messages appear in real time. The LiveView process subscribes to `agent.message` via `LLMAgent.EventBus.subscribe("agent.message")` and filters by `agent_id`. When a message event arrives, it is appended to the chat display without a page refresh.

**R1.5** — Tool dispatch is visible. When `agent.tool_dispatch` and `tool.<name>` events arrive, display them inline in the chat as collapsible metadata blocks showing: tool name, action, args (sanitized), result status, duration. Subscribe to `agent.tool_dispatch` and to each tool topic from `Tools.all/0`.

**R1.6** — Errors are visible. Subscribe to `agent.error`; display errors inline with reason and source.

**R1.7** — Display a "thinking" indicator between `agent.prompt` and the next `agent.message` with role `"assistant"`. Clear it when the assistant message arrives or an error occurs.

### R2: Agent Management

**R2.1** — Start a new agent. Form fields: name (atom), role (dropdown from known roles — introspect `LLMAgent.RolePrompt` or allow free-form), model (text), api_host (text), llm_client (dropdown of known implementations — default OpenAI), memory (dropdown — default ETS). Calls `AgentSupervisor.start_agent/1`.

**R2.2** — Stop an agent. Confirmation dialog, then `AgentSupervisor.stop_agent/1`.

**R2.3** — View agent configuration. Read-only display of the agent's state map (name, role, model, api_host, llm_client module, memory module, history length).

**R2.4** — Clear agent history. Calls `DurableLog.clear(agent_id)` and `Memory.ETS.delete(agent_id, :history)`. Requires confirmation.

### R3: Event Explorer

A queryable view over the event streams.

**R3.1** — Live event stream. A scrolling list of events from EventBus, subscribed to all known topics. Each event shows: timestamp, topic, type, source, and a collapsible data payload. New events appear at the top. Toggle auto-scroll.

**R3.2** — Filter events by topic, type, agent_id, and time range. Topic and type are dropdowns populated from observed values. Agent ID is a dropdown from running agents plus any agent_ids seen in events. Time range is a date-time picker.

**R3.3** — Query the DurableLog. Separate from the live stream — this queries persisted history. Inputs: agent_id, optional `since` timestamp. Results displayed as a table.

**R3.4** — Query the in-memory EventLog. Same UI pattern: `for_topic/1`, `for_type/1`, `since/1`, `all/0`.

**R3.5** — Event detail view. Click an event to see the full `EventStruct` fields: timestamp, source, type, topic, and the complete data map (rendered as formatted JSON or an Elixir term).

### R4: Supervision Tree Viewer

**R4.1** — Display the LLMAgent supervision tree as a collapsible tree structure. Start from `LLMAgent.Supervisor` and recurse through children using `Supervisor.which_children/1`.

**R4.2** — For each process, show: registered name (if any), module, PID, status (alive/dead), and current message queue length (via `Process.info(pid, :message_queue_len)`).

**R4.3** — For `DynamicSupervisor` (AgentSupervisor), list all children with their agent names (extracted from state).

**R4.4** — Refresh on demand (button) and optionally auto-refresh on a configurable interval.

### R5: Comn Infrastructure Inspector

Inspect the Comn subsystems that LLMAgent uses.

**R5.1 — ETS Tables.** List all ETS tables matching `llmagent_mem_*` pattern (Memory tables). For each table: show name, size (count), memory usage, and allow browsing key-value pairs via `Comn.Repo.Table.ETS.observe/2`. Also show the DurableLog's DETS table info.

**R5.2 — Contexts.** Display the current `Comn.Contexts` state for each agent process. This requires sending a `:sys` call or similar introspection — contexts are in the process dictionary, so the UI must call `Process.info(pid, :dictionary)` and extract `:comn_context`. Display the ContextStruct fields.

**R5.3 — Error Catalog.** Display `Comn.Errors.categories/0` and provide a view that aggregates errors from the event stream (events with type `:error`), grouped by category (using `Comn.Errors.categorize/1` on the reason field).

**R5.4 — Module Introspection.** For any module that implements the `Comn` behaviour, the UI can call `Module.look/0`, `Module.recon/0`, and `Module.choices/0` to render a capability card. Build a generic component that takes a module and renders its introspection data. Populate the list by scanning loaded modules that export `look/0`, `recon/0`, `choices/0`, and `act/1`.

### R6: Tool Inspector

**R6.1** — List all registered tools via `LLMAgent.Tools.all/0`. For each tool, display the module name and `describe/0` output.

**R6.2** — Tool detail view. Show the tool's `describe/0` text. If the tool module implements the `Comn` behaviour (exports `recon/0`), show capability details.

**R6.3** — Manual tool invocation. A form that allows selecting a tool, entering an action and args (JSON), and calling `perform/2` directly. Display the result. This is for debugging, not for production use — gate it behind a config flag or admin role.

### R7: DurableLog / DETS Inspector

**R7.1** — Show DurableLog status: DETS file path, file size on disk, total record count.

**R7.2** — Browse by agent: select an agent_id, see total event count, total message count, and the first/last timestamps.

**R7.3** — Export: download an agent's event history as JSON (all events or messages only).

---

## Version-Adaptive Design

The UI must not hardcode LLMAgent internals. Specific requirements:

**VA1** — Tool list comes from `LLMAgent.Tools.all/0` at runtime. If a new tool is added to LLMAgent, it appears in the UI without changes.

**VA2** — Event topics are discovered from live observation and from known patterns (`agent.*`, `tool.*`). The UI does not maintain a static list of topics.

**VA3** — Agent configuration options (roles, llm_client implementations, memory implementations) are discovered by scanning modules that implement the relevant behaviours. Use `Protocol.extract_impls/1` or scan `:code.all_loaded/0` for modules exporting the right callbacks.

**VA4** — Comn module capabilities are rendered via the `Comn` behaviour (`look/0`, `recon/0`, `choices/0`). The UI does not hardcode what Comn modules exist.

**VA5** — The supervision tree viewer uses `Supervisor.which_children/1` recursively and does not hardcode the tree structure.

**VA6** — EventStruct fields are rendered generically (the `data` map is displayed as-is). The UI does not hardcode what fields exist in event data.

---

## Technical Decisions

### Architecture

- Phoenix 1.7+ with LiveView
- No separate JavaScript framework — LiveView handles real-time updates
- The web app runs in the same BEAM node as LLMAgent (it's an Elixir dependency, not a separate service)
- The web app uses `Comn.Contexts` for its own request tracing (set context on each LiveView mount/event)
- The web app emits its own events via `LLMAgent.Events.emit/4` on topic `"web.*"` so its actions are observable in the same event infrastructure

### LiveView Patterns

- Each chat view is a LiveView process that subscribes to EventBus topics
- The event explorer is a LiveView with server-side filtering (not client-side)
- The supervision tree viewer polls on demand or on interval — it does not need push updates
- Use `Phoenix.PubSub` as the transport layer between EventBus subscriptions and LiveView. A bridge GenServer subscribes to EventBus topics and rebroadcasts to Phoenix.PubSub so multiple LiveView processes can receive the same events.

### The EventBus-to-LiveView Bridge

EventBus delivers messages to the subscribing process only. LiveView processes mount and unmount dynamically. A bridge is needed:

```
EventBusBridge (GenServer)
  on init: subscribe to all known EventBus topics
  on {:event, topic, event}: Phoenix.PubSub.broadcast("llmagent_web:events", {topic, event})

LiveView processes:
  on mount: Phoenix.PubSub.subscribe("llmagent_web:events")
  on info {topic, event}: filter by interest, update assigns
```

The bridge should also subscribe to any new topics it discovers (e.g., from new tool registrations). Poll `Tools.all/0` periodically or on a refresh trigger.

### Authentication / Authorization

Out of scope for v1. The web app is assumed to run on a private network or behind a reverse proxy. If the team wants to add auth, Phoenix's built-in auth generators are fine.

### Persistence

The web app itself does not need a database. All data comes from LLMAgent's DurableLog, EventLog, ETS tables, and process state. If the team wants user preferences or saved queries, SQLite via Ecto is the preferred choice (consistent with the broader stack).

---

## Non-Requirements

- No mobile-specific layout. Desktop-first is fine.
- No multi-node support. Single BEAM node.
- No user accounts or auth (v1).
- No direct LLM API key management in the UI. Keys are configured via environment variables or the LLMClient module.
- No editing of Comn infrastructure from the UI (secrets, repos, etc.) — read-only inspection. The only write operations are: sending prompts, starting/stopping agents, and clearing history.

---

## Project Setup

### Dependencies

```elixir
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 1.0"},
    {:phoenix_html, "~> 4.0"},
    {:tailwind, "~> 0.2", runtime: false},
    {:heroicons, "~> 0.5"},
    {:jason, "~> 1.4"},
    {:LLMAgent, path: "../llmagent"},
    # Comn comes transitively through LLMAgent
  ]
end
```

### Application Config

```elixir
# config/config.exs
config :llmagent_web, LLMAgentWeb.Endpoint,
  # standard Phoenix endpoint config

# Do NOT start LLMAgent.Application separately —
# it starts via the :LLMAgent app dependency.
# The web app's Application should start:
#   - Phoenix Endpoint
#   - Phoenix.PubSub
#   - LLMAgentWeb.EventBusBridge
```

### Runtime Configuration

```elixir
# config/runtime.exs — these flow through to LLMAgent
config :LLMAgent,
  model: System.get_env("LLMAGENT_MODEL", "llama3.2"),
  api_host: System.get_env("LLMAGENT_API_HOST", "http://localhost:11434/v1"),
  role: System.get_env("LLMAGENT_ROLE", "sysadmin")
```

---

## Integration Tests

These tests verify that the web application correctly integrates with LLMAgent and Comn. They run against a live supervision tree (not mocks) with a mock LLM client that returns predictable responses.

### Mock LLM Client

Create `LLMAgentWeb.TestLLMClient` implementing `LLMAgent.LLMClient`:

```elixir
defmodule LLMAgentWeb.TestLLMClient do
  @behaviour LLMAgent.LLMClient

  @impl true
  def chat(messages, _opts) do
    last = List.last(messages)

    cond do
      last.content =~ "use_tool" ->
        {:ok, Jason.encode!(%{"tool" => "bash", "action" => "exec", "args" => %{"command" => "echo test_output"}})}

      last.content =~ "fail_tool" ->
        {:ok, Jason.encode!(%{"tool" => "bash", "action" => "exec", "args" => %{"command" => "exit 1"}})}

      last.content =~ "error_response" ->
        {:error, :simulated_failure}

      # Tool result followups get a plain text response (ends the loop)
      last.role == "user" && last.content =~ "status" ->
        {:ok, "The tool completed successfully."}

      true ->
        {:ok, "This is a test response to: #{last.content}"}
    end
  end
end
```

### Test: Agent List (R1.1, R2.1, R2.2)

```
1. Start the web app with TestLLMClient
2. GET /agents — verify empty list or only default agent
3. POST /agents — create agent with name: :integration_test, role: :sysadmin
4. GET /agents — verify :integration_test appears with correct role and model
5. DELETE /agents/:integration_test — verify agent removed
6. GET /agents — verify :integration_test gone
```

### Test: Chat Round Trip (R1.2, R1.3, R1.4)

```
1. Start agent :chat_test with TestLLMClient
2. Mount LiveView for :chat_test
3. Verify system prompt message is displayed (from DurableLog.messages_for)
4. Submit prompt "hello world"
5. Wait for agent.message event with role "user", content "hello world"
6. Wait for agent.message event with role "assistant"
7. Verify both messages render in the chat view
8. Verify message order: system, user, assistant
```

### Test: Tool Dispatch Visibility (R1.5)

```
1. Start agent :tool_test with TestLLMClient
2. Mount LiveView for :tool_test
3. Submit prompt "use_tool"
4. Wait for agent.tool_dispatch event (tool: :bash, action: "exec")
5. Wait for tool.bash invocation event
6. Verify tool dispatch metadata appears in chat view (tool name, action, duration)
7. Wait for the followup assistant message ("The tool completed successfully.")
8. Verify full sequence renders: user -> tool call -> tool result -> assistant
```

### Test: Error Display (R1.6)

```
1. Start agent :error_test with TestLLMClient
2. Mount LiveView for :error_test
3. Submit prompt "error_response"
4. Wait for agent.error event
5. Verify error is displayed in chat with reason and source
```

### Test: Event Explorer (R3.1, R3.2)

```
1. Start agent :event_test with TestLLMClient
2. Submit several prompts to generate events
3. Mount event explorer LiveView
4. Verify events appear in the stream
5. Filter by topic "agent.prompt" — verify only prompt events shown
6. Filter by agent_id :event_test — verify only that agent's events shown
7. Clear filters — verify all events return
```

### Test: DurableLog Query (R3.3, R7.2)

```
1. Start agent :durable_test with TestLLMClient
2. Submit prompt, wait for response
3. Query DurableLog via UI for :durable_test
4. Verify messages_for returns system + user + assistant
5. Verify events_for returns prompt + llm_response + message events
6. Record a timestamp, submit another prompt
7. Query with since: timestamp — verify only new events returned
```

### Test: Supervision Tree (R4.1, R4.3)

```
1. Mount supervision tree viewer
2. Verify LLMAgent.Supervisor appears as root
3. Verify children: TaskSup, Watcher, AgentSupervisor, EventBus, EventLog, DurableLog
4. Start a new agent :tree_test
5. Refresh tree — verify :tree_test appears under AgentSupervisor
6. Stop :tree_test — refresh — verify it's gone
```

### Test: ETS Table Inspector (R5.1)

```
1. Start agent :ets_test with TestLLMClient
2. Submit a prompt (creates memory table entry)
3. Mount ETS inspector
4. Verify table llmagent_mem_ets_test appears in list
5. Click table — verify :history key visible with message list
6. Stop agent, delete memory table via teardown
7. Refresh — verify table gone
```

### Test: Tool Inspector (R6.1)

```
1. Mount tool inspector
2. Verify all tools from LLMAgent.Tools.all/0 appear
3. For each tool, verify describe/0 output is displayed
4. Verify tool count matches LLMAgent.Tools.all/0 length
```

### Test: Version Adaptivity (VA1)

```
1. At test setup, dynamically define a new tool module:
   defmodule LLMAgent.Tools.TestDynamic do
     @behaviour LLMAgent.Tool
     def describe, do: "A test tool"
     def perform(_, _), do: {:ok, %{output: "dynamic", metadata: %{}}}
   end
2. Add it to Tools.all/0 (this requires a mechanism — if Tools.all/0 is hardcoded,
   this test documents the limitation and the team should add a runtime registry)
3. Mount tool inspector — verify TestDynamic appears
4. Mount event explorer — verify tool.test_dynamic is a subscribable topic
```

### Test: EventBus Bridge (architectural)

```
1. Start EventBusBridge
2. Mount two separate LiveView processes for the same agent
3. Submit a prompt from LiveView #1
4. Verify both LiveView processes receive the agent.message event
5. Unmount LiveView #1
6. Submit another prompt from LiveView #2
7. Verify LiveView #2 still receives events (bridge is independent of LiveView lifecycle)
```

### Test: Web App Uses Comn (self-consistency)

```
1. Mount any LiveView
2. Verify Comn.Contexts is set with a request_id on the LiveView process
3. Submit a prompt
4. Check EventLog for events with topic "web.*"
5. Verify the web app's own events have context enrichment (request_id, trace_id)
```

---

## UI Layout

Four top-level navigation sections:

1. **Chat** — agent list sidebar + chat panel (R1, R2)
2. **Events** — live stream + query interface (R3)
3. **System** — supervision tree + ETS tables + contexts + error catalog (R4, R5, R7)
4. **Tools** — tool registry + manual invocation (R6)

The team has full discretion on visual design. Tailwind CSS is the default. No specific component library is required.

---

## Delivery Criteria

```
mix compile              -> 0 errors
mix test                 -> all integration tests pass
mix phx.server           -> web app serves on localhost:4000
                            (or configured port; LLMAgent API host must differ)
Agent chat               -> send prompt, see response, see tool calls
Event explorer           -> live stream updates, filters work
Supervision tree         -> renders current tree, reflects agent start/stop
DurableLog               -> queryable, shows persisted history
Tool inspector           -> lists all tools dynamically
ETS inspector            -> browses memory tables
```

---

## Resolved Questions

1. **Port conflict.** Resolved. LLMAgent now defaults `api_host` to `http://localhost:11434/v1` (Ollama), freeing `:4000` for Phoenix. No configuration conflict.

2. **Tool registry extensibility.** Resolved. `LLMAgent.Tools` is now a `persistent_term`-backed runtime registry with `register/2`, `unregister/1`, `get/1`, and `all/0`. Built-in tools are seeded on application start via `init_registry/0`. Custom tools can be added at runtime — VA1 is fully supported.

3. **Agent name discovery.** Resolved. `AgentSupervisor.list_agents_with_state/0` returns a list of maps with `pid`, `name`, `role`, `model`, `api_host`, and `history_length` for each running agent.

4. **Authentication.** Convention established. When auth is added, set `user_id` and `actor` on `Comn.Contexts.new/1` at LiveView mount. All events emitted during that session will carry attribution automatically via context enrichment in `LLMAgent.Events.emit/4`.
