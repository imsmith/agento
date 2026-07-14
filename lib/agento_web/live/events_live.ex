defmodule AgentoWeb.EventsLive do
  @moduledoc """
  Event Explorer LiveView -- live stream + query interface.
  Implements R3 (Event Explorer).
  """
  use AgentoWeb, :live_view

  alias AgentoWeb.Discovery.Events
  alias Agento.EventBusBridge

  @max_stream_events 200

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EventBusBridge.pubsub(), EventBusBridge.pubsub_topic())
    end

    socket =
      socket
      |> assign(
        active_nav: :events,
        live_events: [],
        auto_scroll: true,
        # Rows whose data payload is expanded inline (R3.1)
        expanded_rows: MapSet.new(),
        # Filters
        filter_topic: "",
        filter_type: "",
        filter_agent_id: "",
        filter_from: "",
        filter_to: "",
        # Dropdown options (discovered)
        known_topics: Events.topics(),
        known_types: Events.types(),
        # Merge topics observed in events with currently-running agents (R3.2)
        known_agents: merged_agent_ids(),
        # Tab: :live | :durable_log | :event_log
        active_tab: :live,
        # Query results
        query_agent_id: "",
        query_since: "",
        query_results: [],
        # EventLog query
        eventlog_mode: "all",
        eventlog_filter: "",
        eventlog_results: [],
        # Selected event detail
        selected_event: nil
      )

    {:ok, socket}
  end

  # -- PubSub events --

  @impl true
  def handle_info({topic, event}, socket) when is_binary(topic) do
    Events.track(event)

    new_events =
      [{topic, event} | socket.assigns.live_events]
      |> Enum.take(@max_stream_events)

    socket =
      socket
      |> assign(live_events: new_events)
      |> update_known_filters(topic, event)

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- User events --

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: String.to_existing_atom(tab))}
  end

  def handle_event("toggle_auto_scroll", _params, socket) do
    {:noreply, assign(socket, auto_scroll: !socket.assigns.auto_scroll)}
  end

  def handle_event("toggle_row", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    expanded = socket.assigns.expanded_rows

    expanded =
      if MapSet.member?(expanded, index) do
        MapSet.delete(expanded, index)
      else
        MapSet.put(expanded, index)
      end

    {:noreply, assign(socket, expanded_rows: expanded)}
  end

  def handle_event("clear_stream", _params, socket) do
    {:noreply, assign(socket, live_events: [])}
  end

  # Filters
  def handle_event("update_filter", params, socket) do
    {:noreply,
     assign(socket,
       filter_topic: Map.get(params, "topic", socket.assigns.filter_topic),
       filter_type: Map.get(params, "type", socket.assigns.filter_type),
       filter_agent_id: Map.get(params, "agent_id", socket.assigns.filter_agent_id),
       filter_from: Map.get(params, "from", socket.assigns.filter_from),
       filter_to: Map.get(params, "to", socket.assigns.filter_to)
     )}
  end

  def handle_event("clear_filters", _params, socket) do
    {:noreply,
     assign(socket,
       filter_topic: "",
       filter_type: "",
       filter_agent_id: "",
       filter_from: "",
       filter_to: ""
     )}
  end

  # DurableLog query (R3.3)
  def handle_event("update_durable_query", params, socket) do
    {:noreply,
     assign(socket,
       query_agent_id: Map.get(params, "agent_id", socket.assigns.query_agent_id),
       query_since: Map.get(params, "since", socket.assigns.query_since)
     )}
  end

  def handle_event("query_durable_log", params, socket) do
    agent_id = Map.get(params, "agent_id", socket.assigns.query_agent_id)
    query_since = Map.get(params, "since", socket.assigns.query_since)

    results =
      if agent_id != "" do
        agent_atom = String.to_existing_atom(agent_id)

        try do
          if query_since != "" do
            LLMAgent.DurableLog.events_for(agent_atom, since: query_since)
          else
            LLMAgent.DurableLog.events_for(agent_atom)
          end
        rescue
          # No DurableLog for this agent, or a malformed since-timestamp.
          _e in [ArgumentError, KeyError, MatchError] -> []
        end
      else
        []
      end

    {:noreply, assign(socket, query_results: results)}
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown agent ID")}
  end

  # EventLog query (R3.4)
  def handle_event("update_eventlog_query", params, socket) do
    {:noreply,
     assign(socket,
       eventlog_mode: Map.get(params, "mode", socket.assigns.eventlog_mode),
       eventlog_filter: Map.get(params, "filter", socket.assigns.eventlog_filter)
     )}
  end

  def handle_event("query_event_log", _params, socket) do
    results =
      try do
        case socket.assigns.eventlog_mode do
          "all" ->
            LLMAgent.EventLog.all()

          "for_topic" ->
            LLMAgent.EventLog.for_topic(socket.assigns.eventlog_filter)

          "for_type" ->
            LLMAgent.EventLog.for_type(String.to_existing_atom(socket.assigns.eventlog_filter))

          "since" ->
            LLMAgent.EventLog.since(socket.assigns.eventlog_filter)

          _ ->
            []
        end
      rescue
        # EventLog may be absent, or the filter may be an unknown atom/timestamp.
        _e in [ArgumentError, KeyError, MatchError] -> []
      end

    {:noreply, assign(socket, eventlog_results: results)}
  end

  # Event detail (R3.5)
  def handle_event("show_event", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    {_topic, event} = Enum.at(socket.assigns.live_events, index)
    {:noreply, assign(socket, selected_event: event)}
  end

  def handle_event("show_query_event", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    event = Enum.at(socket.assigns.query_results, index)
    {:noreply, assign(socket, selected_event: event)}
  end

  def handle_event("show_eventlog_event", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    event = Enum.at(socket.assigns.eventlog_results, index)
    {:noreply, assign(socket, selected_event: event)}
  end

  def handle_event("close_event_detail", _params, socket) do
    {:noreply, assign(socket, selected_event: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:events}>
      <div class="flex flex-col h-full">
        <%!-- Tabs --%>
        <div class="tabs tabs-bordered px-4 pt-2 bg-base-100 border-b border-base-300">
          <button
            phx-click="set_tab"
            phx-value-tab="live"
            class={["tab", @active_tab == :live && "tab-active"]}
          >
            Live Stream
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="durable_log"
            class={["tab", @active_tab == :durable_log && "tab-active"]}
          >
            DurableLog Query
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="event_log"
            class={["tab", @active_tab == :event_log && "tab-active"]}
          >
            EventLog Query
          </button>
        </div>

        <div class="flex-1 overflow-hidden flex">
          <%!-- Main content --%>
          <div class="flex-1 flex flex-col overflow-hidden">
            <%= case @active_tab do %>
              <% :live -> %>
                <.live_stream_panel
                  events={
                    filtered_events(
                      @live_events,
                      @filter_topic,
                      @filter_type,
                      @filter_agent_id,
                      @filter_from,
                      @filter_to
                    )
                  }
                  auto_scroll={@auto_scroll}
                  expanded_rows={@expanded_rows}
                  filter_topic={@filter_topic}
                  filter_type={@filter_type}
                  filter_agent_id={@filter_agent_id}
                  filter_from={@filter_from}
                  filter_to={@filter_to}
                  known_topics={@known_topics}
                  known_types={@known_types}
                  known_agents={@known_agents}
                />
              <% :durable_log -> %>
                <.durable_log_panel
                  query_agent_id={@query_agent_id}
                  query_since={@query_since}
                  query_results={@query_results}
                  known_agents={@known_agents}
                />
              <% :event_log -> %>
                <.event_log_panel
                  mode={@eventlog_mode}
                  filter={@eventlog_filter}
                  results={@eventlog_results}
                />
            <% end %>
          </div>

          <%!-- Event detail sidebar (R3.5) --%>
          <%= if @selected_event do %>
            <aside class="w-96 border-l border-base-300 bg-base-200 overflow-y-auto p-4">
              <div class="flex items-center justify-between mb-3">
                <h3 class="font-semibold">Event Detail</h3>
                <button phx-click="close_event_detail" class="btn btn-ghost btn-xs">
                  <.icon name="hero-x-mark-mini" class="size-4" />
                </button>
              </div>
              <.event_detail event={@selected_event} />
            </aside>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  # -- Subcomponents --

  defp live_stream_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <%!-- Filters --%>
      <div class="p-3 border-b border-base-300 bg-base-100">
        <form phx-change="update_filter" class="flex gap-2 items-end flex-wrap">
          <div>
            <label class="label text-xs">Topic</label>
            <select name="topic" class="select select-bordered select-sm">
              <option value="">All topics</option>
              <%= for t <- @known_topics do %>
                <option value={t} selected={@filter_topic == t}>{t}</option>
              <% end %>
            </select>
          </div>
          <div>
            <label class="label text-xs">Type</label>
            <select name="type" class="select select-bordered select-sm">
              <option value="">All types</option>
              <%= for t <- @known_types do %>
                <option value={t} selected={@filter_type == to_string(t)}>{t}</option>
              <% end %>
            </select>
          </div>
          <div>
            <label class="label text-xs">Agent</label>
            <select name="agent_id" class="select select-bordered select-sm">
              <option value="">All agents</option>
              <%= for a <- @known_agents do %>
                <option value={a} selected={@filter_agent_id == to_string(a)}>{a}</option>
              <% end %>
            </select>
          </div>
          <div>
            <label class="label text-xs">From</label>
            <input
              type="datetime-local"
              name="from"
              value={@filter_from}
              class="input input-bordered input-sm"
            />
          </div>
          <div>
            <label class="label text-xs">To</label>
            <input
              type="datetime-local"
              name="to"
              value={@filter_to}
              class="input input-bordered input-sm"
            />
          </div>
          <button type="button" phx-click="clear_filters" class="btn btn-ghost btn-sm">
            Clear
          </button>
          <div class="flex-1"></div>
          <button
            type="button"
            phx-click="toggle_auto_scroll"
            class={[
              "btn btn-sm",
              if(@auto_scroll, do: "btn-primary", else: "btn-ghost")
            ]}
          >
            Auto-scroll
          </button>
          <button type="button" phx-click="clear_stream" class="btn btn-ghost btn-sm">
            Clear stream
          </button>
        </form>
      </div>

      <%!-- Event list --%>
      <div
        class="flex-1 overflow-y-auto"
        id="event-stream"
        phx-hook="AutoScroll"
        data-auto-scroll={to_string(@auto_scroll)}
      >
        <%= if @events == [] do %>
          <p class="p-4 text-sm text-base-content/50">No events yet. Waiting for activity...</p>
        <% else %>
          <table class="table table-xs table-zebra w-full">
            <thead class="sticky top-0 bg-base-200">
              <tr>
                <th class="w-44">Timestamp</th>
                <th>Topic</th>
                <th>Type</th>
                <th>Source</th>
                <th class="w-8"></th>
                <th class="w-8"></th>
              </tr>
            </thead>
            <tbody>
              <%= for {{topic, event}, idx} <- Enum.with_index(@events) do %>
                <tr class="hover">
                  <td
                    class="font-mono text-xs cursor-pointer"
                    phx-click="show_event"
                    phx-value-index={idx}
                  >
                    {Map.get(event, :timestamp, "")}
                  </td>
                  <td
                    class="text-xs cursor-pointer"
                    phx-click="show_event"
                    phx-value-index={idx}
                  >
                    {topic}
                  </td>
                  <td class="text-xs">{Map.get(event, :type, "")}</td>
                  <td class="text-xs truncate max-w-32">{Map.get(event, :source, "")}</td>
                  <td>
                    <button
                      type="button"
                      phx-click="toggle_row"
                      phx-value-index={idx}
                      class="btn btn-ghost btn-xs"
                      title="Expand payload"
                    >
                      <.icon
                        name={
                          if MapSet.member?(@expanded_rows, idx),
                            do: "hero-chevron-down-mini",
                            else: "hero-chevron-right-mini"
                        }
                        class="size-3"
                      />
                    </button>
                  </td>
                  <td>
                    <button
                      type="button"
                      phx-click="show_event"
                      phx-value-index={idx}
                      class="btn btn-ghost btn-xs"
                      title="Open detail"
                    >
                      <.icon name="hero-arrow-top-right-on-square-mini" class="size-3" />
                    </button>
                  </td>
                </tr>
                <%= if MapSet.member?(@expanded_rows, idx) do %>
                  <tr class="bg-base-200">
                    <td colspan="6" class="p-0">
                      <pre class="text-xs font-mono bg-base-300 p-3 m-2 rounded whitespace-pre-wrap overflow-x-auto">{inspect(Map.get(event, :data, %{}), pretty: true)}</pre>
                    </td>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp durable_log_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-4 border-b border-base-300 bg-base-100">
        <h3 class="font-semibold mb-2">DurableLog Query (R3.3)</h3>
        <form
          phx-submit="query_durable_log"
          phx-change="update_durable_query"
          class="flex gap-2 items-end"
        >
          <div>
            <label class="label text-xs">Agent ID</label>
            <input
              type="text"
              name="agent_id"
              value={@query_agent_id}
              placeholder="agent_name"
              class="input input-bordered input-sm"
            />
          </div>
          <div>
            <label class="label text-xs">Since (ISO 8601, optional)</label>
            <input
              type="text"
              name="since"
              value={@query_since}
              placeholder="2026-02-24T00:00:00Z"
              class="input input-bordered input-sm"
            />
          </div>
          <button type="submit" class="btn btn-primary btn-sm">Query</button>
        </form>
      </div>

      <div class="flex-1 overflow-y-auto">
        <%= if @query_results == [] do %>
          <p class="p-4 text-sm text-base-content/50">No results. Run a query above.</p>
        <% else %>
          <table class="table table-xs table-zebra w-full">
            <thead class="sticky top-0 bg-base-200">
              <tr>
                <th class="w-44">Timestamp</th>
                <th>Topic</th>
                <th>Type</th>
                <th>Source</th>
                <th class="w-12"></th>
              </tr>
            </thead>
            <tbody>
              <%= for {event, idx} <- Enum.with_index(@query_results) do %>
                <tr class="hover cursor-pointer" phx-click="show_query_event" phx-value-index={idx}>
                  <td class="font-mono text-xs">{Map.get(event, :timestamp, "")}</td>
                  <td class="text-xs">{Map.get(event, :topic, "")}</td>
                  <td class="text-xs">{Map.get(event, :type, "")}</td>
                  <td class="text-xs truncate max-w-32">{Map.get(event, :source, "")}</td>
                  <td>
                    <.icon name="hero-chevron-right-mini" class="size-3" />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp event_log_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-4 border-b border-base-300 bg-base-100">
        <h3 class="font-semibold mb-2">EventLog Query (R3.4, in-memory)</h3>
        <form
          phx-submit="query_event_log"
          phx-change="update_eventlog_query"
          class="flex gap-2 items-end"
        >
          <div>
            <label class="label text-xs">Mode</label>
            <select name="mode" class="select select-bordered select-sm">
              <option value="all" selected={@mode == "all"}>all()</option>
              <option value="for_topic" selected={@mode == "for_topic"}>for_topic/1</option>
              <option value="for_type" selected={@mode == "for_type"}>for_type/1</option>
              <option value="since" selected={@mode == "since"}>since/1</option>
            </select>
          </div>
          <%= if @mode != "all" do %>
            <div>
              <label class="label text-xs">
                <%= case @mode do %>
                  <% "for_topic" -> %>
                    Topic
                  <% "for_type" -> %>
                    Type (atom)
                  <% "since" -> %>
                    Timestamp (ISO 8601)
                  <% _ -> %>
                    Filter
                <% end %>
              </label>
              <input
                type="text"
                name="filter"
                value={@filter}
                class="input input-bordered input-sm"
              />
            </div>
          <% end %>
          <button type="submit" class="btn btn-primary btn-sm">Query</button>
        </form>
      </div>

      <div class="flex-1 overflow-y-auto">
        <%= if @results == [] do %>
          <p class="p-4 text-sm text-base-content/50">No results. Run a query above.</p>
        <% else %>
          <table class="table table-xs table-zebra w-full">
            <thead class="sticky top-0 bg-base-200">
              <tr>
                <th class="w-44">Timestamp</th>
                <th>Topic</th>
                <th>Type</th>
                <th>Source</th>
              </tr>
            </thead>
            <tbody>
              <%= for {event, idx} <- Enum.with_index(@results) do %>
                <tr class="hover cursor-pointer" phx-click="show_eventlog_event" phx-value-index={idx}>
                  <td class="font-mono text-xs">{Map.get(event, :timestamp, "")}</td>
                  <td class="text-xs">{Map.get(event, :topic, "")}</td>
                  <td class="text-xs">{Map.get(event, :type, "")}</td>
                  <td class="text-xs truncate max-w-32">{Map.get(event, :source, "")}</td>
                </tr>
              <% end %>
            </tbody>
          </table>
        <% end %>
      </div>
    </div>
    """
  end

  defp event_detail(assigns) do
    ~H"""
    <div class="space-y-3 text-sm">
      <div>
        <span class="font-semibold">Timestamp:</span>
        <span class="font-mono">{Map.get(@event, :timestamp, "N/A")}</span>
      </div>
      <div>
        <span class="font-semibold">Topic:</span>
        <span>{Map.get(@event, :topic, "N/A")}</span>
      </div>
      <div>
        <span class="font-semibold">Type:</span>
        <span>{Map.get(@event, :type, "N/A")}</span>
      </div>
      <div>
        <span class="font-semibold">Source:</span>
        <span>{Map.get(@event, :source, "N/A")}</span>
      </div>
      <div>
        <span class="font-semibold">Data:</span>
        <pre class="mt-1 text-xs font-mono bg-base-300 p-3 rounded whitespace-pre-wrap overflow-x-auto">{inspect(Map.get(@event, :data, %{}), pretty: true)}</pre>
      </div>
    </div>
    """
  end

  # -- Helpers --

  defp filtered_events(events, topic, type, agent_id, from, to) do
    events
    |> maybe_filter_topic(topic)
    |> maybe_filter_type(type)
    |> maybe_filter_agent(agent_id)
    |> maybe_filter_from(from)
    |> maybe_filter_to(to)
  end

  defp maybe_filter_topic(events, ""), do: events

  defp maybe_filter_topic(events, topic) do
    Enum.filter(events, fn {t, _e} -> t == topic end)
  end

  defp maybe_filter_type(events, ""), do: events

  defp maybe_filter_type(events, type) do
    type_atom =
      try do
        String.to_existing_atom(type)
      rescue
        ArgumentError -> type
      end

    Enum.filter(events, fn {_t, e} -> Map.get(e, :type) == type_atom end)
  end

  defp maybe_filter_agent(events, ""), do: events

  defp maybe_filter_agent(events, agent_id) do
    Enum.filter(events, fn {_t, e} ->
      data = Map.get(e, :data, %{})
      aid = data[:agent_id] || data["agent_id"]
      to_string(aid) == agent_id
    end)
  end

  # Time-range filtering (R3.2). Boundaries come from datetime-local inputs
  # (naive, no zone); event timestamps are ISO-8601. Compare on naive datetimes.
  defp maybe_filter_from(events, ""), do: events

  defp maybe_filter_from(events, from) do
    case parse_boundary(from) do
      nil -> events
      boundary -> Enum.filter(events, &event_at_or_after?(&1, boundary))
    end
  end

  defp maybe_filter_to(events, ""), do: events

  defp maybe_filter_to(events, to) do
    case parse_boundary(to) do
      nil -> events
      boundary -> Enum.filter(events, &event_at_or_before?(&1, boundary))
    end
  end

  defp event_at_or_after?({_t, event}, boundary) do
    case event_naive(event) do
      nil -> false
      naive -> NaiveDateTime.compare(naive, boundary) != :lt
    end
  end

  defp event_at_or_before?({_t, event}, boundary) do
    case event_naive(event) do
      nil -> false
      naive -> NaiveDateTime.compare(naive, boundary) != :gt
    end
  end

  defp event_naive(event) do
    case Map.get(event, :timestamp) do
      ts when is_binary(ts) ->
        case DateTime.from_iso8601(ts) do
          {:ok, dt, _} -> DateTime.to_naive(dt)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # datetime-local yields "YYYY-MM-DDTHH:MM"; NaiveDateTime wants seconds.
  defp parse_boundary(value) do
    normalized =
      case String.split(value, ":") do
        [_h, _m] -> value <> ":00"
        _ -> value
      end

    case NaiveDateTime.from_iso8601(normalized) do
      {:ok, naive} -> naive
      _ -> nil
    end
  end

  # Merge agent IDs seen in events with currently-running agents (R3.2).
  defp merged_agent_ids do
    running =
      AgentoWeb.Discovery.Agents.list()
      |> Enum.map(& &1.name)

    (Events.agent_ids() ++ running)
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
  end

  defp update_known_filters(socket, topic, event) do
    topics = socket.assigns.known_topics
    types = socket.assigns.known_types
    agents = socket.assigns.known_agents

    new_topics = if topic in topics, do: topics, else: Enum.sort([topic | topics])

    type = Map.get(event, :type)
    new_types = if type == nil or type in types, do: types, else: Enum.sort([type | types])

    event_data = Map.get(event, :data, %{})
    agent_id = event_data[:agent_id] || event_data["agent_id"]

    new_agents =
      if agent_id == nil or agent_id in agents, do: agents, else: Enum.sort([agent_id | agents])

    assign(socket, known_topics: new_topics, known_types: new_types, known_agents: new_agents)
  end
end
