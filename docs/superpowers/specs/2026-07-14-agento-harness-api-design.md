# Agento Harness API — Design (v0, first slice)

**Date:** 2026-07-14
**Status:** Draft for review
**Scope:** First slice of agento's native, self-describing, multi-tenant HTTP API.

---

## Motivation

Agento should expose a clean HTTP API that any client can drive, where **the
client stays dumb and agento is smart**: the client resends context freely,
agento maintains the authoritative session state, runs the agent loop with its
own tool substrate, and returns results. Terminal coding agents (opencode, pi)
were the motivating example but are explicitly **not** the target — the goal is
the right API; whatever connects, connects.

This is the first slice of a larger orchestration-proxy direction (later slices:
smart context minimization, stored-action aliases, a DSL, and routing across
MCP / A2A / arbitrary APIs). This document specs only the slice below.

## Scope

**In:**

- Self-describing API: OpenAPI 3.x served at `GET /specification` and `OPTIONS /`.
- `GET /agents` — catalog of instantiable agent types.
- `GET /toolbox` — list of available tools (named `/toolbox`, not `/tools`, to
  avoid colliding with the existing Tools Inspector LiveView at `/tools`).
- `GET /harness` — provision an isolated, multi-tenant session.
- `PUT /harness/:session-id` — interact: send context since the last fold,
  stream result frames back as the agent produces them.
- Server-side execution of agento tools during the loop, through the existing
  `LLMAgent.Tool.Dispatcher` + `%Policy{}`.
- Observability: each session's activity flows through the existing
  EventBus / DurableLog and is visible in the web UI.

**Deferred (not this slice):**

- Stored-action **aliases** (skills / slash-commands via `invoke`).
- **DSL** scripted turns.
- **Smart fold** — summarization / context minimization internals (this slice
  folds as a plain checkpoint; canonical history is retained server-side).
- Routing across **MCP / A2A / external APIs**.
- **DID auth enforcement** (identity is recorded, not enforced).
- Client-driven session teardown (`DELETE`) — sessions are lease-expired.

## Core concepts

### Session = agent instance

A harness session **is** an `LLMAgent` agent started under
`LLMAgent.AgentSupervisor` (a `DynamicSupervisor`). This gives multi-tenancy,
isolated per-session memory/history, the tool substrate, and the prompt/response
loop for free. The `session_id` is the handle; internally it maps to the agent's
registered name.

### Fold

A **fold** is a checkpoint of session context. Agento retains the canonical
conversation history server-side; a fold token marks a boundary. The client
sends only `context` accumulated **since the last fold**, and receives a **new**
fold token in each response. Either side may fold.

