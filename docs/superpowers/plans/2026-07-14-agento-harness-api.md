# Agento Harness API Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add agento's native, self-describing, multi-tenant HTTP harness API so any client can open a session (an `LLMAgent` agent instance) and drive it, streaming results back.

**Architecture:** A thin Phoenix HTTP surface over the existing substrate. A session is an `LLMAgent` agent under `AgentSupervisor` (free multi-tenancy, memory, tools, loop). A `Harness.Registry` GenServer owns session↔agent mapping, leases, folds, and memoized frames. The `PUT` endpoint drives the agent and streams NDJSON frames by subscribing to the existing `EventBusBridge` PubSub and filtering by `agent_id`.

**Tech Stack:** Elixir, Phoenix 1.8 (Bandit), Jason, `LLMAgent` (path dep), Comn (transitive). No new dependencies.

## Global Constraints

- App is `:agento`; Elixir `~> 1.16`; Phoenix `~> 1.8`. Do NOT add dependencies — Jason, Plug, Bandit are already present.
- BEAM style guard hook: every module needs `@moduledoc`; any multi-exception rescue must be `rescue _e in [A, B] ->` with a comment line immediately after `rescue`.
- Tests run ONE file at a time, output redirected to a file (never pipe `mix test` to `tail` — leaked port children hang the wrapper): `mix test <path> > /tmp/out.txt 2>&1; echo $?; tail -60 /tmp/out.txt`.
- Integration tests run against the live `LLMAgent` supervision tree with `AgentoWeb.TestLLMClient` (no mocking of agent internals), consistent with existing agento tests.
- Endpoints (all on the existing endpoint): `OPTIONS /` and `GET /specification` (OpenAPI 3.x JSON), `GET /agents`, `GET /toolbox`, `GET /harness`, `PUT /harness/:session_id`. `/toolbox` (not `/tools`) avoids the existing `live "/tools"` route.
- The `Accept` header is repurposed for agent-type negotiation on `GET /harness` — the harness pipeline must NOT use Phoenix's `:accepts` content-negotiation plug (it would reject `Accept: sysadmin`). Read `Accept` manually.
- A session is an `LLMAgent` agent; observe it via `Phoenix.PubSub` on `AgentoWeb`-side `Agento.EventBusBridge.pubsub()` / `pubsub_topic()` (`"agento:events"`), filtering events by `event.data[:agent_id]` (an atom equal to the agent name).
- Error bodies and error frames use the `Comn.Errors.ErrorStruct` shape: `%{reason, field, message, suggestion}`.

Verified upstream signatures (do not re-derive):

- `LLMAgent.AgentSupervisor.start_agent(opts) :: {:ok, pid} | {:error, term}` — opts keys: `:name` (atom), `:role` (atom), `:model` (string), `:api_host` (string), `:llm_client` (module), `:memory` (module), `:allowed_tools` (`:all` | `[atom]`).
- `LLMAgent.AgentSupervisor.stop_agent(name) :: :ok | {:error, :not_found}`.
- `LLMAgent.prompt({:global, name}, content) :: :ok` (fire-and-forget; response arrives via events).
- `LLMAgent.RolePrompt.roles() :: [atom]`; `LLMAgent.RolePrompt.get(role) :: String.t()`.
- `AgentoWeb.Discovery.Tools.list() :: [{atom, module}]`; `AgentoWeb.Discovery.Tools.describe(module) :: String.t() | nil`.
- `AgentoWeb.Discovery.Endpoints.list() :: [%{id, api_host, model, label}]`.
- `Agento.EventBusBridge.pubsub() :: Agento.PubSub`; `Agento.EventBusBridge.pubsub_topic() :: "agento:events"`. Subscribers receive `{topic, %Comn.Events.EventStruct{}}` where the struct has `.type`, `.topic`, `.data`, `.timestamp`, `.source`.

---

## Task 1: Harness pipeline, routes, and OpenAPI specification endpoint

**Files:**
- Create: `lib/agento_web/harness/spec.ex`
- Create: `lib/agento_web/controllers/harness_controller.ex`
- Modify: `lib/agento_web/router.ex`
- Test: `test/agento_web/controllers/harness_controller_test.exs`

**Interfaces:**
- Produces: `AgentoWeb.Harness.Spec.document/0 :: map` (an OpenAPI 3.x document as an Elixir map). `AgentoWeb.HarnessController` actions `specification/2`, `agents/2`, `toolbox/2`, `create/2`, `interact/2`.

- [ ] **Step 1: Write the failing test**

```elixir
# test/agento_web/controllers/harness_controller_test.exs
defmodule AgentoWeb.HarnessControllerTest do
  @moduledoc false
  use AgentoWeb.ConnCase

  describe "specification" do
    test "GET /specification returns an OpenAPI 3.x document", %{conn: conn} do
      body = conn |> get("/specification") |> json_response(200)
      assert body["openapi"] =~ ~r/^3\./
      assert get_in(body, ["paths", "/harness"]) != nil
      assert get_in(body, ["paths", "/harness/{session_id}"]) != nil
    end

    test "OPTIONS / returns the same specification", %{conn: conn} do
      body = conn |> options("/") |> json_response(200)
      assert body["openapi"] =~ ~r/^3\./
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agento_web/controllers/harness_controller_test.exs > /tmp/t1.txt 2>&1; echo $?; tail -40 /tmp/t1.txt`
Expected: FAIL — no route for `/specification` (and `options/2` helper / route missing).

