defmodule AgentoWeb.ChatLive do
  @moduledoc """
  Chat interface LiveView -- agent list sidebar + chat panel.
  Implements R1 (Agent Chat) and R2 (Agent Management).

  Prompts are routed to the selected agent at its global registration
  (`{:global, name}`). The new-agent form's endpoint dropdown subscribes to
  `AgentoWeb.Discovery.Endpoints` and refreshes live as LAN llama servers are
  discovered or expire.
  """
  use AgentoWeb, :live_view

  alias AgentoWeb.Discovery.Agents
  alias AgentoWeb.Discovery.Behaviours
  alias AgentoWeb.Discovery.Endpoints
  alias Agento.EventBusBridge

  @default_llm_client "LLMAgent.LLMClient.OpenAI"
  @default_memory "LLMAgent.Memory.ETS"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EventBusBridge.pubsub(), EventBusBridge.pubsub_topic())
      # Keep the endpoint dropdown live as LAN llama servers come and go.
      Endpoints.subscribe(self())
    end

    agents = Agents.list()
    options = endpoint_options()

    socket =
      socket
      |> assign(
        active_nav: :chat,
        agents: agents,
        selected_agent: nil,
        messages: [],
        events_inline: [],
        thinking: false,
        prompt_text: "",
        show_new_agent_form: false,
        endpoint_options: options,
        new_agent_form: default_new_agent_form(options),
        show_agent_config: false,
        confirm_stop: nil,
        confirm_clear: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent" => name}, _uri, socket) do
    agent_name = String.to_existing_atom(name)
    agent = Agents.get(agent_name)

    if agent do
      messages = load_messages(agent_name)

      {:noreply,
       socket
       |> assign(selected_agent: agent, messages: messages, events_inline: [], thinking: false)}
    else
      {:noreply,
       socket
       |> put_flash(:error, "Agent #{name} not found")
       |> assign(selected_agent: nil, messages: [], events_inline: [])}
    end
  rescue
    ArgumentError ->
      {:noreply,
       socket
       |> put_flash(:error, "Unknown agent: #{name}")
       |> assign(selected_agent: nil, messages: [], events_inline: [])}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # -- Events from PubSub --

  @impl true
  def handle_info({topic, event}, socket) when is_binary(topic) do
    socket = handle_event_message(topic, event, socket)
    {:noreply, socket}
  end

  # Discovery change from Endpoints.subscribe/1 — re-render the dropdown so
  # servers that appear (or expire) after mount are reflected live.
  def handle_info({event, _ad_id, _coordinate}, socket) when is_atom(event) do
    if event in Endpoints.change_events() do
      {:noreply, refresh_endpoint_options(socket)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  # -- User events --

  @impl true
  def handle_event("select_agent", %{"name" => name}, socket) do
    {:noreply, push_patch(socket, to: "/chat?agent=#{name}")}
  end

  def handle_event("send_prompt", %{"prompt" => text}, socket) do
    text = String.trim(text)

    if text != "" and socket.assigns.selected_agent do
      agent_name = socket.assigns.selected_agent.name
      LLMAgent.prompt({:global, agent_name}, text)
      AgentoWeb.WebEvents.emit_prompt_sent(agent_name, text)

      {:noreply, socket |> assign(prompt_text: "", thinking: true)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_prompt", %{"prompt" => text}, socket) do
    {:noreply, assign(socket, prompt_text: text)}
  end

  def handle_event("refresh_agents", _params, socket) do
    {:noreply, assign(socket, agents: Agents.list())}
  end

  # -- Agent management (R2) --

  def handle_event("toggle_new_agent_form", _params, socket) do
    {:noreply, assign(socket, show_new_agent_form: !socket.assigns.show_new_agent_form)}
  end

  def handle_event("update_new_agent", params, socket) do
    options = socket.assigns.endpoint_options
    current = socket.assigns.new_agent_form
    endpoint_id = Map.get(params, "endpoint", current.endpoint_id)

    # "manual" reveals free-form model/api_host inputs; take those verbatim.
    # Otherwise the selected endpoint supplies both values.
    {model, api_host} =
      if endpoint_id == "manual" do
        {Map.get(params, "model", current.model), Map.get(params, "api_host", current.api_host)}
      else
        selected = Enum.find(options, &(&1.id == endpoint_id)) || List.first(options)
        {selected.model, selected.api_host}
      end

    form =
      current
      |> Map.merge(%{
        name: Map.get(params, "name", current.name),
        role: Map.get(params, "role", current.role),
        endpoint_id: endpoint_id,
        model: model,
        api_host: api_host,
        llm_client: Map.get(params, "llm_client", current.llm_client),
        memory: Map.get(params, "memory", current.memory)
      })

    {:noreply, assign(socket, new_agent_form: form)}
  end

  def handle_event("start_agent", _params, socket) do
    form = socket.assigns.new_agent_form
    name = String.to_atom(form.name)

    opts = [
      name: name,
      role: String.to_atom(form.role),
      model: form.model,
      api_host: form.api_host,
      llm_client: to_module(form.llm_client),
      memory: to_module(form.memory)
    ]

    case Agents.start(opts) do
      {:ok, _pid} ->
        AgentoWeb.WebEvents.emit_agent_started(name, opts)
        options = endpoint_options()

        {:noreply,
         socket
         |> assign(
           agents: Agents.list(),
           show_new_agent_form: false,
           endpoint_options: options,
           new_agent_form: default_new_agent_form(options)
         )
         |> put_flash(:info, "Agent #{name} started")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start agent: #{inspect(reason)}")}
    end
  end

  def handle_event("confirm_stop", %{"name" => name}, socket) do
    {:noreply, assign(socket, confirm_stop: name)}
  end

  def handle_event("cancel_stop", _params, socket) do
    {:noreply, assign(socket, confirm_stop: nil)}
  end

  def handle_event("stop_agent", %{"name" => name}, socket) do
    agent_name = String.to_existing_atom(name)

    case Agents.stop(agent_name) do
      :ok ->
        AgentoWeb.WebEvents.emit_agent_stopped(agent_name)

        selected =
          if socket.assigns.selected_agent && socket.assigns.selected_agent.name == agent_name,
            do: nil,
            else: socket.assigns.selected_agent

        {:noreply,
         socket
         |> assign(agents: Agents.list(), selected_agent: selected, confirm_stop: nil)
         |> put_flash(:info, "Agent #{name} stopped")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> assign(confirm_stop: nil)
         |> put_flash(:error, "Agent #{name} not found")}
    end
  end

  def handle_event("show_config", _params, socket) do
    {:noreply, assign(socket, show_agent_config: !socket.assigns.show_agent_config)}
  end

  def handle_event("confirm_clear", _params, socket) do
    {:noreply, assign(socket, confirm_clear: true)}
  end

  def handle_event("cancel_clear", _params, socket) do
    {:noreply, assign(socket, confirm_clear: nil)}
  end

  def handle_event("clear_history", _params, socket) do
    if socket.assigns.selected_agent do
      agent_name = socket.assigns.selected_agent.name
      LLMAgent.DurableLog.clear(agent_name)
      LLMAgent.Memory.ETS.delete(agent_name, :history)

      {:noreply,
       socket
       |> assign(messages: [], events_inline: [], confirm_clear: nil)
       |> put_flash(:info, "History cleared for #{agent_name}")}
    else
      {:noreply, assign(socket, confirm_clear: nil)}
    end
  end

  # -- Render --

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:chat}>
      <div class="flex h-full gap-2">
        <%!-- Agent sidebar --%>
        <.card title="Agents" density={:compact} flush class="w-32 flex flex-col min-h-0">
          <:actions>
            <.button size={:sm} icon="m-refresh" phx-click="refresh_agents" title="Refresh"><span class="sr-only">Refresh</span></.button>
            <.button size={:sm} icon="m-add" phx-click="toggle_new_agent_form" title="New agent"><span class="sr-only">New agent</span></.button>
          </:actions>

          <div :if={@show_new_agent_form} class="p-1 border-b border-border">
            <.new_agent_form form={@new_agent_form} endpoint_options={@endpoint_options} />
          </div>

          <div class="flex-1 overflow-y-auto">
            <.empty :if={@agents == []}>No agents running.</.empty>
            <div
              :for={agent <- @agents}
              phx-click="select_agent"
              phx-value-name={agent.name}
              class={[
                "p-1 cursor-pointer border-b border-border hover:bg-surface-raised",
                @selected_agent && @selected_agent.name == agent.name && "bg-surface-raised"
              ]}
              aria-current={@selected_agent && @selected_agent.name == agent.name && "true"}
            >
              <div class="font-medium text-small">{agent.name}</div>
              <div class="text-caption text-muted">{agent.role} / {agent.model}</div>
              <%= if to_string(agent.name) == @confirm_stop do %>
                <div class="mt-0.5 flex gap-0.5">
                  <.button
                    size={:sm}
                    variant={:danger}
                    phx-click="stop_agent"
                    phx-value-name={agent.name}
                  >Stop {agent.name}</.button>
                  <.button size={:sm} phx-click="cancel_stop">Cancel</.button>
                </div>
              <% else %>
                <.button
                  size={:sm}
                  class="mt-0.5"
                  phx-click="confirm_stop"
                  phx-value-name={agent.name}
                >Stop</.button>
              <% end %>
            </div>
          </div>
        </.card>

        <%!-- Chat panel --%>
        <div class="flex-1 flex flex-col min-h-0">
          <%= if @selected_agent do %>
            <div class="p-1 border-b border-border flex items-center justify-between">
              <div>
                <span class="font-bold">{@selected_agent.name}</span>
                <span class="text-small text-muted ml-1">{@selected_agent.role} / {@selected_agent.model}</span>
              </div>
              <div class="flex gap-0.5">
                <.button size={:sm} icon="m-settings" phx-click="show_config">Config</.button>
                <%= if @confirm_clear do %>
                  <.button size={:sm} variant={:danger} phx-click="clear_history">Clear history for {@selected_agent.name}</.button>
                  <.button size={:sm} phx-click="cancel_clear">Cancel</.button>
                <% else %>
                  <.button size={:sm} icon="m-delete" phx-click="confirm_clear">Clear</.button>
                <% end %>
              </div>
            </div>

            <div :if={@show_agent_config} class="p-1 border-b border-border bg-surface">
              <.agent_config agent={@selected_agent} />
            </div>

            <div
              class="flex-1 overflow-y-auto p-2 space-y-1.5"
              id="chat-messages"
              phx-hook="ScrollBottom"
            >
              <%= for item <- interleave_messages_and_events(@messages, @events_inline) do %>
                <%= case item do %>
                  <% {:message, msg} -> %>
                    <.chat_message message={msg} />
                  <% {:tool_dispatch, evt} -> %>
                    <.tool_dispatch_block event={evt} />
                  <% {:tool_result, evt} -> %>
                    <.tool_result_block event={evt} />
                  <% {:error, evt} -> %>
                    <.error_block event={evt} />
                <% end %>
              <% end %>

              <div :if={@thinking} class="chat-msg" aria-busy="true">
                <.mark name="m-refresh" size={14} class="ds-btn__spin" label="thinking" /> thinking
              </div>
            </div>

            <form phx-submit="send_prompt" class="p-1 border-t border-border">
              <div class="flex gap-1">
                <.input
                  name="prompt"
                  value={@prompt_text}
                  phx-change="update_prompt"
                  placeholder="Type a message..."
                  autocomplete="off"
                  class="flex-1"
                />
                <.button type="submit" variant={:primary} icon="m-send" disabled={@prompt_text == ""}>Send</.button>
              </div>
            </form>
          <% else %>
            <.state_panel mode={:empty} mark="m-chat" title="No agent selected.">
              Pick an agent on the left to begin chatting.
            </.state_panel>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  # -- Subcomponents --

  defp chat_message(assigns) do
    ~H"""
    <div class={["chat-msg", role_class(@message.role)]}>
      <div class="chat-role">{@message.role}</div>
      <div>{@message.content}</div>
    </div>
    """
  end

  defp tool_dispatch_block(assigns) do
    ~H"""
    <.disclosure
      icon="m-tool"
      summary={"Tool: #{@event.data[:tool] || @event.data["tool"]} / #{@event.data[:action] || @event.data["action"]}"}
    >
      <.pre value={sanitize_event_data(@event.data)} />
    </.disclosure>
    """
  end

  defp tool_result_block(assigns) do
    dur = assigns.event.data[:duration_ms] || assigns.event.data["duration_ms"]
    assigns = assign(assigns, :dur, dur)

    ~H"""
    <.disclosure
      icon="m-low"
      step={:low}
      summary={"Tool result: #{@event.data[:result] || @event.data["result"]}#{if @dur, do: " (#{@dur} ms)", else: ""}"}
    >
      <.pre value={sanitize_event_data(@event.data)} />
    </.disclosure>
    """
  end

  defp error_block(assigns) do
    ~H"""
    <.alert
      severity={:critical}
      title={"Error: #{@event.data[:reason] || @event.data["reason"]}"}
      class="my-0.5"
    >
      Source: {@event.data[:source] || @event.data["source"]}
    </.alert>
    """
  end

  defp agent_config(assigns) do
    ~H"""
    <.key_value density={:dense} columns={2}>
      <:item key="Name">{@agent.name}</:item>
      <:item key="Role">{@agent.role}</:item>
      <:item key="Model">{@agent.model}</:item>
      <:item key="API host">{@agent.api_host}</:item>
      <:item key="LLM client">{inspect(@agent.llm_client)}</:item>
      <:item key="Memory">{inspect(@agent.memory)}</:item>
      <:item key="History length" num>{@agent.history_length}</:item>
    </.key_value>
    """
  end

  defp new_agent_form(assigns) do
    ~H"""
    <form id="new-agent-form" phx-submit="start_agent" phx-change="update_new_agent" class="space-y-1">
      <.input name="name" value={@form.name} placeholder="Agent name (atom)" required />
      <.select name="role" options={available_roles()} value={@form.role} />
      <.select
        name="endpoint"
        options={Enum.map(@endpoint_options, &{&1.label, &1.id})}
        value={@form.endpoint_id}
      />
      <%= if @form.endpoint_id == "manual" do %>
        <.input name="model" value={@form.model} placeholder="Model (e.g. llama3.2)" />
        <.input
          name="api_host"
          value={@form.api_host}
          placeholder="API host (e.g. http://localhost:11434/v1)"
        />
      <% end %>
      <.select name="llm_client" options={llm_client_options()} value={@form.llm_client} />
      <.select name="memory" options={memory_options()} value={@form.memory} />
      <div class="flex gap-0.5">
        <.button type="submit" variant={:primary} size={:sm} class="flex-1">Start</.button>
        <.button type="button" size={:sm} phx-click="toggle_new_agent_form">Cancel</.button>
      </div>
    </form>
    """
  end

  # -- Helpers --

  defp handle_event_message(topic, event, socket) do
    agent_name =
      if socket.assigns.selected_agent, do: socket.assigns.selected_agent.name, else: nil

    data = Map.get(event, :data, %{})
    event_agent_id = data[:agent_id] || data["agent_id"]

    matches_agent? = agent_name != nil and event_agent_id == agent_name

    case topic do
      "agent.message" when matches_agent? ->
        msg = %{
          role: get_in(event.data, [:role]) || get_in(event.data, ["role"]),
          content: get_in(event.data, [:content]) || get_in(event.data, ["content"])
        }

        role = msg.role
        is_assistant? = role in ["assistant", :assistant]

        socket
        |> update(:messages, &(&1 ++ [msg]))
        |> assign(thinking: if(is_assistant?, do: false, else: socket.assigns.thinking))

      # Both agent.tool_dispatch and tool.* carry agent_id, so filter by the
      # selected agent directly rather than guessing from thinking state.
      "agent.tool_dispatch" when matches_agent? ->
        update(socket, :events_inline, &(&1 ++ [{:tool_dispatch, event}]))

      "agent.error" when matches_agent? ->
        socket
        |> update(:events_inline, &(&1 ++ [{:error, event}]))
        |> assign(thinking: false)

      "tool." <> _name when matches_agent? ->
        update(socket, :events_inline, &(&1 ++ [{:tool_result, event}]))

      "agent.prompt" when matches_agent? ->
        assign(socket, thinking: true)

      _ ->
        # Refresh agent list on any agent event
        if String.starts_with?(topic, "agent.") do
          assign(socket, agents: Agents.list())
        else
          socket
        end
    end
  end

  defp load_messages(agent_name) do
    try do
      LLMAgent.DurableLog.messages_for(agent_name)
    rescue
      ArgumentError -> []
    end
  end

  defp interleave_messages_and_events(messages, events) do
    msg_items = Enum.map(messages, fn m -> {:message, m} end)
    # Append inline events at the end for now (they arrive in order)
    msg_items ++ events
  end

  defp role_class(role) when role in ["user", :user], do: "chat-msg--user"
  defp role_class(role) when role in ["system", :system], do: "chat-msg--system"
  defp role_class(_), do: nil

  # Always-present fallback so the endpoint select is never empty, even
  # before mDNS discovery has surfaced any LAN servers.
  defp local_fallback do
    %{
      id: "local",
      api_host: "http://localhost:11434/v1",
      model: "llama3.2",
      label: "llama3.2 @ localhost (fallback)"
    }
  end

  defp endpoint_options do
    Endpoints.list() ++ [local_fallback(), manual_option()]
  end

  # Sentinel option that reveals free-form model/api_host inputs. Kept last so
  # discovered endpoints (and the local fallback) remain the default selection.
  defp manual_option do
    %{id: "manual", api_host: "", model: "", label: "Manual entry"}
  end

  # Recompute the dropdown after a discovery change, preserving the user's
  # current selection when it still exists, otherwise snapping to the first
  # available option.
  defp refresh_endpoint_options(socket) do
    options = endpoint_options()
    form = socket.assigns.new_agent_form

    # Manual entry owns its own model/api_host; only re-derive for real endpoints.
    form =
      if form.endpoint_id == "manual" do
        form
      else
        selected = Enum.find(options, &(&1.id == form.endpoint_id)) || List.first(options)

        Map.merge(form, %{
          endpoint_id: selected.id,
          model: selected.model,
          api_host: selected.api_host
        })
      end

    assign(socket, endpoint_options: options, new_agent_form: form)
  end

  defp default_new_agent_form(options) do
    ep = List.first(options) || local_fallback()

    %{
      name: "",
      role: "default",
      endpoint_id: ep.id,
      model: ep.model,
      api_host: ep.api_host,
      llm_client: @default_llm_client,
      memory: @default_memory
    }
  end

  defp available_roles do
    if function_exported?(LLMAgent.RolePrompt, :roles, 0) do
      LLMAgent.RolePrompt.roles() |> Enum.map(&to_string/1)
    else
      ["default", "sysadmin"]
    end
  end

  # Discovered LLM client / memory modules, rendered as their inspected names
  # (e.g. "LLMAgent.LLMClient.OpenAI"). The default is always present so the
  # select is never empty before discovery has surfaced anything.
  defp llm_client_options do
    Behaviours.llm_clients()
    |> Enum.map(&inspect/1)
    |> ensure_default(@default_llm_client)
  end

  defp memory_options do
    Behaviours.memory_backends()
    |> Enum.map(&inspect/1)
    |> ensure_default(@default_memory)
  end

  defp ensure_default(mods, default) do
    if default in mods, do: mods, else: [default | mods]
  end

  defp to_module(str) when is_binary(str), do: Module.concat([str])

  # Truncate long string values (mirroring LLMAgent's 200-char cap) before we
  # render event payloads inline in the chat, recursing into nested maps/lists.
  defp sanitize_event_data(%{__struct__: _} = data), do: data

  defp sanitize_event_data(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {k, sanitize_value(v)} end)
  end

  defp sanitize_event_data(data), do: data

  defp sanitize_value(v) when is_binary(v) and byte_size(v) > 200 do
    String.slice(v, 0, 200) <> "...(truncated)"
  end

  defp sanitize_value(v) when is_map(v), do: sanitize_event_data(v)
  defp sanitize_value(v) when is_list(v), do: Enum.map(v, &sanitize_value/1)
  defp sanitize_value(v), do: v
end