In this slice a fold is a plain monotonic checkpoint marker (e.g. an opaque
token encoding the message count / offset at fold time). Smart folding
(summarizing folded history so even agento's own prompt shrinks) is a later
slice; the wire protocol is unchanged when it lands.

### Identity

Client/agent identity is **optional** and travels in the `User-Agent` header,
DID-friendly, e.g.:

```text
User-Agent: Sherpa/1.0 (+html; did:web:example.com:agents:sherpa)
```

When present it is parsed and recorded (attributed onto the session and its
events for observability/authority later). It is **not required** to open a
session and is **not enforced** in this slice.

### Session lifecycle (no DELETE)

Sessions are **lease-based**, mirroring the discovery substrate's ad leases: a
session carries an `expires_at`, renewed on each `PUT`. A periodic sweeper stops
agents whose lease has expired and tears down their memory. There is no
client-facing delete — idle sessions expire on their own.

## API contract

All responses are `application/json` unless noted. The served OpenAPI document
is the normative contract; the shapes below are illustrative.

### `GET /specification` and `OPTIONS /`

Return the OpenAPI 3.x document describing this API. Served as JSON
(`application/openapi+json` / `application/json`). For this first slice the
document is hand-authored in `AgentoWeb.Harness.Spec` rather than a checked-in
static file, so it ships with the code and is covered by a route-coverage test
that keeps documented paths and live routes in sync. Runtime route-introspection
generation (deriving the document directly from the router) is a future
refinement, not yet implemented.

### `GET /agents`

Catalog of instantiable agent types (sourced from `LLMAgent.RolePrompt` roles
and their declared capabilities).

```json
{
  "agents": [
    {
      "id": "default",
      "name": "Default",
      "description": "General-purpose assistant.",
      "capabilities": ["chat"]
    },
    {
      "id": "sysadmin",
      "name": "Sysadmin",
      "description": "Linux system administration with system tools.",
      "capabilities": ["chat", "tools"]
    }
  ]
}
```

### `GET /toolbox`

List of available tools (from `LLMAgent.Tools.all/0` via
`AgentoWeb.Discovery.Tools`). Named `/toolbox` to avoid colliding with the
existing Tools Inspector LiveView mounted at `/tools`.

```json
{
  "tools": [
    { "name": "bash", "module": "LLMAgent.Tools.Bash",
      "describe": "Executes shell commands." }
  ]
}
```

### `GET /harness`

Provision an isolated session. No query parameters. Starts an agent under the
supervisor.

**Agent-type selection is capability negotiation via `Accept`.** The client
names the agent type it wants with an `Accept` header (content negotiation),
matched against the `GET /agents` catalog:

```text
Accept: sysadmin
User-Agent: Sherpa/1.0 (+html; did:web:example.com:agents:sherpa)
```

Agento binds the session to the requested agent type; absent or unsupported →
the **default** agent (and the response echoes which agent was bound).
`User-Agent` still carries optional *client* identity (recorded, not enforced),
distinct from the *agent-type* the `Accept` header requests.

Response `201 Created`:

```json
{
  "session_id": "hns_9f3a…",
  "agent": "sysadmin",
  "fold": "fold_0",
  "expires_at": "2026-07-14T20:30:00Z"
}
```

### `PUT /harness/:session-id`

Interact with the session by PUTting the context since the last fold; agento
streams result frames back as the agent produces them (see "Async streaming"
below).

**Idempotent replay.** Agento memoizes each processed turn's **frame sequence**
keyed by `(fold, context)`. A `PUT` is handled by three cases:

1. `fold` is the session's **current** fold → process the turn, streaming frames
   as they are produced, and store `(fold, context) → frames`.
2. `fold` is **stale but matches** a previously processed `(fold, context)` →
   re-stream the stored frames. This makes network retries and duplicate sends
   safe.
3. `fold` is **stale and does not match** any processed turn → `409`, with the
   session's current fold so the client can re-sync.

Rewriting history (PUT an old fold with *different* context to branch/edit) is
out of scope for this slice — that is case 3.

Request body:

```json
{
  "fold": "fold_3",
  "context": [
    { "role": "user", "content": "What's the hostname of this machine?" }
  ]
}
```

- `fold` — the fold token the client last received. Agento validates it against
  the session's canonical history; a stale/unknown token is an error (client
  should re-sync).
- `context` — the turns since that fold (usually one user turn).

Agento appends the new context to the session's canonical history, runs the
agent loop (the agent calls its own tools server-side through
`Tool.Dispatcher` + `%Policy{}`, talking to the discovered llama), and **streams
results back as they arrive** over a maintained async connection.

**Async streaming, no completion detection.** The harness does not try to decide
when a turn is "done." It stamps the request on receipt (`req_ts`), holds the
response open (chunked / SSE-style newline-delimited JSON), and writes one frame
per result the agent produces — intermediate tool dispatches, tool results, and
assistant messages — as each occurs. Every frame carries `req_ts` so the client
can correlate frames to the request that caused them and order them, even with
multiple requests in flight on the session. Frames also carry the current `fold`.

Response `200 OK`, `Content-Type: application/x-ndjson`, streamed:

```json
{"req_ts":"2026-07-14T20:44:58.120Z","type":"tool_dispatch","data":{"tool":"bash","action":"exec"},"fold":"fold_3"}
{"req_ts":"2026-07-14T20:44:58.120Z","type":"tool_result","data":{"output":"radon\n","status":"ok"},"fold":"fold_3"}
{"req_ts":"2026-07-14T20:44:58.120Z","type":"message","data":{"role":"assistant","content":"The hostname is radon."},"fold":"fold_4"}
```

The connection stays open for the session's lease; the client reads frames as
they arrive and tracks the latest `fold`. There is no terminal "done" frame — the
stream simply quiets between turns.

If the session is unknown or expired: `404`. Fold handling follows the replay
rules above (stale-but-matching replays the stored frames; genuine divergence →
`409` with the current fold).

## Architecture

New, thin Phoenix surface over existing substrate. No new subsystems.

```text
HTTP client
   │  (OpenAPI 3.x contract)
   ▼
AgentoWeb.Router  ──►  AgentoWeb.HarnessController      (parse, validate, identity)
                          │
                          ├─► AgentoWeb.Harness.Registry (session_id ⇄ agent name, lease)
                          │
                          └─► AgentoWeb.Harness.Session  (per-session orchestration)
                                 │
                                 ├─► LLMAgent.AgentSupervisor / LLMAgent agent
                                 │      (memory, history, prompt/response loop)
                                 ├─► LLMAgent.Tool.Dispatcher + %Policy{}   (server-side tools)
                                 ├─► LLMAgent.Tools.Discovery                (llama routing)
                                 └─► EventBus / DurableLog                   (observability)
```

