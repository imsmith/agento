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

  # A source is a module, an atom, a string — or, from a rule's emit,
  # `{LLMAgent.Anemos.Channel, runtime}`. Only the first three are iodata.
  defp source_text(source) when is_binary(source) or is_atom(source), do: source
  defp source_text(source), do: inspect(source)

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:events}>
      <div class="flex flex-col h-full">
        <div class="ds-tabs">
          <div class="ds-tabs__list" role="tablist">
            <button
              :for={{id, label} <- tabs()}
              type="button"
              role="tab"
              class="ds-tab"
              aria-selected={to_string(@active_tab == id)}
              phx-click="set_tab"
              phx-value-tab={id}
            >
              <span>{label}</span>
            </button>
          </div>
        </div>

        <div class="flex-1 overflow-hidden flex gap-2 pt-1">
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

          <.card
            :if={@selected_event}
            title="Event detail"
            density={:compact}
            class="w-48 overflow-y-auto"
          >
            <:actions>
              <.button size={:sm} icon="m-close" phx-click="close_event_detail" title="Close">
                <span class="sr-only">Close</span>
              </.button>
            </:actions>
            <.event_detail event={@selected_event} />
          </.card>
        </div>
      </div>
    </.app>
    """
  end

  defp tabs,
    do: [live: "Live Stream", durable_log: "DurableLog Query", event_log: "EventLog Query"]

  # -- Subcomponents --

  defp live_stream_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <form
        id="live-filters"
        phx-change="update_filter"
        class="flex gap-1 items-end flex-wrap p-1 border-b border-border"
      >
        <.select name="topic" label="Topic" options={@known_topics} value={@filter_topic}>
          <option value="">All topics</option>
        </.select>
        <.select
          name="type"
          label="Type"
          options={Enum.map(@known_types, &to_string/1)}
          value={@filter_type}
        >
          <option value="">All types</option>
        </.select>
        <.select
          name="agent_id"
          label="Agent"
          options={Enum.map(@known_agents, &to_string/1)}
          value={@filter_agent_id}
        >
          <option value="">All agents</option>
        </.select>
        <.input type="datetime-local" name="from" label="From" value={@filter_from} />
        <.input type="datetime-local" name="to" label="To" value={@filter_to} />
        <.button type="button" size={:sm} phx-click="clear_filters">Clear</.button>
        <div class="flex-1"></div>
        <.freshness state={if @auto_scroll, do: :live, else: :paused} />
        <.button
          type="button"
          size={:sm}
          variant={if @auto_scroll, do: :primary, else: :ghost}
          phx-click="toggle_auto_scroll"
        >Auto-scroll</.button>
        <.button type="button" size={:sm} phx-click="clear_stream">Clear stream</.button>
      </form>

      <div
        class="flex-1 overflow-y-auto"
        id="event-stream"
        phx-hook="AutoScroll"
        data-auto-scroll={to_string(@auto_scroll)}
      >
        <.empty :if={@events == []}>No events yet. Waiting for activity.</.empty>
        <div :if={@events != []} class="overflow-x-auto">
          <table class="ds-table ds-table--dense w-full">
            <thead class="sticky top-0 bg-surface">
              <tr>
                <th class="ds-table__th w-22">Timestamp</th>
                <th class="ds-table__th">Topic</th>
                <th class="ds-table__th">Type</th>
                <th class="ds-table__th">Source</th>
                <th class="ds-table__th w-4"></th>
                <th class="ds-table__th w-4"></th>
              </tr>
            </thead>
            <tbody>
              <%= for {{topic, event}, idx} <- Enum.with_index(@events) do %>
                <tr class="ds-table__row ds-table__row--interactive">
                  <td class="ds-table__td cursor-pointer" phx-click="show_event" phx-value-index={idx}>
                    {Map.get(event, :timestamp, "")}
                  </td>
                  <td class="ds-table__td cursor-pointer" phx-click="show_event" phx-value-index={idx}>
                    {topic}
                  </td>
                  <td class="ds-table__td">{Map.get(event, :type, "")}</td>
                  <td class="ds-table__td truncate max-w-16">
                    {source_text(Map.get(event, :source, ""))}
                  </td>
                  <td class="ds-table__td">
                    <.button
                      type="button"
                      size={:sm}
                      variant={:text}
                      phx-click="toggle_row"
                      phx-value-index={idx}
                      title="Expand payload"
                      aria-expanded={to_string(MapSet.member?(@expanded_rows, idx))}
                    >
                      <.mark
                        name="m-chevron"
                        size={12}
                        class={MapSet.member?(@expanded_rows, idx) && "rotate-90"}
                      />
                    </.button>
                  </td>
                  <td class="ds-table__td">
                    <.button
                      type="button"
                      size={:sm}
                      variant={:text}
                      icon="m-external"
                      phx-click="show_event"
                      phx-value-index={idx}
                      title="Open detail"
                    >
                      <span class="sr-only">Open</span>
                    </.button>
                  </td>
                </tr>
                <tr :if={MapSet.member?(@expanded_rows, idx)}>
                  <td colspan="6" class="ds-table__td p-0">
                    <.pre value={Map.get(event, :data, %{})} class="m-1" />
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp durable_log_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-1 border-b border-border">
        <h3 class="ds-label mb-1">DurableLog query</h3>
        <form
          id="durable-log-query"
          phx-submit="query_durable_log"
          phx-change="update_durable_query"
          class="flex gap-1 items-end"
        >
          <.input name="agent_id" label="Agent ID" value={@query_agent_id} placeholder="agent_name" />
          <.input
            name="since"
            label="Since (ISO 8601, optional)"
            value={@query_since}
            placeholder="2026-02-24T00:00:00Z"
          />
          <.button type="submit" variant={:primary} size={:sm}>Query</.button>
        </form>
      </div>
      <div class="flex-1 overflow-y-auto">
        <.empty :if={@query_results == []}>No results. Run a query above.</.empty>
        <div :if={@query_results != []} class="overflow-x-auto">
          <table class="ds-table ds-table--dense w-full">
            <thead class="sticky top-0 bg-surface">
              <tr>
                <th class="ds-table__th w-22">Timestamp</th><th class="ds-table__th">Topic</th><th class="ds-table__th">
                  Type
                </th><th class="ds-table__th">Source</th><th class="ds-table__th w-4"></th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{event, idx} <- Enum.with_index(@query_results)}
                class="ds-table__row ds-table__row--interactive cursor-pointer"
                phx-click="show_query_event"
                phx-value-index={idx}
                tabindex="0"
              >
                <td class="ds-table__td">{Map.get(event, :timestamp, "")}</td>
                <td class="ds-table__td">{Map.get(event, :topic, "")}</td>
                <td class="ds-table__td">{Map.get(event, :type, "")}</td>
                <td class="ds-table__td truncate max-w-16">
                  {source_text(Map.get(event, :source, ""))}
                </td>
                <td class="ds-table__td"><.mark name="m-chevron" size={12} /></td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp event_log_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full">
      <div class="p-1 border-b border-border">
        <h3 class="ds-label mb-1">EventLog query (in-memory)</h3>
        <form
          id="event-log-query"
          phx-submit="query_event_log"
          phx-change="update_eventlog_query"
          class="flex gap-1 items-end"
        >
          <.select
            name="mode"
            label="Query mode"
            options={[
              {"all()", "all"},
              {"for_topic/1", "for_topic"},
              {"for_type/1", "for_type"},
              {"since/1", "since"}
            ]}
            value={@mode}
          />
          <.input :if={@mode != "all"} name="filter" label={filter_label(@mode)} value={@filter} />
          <.button type="submit" variant={:primary} size={:sm}>Query</.button>
        </form>
      </div>
      <div class="flex-1 overflow-y-auto">
        <.empty :if={@results == []}>No results. Run a query above.</.empty>
        <div :if={@results != []} class="overflow-x-auto">
          <table class="ds-table ds-table--dense w-full">
            <thead class="sticky top-0 bg-surface">
              <tr>
                <th class="ds-table__th w-22">Timestamp</th><th class="ds-table__th">Topic</th><th class="ds-table__th">
                  Type
                </th><th class="ds-table__th">Source</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={{event, idx} <- Enum.with_index(@results)}
                class="ds-table__row ds-table__row--interactive cursor-pointer"
                phx-click="show_eventlog_event"
                phx-value-index={idx}
                tabindex="0"
              >
                <td class="ds-table__td">{Map.get(event, :timestamp, "")}</td>
                <td class="ds-table__td">{Map.get(event, :topic, "")}</td>
                <td class="ds-table__td">{Map.get(event, :type, "")}</td>
                <td class="ds-table__td truncate max-w-16">
                  {source_text(Map.get(event, :source, ""))}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
    """
  end

  defp filter_label("for_topic"), do: "Topic"
  defp filter_label("for_type"), do: "Type (atom)"
  defp filter_label("since"), do: "Timestamp (ISO 8601)"
  defp filter_label(_), do: "Filter"

  defp event_detail(assigns) do
    ~H"""
    <.key_value density={:dense}>
      <:item key="Timestamp">{Map.get(@event, :timestamp, "N/A")}</:item>
      <:item key="Topic">{Map.get(@event, :topic, "N/A")}</:item>
      <:item key="Type">{Map.get(@event, :type, "N/A")}</:item>
      <:item key="Source">{source_text(Map.get(@event, :source, "N/A"))}</:item>
      <:item key="Data"><.pre value={Map.get(@event, :data, %{})} /></:item>
    </.key_value>
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
