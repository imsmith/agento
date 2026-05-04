defmodule AgentoWeb.ChatLive do
  @moduledoc """
  Chat interface LiveView -- agent list sidebar + chat panel.
  Implements R1 (Agent Chat) and R2 (Agent Management).
  """
  use AgentoWeb, :live_view

  alias AgentoWeb.Discovery.Agents
  alias Agento.EventBusBridge

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EventBusBridge.pubsub(), EventBusBridge.pubsub_topic())
    end

    agents = Agents.list()

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
        new_agent_form: default_new_agent_form(),
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
    form =
      socket.assigns.new_agent_form
      |> Map.merge(%{
        name: Map.get(params, "name", ""),
        role: Map.get(params, "role", ""),
        model: Map.get(params, "model", ""),
        api_host: Map.get(params, "api_host", "")
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
      api_host: form.api_host
    ]

    case Agents.start(opts) do
      {:ok, _pid} ->
        AgentoWeb.WebEvents.emit_agent_started(name, opts)

        {:noreply,
         socket
         |> assign(
           agents: Agents.list(),
           show_new_agent_form: false,
           new_agent_form: default_new_agent_form()
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
      <div class="flex h-full">
        <%!-- Agent sidebar --%>
        <aside class="w-64 border-r border-base-300 bg-base-200 flex flex-col overflow-hidden">
          <div class="p-3 border-b border-base-300 flex items-center justify-between">
            <span class="font-semibold text-sm">Agents</span>
            <div class="flex gap-1">
              <button phx-click="refresh_agents" class="btn btn-ghost btn-xs" title="Refresh">
                <.icon name="hero-arrow-path-mini" class="size-4" />
              </button>
              <button phx-click="toggle_new_agent_form" class="btn btn-ghost btn-xs" title="New agent">
                <.icon name="hero-plus-mini" class="size-4" />
              </button>
            </div>
          </div>

          <%= if @show_new_agent_form do %>
            <div class="p-3 border-b border-base-300 bg-base-100 space-y-2">
              <.new_agent_form form={@new_agent_form} />
            </div>
          <% end %>

          <div class="flex-1 overflow-y-auto">
            <%= if @agents == [] do %>
              <p class="p-3 text-sm text-base-content/50">No agents running.</p>
            <% else %>
              <%= for agent <- @agents do %>
                <div
                  phx-click="select_agent"
                  phx-value-name={agent.name}
                  class={[
                    "p-3 cursor-pointer border-b border-base-300 hover:bg-base-300/50",
                    @selected_agent && @selected_agent.name == agent.name && "bg-base-300"
                  ]}
                >
                  <div class="font-medium text-sm">{agent.name}</div>
                  <div class="text-xs text-base-content/60">
                    {agent.role} / {agent.model}
                  </div>
                  <%= if to_string(agent.name) == @confirm_stop do %>
                    <div class="mt-1 flex gap-1">
                      <button
                        phx-click="stop_agent"
                        phx-value-name={agent.name}
                        class="btn btn-error btn-xs"
                      >
                        Confirm stop
                      </button>
                      <button phx-click="cancel_stop" class="btn btn-ghost btn-xs">Cancel</button>
                    </div>
                  <% else %>
                    <button
                      phx-click="confirm_stop"
                      phx-value-name={agent.name}
                      class="btn btn-ghost btn-xs mt-1 text-error"
                    >
                      Stop
                    </button>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        </aside>

        <%!-- Chat panel --%>
        <div class="flex-1 flex flex-col">
          <%= if @selected_agent do %>
            <%!-- Chat header --%>
            <div class="p-3 border-b border-base-300 flex items-center justify-between bg-base-100">
              <div>
                <span class="font-bold">{@selected_agent.name}</span>
                <span class="text-sm text-base-content/60 ml-2">
                  {@selected_agent.role} / {@selected_agent.model}
                </span>
              </div>
              <div class="flex gap-1">
                <button phx-click="show_config" class="btn btn-ghost btn-xs">
                  <.icon name="hero-cog-6-tooth-mini" class="size-4" /> Config
                </button>
                <%= if @confirm_clear do %>
                  <button phx-click="clear_history" class="btn btn-error btn-xs">
                    Confirm clear
                  </button>
                  <button phx-click="cancel_clear" class="btn btn-ghost btn-xs">Cancel</button>
                <% else %>
                  <button phx-click="confirm_clear" class="btn btn-ghost btn-xs text-warning">
                    <.icon name="hero-trash-mini" class="size-4" /> Clear
                  </button>
                <% end %>
              </div>
            </div>

            <%!-- Agent config panel (R2.3) --%>
            <%= if @show_agent_config do %>
              <div class="p-3 border-b border-base-300 bg-base-200 text-sm font-mono">
                <.agent_config agent={@selected_agent} />
              </div>
            <% end %>

            <%!-- Messages --%>
            <div
              class="flex-1 overflow-y-auto p-4 space-y-3"
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

              <%= if @thinking do %>
                <div class="chat chat-start">
                  <div class="chat-bubble chat-bubble-neutral">
                    <span class="loading loading-dots loading-sm"></span>
                  </div>
                </div>
              <% end %>
            </div>

            <%!-- Input --%>
            <form phx-submit="send_prompt" class="p-3 border-t border-base-300 bg-base-100">
              <div class="flex gap-2">
                <input
                  type="text"
                  name="prompt"
                  value={@prompt_text}
                  phx-change="update_prompt"
                  placeholder="Type a message..."
                  class="input input-bordered flex-1"
                  autocomplete="off"
                />
                <button type="submit" class="btn btn-primary" disabled={@prompt_text == ""}>
                  <.icon name="hero-paper-airplane-mini" class="size-4" /> Send
                </button>
              </div>
            </form>
          <% else %>
            <div class="flex-1 flex items-center justify-center text-base-content/40">
              <div class="text-center">
                <.icon name="hero-chat-bubble-left-right" class="size-12 mx-auto mb-2" />
                <p>Select an agent from the sidebar to begin chatting.</p>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  # -- Subcomponents --

  defp chat_message(assigns) do
    ~H"""
    <div class={["chat", role_alignment(@message.role)]}>
      <div class="chat-header text-xs opacity-60 mb-1">
        {@message.role}
      </div>
      <div class={["chat-bubble", role_bubble_class(@message.role)]}>
        <div class="whitespace-pre-wrap">{@message.content}</div>
      </div>
    </div>
    """
  end

  defp tool_dispatch_block(assigns) do
    ~H"""
    <div class="collapse collapse-arrow bg-info/10 border border-info/30 rounded-lg my-1">
      <input type="checkbox" />
      <div class="collapse-title text-sm font-medium flex items-center gap-2 py-2 min-h-0">
        <.icon name="hero-wrench-screwdriver-mini" class="size-4 text-info" />
        Tool: {@event.data[:tool] || @event.data["tool"]} / {@event.data[:action] ||
          @event.data["action"]}
      </div>
      <div class="collapse-content text-xs font-mono">
        <pre class="whitespace-pre-wrap">{inspect(@event.data, pretty: true)}</pre>
      </div>
    </div>
    """
  end

  defp tool_result_block(assigns) do
    ~H"""
    <div class="collapse collapse-arrow bg-success/10 border border-success/30 rounded-lg my-1">
      <input type="checkbox" />
      <div class="collapse-title text-sm font-medium flex items-center gap-2 py-2 min-h-0">
        <.icon name="hero-check-circle-mini" class="size-4 text-success" />
        Tool result: {@event.data[:result] || @event.data["result"]}
        <%= if dur = @event.data[:duration_ms] || @event.data["duration_ms"] do %>
          <span class="text-xs opacity-60">({dur}ms)</span>
        <% end %>
      </div>
      <div class="collapse-content text-xs font-mono">
        <pre class="whitespace-pre-wrap">{inspect(@event.data, pretty: true)}</pre>
      </div>
    </div>
    """
  end

  defp error_block(assigns) do
    ~H"""
    <div class="alert alert-error text-sm my-1">
      <.icon name="hero-exclamation-triangle-mini" class="size-4" />
      <div>
        <div class="font-medium">
          Error: {@event.data[:reason] || @event.data["reason"]}
        </div>
        <div class="text-xs opacity-70">
          Source: {@event.data[:source] || @event.data["source"]}
        </div>
      </div>
    </div>
    """
  end

  defp agent_config(assigns) do
    ~H"""
    <table class="table table-xs">
      <tbody>
        <tr>
          <td class="font-semibold">Name</td>
          <td>{@agent.name}</td>
        </tr>
        <tr>
          <td class="font-semibold">Role</td>
          <td>{@agent.role}</td>
        </tr>
        <tr>
          <td class="font-semibold">Model</td>
          <td>{@agent.model}</td>
        </tr>
        <tr>
          <td class="font-semibold">API Host</td>
          <td>{@agent.api_host}</td>
        </tr>
        <tr>
          <td class="font-semibold">History Length</td>
          <td>{@agent.history_length}</td>
        </tr>
      </tbody>
    </table>
    """
  end

  defp new_agent_form(assigns) do
    ~H"""
    <form phx-submit="start_agent" phx-change="update_new_agent" class="space-y-2">
      <input
        type="text"
        name="name"
        value={@form.name}
        placeholder="Agent name (atom)"
        class="input input-bordered input-sm w-full"
        required
      />
      <input
        type="text"
        name="role"
        value={@form.role}
        placeholder="Role (e.g. sysadmin)"
        class="input input-bordered input-sm w-full"
      />
      <input
        type="text"
        name="model"
        value={@form.model}
        placeholder="Model (e.g. llama3.2)"
        class="input input-bordered input-sm w-full"
      />
      <input
        type="text"
        name="api_host"
        value={@form.api_host}
        placeholder="API host"
        class="input input-bordered input-sm w-full"
      />
      <div class="flex gap-1">
        <button type="submit" class="btn btn-primary btn-sm flex-1">Start</button>
        <button type="button" phx-click="toggle_new_agent_form" class="btn btn-ghost btn-sm">
          Cancel
        </button>
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

      # tool_dispatch and tool.* events don't carry agent_id in their data,
      # so we match on thinking state (we're waiting for a response from this agent)
      "agent.tool_dispatch" ->
        if socket.assigns.thinking and agent_name != nil do
          update(socket, :events_inline, &(&1 ++ [{:tool_dispatch, event}]))
        else
          socket
        end

      "agent.error" when matches_agent? ->
        socket
        |> update(:events_inline, &(&1 ++ [{:error, event}]))
        |> assign(thinking: false)

      "tool." <> _name ->
        if socket.assigns.thinking and agent_name != nil do
          update(socket, :events_inline, &(&1 ++ [{:tool_result, event}]))
        else
          socket
        end

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

  defp role_alignment(role) when role in ["user", :user], do: "chat-end"
  defp role_alignment(_), do: "chat-start"

  defp role_bubble_class(role) when role in ["user", :user], do: "chat-bubble-primary"
  defp role_bubble_class(role) when role in ["system", :system], do: "chat-bubble-neutral"
  defp role_bubble_class(_), do: "chat-bubble-secondary"

  defp default_new_agent_form do
    %{
      name: "",
      role: "sysadmin",
      model: "llama3.2",
      api_host: "http://localhost:11434/v1"
    }
  end
end
