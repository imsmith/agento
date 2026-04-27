defmodule LlmagentWebWeb.Discovery.Events do
  @moduledoc """
  Tracks observed event topics and types for the Event Explorer.

  Maintains an Agent-backed set of topics and types seen in the
  event stream, used to populate filter dropdowns dynamically.
  """

  use Agent

  @known_topics [
    "agent.prompt",
    "agent.llm_response",
    "agent.tool_dispatch",
    "agent.message",
    "agent.error"
  ]

  def start_link(_opts) do
    Agent.start_link(
      fn ->
        %{
          topics: MapSet.new(@known_topics),
          types: MapSet.new(),
          agent_ids: MapSet.new()
        }
      end,
      name: __MODULE__
    )
  end

  @doc "Records an observed event, tracking its topic, type, and agent_id."
  @spec track(map()) :: :ok
  def track(event) do
    Agent.update(__MODULE__, fn state ->
      state
      |> maybe_add(:topics, Map.get(event, :topic))
      |> maybe_add(:types, Map.get(event, :type))
      |> maybe_add_agent_id(event)
    end)
  end

  @doc "Returns all observed topics as a sorted list."
  @spec topics() :: [String.t()]
  def topics do
    Agent.get(__MODULE__, fn state ->
      state.topics |> MapSet.to_list() |> Enum.sort()
    end)
  end

  @doc "Returns all observed event types as a sorted list."
  @spec types() :: [atom()]
  def types do
    Agent.get(__MODULE__, fn state ->
      state.types |> MapSet.to_list() |> Enum.sort()
    end)
  end

  @doc "Returns all observed agent IDs as a sorted list."
  @spec agent_ids() :: [term()]
  def agent_ids do
    Agent.get(__MODULE__, fn state ->
      state.agent_ids |> MapSet.to_list() |> Enum.sort()
    end)
  end

  # -- Private --

  defp maybe_add(state, _key, nil), do: state

  defp maybe_add(state, key, value) do
    Map.update!(state, key, &MapSet.put(&1, value))
  end

  defp maybe_add_agent_id(state, event) do
    data = Map.get(event, :data, %{})

    case data[:agent_id] || data["agent_id"] do
      nil -> state
      agent_id -> Map.update!(state, :agent_ids, &MapSet.put(&1, agent_id))
    end
  end
end