- [ ] **Step 3: Create the OpenAPI document module**

```elixir
# lib/agento_web/harness/spec.ex
defmodule AgentoWeb.Harness.Spec do
  @moduledoc """
  Builds the OpenAPI 3.x document describing the harness API. Returned by
  `GET /specification` and `OPTIONS /`. Authored here rather than checked in as
  a static file so it ships with the code that implements it.
  """

  @spec document() :: map()
  def document do
    %{
      "openapi" => "3.1.0",
      "info" => %{
        "title" => "Agento Harness API",
        "version" => "0",
        "description" => "Self-describing, multi-tenant harness over LLMAgent."
      },
      "paths" => %{
        "/specification" => %{"get" => op("Return this OpenAPI document.")},
        "/agents" => %{"get" => op("List instantiable agent types.")},
        "/toolbox" => %{"get" => op("List available tools.")},
        "/harness" => %{
          "get" => op("Provision a session. Agent type negotiated via the Accept header.")
        },
        "/harness/{session_id}" => %{
          "put" => op("Interact: PUT context-since-fold; stream NDJSON result frames.")
        }
      }
    }
  end

  defp op(summary), do: %{"summary" => summary, "responses" => %{"200" => %{"description" => "OK"}}}
end
```

- [ ] **Step 4: Create the controller with the specification action and stubs**

```elixir
# lib/agento_web/controllers/harness_controller.ex
defmodule AgentoWeb.HarnessController do
  @moduledoc """
  HTTP boundary for the harness API. Parses/validates requests, delegates to
  `AgentoWeb.Harness.*`, and maps results to responses. No orchestration logic.
  """
  use AgentoWeb, :controller

  alias AgentoWeb.Harness.Spec

  def specification(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Spec.document())
  end

  def agents(conn, _params), do: json(conn, %{"agents" => []})
  def toolbox(conn, _params), do: json(conn, %{"tools" => []})
  def create(conn, _params), do: send_resp(conn, 501, "not implemented")
  def interact(conn, _params), do: send_resp(conn, 501, "not implemented")
end
```

- [ ] **Step 5: Add the harness pipeline and routes**

Add to `lib/agento_web/router.ex` after the existing `pipeline :api` block:

```elixir
  # No :accepts plug — the Accept header is repurposed for agent negotiation
  # on GET /harness, so standard content negotiation must not run here.
  pipeline :harness do
    plug :put_format, :json
  end

  scope "/", AgentoWeb do
    pipe_through :harness

    match :options, "/", HarnessController, :specification
    get "/specification", HarnessController, :specification
    get "/agents", HarnessController, :agents
    get "/toolbox", HarnessController, :toolbox
    get "/harness", HarnessController, :create
    put "/harness/:session_id", HarnessController, :interact
  end
```

- [ ] **Step 6: Run test to verify it passes**

Run: `mix test test/agento_web/controllers/harness_controller_test.exs > /tmp/t1.txt 2>&1; echo $?; tail -40 /tmp/t1.txt`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
git add lib/agento_web/harness/spec.ex lib/agento_web/controllers/harness_controller.ex lib/agento_web/router.ex test/agento_web/controllers/harness_controller_test.exs
git commit -m "feat(harness): API pipeline, routes, OpenAPI specification endpoint"
```

---

## Task 2: Agents and toolbox catalogs

**Files:**
- Create: `lib/agento_web/harness/catalog.ex`
- Modify: `lib/agento_web/controllers/harness_controller.ex`
- Test: `test/agento_web/controllers/harness_controller_test.exs`

**Interfaces:**
- Produces: `AgentoWeb.Harness.Catalog.agents/0 :: [%{id: String.t, name: String.t}]`, `AgentoWeb.Harness.Catalog.toolbox/0 :: [%{name: String.t, module: String.t, describe: String.t | nil}]`, `AgentoWeb.Harness.Catalog.agent_ids/0 :: [String.t]`.

- [ ] **Step 1: Write the failing test**

```elixir
# add to test/agento_web/controllers/harness_controller_test.exs
  describe "catalogs" do
    test "GET /agents lists instantiable agent types with id and name", %{conn: conn} do
      body = conn |> get("/agents") |> json_response(200)
      ids = Enum.map(body["agents"], & &1["id"])
      assert "default" in ids
      assert Enum.all?(body["agents"], &is_binary(&1["name"]))
    end

    test "GET /toolbox lists tools with name and module", %{conn: conn} do
      body = conn |> get("/toolbox") |> json_response(200)
      assert is_list(body["tools"])
      assert Enum.all?(body["tools"], &(is_binary(&1["name"]) and is_binary(&1["module"])))
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agento_web/controllers/harness_controller_test.exs > /tmp/t2.txt 2>&1; echo $?; tail -40 /tmp/t2.txt`
Expected: FAIL — `/agents` returns empty list, so `"default" in ids` is false.

- [ ] **Step 3: Create the catalog module**

```elixir
# lib/agento_web/harness/catalog.ex
defmodule AgentoWeb.Harness.Catalog do
  @moduledoc """
  Read-only catalogs surfaced by the harness API: instantiable agent types
  (from `LLMAgent.RolePrompt`) and available tools (via `Discovery.Tools`).
  """

  @spec agents() :: [%{id: String.t(), name: String.t()}]
  def agents do
    LLMAgent.RolePrompt.roles()
    |> Enum.map(fn role ->
      %{id: to_string(role), name: humanize(role)}
    end)
  rescue
    # RolePrompt not loaded — no catalog rather than a crash.
    _e in [UndefinedFunctionError, ArgumentError] -> []
  end

  @spec agent_ids() :: [String.t()]
  def agent_ids, do: Enum.map(agents(), & &1.id)

  @spec toolbox() :: [%{name: String.t(), module: String.t(), describe: String.t() | nil}]
  def toolbox do
    AgentoWeb.Discovery.Tools.list()
    |> Enum.map(fn {name, module} ->
      %{
        name: to_string(name),
        module: inspect(module),
        describe: AgentoWeb.Discovery.Tools.describe(module)
      }
    end)
  end

  defp humanize(role) do
    role |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
