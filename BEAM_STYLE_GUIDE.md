# BEAM/Elixir Style Guide for Comn Project

This guide outlines coding standards and design principles for writing idiomatic BEAM/Elixir code that leverages OTP's unique characteristics.

## Core Philosophy

Write code that embraces the BEAM's strengths:

- Use **behaviors** to define clear contracts for modules.
- Use **protocols** for polymorphism across types.
- Design **data models** that encapsulate behavior and validation.
- Leverage **supervision trees** for process management.
- Favor **message passing** over shared state.
- Adopt the "let it crash" philosophy for error handling.
- Utilize **Registry** for process discovery.
- Separate public APIs from implementation details.
- Organize code for clarity and maintainability.
- Write comprehensive tests and documentation.
- Avoid common anti-patterns.

## **Core Principles for BEAM-Native Design:**

### **1. Behaviors as Contracts, Not Just Interfaces**

Behaviors should define **semantic contracts**, not just function signatures:

```elixir
# ❌ Too generic
@callback handle(data :: any()) :: any()

# ✅ Semantic and clear
@callback publish_event(event :: Event.t(), opts :: keyword()) :: 
  :ok | {:error, :connection_failed | :invalid_event}
```

### **2. Protocols for Polymorphism, Not Type Checking**

Use protocols when you need **runtime polymorphism** across types you don't control:

```elixir
# Your Comn.Event protocol is good, but could be more specific:
defprotocol Comn.Event do
  @doc """
  Converts a term into a normalized EventStruct.
  
  Implementations should validate the term and return a complete
  EventStruct with :id, :type, :timestamp, and :payload fields.
  """
  @spec to_event(term) :: {:ok, EventStruct.t()} | {:error, term()}
  def to_event(term)
end
```

### **3. Supervision Trees Over Ad-Hoc GenServers**

Your NATS module should be part of a supervision tree:

```elixir
defmodule Comn.Events.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Named process - no PID management needed
      {Comn.Events.NATS, name: Comn.Events.NATS},
      # Could add other adapters here
      {Comn.Events.Registry, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
```

Then your NATS module becomes:

```elixir
defmodule Comn.Events.NATS do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  # No PID needed - use module name
  def broadcast(topic, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:broadcast, topic, payload, opts})
  end
end
```

### **4. Data Models as First-Class Citizens**

Your structs should carry behavior and validation:

```elixir
# arch/data_models/event_struct.ex
defmodule Comn.EventStruct do
  @enforce_keys [:id, :type, :timestamp]
  defstruct [:id, :type, :timestamp, :payload, :metadata]
  
  @type t :: %__MODULE__{
    id: String.t(),
    type: atom(),
    timestamp: DateTime.t(),
    payload: term(),
    metadata: map()
  }
  
  @doc "Creates a new event with generated ID and timestamp"
  def new(type, payload, metadata \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      type: type,
      timestamp: DateTime.utc_now(),
      payload: payload,
      metadata: metadata
    }
  end
  
  @doc "Validates event structure"
  def valid?(%__MODULE__{} = event) do
    not is_nil(event.id) and 
    is_atom(event.type) and
    %DateTime{} = event.timestamp
  end
  
  defp generate_id, do: UUID.uuid4()
end
```

### **5. Let It Crash - Use Error Tuples Wisely**

Don't catch everything - let GenServers crash and restart:

```elixir
# ❌ Over-defensive
def handle_call({:broadcast, topic, payload, opts}, _from, state) do
  try do
    result = Gnat.pub(state.conn_pid, topic, payload)
    {:reply, {:ok, result}, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end
end

# ✅ Let it crash for unexpected errors, handle expected ones
def handle_call({:broadcast, topic, payload, opts}, _from, state) do
  case Gnat.pub(state.conn_pid, topic, payload) do
    :ok -> {:reply, :ok, state}
    {:error, :not_connected} -> 
      # Expected error - maybe trigger reconnect
      {:reply, {:error, :not_connected}, state}
    # Unexpected errors crash and restart via supervisor
  end
end
```

### **6. Message Passing Over Shared State**

