defmodule Agento.EventBusBridge do
  @moduledoc """
  Bridge between LLMAgent.EventBus and Phoenix.PubSub.

  Subscribes to all known EventBus topics and rebroadcasts events
  to Phoenix.PubSub on the "agento:events" topic so that
  multiple LiveView processes can receive the same events.

  Periodically polls LLMAgent.Tools.all/0 to discover new tool
  topics and subscribe to them automatically.
  """

  use GenServer

  require Logger

  @pubsub Agento.PubSub
  @pubsub_topic "agento:events"
  @tool_poll_interval :timer.seconds(30)

  @known_topics [
    "agent.prompt",
    "agent.llm_response",
    "agent.tool_dispatch",
    "agent.message",
    "agent.error",
    "tool.inotify.event",
    "web.mount",
    "web.event",
    "web.prompt_sent",
    "web.agent_started",
    "web.agent_stopped",
    "web.history_cleared"
  ]

  # -- Public API --

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the PubSub topic that LiveViews should subscribe to."
  @spec pubsub_topic() :: String.t()
  def pubsub_topic, do: @pubsub_topic

  @doc "Returns the PubSub name used by the bridge."
  @spec pubsub() :: atom()
  def pubsub, do: @pubsub

  # -- GenServer callbacks --

  @impl true
  def init(_opts) do
    subscribed = subscribe_to_topics(@known_topics, MapSet.new())
    tool_topics = discover_tool_topics()
    subscribed = subscribe_to_topics(tool_topics, subscribed)

    schedule_tool_poll()

    {:ok, %{subscribed_topics: subscribed}}
  end

  @impl true
  def handle_info({:event, topic, event}, state) do
    Phoenix.PubSub.broadcast(@pubsub, @pubsub_topic, {topic, event})
    {:noreply, state}
  end

  def handle_info(:poll_tools, state) do
    tool_topics = discover_tool_topics()
    new_subscribed = subscribe_to_topics(tool_topics, state.subscribed_topics)
    schedule_tool_poll()
    {:noreply, %{state | subscribed_topics: new_subscribed}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # -- Private --

  defp subscribe_to_topics(topics, already_subscribed) do
    Enum.reduce(topics, already_subscribed, fn topic, acc ->
      if MapSet.member?(acc, topic) do
        acc
      else
        case LLMAgent.EventBus.subscribe(topic) do
          {:ok, _} ->
            Logger.debug("EventBusBridge subscribed to #{topic}")
            MapSet.put(acc, topic)

          {:error, reason} ->
            Logger.warning("EventBusBridge failed to subscribe to #{topic}: #{inspect(reason)}")
            acc
        end
      end
    end)
  end

  defp discover_tool_topics do
    try do
      LLMAgent.Tools.all()
      |> Enum.map(fn {name, _module} -> "tool.#{name}" end)
    rescue
      _ -> []
    end
  end

  defp schedule_tool_poll do
    Process.send_after(self(), :poll_tools, @tool_poll_interval)
  end
end
