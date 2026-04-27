defmodule LlmagentWebWeb.ToolsLive do
  @moduledoc """
  Tool Inspector LiveView -- tool registry + manual invocation.
  Implements R6 (Tool Inspector).
  """
  use LlmagentWebWeb, :live_view

  alias LlmagentWebWeb.Discovery.Tools

  @impl true
  def mount(_params, _session, socket) do
    tools = Tools.list()

    socket =
      socket
      |> assign(
        active_nav: :tools,
        tools: tools,
        selected_tool: nil,
        selected_module: nil,
        tool_introspection: nil,
        invoke_action: "",
        invoke_args: "{}",
        invoke_result: nil,
        invoke_error: nil
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("refresh_tools", _params, socket) do
    {:noreply, assign(socket, tools: Tools.list())}
  end

  def handle_event("select_tool", %{"name" => name, "module" => module_str}, socket) do
    module = String.to_existing_atom(module_str)
    description = Tools.describe(module)
    introspection = Tools.introspect(module)

    {:noreply,
     assign(socket,
       selected_tool: name,
       selected_module: module,
       tool_description: description,
       tool_introspection: introspection,
       invoke_result: nil,
       invoke_error: nil
     )}
  rescue
    ArgumentError ->
      {:noreply, put_flash(socket, :error, "Unknown tool module: #{module_str}")}
  end

  def handle_event("update_invoke", params, socket) do
    {:noreply,
     assign(socket,
       invoke_action: Map.get(params, "action", socket.assigns.invoke_action),
       invoke_args: Map.get(params, "args", socket.assigns.invoke_args)
     )}
  end

  def handle_event("invoke_tool", _params, socket) do
    module = socket.assigns.selected_module
    action = socket.assigns.invoke_action

    case Jason.decode(socket.assigns.invoke_args) do
      {:ok, args} ->
        try do
          result = module.perform(action, args)

          case result do
            {:ok, data} ->
              {:noreply, assign(socket, invoke_result: data, invoke_error: nil)}

            {:error, reason} ->
              {:noreply, assign(socket, invoke_result: nil, invoke_error: inspect(reason))}
          end
        rescue
          e ->
            {:noreply, assign(socket, invoke_result: nil, invoke_error: Exception.message(e))}
        end

      {:error, _} ->
        {:noreply, assign(socket, invoke_error: "Invalid JSON in args field")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:tools}>
      <div class="flex h-full">
        <%!-- Tool list sidebar --%>
        <aside class="w-72 border-r border-base-300 bg-base-200 flex flex-col overflow-hidden">
          <div class="p-3 border-b border-base-300 flex items-center justify-between">
            <span class="font-semibold text-sm">
              Registered Tools ({length(@tools)})
            </span>
            <button phx-click="refresh_tools" class="btn btn-ghost btn-xs" title="Refresh">
              <.icon name="hero-arrow-path-mini" class="size-4" />
            </button>
          </div>
          <div class="flex-1 overflow-y-auto">
            <%= if @tools == [] do %>
              <p class="p-3 text-sm text-base-content/50">No tools registered.</p>
            <% else %>
              <%= for {name, module} <- @tools do %>
                <div
                  phx-click="select_tool"
                  phx-value-name={name}
                  phx-value-module={module}
                  class={[
                    "p-3 cursor-pointer border-b border-base-300 hover:bg-base-300/50",
                    @selected_tool == to_string(name) && "bg-base-300"
                  ]}
                >
                  <div class="font-medium text-sm font-mono">{name}</div>
                  <div class="text-xs text-base-content/60 truncate">{module}</div>
                </div>
              <% end %>
            <% end %>
          </div>
        </aside>

        <%!-- Tool detail panel --%>
        <div class="flex-1 overflow-y-auto p-4">
          <%= if @selected_module do %>
            <h2 class="text-xl font-bold mb-2 font-mono">{@selected_tool}</h2>
            <p class="text-sm text-base-content/70 mb-1">{@selected_module}</p>

            <%!-- Description (R6.2) --%>
            <%= if assigns[:tool_description] do %>
              <div class="card bg-base-200 p-4 mb-4">
                <h3 class="font-semibold text-sm mb-1">Description</h3>
                <p class="text-sm whitespace-pre-wrap">{@tool_description}</p>
              </div>
            <% end %>

            <%!-- Comn introspection (R6.2) --%>
            <%= if @tool_introspection do %>
              <div class="card bg-base-200 p-4 mb-4">
                <h3 class="font-semibold text-sm mb-2">Comn Introspection</h3>
                <div class="text-sm mb-2">
                  <span class="font-semibold">look/0:</span> {@tool_introspection.look}
                </div>
                <div class="text-sm mb-2">
                  <span class="font-semibold">recon/0:</span>
                  <pre class="text-xs font-mono mt-1 whitespace-pre-wrap bg-base-300 p-2 rounded">{inspect(@tool_introspection.recon, pretty: true)}</pre>
                </div>
                <div class="text-sm">
                  <span class="font-semibold">choices/0:</span>
                  <pre class="text-xs font-mono mt-1 whitespace-pre-wrap bg-base-300 p-2 rounded">{inspect(@tool_introspection.choices, pretty: true)}</pre>
                </div>
              </div>
            <% end %>

            <%!-- Manual invocation (R6.3) --%>
            <div class="card bg-base-200 p-4">
              <h3 class="font-semibold text-sm mb-2">Manual Invocation</h3>
              <form phx-submit="invoke_tool" phx-change="update_invoke" class="space-y-2">
                <input
                  type="text"
                  name="action"
                  value={@invoke_action}
                  placeholder="Action"
                  class="input input-bordered input-sm w-full"
                />
                <textarea
                  name="args"
                  class="textarea textarea-bordered w-full font-mono text-sm"
                  rows="4"
                  placeholder='{"key": "value"}'
                >{@invoke_args}</textarea>
                <button type="submit" class="btn btn-warning btn-sm">
                  <.icon name="hero-play-mini" class="size-4" /> Invoke
                </button>
              </form>

              <%= if @invoke_result do %>
                <div class="mt-3 p-3 bg-success/10 border border-success/30 rounded text-sm">
                  <div class="font-semibold mb-1">Result:</div>
                  <pre class="font-mono text-xs whitespace-pre-wrap">{inspect(@invoke_result, pretty: true)}</pre>
                </div>
              <% end %>

              <%= if @invoke_error do %>
                <div class="mt-3 p-3 bg-error/10 border border-error/30 rounded text-sm">
                  <div class="font-semibold mb-1">Error:</div>
                  <pre class="font-mono text-xs whitespace-pre-wrap">{@invoke_error}</pre>
                </div>
              <% end %>
            </div>
          <% else %>
            <div class="flex items-center justify-center h-full text-base-content/40">
              <div class="text-center">
                <.icon name="hero-wrench-screwdriver" class="size-12 mx-auto mb-2" />
                <p>Select a tool from the list to view details.</p>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end
end
