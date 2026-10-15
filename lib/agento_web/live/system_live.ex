defmodule AgentoWeb.SystemLive do
  @moduledoc """
  System inspection LiveView -- supervision tree, ETS, contexts, errors, DurableLog.
  Implements R4 (Supervision Tree), R5 (Comn Inspector), R7 (DurableLog Inspector).
  """
  use AgentoWeb, :live_view

  alias AgentoWeb.Discovery.{Agents, Behaviours}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        active_nav: :system,
        # Tab: :sup_tree | :ets | :contexts | :errors | :modules | :durable_log
        active_tab: :sup_tree,
        # Supervision tree (R4)
        tree: [],
        auto_refresh: false,
        # ETS (R5.1)
        ets_tables: [],
        selected_table: nil,
        table_entries: [],
        # Contexts (R5.2)
        agent_contexts: [],
        # Errors (R5.3)
        error_categories: [],
        error_events: [],
        # Modules (R5.4)
        comn_modules: [],
        selected_module: nil,
        module_introspection: nil,
        # DurableLog (R7)
        durable_status: nil,
        durable_agents: [],
        durable_selected: nil,
        durable_info: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("set_tab", %{"tab" => tab}, socket) do
    tab_atom = String.to_existing_atom(tab)
    socket = load_tab_data(tab_atom, socket)
    {:noreply, assign(socket, active_tab: tab_atom)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, load_tab_data(socket.assigns.active_tab, socket)}
  end

  # -- Supervision tree events (R4) --

  def handle_event("toggle_auto_refresh", _params, socket) do
    auto = !socket.assigns.auto_refresh

    if auto do
      Process.send_after(self(), :auto_refresh, 5000)
    end

    {:noreply, assign(socket, auto_refresh: auto)}
  end

  # -- ETS events (R5.1) --

  def handle_event("select_ets_table", %{"name" => name}, socket) do
    table_name = String.to_existing_atom(name)

    entries =
      try do
        Comn.Repo.Table.ETS.observe(table_name, [])
      rescue
        ArgumentError -> []
      end

    {:noreply, assign(socket, selected_table: name, table_entries: entries)}
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown table: #{name}")}
  end

  # -- Contexts events (R5.2) --

  # -- Error catalog events (R5.3) --

  # -- Module introspection events (R5.4) --

  def handle_event("select_module", %{"module" => mod_str}, socket) do
    module = String.to_existing_atom(mod_str)

    introspection =
      try do
        %{
          look: module.look(),
          recon: module.recon(),
          choices: module.choices()
        }
      rescue
        ArgumentError -> nil
      end

    {:noreply, assign(socket, selected_module: mod_str, module_introspection: introspection)}
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown module")}
  end

  # -- DurableLog events (R7) --

  def handle_event("select_durable_agent", %{"agent" => agent_str}, socket) do
    agent = String.to_existing_atom(agent_str)

    info =
      try do
        events = LLMAgent.DurableLog.events_for(agent)
        messages = LLMAgent.DurableLog.messages_for(agent)

        first_ts =
          case events do
            [first | _] -> Map.get(first, :timestamp)
            _ -> nil
          end

        last_ts =
          case Enum.reverse(events) do
            [last | _] -> Map.get(last, :timestamp)
            _ -> nil
          end

        %{
          agent: agent,
          event_count: length(events),
          message_count: length(messages),
          first_timestamp: first_ts,
          last_timestamp: last_ts
        }
      rescue
        ArgumentError -> nil
      end

    {:noreply, assign(socket, durable_selected: agent_str, durable_info: info)}
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown agent")}
  end

  # -- Auto refresh --

  @impl true
  def handle_info(:auto_refresh, socket) do
    if socket.assigns.auto_refresh do
      Process.send_after(self(), :auto_refresh, 5000)
      {:noreply, load_tab_data(socket.assigns.active_tab, socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:system}>
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

        <div class="flex-1 overflow-y-auto pt-1 space-y-2">
          <div class="flex items-center justify-between">
            <.button size={:sm} icon="m-refresh" phx-click="refresh">Refresh</.button>
          </div>

          <%= case @active_tab do %>
            <% :sup_tree -> %>
              <.sup_tree_panel tree={@tree} auto_refresh={@auto_refresh} />
            <% :ets -> %>
              <.ets_panel tables={@ets_tables} selected={@selected_table} entries={@table_entries} />
            <% :contexts -> %>
              <.contexts_panel contexts={@agent_contexts} />
            <% :errors -> %>
              <.errors_panel categories={@error_categories} events={@error_events} />
            <% :modules -> %>
              <.modules_panel
                modules={@comn_modules}
                selected={@selected_module}
                introspection={@module_introspection}
              />
            <% :durable_log -> %>
              <.durable_log_panel
                status={@durable_status}
                agents={@durable_agents}
                selected={@durable_selected}
                info={@durable_info}
              />
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  defp tabs,
    do: [
      sup_tree: "Supervision tree",
      ets: "ETS tables",
      contexts: "Contexts",
      errors: "Error catalog",
      modules: "Modules",
      durable_log: "DurableLog"
    ]

  # -- Sub-panels --

  defp sup_tree_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-1 mb-1.5">
        <h3 class="ds-label">LLMAgent supervision tree</h3>
        <.button
          size={:sm}
          variant={if @auto_refresh, do: :primary, else: :ghost}
          phx-click="toggle_auto_refresh"
        >Auto-refresh</.button>
      </div>
      <.empty :if={@tree == []}>No supervision tree loaded. Click Refresh above.</.empty>
      <div :if={@tree != []} class="space-y-0.5">
        <.tree_node :for={node <- @tree} node={node} depth={0} />
      </div>
    </div>
    """
  end

  defp tree_node(assigns) do
    ~H"""
    <div style={"margin-left: #{@depth * 1.5}rem"}>
      <div class="flex items-center gap-1 p-1 rounded-md hover:bg-surface-raised text-small">
        <%= if @node[:children] && @node[:children] != [] do %>
          <.mark name="m-chevron" size={12} class="rotate-90" />
        <% else %>
          <span class="w-1.5"></span>
        <% end %>
        <span class="ds-data font-medium">{@node[:name] || @node[:module]}</span>
        <span class="text-caption text-muted">{@node[:module]}</span>
        <.status_badge step={if @node[:alive], do: :low, else: :critical} size={10} />
        <span :if={@node[:pid]} class="text-caption ds-data text-muted">{inspect(@node[:pid])}</span>
        <span :if={@node[:message_queue_len]} class="text-caption text-muted">mq: {@node[
          :message_queue_len
        ]}</span>
      </div>
      <%= if @node[:children] do %>
        <.tree_node :for={child <- @node[:children]} node={child} depth={@depth + 1} />
      <% end %>
    </div>
    """
  end

  defp ets_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">ETS tables</h3>
      <div class="flex gap-2">
        <div class="w-32 space-y-0.5">
          <.empty :if={@tables == []}>No llmagent memory tables found.</.empty>
          <div
            :for={table <- @tables}
            phx-click="select_ets_table"
            phx-value-name={table.name}
            class={[
              "p-1 rounded-md cursor-pointer hover:bg-surface-raised text-small",
              @selected == to_string(table.name) && "bg-surface-raised"
            ]}
            aria-current={@selected == to_string(table.name) && "true"}
          >
            <div class="ds-data font-medium">{table.name}</div>
            <div class="text-caption text-muted">Size: {table.size} | Mem: {table.memory} words</div>
          </div>
        </div>
        <div :if={@selected} class="flex-1">
          <h4 class="ds-data mb-1">{@selected}</h4>
          <.empty :if={@entries == []}>Table is empty.</.empty>
          <div :if={@entries != []} class="space-y-1">
            <.pre :for={entry <- @entries} value={entry} />
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp contexts_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-0.5">Agent contexts</h3>
      <p class="text-caption text-muted mb-1.5">
        Point-in-time snapshot. Context data is ephemeral and only set during prompt handling.
      </p>
      <.empty :if={@contexts == []}>No agent contexts found.</.empty>
      <div :if={@contexts != []} class="space-y-1.5">
        <.card :for={ctx <- @contexts} title={to_string(ctx.agent_name)} density={:compact}>
          <.key_value :if={ctx.context} density={:dense}>
            <:item :for={{key, val} <- Map.from_struct(ctx.context)} key={to_string(key)}>
              {inspect(val)}
            </:item>
          </.key_value>
          <.empty :if={!ctx.context}>No context set.</.empty>
        </.card>
      </div>
    </div>
    """
  end

  defp errors_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">Error catalog</h3>
      <div class="mb-2">
        <h4 class="ds-label mb-0.5">Categories</h4>
        <div class="flex gap-1 flex-wrap">
          <.tag :for={cat <- @categories}>{cat}</.tag>
        </div>
      </div>
      <div>
        <h4 class="ds-label mb-0.5">Error events by category</h4>
        <.empty :if={@events == []}>No error events recorded.</.empty>
        <div :if={@events != []} class="space-y-2">
          <div :for={{category, evts} <- group_errors_by_category(@events)} data-category={category}>
            <div class="flex items-center gap-1 mb-0.5">
              <.tag accent>{category}</.tag>
              <span class="text-caption text-muted">{length(evts)}</span>
            </div>
            <div class="space-y-1">
              <.alert
                :for={evt <- evts}
                severity={:critical}
                title={to_string(evt.data[:reason] || evt.data["reason"] || "unknown")}
              >
                Source: {evt.data[:source] || evt.data["source"] || "unknown"}
              </.alert>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp modules_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">Comn modules</h3>
      <div class="flex gap-2">
        <div class="w-36 space-y-0.5">
          <.empty :if={@modules == []}>No Comn behaviour modules found.</.empty>
          <div
            :for={mod <- @modules}
            phx-click="select_module"
            phx-value-module={mod}
            class={[
              "p-1 rounded-md cursor-pointer hover:bg-surface-raised text-small ds-data",
              @selected == to_string(mod) && "bg-surface-raised"
            ]}
            aria-current={@selected == to_string(mod) && "true"}
          >
            {mod}
          </div>
        </div>
        <div :if={@introspection} class="flex-1">
          <.card density={:compact}>
            <.key_value>
              <:item key="look/0">{@introspection.look}</:item>
              <:item key="recon/0"><.pre value={@introspection.recon} /></:item>
              <:item key="choices/0"><.pre value={@introspection.choices} /></:item>
            </.key_value>
          </.card>
        </div>
      </div>
    </div>
    """
  end

  defp durable_log_panel(assigns) do
    ~H"""
    <div>
      <h3 class="ds-label mb-1.5">DurableLog inspector</h3>

      <div :if={@status} class="grid grid-cols-3 gap-1 mb-2">
        <.stat_tile label="Record count" value={@status[:record_count]} />
        <.stat_tile label="File size" value={@status[:file_size]} unit="bytes" />
        <.stat_tile label="DETS file" value={@status[:file_path]} class="col-span-1 overflow-hidden" />
      </div>

      <div class="flex gap-2">
        <div class="w-32">
          <h4 class="ds-label mb-1">Agents</h4>
          <.empty :if={@agents == []}>No agents found.</.empty>
          <div :if={@agents != []} class="space-y-0.5">
            <div
              :for={agent <- @agents}
              phx-click="select_durable_agent"
              phx-value-agent={agent}
              class={[
                "p-1 rounded-md cursor-pointer hover:bg-surface-raised text-small ds-data",
                @selected == to_string(agent) && "bg-surface-raised"
              ]}
              aria-current={@selected == to_string(agent) && "true"}
            >
              {agent}
            </div>
          </div>
        </div>

        <div :if={@info} class="flex-1">
          <.card title={to_string(@info.agent)} density={:compact}>
            <div class="grid grid-cols-2 gap-1 mb-1">
              <.stat_tile label="Event count" value={@info.event_count} />
              <.stat_tile label="Message count" value={@info.message_count} />
            </div>
            <.key_value density={:dense}>
              <:item key="First timestamp">{@info.first_timestamp || "N/A"}</:item>
              <:item key="Last timestamp">{@info.last_timestamp || "N/A"}</:item>
            </.key_value>
            <:footer>
              <a
                href={~p"/export/#{@info.agent}?kind=events"}
                class="ds-btn ds-btn--primary ds-btn--sm"
                download
              >
                <.mark name="m-download" size={14} /> Events JSON
              </a>
              <a
                href={~p"/export/#{@info.agent}?kind=messages"}
                class="ds-btn ds-btn--primary ds-btn--sm"
                download
              >
                <.mark name="m-download" size={14} /> Messages JSON
              </a>
            </:footer>
          </.card>
        </div>
      </div>
    </div>
    """
  end

  # -- Data loading --

  defp load_tab_data(:sup_tree, socket) do
    tree = build_supervision_tree()
    assign(socket, tree: tree)
  end

  defp load_tab_data(:ets, socket) do
    tables = list_memory_tables()
    assign(socket, ets_tables: tables)
  end

  defp load_tab_data(:contexts, socket) do
    contexts = load_agent_contexts()
    assign(socket, agent_contexts: contexts)
  end

  defp load_tab_data(:errors, socket) do
    categories =
      try do
        Comn.Errors.categories()
      rescue
        ArgumentError -> []
      end

    error_events =
      try do
        LLMAgent.EventLog.for_type(:error)
      rescue
        ArgumentError -> []
      end

    assign(socket, error_categories: categories, error_events: error_events)
  end

  defp load_tab_data(:modules, socket) do
    modules = Behaviours.comn_modules()
    assign(socket, comn_modules: modules)
  end

  defp load_tab_data(:durable_log, socket) do
    status = get_durable_log_status()
    agents = get_durable_agents()
    assign(socket, durable_status: status, durable_agents: agents)
  end

  defp load_tab_data(_, socket), do: socket

  # -- Supervision tree builder (R4.1, R4.2, R4.3, VA5) --

  defp build_supervision_tree do
    try do
      pid = Process.whereis(LLMAgent.Supervisor)

      if pid && Process.alive?(pid) do
        [build_tree_node(pid, "LLMAgent.Supervisor")]
      else
        []
      end
    rescue
      ArgumentError -> []
    end
  end

  defp build_tree_node(pid, label) do
    alive = Process.alive?(pid)
    info = if alive, do: Process.info(pid), else: nil
    mq_len = if info, do: Keyword.get(info, :message_queue_len, 0), else: 0

    registered_name =
      case info && Keyword.get(info, :registered_name) do
        nil -> nil
        [] -> nil
        name -> name
      end

    children =
      try do
        Supervisor.which_children(pid)
        |> Enum.map(fn {id, child_pid, type, modules} ->
          child_label = to_string(id)

          if is_pid(child_pid) and type == :supervisor do
            build_tree_node(child_pid, child_label)
          else
            child_info =
              if is_pid(child_pid) and Process.alive?(child_pid),
                do: Process.info(child_pid),
                else: nil

            child_mq = if child_info, do: Keyword.get(child_info, :message_queue_len, 0), else: 0

            %{
              name: node_label(child_pid, child_label),
              module: modules |> List.wrap() |> Enum.join(", "),
              pid: child_pid,
              alive: is_pid(child_pid) and Process.alive?(child_pid),
              message_queue_len: child_mq,
              children: maybe_children(child_pid, type)
            }
          end
        end)
      rescue
        ArgumentError -> []
      end

    %{
      name: registered_name || label,
      module: label,
      pid: pid,
      alive: alive,
      message_queue_len: mq_len,
      children: children
    }
  end

  # Best-effort label for a supervision-tree node. Prefer the local registered
  # name; agents run unregistered under the DynamicSupervisor (R4.3), so fall
  # back to the `.name` field in the process's GenServer state before the
  # supervisor child id.
  defp node_label(pid, fallback) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) and not is_nil(name) ->
        to_string(name)

      _ ->
        state_name(pid) || fallback
    end
  rescue
    ArgumentError -> fallback
  end

  defp node_label(_, fallback), do: fallback

  # Extract `.name` from a process's GenServer state via :sys.get_state. Guards
  # against non-agent processes (state may not be a map or may lack :name) and
  # against :sys.get_state failing, timing out, or exiting.
  defp state_name(pid) when is_pid(pid) do
    case :sys.get_state(pid, 100) do
      %{name: name} when not is_nil(name) -> to_string(name)
      _ -> nil
    end
  rescue
    # Non-OTP or non-map state; nothing to extract.
    _e in [ArgumentError, RuntimeError] -> nil
  catch
    :exit, _ -> nil
  end

  defp maybe_children(pid, :supervisor) when is_pid(pid) do
    try do
      Supervisor.which_children(pid)
      |> Enum.map(fn {id, child_pid, type, modules} ->
        %{
          name: node_label(child_pid, to_string(id)),
          module: modules |> List.wrap() |> Enum.join(", "),
          pid: child_pid,
          alive: is_pid(child_pid) and Process.alive?(child_pid),
          message_queue_len: process_mq(child_pid),
          children: maybe_children(child_pid, type)
        }
      end)
    rescue
      ArgumentError -> []
    end
  end

  defp maybe_children(_, _), do: nil

  defp process_mq(pid) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      _ -> 0
    end
  rescue
    ArgumentError -> 0
  end

  defp process_mq(_), do: 0

  # -- ETS helpers (R5.1) --

  defp list_memory_tables do
    :ets.all()
    |> Enum.filter(fn table ->
      name =
        try do
          :ets.info(table, :name)
        rescue
          ArgumentError -> nil
        end

      name && to_string(name) |> String.starts_with?("llmagent_mem_")
    end)
    |> Enum.map(fn table ->
      info = :ets.info(table)

      %{
        name: Keyword.get(info, :name),
        size: Keyword.get(info, :size, 0),
        memory: Keyword.get(info, :memory, 0)
      }
    end)
  end

  # -- Context helpers (R5.2) --

  defp load_agent_contexts do
    Agents.list()
    |> Enum.map(fn agent ->
      context =
        try do
          case Process.info(agent.pid, :dictionary) do
            {:dictionary, dict} ->
              Keyword.get(dict, :comn_context)

            _ ->
              nil
          end
        rescue
          ArgumentError -> nil
        end

      %{agent_name: agent.name, context: context}
    end)
  end

  # -- Error helpers (R5.3) --

  defp categorize_reason(reason) do
    try do
      Comn.Errors.categorize(reason)
    rescue
      ArgumentError -> :unknown
    end
  end

  # Group error events by their Comn.Errors category, returning
  # `[{category, events}]` in the canonical category order (Comn.Errors.categories/0),
  # with any unexpected categories appended and empty categories dropped.
  defp group_errors_by_category(events) do
    by_cat =
      Enum.group_by(events, fn evt ->
        categorize_reason(evt.data[:reason] || evt.data["reason"])
      end)

    ordered = Comn.Errors.categories()
    extra = Map.keys(by_cat) -- ordered

    (ordered ++ extra)
    |> Enum.map(fn category -> {category, Map.get(by_cat, category, [])} end)
    |> Enum.reject(fn {_category, evts} -> evts == [] end)
  end

  # -- DurableLog helpers (R7) --

  defp get_durable_log_status do
    try do
      # Attempt to get DETS info
      info = :dets.info(:llmagent_durable_log)

      if info == :undefined do
        nil
      else
        %{
          file_path: Keyword.get(info, :filename, "unknown"),
          file_size: Keyword.get(info, :file_size, 0),
          record_count: Keyword.get(info, :size, 0)
        }
      end
    rescue
      ArgumentError -> nil
    end
  end

  defp get_durable_agents do
    # Merge currently-running agents with any agent_ids that only exist in the
    # DurableLog DETS table (agents that ran and stopped). Dedup and sort.
    running = Agents.list() |> Enum.map(& &1.name)
    historical = durable_log_agent_ids()

    (running ++ historical)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Enumerate the distinct agent_ids stored in the DurableLog DETS table.
  # The table is keyed by agent_id ({agent_id, event}); a read-only fold
  # collects the distinct keys. The table is owned by LLMAgent.DurableLog;
  # we only read it and never open, write, or close it.
  defp durable_log_agent_ids do
    :dets.foldl(
      fn {agent_id, _event}, acc -> MapSet.put(acc, agent_id) end,
      MapSet.new(),
      :llmagent_durable_log
    )
    |> MapSet.to_list()
  rescue
    # DETS table not open or unavailable; no historical agents to add.
    _e in [ArgumentError, RuntimeError] -> []
  end
end