```

- [ ] **Step 4: Wire the controller actions to the catalog**

Replace the `agents/2` and `toolbox/2` stubs in `lib/agento_web/controllers/harness_controller.ex`:

```elixir
  alias AgentoWeb.Harness.Catalog

  def agents(conn, _params), do: json(conn, %{"agents" => Catalog.agents()})
  def toolbox(conn, _params), do: json(conn, %{"tools" => Catalog.toolbox()})
```

(Add `alias AgentoWeb.Harness.Catalog` near the existing `alias AgentoWeb.Harness.Spec`.)

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/agento_web/controllers/harness_controller_test.exs > /tmp/t2.txt 2>&1; echo $?; tail -40 /tmp/t2.txt`
Expected: PASS (4 tests total).

- [ ] **Step 6: Commit**

```bash
git add lib/agento_web/harness/catalog.ex lib/agento_web/controllers/harness_controller.ex test/agento_web/controllers/harness_controller_test.exs
git commit -m "feat(harness): GET /agents and GET /toolbox catalogs"
```

---

## Task 3: Session registry (sessions, leases, folds, memoized frames)

**Files:**
- Create: `lib/agento_web/harness/registry.ex`
- Modify: `lib/agento/application.ex`
- Test: `test/agento_web/harness/registry_test.exs`

**Interfaces:**
- Produces:
  - `AgentoWeb.Harness.Registry.create(agent_name :: atom, ttl_ms :: pos_integer) :: {:ok, session}` where `session :: %{id: String.t, agent: atom, fold: non_neg_integer, expires_at: DateTime.t}`
  - `Registry.lookup(id :: String.t) :: {:ok, session} | {:error, :not_found}`
  - `Registry.renew(id) :: :ok` (extends the lease)
  - `Registry.current_fold(id) :: {:ok, non_neg_integer} | {:error, :not_found}`
  - `Registry.commit_turn(id, fold :: non_neg_integer, context_hash :: String.t, frames :: [map]) :: {:ok, next_fold :: non_neg_integer}` (advances fold, memoizes frames)
  - `Registry.replay(id, fold, context_hash) :: {:ok, frames} | :miss`
  - `Registry.sweep() :: :ok` (stops agents whose lease expired; called by an internal timer)

- [ ] **Step 1: Write the failing test**

```elixir
# test/agento_web/harness/registry_test.exs
defmodule AgentoWeb.Harness.RegistryTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias AgentoWeb.Harness.Registry

  test "create returns a session with a fold of 0 and a lease" do
    {:ok, s} = Registry.create(:reg_test_a, 60_000)
    assert is_binary(s.id)
    assert s.fold == 0
    assert %DateTime{} = s.expires_at
    assert {:ok, ^s} = Registry.lookup(s.id)
  end

  test "unknown session is not found" do
    assert {:error, :not_found} = Registry.lookup("nope")
  end

  test "commit_turn advances the fold and memoizes frames for replay" do
    {:ok, s} = Registry.create(:reg_test_b, 60_000)
    frames = [%{"type" => "message", "data" => %{"content" => "hi"}}]
    {:ok, next} = Registry.commit_turn(s.id, 0, "hash0", frames)
    assert next == 1
    assert {:ok, 1} = Registry.current_fold(s.id)
    assert {:ok, ^frames} = Registry.replay(s.id, 0, "hash0")
    assert :miss = Registry.replay(s.id, 0, "other")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agento_web/harness/registry_test.exs > /tmp/t3.txt 2>&1; echo $?; tail -40 /tmp/t3.txt`
Expected: FAIL — `AgentoWeb.Harness.Registry` undefined.

- [ ] **Step 3: Implement the registry GenServer**

