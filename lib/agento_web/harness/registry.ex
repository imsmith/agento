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
