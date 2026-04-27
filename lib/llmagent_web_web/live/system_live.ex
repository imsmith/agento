defmodule LlmagentWebWeb.SystemLive do
  @moduledoc """
  System inspection LiveView -- supervision tree, ETS, contexts, errors, DurableLog.
  Implements R4 (Supervision Tree), R5 (Comn Inspector), R7 (DurableLog Inspector).
  """
  use LlmagentWebWeb, :live_view

  alias LlmagentWebWeb.Discovery.{Agents, Behaviours}

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
        _ -> []
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
        _ -> nil
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
        _ -> nil
      end

    {:noreply, assign(socket, durable_selected: agent_str, durable_info: info)}
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown agent")}
  end

  def handle_event("export_events_json", %{"agent" => _agent_str}, socket) do
    # Export is handled via a download link generated from the data
    # For now, we present the data inline
    {:noreply, socket}
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
        <%!-- Sub-tabs --%>
        <div class="tabs tabs-bordered px-4 pt-2 bg-base-100 border-b border-base-300">
          <button
            phx-click="set_tab"
            phx-value-tab="sup_tree"
            class={["tab", @active_tab == :sup_tree && "tab-active"]}
          >
            Supervision Tree
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="ets"
            class={["tab", @active_tab == :ets && "tab-active"]}
          >
            ETS Tables
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="contexts"
            class={["tab", @active_tab == :contexts && "tab-active"]}
          >
            Contexts
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="errors"
            class={["tab", @active_tab == :errors && "tab-active"]}
          >
            Error Catalog
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="modules"
            class={["tab", @active_tab == :modules && "tab-active"]}
          >
            Modules
          </button>
          <button
            phx-click="set_tab"
            phx-value-tab="durable_log"
            class={["tab", @active_tab == :durable_log && "tab-active"]}
          >
            DurableLog
          </button>
        </div>

        <%!-- Tab content --%>
        <div class="flex-1 overflow-y-auto p-4">
          <div class="flex items-center justify-between mb-4">
            <button phx-click="refresh" class="btn btn-ghost btn-sm">
              <.icon name="hero-arrow-path-mini" class="size-4" /> Refresh
            </button>
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

  # -- Sub-panels --

  defp sup_tree_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center gap-2 mb-3">
        <h3 class="font-semibold">LLMAgent Supervision Tree (R4)</h3>
        <button
          phx-click="toggle_auto_refresh"
          class={[
            "btn btn-xs",
            if(@auto_refresh, do: "btn-primary", else: "btn-ghost")
          ]}
        >
          Auto-refresh
        </button>
      </div>

      <%= if @tree == [] do %>
        <p class="text-sm text-base-content/50">
          No supervision tree loaded. Click Refresh above.
        </p>
      <% else %>
        <div class="space-y-1">
          <%= for node <- @tree do %>
            <.tree_node node={node} depth={0} />
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp tree_node(assigns) do
    ~H"""
    <div style={"margin-left: #{@depth * 1.5}rem"}>
      <div class="flex items-center gap-2 p-2 rounded hover:bg-base-200 text-sm">
        <%= if @node[:children] && @node[:children] != [] do %>
          <.icon name="hero-chevron-down-mini" class="size-3" />
        <% else %>
          <span class="w-3"></span>
        <% end %>
        <span class="font-mono font-medium">{@node[:name] || @node[:module]}</span>
        <span class="text-xs text-base-content/60">{@node[:module]}</span>
        <span class={[
          "badge badge-xs",
          if(@node[:alive], do: "badge-success", else: "badge-error")
        ]}>
          {if @node[:alive], do: "alive", else: "dead"}
        </span>
        <%= if @node[:pid] do %>
          <span class="text-xs font-mono text-base-content/40">{inspect(@node[:pid])}</span>
        <% end %>
        <%= if @node[:message_queue_len] do %>
          <span class="text-xs text-base-content/40">
            mq: {@node[:message_queue_len]}
          </span>
        <% end %>
      </div>
      <%= if @node[:children] do %>
        <%= for child <- @node[:children] do %>
          <.tree_node node={child} depth={@depth + 1} />
        <% end %>
      <% end %>
    </div>
    """
  end

  defp ets_panel(assigns) do
    ~H"""
    <div>
      <h3 class="font-semibold mb-3">ETS Tables (R5.1)</h3>
      <div class="flex gap-4">
        <div class="w-64 space-y-1">
          <%= if @tables == [] do %>
            <p class="text-sm text-base-content/50">No llmagent memory tables found.</p>
          <% else %>
            <%= for table <- @tables do %>
              <div
                phx-click="select_ets_table"
                phx-value-name={table.name}
                class={[
                  "p-2 rounded cursor-pointer hover:bg-base-200 text-sm",
                  @selected == to_string(table.name) && "bg-base-200"
                ]}
              >
                <div class="font-mono font-medium">{table.name}</div>
                <div class="text-xs text-base-content/60">
                  Size: {table.size} | Mem: {table.memory} words
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <%= if @selected do %>
          <div class="flex-1">
            <h4 class="font-semibold mb-2 font-mono">{@selected}</h4>
            <%= if @entries == [] do %>
              <p class="text-sm text-base-content/50">Table is empty.</p>
            <% else %>
              <div class="space-y-2">
                <%= for entry <- @entries do %>
                  <div class="bg-base-200 p-3 rounded">
                    <pre class="text-xs font-mono whitespace-pre-wrap">{inspect(entry, pretty: true)}</pre>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp contexts_panel(assigns) do
    ~H"""
    <div>
      <h3 class="font-semibold mb-1">Agent Contexts (R5.2)</h3>
      <p class="text-xs text-base-content/50 mb-3">
        Point-in-time snapshot. Context data is ephemeral and only set during prompt handling.
      </p>
      <%= if @contexts == [] do %>
        <p class="text-sm text-base-content/50">No agent contexts found.</p>
      <% else %>
        <div class="space-y-3">
          <%= for ctx <- @contexts do %>
            <div class="card bg-base-200 p-4">
              <h4 class="font-semibold font-mono mb-2">{ctx.agent_name}</h4>
              <%= if ctx.context do %>
                <table class="table table-xs">
                  <tbody>
                    <%= for {key, val} <- Map.from_struct(ctx.context) do %>
                      <tr>
                        <td class="font-semibold w-40">{key}</td>
                        <td class="font-mono text-xs">{inspect(val)}</td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              <% else %>
                <p class="text-sm text-base-content/50">No context set.</p>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp errors_panel(assigns) do
    ~H"""
    <div>
      <h3 class="font-semibold mb-3">Error Catalog (R5.3)</h3>

      <div class="mb-4">
        <h4 class="text-sm font-semibold mb-1">Categories</h4>
        <div class="flex gap-2 flex-wrap">
          <%= for cat <- @categories do %>
            <span class="badge badge-outline">{cat}</span>
          <% end %>
        </div>
      </div>

      <div>
        <h4 class="text-sm font-semibold mb-1">Recent Error Events</h4>
        <%= if @events == [] do %>
          <p class="text-sm text-base-content/50">No error events recorded.</p>
        <% else %>
          <div class="space-y-2">
            <%= for evt <- @events do %>
              <div class="alert alert-error text-sm">
                <div>
                  <div class="font-medium">
                    {evt.data[:reason] || evt.data["reason"] || "unknown"}
                  </div>
                  <div class="text-xs">
                    Source: {evt.data[:source] || evt.data["source"] || "unknown"} | Category: {categorize_reason(
                      evt.data[:reason] || evt.data["reason"]
                    )}
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp modules_panel(assigns) do
    ~H"""
    <div>
      <h3 class="font-semibold mb-3">Comn Modules (R5.4)</h3>
      <div class="flex gap-4">
        <div class="w-72 space-y-1">
          <%= if @modules == [] do %>
            <p class="text-sm text-base-content/50">No Comn behaviour modules found.</p>
          <% else %>
            <%= for mod <- @modules do %>
              <div
                phx-click="select_module"
                phx-value-module={mod}
                class={[
                  "p-2 rounded cursor-pointer hover:bg-base-200 text-sm font-mono",
                  @selected == to_string(mod) && "bg-base-200"
                ]}
              >
                {mod}
              </div>
            <% end %>
          <% end %>
        </div>

        <%= if @introspection do %>
          <div class="flex-1 space-y-3">
            <div class="card bg-base-200 p-4">
              <h4 class="font-semibold text-sm mb-1">look/0</h4>
              <p class="text-sm">{@introspection.look}</p>
            </div>
            <div class="card bg-base-200 p-4">
              <h4 class="font-semibold text-sm mb-1">recon/0</h4>
              <pre class="text-xs font-mono whitespace-pre-wrap">{inspect(@introspection.recon, pretty: true)}</pre>
            </div>
            <div class="card bg-base-200 p-4">
              <h4 class="font-semibold text-sm mb-1">choices/0</h4>
              <pre class="text-xs font-mono whitespace-pre-wrap">{inspect(@introspection.choices, pretty: true)}</pre>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp durable_log_panel(assigns) do
    ~H"""
    <div>
      <h3 class="font-semibold mb-3">DurableLog Inspector (R7)</h3>

      <%!-- Status (R7.1) --%>
      <%= if @status do %>
        <div class="card bg-base-200 p-4 mb-4">
          <h4 class="font-semibold text-sm mb-2">DurableLog Status</h4>
          <table class="table table-xs">
            <tbody>
              <tr>
                <td class="font-semibold">DETS File</td>
                <td class="font-mono">{@status[:file_path]}</td>
              </tr>
              <tr>
                <td class="font-semibold">File Size</td>
                <td>{@status[:file_size]}</td>
              </tr>
              <tr>
                <td class="font-semibold">Record Count</td>
                <td>{@status[:record_count]}</td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>

      <%!-- Browse by agent (R7.2) --%>
      <div class="flex gap-4">
        <div class="w-64">
          <h4 class="font-semibold text-sm mb-2">Agents</h4>
          <%= if @agents == [] do %>
            <p class="text-sm text-base-content/50">No agents found.</p>
          <% else %>
            <div class="space-y-1">
              <%= for agent <- @agents do %>
                <div
                  phx-click="select_durable_agent"
                  phx-value-agent={agent}
                  class={[
                    "p-2 rounded cursor-pointer hover:bg-base-200 text-sm font-mono",
                    @selected == to_string(agent) && "bg-base-200"
                  ]}
                >
                  {agent}
                </div>
              <% end %>
            </div>
          <% end %>
        </div>

        <%= if @info do %>
          <div class="flex-1">
            <div class="card bg-base-200 p-4">
              <h4 class="font-semibold font-mono mb-2">{@info.agent}</h4>
              <table class="table table-xs">
                <tbody>
                  <tr>
                    <td class="font-semibold">Event Count</td>
                    <td>{@info.event_count}</td>
                  </tr>
                  <tr>
                    <td class="font-semibold">Message Count</td>
                    <td>{@info.message_count}</td>
                  </tr>
                  <tr>
                    <td class="font-semibold">First Timestamp</td>
                    <td class="font-mono">{@info.first_timestamp || "N/A"}</td>
                  </tr>
                  <tr>
                    <td class="font-semibold">Last Timestamp</td>
                    <td class="font-mono">{@info.last_timestamp || "N/A"}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        <% end %>
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
        _ -> []
      end

    error_events =
      try do
        LLMAgent.EventLog.for_type(:error)
      rescue
        _ -> []
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
      _ -> []
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
              name: registered_name(child_pid, child_label),
              module: modules |> List.wrap() |> Enum.join(", "),
              pid: child_pid,
              alive: is_pid(child_pid) and Process.alive?(child_pid),
              message_queue_len: child_mq,
              children: maybe_children(child_pid, type)
            }
          end
        end)
      rescue
        _ -> []
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

  defp registered_name(pid, fallback) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) -> to_string(name)
      _ -> fallback
    end
  rescue
    _ -> fallback
  end

  defp registered_name(_, fallback), do: fallback

  defp maybe_children(pid, :supervisor) when is_pid(pid) do
    try do
      Supervisor.which_children(pid)
      |> Enum.map(fn {id, child_pid, type, modules} ->
        %{
          name: registered_name(child_pid, to_string(id)),
          module: modules |> List.wrap() |> Enum.join(", "),
          pid: child_pid,
          alive: is_pid(child_pid) and Process.alive?(child_pid),
          message_queue_len: process_mq(child_pid),
          children: maybe_children(child_pid, type)
        }
      end)
    rescue
      _ -> []
    end
  end

  defp maybe_children(_, _), do: nil

  defp process_mq(pid) when is_pid(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      _ -> 0
    end
  rescue
    _ -> 0
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
          _ -> nil
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
          _ -> nil
        end

      %{agent_name: agent.name, context: context}
    end)
  end

  # -- Error helpers (R5.3) --

  defp categorize_reason(reason) do
    try do
      Comn.Errors.categorize(reason)
    rescue
      _ -> :unknown
    end
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
      _ -> nil
    end
  end

  defp get_durable_agents do
    # Derive agent list from running agents + any we can discover from DurableLog
    Agents.list()
    |> Enum.map(& &1.name)
    |> Enum.sort()
  end
end