Instead of storing subscriptions in GenServer state, use message passing:

```elixir
# Instead of tracking subscriptions in state,
# let each subscriber be its own process
defmodule Comn.Events.Subscriber do
  use GenServer
  
  def start_link(topic, handler) do
    GenServer.start_link(__MODULE__, {topic, handler})
  end
  
  def init({topic, handler}) do
    Comn.Events.NATS.subscribe(self(), topic)
    {:ok, %{topic: topic, handler: handler}}
  end
  
  def handle_info({:nats_msg, msg}, state) do
    state.handler.(msg)
    {:noreply, state}
  end
end
```

### **7. Use Registry for Process Discovery**

Instead of managing PIDs, use Registry:

```elixir
# Start in your application.ex
children = [
  {Registry, keys: :unique, name: Comn.Events.Registry},
  Comn.Events.Supervisor
]

# Then in your code:
def start_adapter(adapter_module, opts) do
  Registry.register(Comn.Events.Registry, adapter_module, opts)
  adapter_module.start_link(opts)
end

def broadcast(topic, payload) do
  adapters = Registry.lookup(Comn.Events.Registry, :adapters)
  Enum.each(adapters, fn {pid, _} -> 
    send(pid, {:broadcast, topic, payload})
  end)
end
```

## **Recommended Structure for Your Project:**

```bash
apps/events/
  lib/comn/
    events.ex              # Public API (no GenServer)
    events/
      adapter.ex           # Behaviour definition
      supervisor.ex        # Supervision tree
      nats.ex             # NATS adapter (GenServer)
      registry.ex         # Registry adapter (ETS-based)
      subscriber.ex       # Subscription handler process

arch/
  data_models/
    event_struct.ex       # Event data model with behavior
    repo_struct.ex        # Repo data model
```

Would you like me to refactor any specific module following these principles?

imsmith: go ahead and draft this style guide as a .md file

GitHub Copilot: Optimizing tool selection...

imsmith: @agent Try Again