```elixir
# lib/agento_web/harness/registry.ex
defmodule AgentoWeb.Harness.Registry do
  @moduledoc """
  Owns harness sessions: the session-id ⇄ agent mapping, lease timestamps, the
  current fold, and memoized frame sequences for idempotent replay. A periodic
  sweep stops agents whose lease has expired.
  """
  use GenServer

  @sweep_interval_ms 10_000

  @type session :: %{id: String.t(), agent: atom(), fold: non_neg_integer(), expires_at: DateTime.t()}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec create(atom(), pos_integer()) :: {:ok, session()}
  def create(agent_name, ttl_ms), do: GenServer.call(__MODULE__, {:create, agent_name, ttl_ms})

  @spec lookup(String.t()) :: {:ok, session()} | {:error, :not_found}
  def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})

  @spec renew(String.t()) :: :ok | {:error, :not_found}
  def renew(id), do: GenServer.call(__MODULE__, {:renew, id})

  @spec current_fold(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def current_fold(id), do: GenServer.call(__MODULE__, {:current_fold, id})

  @spec commit_turn(String.t(), non_neg_integer(), String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def commit_turn(id, fold, hash, frames),
    do: GenServer.call(__MODULE__, {:commit, id, fold, hash, frames})

  @spec replay(String.t(), non_neg_integer(), String.t()) :: {:ok, [map()]} | :miss
  def replay(id, fold, hash), do: GenServer.call(__MODULE__, {:replay, id, fold, hash})

  @spec sweep() :: :ok
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  # -- Server --

  @impl true
  def init(opts) do
    ttl = Keyword.get(opts, :ttl_ms, 900_000)
    schedule_sweep()
    {:ok, %{sessions: %{}, default_ttl: ttl}}
  end

  @impl true
  def handle_call({:create, agent_name, ttl_ms}, _from, state) do
    id = "hns_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    session = %{
      id: id,
      agent: agent_name,
      fold: 0,
      expires_at: expiry(ttl_ms),
      ttl_ms: ttl_ms,
      turns: %{}
    }

    {:reply, {:ok, public(session)}, put_in(state.sessions[id], session)}
  end

  def handle_call({:lookup, id}, _from, state) do
    case state.sessions[id] do
      nil -> {:reply, {:error, :not_found}, state}
      s -> {:reply, {:ok, public(s)}, state}
    end
  end

  def handle_call({:renew, id}, _from, state) do
    with_session(state, id, fn s -> {%{s | expires_at: expiry(s.ttl_ms)}, :ok} end)
  end

  def handle_call({:current_fold, id}, _from, state) do
    case state.sessions[id] do
      nil -> {:reply, {:error, :not_found}, state}
      s -> {:reply, {:ok, s.fold}, state}
    end
  end

  def handle_call({:commit, id, fold, hash, frames}, _from, state) do
    with_session(state, id, fn s ->
      next = fold + 1
      s = %{s | fold: next, turns: Map.put(s.turns, {fold, hash}, frames)}
      {s, {:ok, next}}
    end)
  end

  def handle_call({:replay, id, fold, hash}, _from, state) do
    reply =
      case state.sessions[id] do
        nil -> :miss
        s -> Map.get(s.turns, {fold, hash}) |> then(&if(&1, do: {:ok, &1}, else: :miss))
      end

    {:reply, reply, state}
  end

  def handle_call(:sweep, _from, state), do: {:reply, :ok, do_sweep(state)}

  @impl true
  def handle_info(:sweep, state) do
    schedule_sweep()
    {:noreply, do_sweep(state)}
  end

  # -- Helpers --

  defp with_session(state, id, fun) do
    case state.sessions[id] do
      nil ->
        {:reply, {:error, :not_found}, state}

      s ->
        {s2, reply} = fun.(s)
        {:reply, reply, put_in(state.sessions[id], s2)}
    end
  end

  defp do_sweep(state) do
    now = now()

    {expired, live} =
      Map.split_with(state.sessions, fn {_id, s} ->
        DateTime.compare(s.expires_at, now) == :lt
      end)

    Enum.each(expired, fn {_id, s} -> LLMAgent.AgentSupervisor.stop_agent(s.agent) end)
    %{state | sessions: live}
  end

  defp public(s), do: Map.take(s, [:id, :agent, :fold, :expires_at])
  defp expiry(ttl_ms), do: DateTime.add(now(), ttl_ms, :millisecond)
  defp now, do: DateTime.utc_now()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
```

Note: `DateTime.utc_now/0` is available in this app (unlike the workflow-script sandbox).

- [ ] **Step 4: Start the registry in the supervision tree**

In `lib/agento/application.ex`, add `AgentoWeb.Harness.Registry` to the `children` list, after `Agento.EventBusBridge`:

```elixir
      Agento.EventBusBridge,
      AgentoWeb.Harness.Registry,
      AgentoWeb.Endpoint
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/agento_web/harness/registry_test.exs > /tmp/t3.txt 2>&1; echo $?; tail -40 /tmp/t3.txt`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/agento_web/harness/registry.ex lib/agento/application.ex test/agento_web/harness/registry_test.exs
git commit -m "feat(harness): session registry with leases, folds, and frame memoization"
```

---

## Task 4: GET /harness — Accept negotiation and session provisioning

**Files:**
- Create: `lib/agento_web/harness/session.ex`
- Modify: `lib/agento_web/controllers/harness_controller.ex`
- Test: `test/agento_web/controllers/harness_controller_test.exs`

**Interfaces:**
- Produces:
  - `AgentoWeb.Harness.Session.negotiate_agent(accept :: [String.t]) :: atom` — picks a role id from the `Accept` header values, matched against `Catalog.agent_ids/0`; falls back to `:default`.
  - `AgentoWeb.Harness.Session.open(agent_type :: atom) :: {:ok, session} | {:error, term}` — starts an `LLMAgent` agent bound to a discovered endpoint and registers a session.

- [ ] **Step 1: Write the failing test**

```elixir
# add to test/agento_web/controllers/harness_controller_test.exs
  describe "GET /harness" do
    test "provisions a session with a default agent and a fold", %{conn: conn} do
      body = conn |> get("/harness") |> json_response(201)
      assert is_binary(body["session_id"])
      assert body["agent"] == "default"
      assert body["fold"] == "fold_0"
      assert is_binary(body["expires_at"])
    end

    test "negotiates the agent type via the Accept header", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept", "sysadmin")
        |> get("/harness")
        |> json_response(201)

      assert body["agent"] == "sysadmin"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agento_web/controllers/harness_controller_test.exs > /tmp/t4.txt 2>&1; echo $?; tail -40 /tmp/t4.txt`
Expected: FAIL — `create/2` returns 501.

- [ ] **Step 3: Implement the session module (negotiation + open)**

```elixir
# lib/agento_web/harness/session.ex
defmodule AgentoWeb.Harness.Session do
  @moduledoc """
  Per-session orchestration for the harness: negotiate the agent type, start the
  backing `LLMAgent` agent bound to a discovered endpoint, and (later) reconcile
  folds and drive interaction. A session IS an `LLMAgent` agent instance.
  """

  alias AgentoWeb.Harness.{Catalog, Registry}

  @default_ttl_ms 900_000
  @fallback_model "llama3.2"
  @fallback_api_host "http://localhost:11434/v1"

  @spec negotiate_agent([String.t()]) :: atom()
  def negotiate_agent(accept_values) do
    wanted =
      accept_values
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&(&1 |> String.split(";") |> hd() |> String.trim()))

    ids = Catalog.agent_ids()
    Enum.find(wanted, &(&1 in ids)) |> to_role()
  end

  @spec open(atom()) :: {:ok, map()} | {:error, term()}
  def open(agent_type) do
    {model, api_host} = endpoint()
    name = String.to_atom("hns_agent_" <> Integer.to_string(System.unique_integer([:positive])))

    opts = [
      name: name,
      role: agent_type,
      model: model,
      api_host: api_host,
      # Tool policy for harness-backed agents. The spec calls for deny-by-default;
      # this reads config so deployments can restrict it. Default is intentionally
      # permissive for now — the SAME security surface deferred for the web UI's
      # R6.3 (gate on auth). Restrict via config/runtime.exs before exposing the
      # API off a trusted network. `:all` or a list of tool atoms.
      allowed_tools: Application.get_env(:agento, :harness_allowed_tools, :all)
    ]

    case LLMAgent.AgentSupervisor.start_agent(opts) do
      {:ok, _pid} ->
        {:ok, session} = Registry.create(name, @default_ttl_ms)
        {:ok, Map.put(session, :agent_type, agent_type)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp to_role(nil), do: :default
  defp to_role(id), do: String.to_existing_atom(id)

  defp endpoint do
    case AgentoWeb.Discovery.Endpoints.list() do
      [%{model: m, api_host: h} | _] -> {m, h}
      _ -> {@fallback_model, @fallback_api_host}
    end
  end
end
```

- [ ] **Step 4: Implement the controller `create/2`**

Replace the `create/2` stub in `lib/agento_web/controllers/harness_controller.ex`:

```elixir
  alias AgentoWeb.Harness.Session

  def create(conn, _params) do
    agent_type = Session.negotiate_agent(get_req_header(conn, "accept"))

    case Session.open(agent_type) do
      {:ok, session} ->
        conn
        |> put_status(201)
        |> json(%{
          "session_id" => session.id,
          "agent" => to_string(session.agent_type),
          "fold" => "fold_#{session.fold}",
          "expires_at" => DateTime.to_iso8601(session.expires_at)
        })

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(error_body("agent_start_failed", nil, "could not start agent: #{inspect(reason)}"))
    end
  end

  defp error_body(reason, field, message) do
    %{"error" => %{"reason" => reason, "field" => field, "message" => message, "suggestion" => nil}}
  end
```

(Add `alias AgentoWeb.Harness.Session` with the other aliases.)

- [ ] **Step 5: Run test to verify it passes**

Run: `mix test test/agento_web/controllers/harness_controller_test.exs > /tmp/t4.txt 2>&1; echo $?; tail -40 /tmp/t4.txt`
Expected: PASS (6 tests total). Note: tests start real agents; add a cleanup `on_exit` in these tests calling `LLMAgent.AgentSupervisor.stop_agent/1` if the suite warns about lingering agents — mirror `test/support/integration_helper.ex`.

- [ ] **Step 6: Commit**

```bash
git add lib/agento_web/harness/session.ex lib/agento_web/controllers/harness_controller.ex test/agento_web/controllers/harness_controller_test.exs
git commit -m "feat(harness): GET /harness provisioning with Accept negotiation"
```

---

## Task 5: Fold reconciliation (pure logic)

**Files:**
- Modify: `lib/agento_web/harness/session.ex`
- Test: `test/agento_web/harness/session_test.exs`

**Interfaces:**
- Produces:
  - `Session.parse_fold(String.t) :: {:ok, non_neg_integer} | :error` (`"fold_3"` → `{:ok, 3}`)
  - `Session.fold_token(non_neg_integer) :: String.t` (`3` → `"fold_3"`)
  - `Session.context_hash(list) :: String.t`
  - `Session.reconcile(session_id, fold_str, context) :: {:process, user_content} | {:replay, frames} | {:diverged, current_fold_str} | {:error, :not_found}`

- [ ] **Step 1: Write the failing test**

```elixir
# test/agento_web/harness/session_test.exs
defmodule AgentoWeb.Harness.SessionTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias AgentoWeb.Harness.{Registry, Session}

  test "fold token round-trips" do
    assert Session.fold_token(3) == "fold_3"
    assert Session.parse_fold("fold_3") == {:ok, 3}
    assert Session.parse_fold("garbage") == :error
  end

  test "reconcile: current fold → process the last user turn" do
    {:ok, s} = Registry.create(:sess_test_a, 60_000)
    ctx = [%{"role" => "user", "content" => "hello"}]
    assert {:process, "hello"} = Session.reconcile(s.id, "fold_0", ctx)
  end

  test "reconcile: stale-but-matching fold → replay stored frames" do
    {:ok, s} = Registry.create(:sess_test_b, 60_000)
    ctx = [%{"role" => "user", "content" => "hi"}]
    hash = Session.context_hash(ctx)
    frames = [%{"type" => "message"}]
    {:ok, 1} = Registry.commit_turn(s.id, 0, hash, frames)
    assert {:replay, ^frames} = Session.reconcile(s.id, "fold_0", ctx)
  end

  test "reconcile: stale non-matching fold → diverged with current fold" do
    {:ok, s} = Registry.create(:sess_test_c, 60_000)
    {:ok, 1} = Registry.commit_turn(s.id, 0, "otherhash", [])
    ctx = [%{"role" => "user", "content" => "new"}]
    assert {:diverged, "fold_1"} = Session.reconcile(s.id, "fold_0", ctx)
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agento_web/harness/session_test.exs > /tmp/t5.txt 2>&1; echo $?; tail -40 /tmp/t5.txt`
Expected: FAIL — `Session.fold_token/1` undefined.

- [ ] **Step 3: Add fold + reconcile functions to `Session`**

Add to `lib/agento_web/harness/session.ex`:

```elixir
  @spec fold_token(non_neg_integer()) :: String.t()
  def fold_token(n), do: "fold_#{n}"

  @spec parse_fold(String.t()) :: {:ok, non_neg_integer()} | :error
  def parse_fold("fold_" <> n) do
    case Integer.parse(n) do
      {i, ""} when i >= 0 -> {:ok, i}
      _ -> :error
    end
  end

  def parse_fold(_), do: :error

  @spec context_hash(list()) :: String.t()
  def context_hash(context) do
    :crypto.hash(:sha256, :erlang.term_to_binary(context)) |> Base.url_encode64(padding: false)
  end

  @spec reconcile(String.t(), String.t(), list()) ::
          {:process, String.t()} | {:replay, [map()]} | {:diverged, String.t()} | {:error, :not_found}
  def reconcile(session_id, fold_str, context) do
    with {:ok, fold} <- parse_fold(fold_str),
         {:ok, current} <- Registry.current_fold(session_id) do
      hash = context_hash(context)

      cond do
        fold == current -> {:process, last_user_content(context)}
        match?({:ok, _}, Registry.replay(session_id, fold, hash)) ->
          {:ok, frames} = Registry.replay(session_id, fold, hash)
          {:replay, frames}
        true -> {:diverged, fold_token(current)}
      end
    else
      :error -> {:diverged, "fold_0"}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  defp last_user_content(context) do
    context
    |> Enum.reverse()
    |> Enum.find(&(&1["role"] == "user"))
    |> case do
      %{"content" => c} -> c
      _ -> ""
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/agento_web/harness/session_test.exs > /tmp/t5.txt 2>&1; echo $?; tail -40 /tmp/t5.txt`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/agento_web/harness/session.ex test/agento_web/harness/session_test.exs
git commit -m "feat(harness): fold reconciliation and idempotent-replay logic"
```

---

## Task 6: PUT /harness/:session_id — streaming interaction

**Files:**
- Modify: `lib/agento_web/controllers/harness_controller.ex`
- Test: `test/agento_web/controllers/harness_stream_test.exs`

**Interfaces:**
- Consumes: `Registry.lookup/1`, `Registry.renew/1`, `Registry.commit_turn/4`, `Session.reconcile/3`, `Session.context_hash/1`, `Session.fold_token/1`, `Agento.EventBusBridge.pubsub/0` + `pubsub_topic/0`, `LLMAgent.prompt/2`.
- Produces: streamed `application/x-ndjson` frames `%{"req_ts", "type", "data", "fold"}`.

Design notes for the implementer:
- Frames are built from EventBus events filtered by `event.data[:agent_id] == session.agent`. Map event topics to frame types: `"agent.tool_dispatch"` → `"tool_dispatch"`, `"tool." <> _` → `"tool_result"`, `"agent.message"` (role assistant) → `"message"`, `"agent.error"` → `"error"`. Skip `agent.message` with role `"user"`/`"system"` and `agent.llm_response`/`agent.prompt`.
- "Dumb" close: there is no completion event. After the first frame, if no matching event arrives for `@idle_close_ms` (default 1500 ms), close the stream and memoize the collected frames. This is transport quiet-detection, not semantic completion detection.

- [ ] **Step 1: Write the failing test**

```elixir
# test/agento_web/controllers/harness_stream_test.exs
defmodule AgentoWeb.HarnessStreamTest do
  @moduledoc false
  use AgentoWeb.ConnCase

  defp open_session(conn) do
    conn |> get("/harness") |> json_response(201)
  end

  test "PUT streams an assistant message frame tagged with req_ts and fold", %{conn: conn} do
    s = open_session(conn)

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put("/harness/#{s["session_id"]}", %{
        "fold" => s["fold"],
        "context" => [%{"role" => "user", "content" => "hello there"}]
      })

    assert conn.status == 200
    frames = conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    msg = Enum.find(frames, &(&1["type"] == "message"))
    assert msg["data"]["content"] =~ "test response"
    assert is_binary(msg["req_ts"])
    assert msg["fold"] == "fold_1"
  end

  test "PUT on an unknown session returns 404", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put("/harness/nope", %{"fold" => "fold_0", "context" => []})

    assert conn.status == 404
  end
end
```

The default `AgentoWeb.TestLLMClient` replies `"This is a test response to: ..."` for a plain user turn, so the assistant `message` frame's content contains `"test response"`. Confirm `config/test.exs` sets `llm_client: AgentoWeb.TestLLMClient` for `:LLMAgent`; if harness-created agents don't pick it up, pass `llm_client: AgentoWeb.TestLLMClient` in `Session.open/1`'s opts under `Mix.env() == :test` — but prefer configuring it globally in `config/test.exs` so production is untouched.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test test/agento_web/controllers/harness_stream_test.exs > /tmp/t6.txt 2>&1; echo $?; tail -50 /tmp/t6.txt`
Expected: FAIL — `interact/2` returns 501.

- [ ] **Step 3: Implement `interact/2` with streaming**

Replace the `interact/2` stub in `lib/agento_web/controllers/harness_controller.ex`:

```elixir
  alias AgentoWeb.Harness.Registry
  alias Agento.EventBusBridge

  @idle_close_ms 1_500

  def interact(conn, %{"session_id" => sid} = params) do
    req_ts = DateTime.utc_now() |> DateTime.to_iso8601()
    fold_str = Map.get(params, "fold", "fold_0")
    context = Map.get(params, "context", [])

    case Registry.lookup(sid) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(error_body("unknown_session", "session_id", "no such session"))

      {:ok, session} ->
        do_interact(conn, session, fold_str, context, req_ts)
    end
  end

  defp do_interact(conn, session, fold_str, context, req_ts) do
    case Session.reconcile(session.id, fold_str, context) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(error_body("unknown_session", "session_id", "no such session"))

      {:diverged, current} ->
        conn
        |> put_status(409)
        |> json(%{"error" => %{"reason" => "fold_diverged"}, "fold" => current})

      {:replay, frames} ->
        stream_static(conn, frames)

      {:process, user_content} ->
        Registry.renew(session.id)
        Phoenix.PubSub.subscribe(EventBusBridge.pubsub(), EventBusBridge.pubsub_topic())
        LLMAgent.prompt({:global, session.agent}, user_content)

        conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)
        {conn, frames} = stream_live(conn, session, req_ts, [])

        hash = Session.context_hash(context)
        {:ok, _next} = Registry.commit_turn(session.id, session.fold, hash, frames)
        conn
    end
  end

  defp stream_live(conn, session, req_ts, acc) do
    receive do
      {topic, event} ->
        case frame_for(topic, event, session.agent, req_ts, session.fold + 1) do
          nil ->
            stream_live(conn, session, req_ts, acc)

          frame ->
            {:ok, conn} = chunk(conn, Jason.encode!(frame) <> "\n")
            stream_live(conn, session, req_ts, [frame | acc])
        end
    after
      @idle_close_ms -> {conn, Enum.reverse(acc)}
    end
  end

  defp stream_static(conn, frames) do
    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

    Enum.reduce(frames, conn, fn frame, c ->
      {:ok, c} = chunk(c, Jason.encode!(frame) <> "\n")
      c
    end)
  end

  defp frame_for(topic, event, agent, req_ts, fold) do
    data = event.data || %{}
    if agent_of(data) == agent, do: build_frame(topic, data, req_ts, fold), else: nil
  end

  defp agent_of(data), do: data[:agent_id] || data["agent_id"]

  defp build_frame("agent.tool_dispatch", data, req_ts, fold),
    do: frame("tool_dispatch", data, req_ts, fold)

  defp build_frame("agent.error", data, req_ts, fold), do: frame("error", data, req_ts, fold)

  defp build_frame("tool." <> _name, data, req_ts, fold),
    do: frame("tool_result", data, req_ts, fold)

  defp build_frame("agent.message", %{role: "assistant"} = data, req_ts, fold),
    do: frame("message", data, req_ts, fold)

  defp build_frame("agent.message", %{"role" => "assistant"} = data, req_ts, fold),
    do: frame("message", data, req_ts, fold)

  defp build_frame(_topic, _data, _req_ts, _fold), do: nil

  defp frame(type, data, req_ts, fold) do
    %{"req_ts" => req_ts, "type" => type, "data" => sanitize(data), "fold" => "fold_#{fold}"}
  end

  defp sanitize(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {to_string(k), sanitize_value(v)} end)
  end

  defp sanitize_value(v) when is_binary(v) and byte_size(v) > 4_000,
    do: String.slice(v, 0, 4_000) <> "...(truncated)"

  defp sanitize_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp sanitize_value(v), do: v
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mix test test/agento_web/controllers/harness_stream_test.exs > /tmp/t6.txt 2>&1; echo $?; tail -60 /tmp/t6.txt`
Expected: PASS (2 tests). Each streaming test takes ~1.5s (the idle-close window); acceptable.

- [ ] **Step 5: Commit**

```bash
git add lib/agento_web/controllers/harness_controller.ex test/agento_web/controllers/harness_stream_test.exs
git commit -m "feat(harness): PUT streaming interaction over NDJSON"
```

---

## Task 7: Full-suite verification and spec-endpoint route coverage

**Files:**
- Modify: `test/agento_web/controllers/harness_controller_test.exs`

**Interfaces:** none new.

- [ ] **Step 1: Add a route-coverage test asserting the spec matches live routes**

```elixir
# add to test/agento_web/controllers/harness_controller_test.exs
  describe "spec matches routes" do
    test "every documented path is a live route", %{conn: conn} do
      body = conn |> get("/specification") |> json_response(200)
      documented = body["paths"] |> Map.keys() |> Enum.reject(&String.contains?(&1, "{"))
      routes = AgentoWeb.Router.__routes__() |> Enum.map(& &1.path)
      for path <- documented, do: assert(path in routes, "#{path} documented but not routed")
    end
  end
```

- [ ] **Step 2: Run the harness tests to verify**

Run: `mix test test/agento_web/controllers/harness_controller_test.exs > /tmp/t7.txt 2>&1; echo $?; tail -40 /tmp/t7.txt`
Expected: PASS.

- [ ] **Step 3: Run the full agento suite (no regressions)**

Run: `mix test > /tmp/full.txt 2>&1; echo $?; grep -E 'tests?,|failure|Finished' /tmp/full.txt | tail -3`
Expected: all green (existing 67 + the new harness tests), 0 failures.

- [ ] **Step 4: Manual smoke (optional, documents the flow)**

```bash
PORT=4000 LLMAGENT_API_HOST=http://10.10.1.226:8080/v1 \
  LLMAGENT_MODEL=gemma-4-26B-A4B-it-Q4_K_M.gguf mix phx.server
# in another shell:
curl -s localhost:4000/specification | jq .openapi
curl -s localhost:4000/agents | jq .
SID=$(curl -s localhost:4000/harness -H 'Accept: sysadmin' | jq -r .session_id)
curl -N -X PUT localhost:4000/harness/$SID -H 'content-type: application/json' \
  -d '{"fold":"fold_0","context":[{"role":"user","content":"what is the hostname?"}]}'
```

- [ ] **Step 5: Commit**

```bash
git add test/agento_web/controllers/harness_controller_test.exs
git commit -m "test(harness): spec/route coverage and full-suite verification"
```

---

## Notes and deferred items (from the spec)

- **Atom growth (DoS) — RESOLVED by re-architecture (2026-07-14).** The original design made a session a named `LLMAgent` agent (`String.to_atom("hns_agent_" <> unique)` per session), minting a non-GC'd atom per `GET /harness`. That was the wrong shape: it put the web session table inside the backend process pool. Fixed by making a session a **web-tier record** (`Harness.Registry`) and running each turn as a function call (`Harness.Turn`) over LLMAgent's standalone competence — no per-session process, no session-named atom. The only remaining atom use is bounded `String.to_existing_atom` for tool/role names (rejects hallucinated names; cannot grow the table). See the design doc's "Session = record" section.
- **Tool policy.** The spec's Security section calls for deny-by-default gating. This slice makes `allowed_tools` config-driven (`:harness_allowed_tools`) but defaults permissive (`:all`) — the same surface you deferred for R6.3 (gate on auth). Set a restrictive allowlist in `config/runtime.exs` before exposing the API beyond a trusted network. Tightening the default to deny-by-default is a one-line config change when auth lands.
- **Long-lived connection.** This slice closes the `PUT` stream on idle-quiet (`@idle_close_ms`). The spec's "connection stays open for the session lease" is a later refinement (SSE keepalive / long-poll); the frame protocol is unchanged when it lands.
- **Smart fold** (summarization), **aliases/`invoke`**, **DSL**, **MCP/A2A/API routing**, and **DID auth enforcement** are explicitly out of scope (see the design doc's "Open questions / future slices").
- **Tool namespacing / TUI-tool passthrough** from the earlier discussion is not part of this slice: a session is a self-contained `LLMAgent` agent that runs its own tools; there is no client-supplied `tools` array in this API. Cross-tool passthrough belongs to the later routing-fabric slice.