Units and responsibilities:

- **`AgentoWeb.HarnessController`** — HTTP boundary: routes the five endpoints,
  parses/validates bodies, extracts `User-Agent` identity, maps results to
  status codes. No orchestration logic.
- **`AgentoWeb.Harness.Registry`** — owns `session_id ⇄ agent` mapping, lease
  timestamps, and the expiry sweeper. Single source of truth for "does this
  session exist / is it alive."
- **`AgentoWeb.Harness.Session`** — the per-session orchestration seam: reconcile
  incoming `context` against canonical history using the `fold` token, drive one
  interaction through the agent, mint the next fold token, renew the lease.
- **`AgentoWeb.Harness.Spec`** — builds the OpenAPI 3.x document from route
  introspection.

### The interaction loop (`PUT`)

1. Stamp the request (`req_ts`) and look up the session in the Registry
   (404 if absent/expired).
2. Validate `fold` (replay rules: current → process; stale-but-matching → replay
   stored frames; genuine divergence → 409).
3. Append `context` turns to the canonical history; renew the lease.
4. Subscribe the connection to the session agent's events
   (`agent.tool_dispatch`, `tool.*`, `agent.message`, `agent.error`) filtered by
   this session's agent, then drive the agent with the new user turn.
5. As each event arrives, write one stream frame tagged with `req_ts` and the
   current fold. The agent's existing loop handles tool calls server-side; no
   completion detection — frames flow as the agent produces them. Advance the
   fold as assistant messages settle.
6. Persist the frame sequence keyed by `(fold, context)` for idempotent replay.
   The connection stays open for the session lease.

## Security

Server-side tool execution driven by remote clients is a real surface (the same
one flagged for the web UI's R6.3). This slice gates it with a `%Policy{}`
governing which tools the harness may run; deny-by-default, per the existing
`Tool.Dispatcher` contract. Identity (`User-Agent`/DID) is recorded to enable
policy-by-identity later but is not an auth mechanism yet. The API is assumed to
run on a trusted network / behind a proxy, consistent with agento's existing
posture.

## Error handling

Pre-stream failures (before any frame is written) use HTTP status codes:

| Case | Status |
|---|---|
| Unknown/expired session | `404` |
| Stale fold, no matching processed turn | `409` (body includes current fold) |
| Stale fold matching a processed turn | `200` (re-streams stored frames — idempotent) |
| Malformed body / bad content type | `400` |

Once the stream is open (`200` sent), failures arrive as **error frames**, not
status codes:

- Policy-denied tool → an `error` frame (and the loop continues or ends per the
  agent's error handling).
- Upstream llama unreachable → an `error` frame.

Error bodies and error frames use the `Comn.Errors.ErrorStruct` shape (`reason`,
`field`, `message`, `suggestion`) for consistency with the rest of the stack.

## Testing

- **Controller/contract tests** (Phoenix `ConnCase`): each endpoint's happy path
  and error codes; `GET /specification` returns a valid OpenAPI 3.x document that
  matches the live routes; `OPTIONS /` matches `GET /specification`.
- **Session lifecycle**: `GET /harness` creates an isolated agent; two sessions
  don't share history; lease expiry stops the agent and subsequent `PUT` → 404.
- **Interaction**: `PUT` with a user turn streams NDJSON frames tagged with
  `req_ts` and an assistant `message` frame; frames carry an advancing fold;
  re-PUT with a stale-but-matching `(fold, context)` re-streams stored frames;
  genuine divergence → 409.
- **Tool augmentation**: a `PUT` whose turn triggers an agento tool streams
  `tool_dispatch` + `tool_result` frames (tool executed server-side, event
  recorded) ahead of the assistant `message` frame — run against the live
  substrate with the test LLM client (no mocks of agent internals), consistent
  with the existing agento test style.

## Open questions / future slices

- **Fold token encoding** — opaque offset marker now; room for a content hash so
  the client can detect divergence.
- **Stream transport detail** — `application/x-ndjson` over chunked transfer is
  the baseline; SSE is an alternative to weigh in the plan. Behaviour is
  identical; only the framing differs.
- **Aliases / stored actions** (`invoke`) — next slice.
- **DSL scripted turns** — future.
- **Smart fold** (summarization) — next slice; wire protocol already
  accommodates it.
- **Routing fabric** (MCP / A2A / external APIs as tools) — later slice, layered
  on this slice's tool-augmentation seam.
- **DID auth enforcement** — later (identity is recorded now, not enforced).