GitHub Copilot: Created [](file:///home/imsmith/github/comn/BEAM_STYLE_GUIDE.md)

I've created a comprehensive BEAM/Elixir style guide at BEAM_STYLE_GUIDE.md.

The guide covers:

1. **Behaviors as Contracts** - Semantic, clear contracts with documented error cases
2. **Protocols for Polymorphism** - When and how to use protocols effectively
3. **Supervision Trees** - Proper process supervision and named processes
4. **Rich Data Models** - Structs with behavior, validation, and construction logic
5. **Let It Crash** - Distinguishing expected vs unexpected errors
6. **Message Passing** - Process-per-entity patterns over shared state
7. **Registry Usage** - Process discovery without PID management
8. **API Design** - Separating public API from implementation
9. **Testing** - BEAM-aware testing patterns
10. **Documentation** - Complete doc standards
11. **Project Organization** - File structure recommendations
12. **Anti-Patterns** - Common mistakes to avoid

There are some markdown linting warnings (spacing around headings/lists), but the content is complete and readable. Would you like me to clean up the formatting to satisfy the linter?

Made changes.

imsmith: yes

GitHub Copilot: Using "Replace String in File"

```exlir

```

Using "Replace String in File"

```elixir

```

Using "Replace String in File"

```elixir

```

Using "Replace String in File"

```elixir

```

Using "Replace String in File"

```elixir

```

Let me fix all the remaining linting issues in a more efficient way by reading the file and making comprehensive fixes:

Read [](file:///home/imsmith/github/comn/BEAM_STYLE_GUIDE.md#95-95), lines 95 to 400

Let me create a corrected version of the file with all proper spacing:

Ran terminal command: cat > /home/imsmith/github/comn/BEAM_STYLE_GUIDE_FIXED.md << 'EOF'

# BEAM/Elixir Style Guide for Comn Project

This guide outlines coding standards and design principles for writing idiomatic BEAM/Elixir code that leverages OTP's unique characteristics.

## Core Philosophy

Write code that embraces the BEAM's strengths:

- **Process isolation and supervision**
- **Message passing over shared state**
- **Let it crash philosophy**
- **Runtime polymorphism through protocols**
- **Semantic contracts through behaviors**

---

## 1. Behaviors as Contracts, Not Just Interfaces

Behaviors should define **semantic contracts** with clear expectations, error cases, and return types.

### ❌ Avoid: Generic, unclear signatures

```elixir
@callback handle(data :: any()) :: any()
@callback process(input :: term()) :: term()
```

### ✅ Prefer: Specific, semantic contracts

```elixir
@callback publish_event(event :: Event.t(), opts :: keyword()) :: 
  :ok | {:error, :connection_failed | :invalid_event | :timeout}

@callback subscribe(topic :: String.t(), handler :: pid(), opts :: keyword()) ::
  {:ok, subscription_id :: String.t()} | {:error, :invalid_topic | :handler_not_alive}
```

**Guidelines:**

- Document all possible return values
- Use specific error atoms, not generic ones
- Include clear `@doc` with examples
- Define types for complex parameters

---

## 2. Protocols for Runtime Polymorphism

Use protocols when you need **polymorphism across types you don't control**, not for simple type checking.

### ✅ Good Protocol Design

```elixir
defprotocol Comn.Event do
  @moduledoc """
  Converts various Elixir terms (map, struct, tuple) into a normalized EventStruct.
  
  Implementations should validate the input and return a complete EventStruct
  with all required fields populated.
  """
  
  @doc """
  Converts a term into an EventStruct.
  
  ## Returns
    - `{:ok, %EventStruct{}}` on successful conversion
    - `{:error, reason}` if conversion fails
  
  ## Examples
  
      iex> Comn.Event.to_event(%{type: :user_created, data: %{id: 1}})
      {:ok, %EventStruct{type: :user_created, payload: %{id: 1}, ...}}
  """
  @spec to_event(term) :: {:ok, EventStruct.t()} | {:error, term()}
  def to_event(term)
end
```

**When to use protocols:**

- Converting multiple types to a common structure
- Extending behavior for types from other libraries
- Implementing polymorphic operations (e.g., serialization, validation)

**When NOT to use protocols:**

- Simple type dispatch (use pattern matching)
- Internal module functions (use private functions)
- When a behavior is more appropriate

---

## 3. Supervision Trees Over Ad-Hoc GenServers

Every GenServer should be part of a supervision tree. Never start processes manually outside of supervision.

### ✅ Proper Supervision Structure

```elixir
# apps/events/lib/comn/events/supervisor.ex
defmodule Comn.Events.Supervisor do
  use Supervisor

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl true
  def init(_init_arg) do
    children = [
      # Named processes - no PID management needed by users
      {Comn.Events.NATS, name: Comn.Events.NATS},
      {Comn.Events.Registry, name: Comn.Events.Registry}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

# In your application.ex
def start(_type, _args) do
  children = [
    Comn.Events.Supervisor,
    Comn.Repo.Supervisor
  ]
  
  Supervisor.start_link(children, strategy: :one_for_one, name: Comn.Supervisor)
end
```

### ✅ Named GenServers

```elixir
defmodule Comn.Events.NATS do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  # No PID needed - use module name directly
  def broadcast(topic, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:broadcast, topic, payload, opts})
  end
  
  def subscribe(topic, opts \\ []) do
    GenServer.call(__MODULE__, {:subscribe, topic, opts})
  end
end
```

**Benefits:**

- No PID management for users
- Automatic restart on crashes
- Clear process hierarchy
- Easier testing and debugging

---

## 4. Data Models as First-Class Citizens

Structs should be more than containers - they should carry behavior, validation, and construction logic.

### ✅ Rich Data Models

```elixir
# arch/data_models/event_struct.ex
defmodule Comn.EventStruct do
  @moduledoc """
  Represents a normalized event in the Comn system.
  """
  
  @enforce_keys [:id, :type, :timestamp]
  defstruct [:id, :type, :timestamp, :payload, :metadata]
  
  @type t :: %__MODULE__{
    id: String.t(),
    type: atom(),
    timestamp: DateTime.t(),
    payload: term(),
    metadata: map()
  }
  
  @doc """
  Creates a new event with generated ID and timestamp.
  
  ## Examples
  
      iex> EventStruct.new(:user_created, %{user_id: 123})
      %EventStruct{id: "...", type: :user_created, ...}
  """
  @spec new(atom(), term(), map()) :: t()
  def new(type, payload, metadata \\ %{}) do
    %__MODULE__{
      id: generate_id(),
      type: type,
      timestamp: DateTime.utc_now(),
      payload: payload,
      metadata: metadata
    }
  end
  
  @doc "Validates that the event has all required fields"
  @spec valid?(t()) :: boolean()
  def valid?(%__MODULE__{} = event) do
    not is_nil(event.id) and 
    is_atom(event.type) and
    match?(%DateTime{}, event.timestamp)
  end
  
  @doc "Serializes event to a wire format"
  @spec serialize(t()) :: binary()
  def serialize(%__MODULE__{} = event) do
    :erlang.term_to_binary(event)
  end
  
  @doc "Deserializes event from wire format"
  @spec deserialize(binary()) :: {:ok, t()} | {:error, term()}
  def deserialize(binary) when is_binary(binary) do
    try do
      event = :erlang.binary_to_term(binary)
      if valid?(event), do: {:ok, event}, else: {:error, :invalid_event}
    rescue
      _ -> {:error, :deserialization_failed}
    end
  end
  
  defp generate_id, do: UUID.uuid4() # or your preferred ID generation
end
```

**Guidelines:**

- Use `@enforce_keys` for required fields
- Provide constructor functions (e.g., `new/2`, `from_map/1`)
- Add validation functions
- Include serialization/deserialization when needed
- Define clear `@type` specs
- Keep structs in `arch/data_models/`

---

## 5. Let It Crash - Use Error Tuples Wisely

Distinguish between **expected errors** (return tuples) and **unexpected errors** (let it crash).

### ❌ Avoid: Over-defensive error handling

```elixir
def handle_call({:broadcast, topic, payload, opts}, _from, state) do
  try do
    result = Gnat.pub(state.conn_pid, topic, payload)
    {:reply, {:ok, result}, state}
  rescue
    e -> {:reply, {:error, e}, state}
  end
end
```

### ✅ Prefer: Let unexpected errors crash

```elixir
def handle_call({:broadcast, topic, payload, opts}, _from, state) do
  case Gnat.pub(state.conn_pid, topic, payload) do
    :ok -> 
      {:reply, :ok, state}
    {:error, :not_connected} -> 
      # Expected error - handle gracefully, maybe trigger reconnect
      schedule_reconnect()
      {:reply, {:error, :not_connected}, state}
    # Other errors crash and restart via supervisor
  end
end
```

**Expected errors to handle:**

- Network disconnections
- Invalid user input
- Resource not found
- Permission denied
- Timeouts

**Unexpected errors to let crash:**

- Programming bugs
- Corrupted state
- Violated invariants
- External library crashes

---

## 6. Message Passing Over Shared State

Favor process-per-entity patterns and message passing over managing complex state in a single GenServer.

### ❌ Avoid: Centralized state management

```elixir
defmodule EventManager do
  use GenServer
  
  # State grows unbounded with subscriptions
  def init(_) do
    {:ok, %{subscriptions: %{}, messages: [], handlers: []}}
  end
end
```

### ✅ Prefer: Process-per-entity

```elixir
# Each subscription is its own process
defmodule Comn.Events.Subscriber do
  use GenServer
  
  def start_link(topic, handler_fn) do
    GenServer.start_link(__MODULE__, {topic, handler_fn})
  end
  
  def init({topic, handler_fn}) do
    # Subscribe this process to the topic
    Comn.Events.NATS.subscribe_pid(self(), topic)
    {:ok, %{topic: topic, handler: handler_fn}}
  end
  
  def handle_info({:event, event}, state) do
    state.handler.(event)
    {:noreply, state}
  end
end

# Manage subscribers via DynamicSupervisor
defmodule Comn.Events.SubscriberSupervisor do
  use DynamicSupervisor
  
  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end
  
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
  
  def start_subscriber(topic, handler_fn) do
    DynamicSupervisor.start_child(
      __MODULE__, 
      {Comn.Events.Subscriber, {topic, handler_fn}}
    )
  end
end
```

---

## 7. Use Registry for Process Discovery

Instead of passing PIDs around, use `Registry` for process discovery and pub/sub patterns.

### ✅ Registry-Based Architecture

```elixir
# In application.ex
children = [
  {Registry, keys: :duplicate, name: Comn.Events.PubSub},
  {Registry, keys: :unique, name: Comn.Events.AdapterRegistry},
  Comn.Events.Supervisor
]

# Register adapters
defmodule Comn.Events.NATS do
  def init(opts) do
    Registry.register(Comn.Events.AdapterRegistry, :nats_adapter, %{})
    # ... connect to NATS
  end
end

# Broadcasting to multiple adapters
defmodule Comn.Events do
  def broadcast(topic, event) do
    # Find all registered adapters
    Registry.lookup(Comn.Events.AdapterRegistry, :adapters)
    |> Enum.each(fn {pid, _meta} ->
      send(pid, {:broadcast, topic, event})
    end)
  end
end

# Pub/sub pattern
defmodule Comn.Events do
  def subscribe(subscriber_pid, topic) do
    Registry.register(Comn.Events.PubSub, topic, [])
  end
  
  def publish(topic, event) do
    Registry.dispatch(Comn.Events.PubSub, topic, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:event, topic, event})
    end)
  end
end
```

---

## 8. Public API vs Implementation

Separate public API from GenServer implementation details.

### ✅ Clean API Separation

```elixir
defmodule Comn.Events do
  @moduledoc """
  Public API for the Comn Events system.
  
  This module provides a unified interface for publishing and subscribing
  to events across multiple backends (NATS, Rabbit, Registry, etc.).
  """
  
  # Public API - no GenServer details leak out
  
  @doc "Publishes an event to all registered adapters"
  @spec broadcast(String.t(), EventStruct.t()) :: :ok | {:error, term()}
  def broadcast(topic, %EventStruct{} = event) do
    # Implementation delegates to adapters
    Comn.Events.Router.broadcast(topic, event)
  end
  
  @doc "Subscribes the calling process to a topic"
  @spec subscribe(String.t(), keyword()) :: :ok | {:error, term()}
  def subscribe(topic, opts \\ []) do
    Comn.Events.Router.subscribe(self(), topic, opts)
  end
end

# Implementation module (internal)
defmodule Comn.Events.Router do
  use GenServer
  
  # This module handles routing, but users never call it directly
  # ...
end
```

---

## 9. Testing Guidelines

Write tests that embrace BEAM semantics.

### ✅ Testing Processes

```elixir
defmodule Comn.Events.NATSTest do
  use ExUnit.Case, async: true
  
  setup do
    # Start supervised process for each test
    {:ok, pid} = start_supervised(Comn.Events.NATS)
    %{nats: pid}
  end
  
  test "broadcasts event to subscribers", %{nats: nats} do
    # Subscribe this test process
    Comn.Events.NATS.subscribe("test.topic")
    
    # Broadcast
    :ok = Comn.Events.NATS.broadcast("test.topic", "test payload")
    
    # Assert we received the message
    assert_receive {:event, "test.topic", "test payload"}, 1000
  end
  
  test "handles connection failure gracefully" do
    # Test expected error cases
    assert {:error, :not_connected} = Comn.Events.NATS.broadcast("topic", "msg")
  end
end
```

---

## 10. Documentation Standards

Every public module and function must have clear documentation.

### ✅ Complete Documentation

```elixir
defmodule Comn.Events.Adapter do
  @moduledoc """
  Behaviour defining the interface for event backends (NATS, Rabbit, Kafka, etc.).
  
  Implement this behaviour to create a new event backend for Comn.Events.
  
  ## Example Implementation
  
      defmodule MyBackend do
        @behaviour Comn.Events.Adapter
        
        def start_link(opts) do
          # ...
        end
        
        def broadcast(event, opts) do
          # ...
        end
      end
  
  ## Configuration
  
      config :comn, :event_adapters, [
        {MyBackend, [host: "localhost", port: 5672]}
      ]
  """
  
  @type event_struct :: EventStruct.t()
  
  @doc """
  Starts the adapter process.
  
  Called by the supervisor during application startup.
  """
  @callback start_link(opts :: keyword()) :: {:ok, pid()} | {:error, term()}
  
  @doc """
  Broadcasts an event to the backend.
  
  ## Options
    - `:timeout` - Request timeout in milliseconds (default: 5000)
    - `:priority` - Message priority (default: :normal)
  
  ## Returns
    - `:ok` - Event successfully published
    - `{:error, :not_connected}` - Backend is disconnected
    - `{:error, :invalid_event}` - Event validation failed
  """
  @callback broadcast(event_struct, opts :: keyword()) :: :ok | {:error, term()}
end
```

---

## 11. File and Module Organization

```text
apps/
  events/
    lib/
      comn/
        events.ex                    # Public API
        event.ex                     # Protocol
        events/
          adapter.ex                 # Behaviour
          supervisor.ex              # Supervision tree
          router.ex                  # Internal routing logic
          subscriber.ex              # Subscriber process
          nats.ex                    # NATS adapter
          rabbit.ex                  # RabbitMQ adapter
          registry.ex                # Local registry adapter
  
  repo/
    lib/
      comn/
        repo.ex                      # Public API
        repo/
          adapter.ex                 # Behaviour
          supervisor.ex
          cmd/
            shell.ex
          file/
            local.ex
            cifs.ex
          graph.ex
          
arch/
  data_models/
    event_struct.ex                  # Event data model
    repo_struct.ex                   # Repo data model
    file_struct.ex                   # File-specific model
    graph_struct.ex                  # Graph-specific model
```

---

## 12. Anti-Patterns to Avoid

### ❌ Exposing GenServer Implementation Details

```elixir
# Don't make users call GenServer directly
def get_state(pid) do
  GenServer.call(pid, :get_state)
end
```

### ❌ Using Process Dictionary

```elixir
# Avoid process dictionary for state
Process.put(:config, config)
```

### ❌ Catching All Errors

```elixir
# Don't catch everything - let it crash
try do
  dangerous_operation()
rescue
  _ -> :ok  # Hides real problems
end
```

### ❌ Large GenServer State

```elixir
# If your state is huge, split into multiple processes
%{
  users: %{}, # 10,000 entries
  sessions: %{}, # 50,000 entries
  cache: %{}, # 1,000,000 entries
  # ... this should be multiple processes/ETS tables
}
```

### ❌ Synchronous Chains

```elixir
# Avoid long chains of synchronous calls
def handle_call(:process, _from, state) do
  result = GenServer.call(ServiceA, :step1)
  result2 = GenServer.call(ServiceB, :step2)
  result3 = GenServer.call(ServiceC, :step3)
  {:reply, result3, state}
end
```

---

## Summary Checklist

- [ ] All GenServers are supervised
- [ ] Processes are named and discoverable
- [ ] Behaviors define clear semantic contracts
- [ ] Protocols used for polymorphism
- [ ] Data models are rich with behavior
- [ ] Expected errors return tuples, unexpected errors crash
- [ ] Message passing preferred over shared state
- [ ] Public API separated from implementation
- [ ] All public functions documented
- [ ] Tests use `start_supervised`
- [ ] No process dictionary usage
- [ ] Registry used for process discovery

---

## Resources

- [Elixir GenServer Guide](https://hexdocs.pm/elixir/GenServer.html)
- [OTP Design Principles](https://www.erlang.org/doc/design_principles/des_princ.html)
- [Elixir School - OTP Supervisors](https://elixirschool.com/en/lessons/advanced/otp_supervisors)
- [Registry Documentation](https://hexdocs.pm/elixir/Registry.html)
EOF

Made changes.
