defmodule AgentoWeb.Harness.Registry do
  @moduledoc """
  The harness session store — web-tier state, not a backend process pool.

  A session is a plain record keyed by an opaque string id: its config
  (agent type, model, endpoint, tool policy, llm client), the canonical
  conversation `history`, the current `fold`, and memoized frame sequences for
  idempotent replay. There is no per-session process and no session-named atom;
  a lease `expires_at` (renewed on each turn) plus a periodic sweep drops idle
  records. Turns run as function calls over this state (`Harness.Turn`).
  """
  use GenServer

  @sweep_interval_ms 10_000

  @type session :: %{
          id: String.t(),
          config: map(),
          history: [map()],
          fold: non_neg_integer(),
          expires_at: DateTime.t()
        }

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Create a session with the given config + initial history; returns the public record."
  @spec create(map(), [map()], pos_integer()) :: {:ok, session()}
  def create(config, history, ttl_ms), do: GenServer.call(__MODULE__, {:create, config, history, ttl_ms})

  @spec lookup(String.t()) :: {:ok, session()} | {:error, :not_found}
  def lookup(id), do: GenServer.call(__MODULE__, {:lookup, id})

  @spec renew(String.t()) :: :ok | {:error, :not_found}
  def renew(id), do: GenServer.call(__MODULE__, {:renew, id})

  @spec current_fold(String.t()) :: {:ok, non_neg_integer()} | {:error, :not_found}
  def current_fold(id), do: GenServer.call(__MODULE__, {:current_fold, id})

  @doc "Advance the fold, memoize the turn's frames, and set the new canonical history."
  @spec commit_turn(String.t(), non_neg_integer(), String.t(), [map()], [map()]) ::
          {:ok, non_neg_integer()} | {:error, :not_found}
  def commit_turn(id, fold, hash, frames, history),
    do: GenServer.call(__MODULE__, {:commit, id, fold, hash, frames, history})

  @spec replay(String.t(), non_neg_integer(), String.t()) :: {:ok, [map()]} | :miss
  def replay(id, fold, hash), do: GenServer.call(__MODULE__, {:replay, id, fold, hash})

  @spec sweep() :: :ok
  def sweep, do: GenServer.call(__MODULE__, :sweep)

  # -- Server --

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{sessions: %{}}}
  end

  @impl true
  def handle_call({:create, config, history, ttl_ms}, _from, state) do
    id = "hns_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    session = %{
      id: id,
      config: config,
      history: history,
      fold: 0,
      turns: %{},
      expires_at: expiry(ttl_ms),
      ttl_ms: ttl_ms
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

  def handle_call({:commit, id, fold, hash, frames, history}, _from, state) do
    with_session(state, id, fn s ->
      # Advance from the session's actual current fold, not the caller-supplied
      # one, so a stale/racing caller cannot move the fold backward.
      _ = fold
      next = s.fold + 1
      s = %{s | fold: next, history: history, turns: Map.put(s.turns, {s.fold, hash}, frames)}
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

  # Drop expired records. No process to stop — the session is just data.
  defp do_sweep(state) do
    now = now()

    live =
      Map.reject(state.sessions, fn {_id, s} ->
        DateTime.compare(s.expires_at, now) == :lt
      end)

    %{state | sessions: live}
  end

  defp public(s), do: Map.take(s, [:id, :config, :history, :fold, :expires_at])
  defp expiry(ttl_ms), do: DateTime.add(now(), ttl_ms, :millisecond)
  defp now, do: DateTime.utc_now()
  defp schedule_sweep, do: Process.send_after(self(), :sweep, @sweep_interval_ms)
end
