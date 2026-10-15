defmodule AgentoWeb.ToolsLive do
  @moduledoc """
  Tool Inspector LiveView -- tool registry + manual invocation.
  Implements R6 (Tool Inspector).
  """
  use AgentoWeb, :live_view

  alias AgentoWeb.Discovery.Tools

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
      <div class="flex h-full gap-2">
        <%!-- Tool list --%>
        <.card
          title={"Registered tools (#{length(@tools)})"}
          density={:compact}
          flush
          class="w-36 flex flex-col min-h-0"
        >
          <:actions>
            <.button size={:sm} icon="m-refresh" phx-click="refresh_tools" title="Refresh">Refresh</.button>
          </:actions>
          <div class="overflow-y-auto">
            <.empty :if={@tools == []}>No tools registered.</.empty>
            <div
              :for={{name, module} <- @tools}
              phx-click="select_tool"
              phx-value-name={name}
              phx-value-module={module}
              class={[
                "p-1 cursor-pointer border-b border-border hover:bg-surface-raised",
                @selected_tool == to_string(name) && "bg-surface-raised"
              ]}
              aria-current={@selected_tool == to_string(name) && "true"}
            >
              <div class="font-medium text-small">{name}</div>
              <div class="text-caption text-muted truncate">{module}</div>
            </div>
          </div>
        </.card>

        <%!-- Tool detail --%>
        <div class="flex-1 overflow-y-auto space-y-2">
          <%= if @selected_module do %>
            <h2 class="text-h3">{@selected_tool}</h2>
            <p class="text-small text-muted">{@selected_module}</p>

            <.card :if={assigns[:tool_description]} title="Description" density={:compact}>
              <p class="text-small whitespace-pre-wrap">{@tool_description}</p>
            </.card>

            <.card :if={@tool_introspection} title="Comn introspection" density={:compact}>
              <.key_value>
                <:item key="look/0">{@tool_introspection.look}</:item>
                <:item key="recon/0"><.pre value={@tool_introspection.recon} /></:item>
                <:item key="choices/0"><.pre value={@tool_introspection.choices} /></:item>
              </.key_value>
            </.card>

            <.card title="Manual invocation" density={:compact}>
              <form
                id="invoke-tool-form"
                phx-submit="invoke_tool"
                phx-change="update_invoke"
                class="space-y-1"
              >
                <.input name="action" value={@invoke_action} placeholder="Action" />
                <.textarea
                  name="args"
                  value={@invoke_args}
                  rows={4}
                  placeholder={~s|{"key": "value"}|}
                />
                <.button type="submit" variant={:primary} size={:sm} icon="m-run">Invoke</.button>
              </form>

              <.alert :if={@invoke_result} severity={:low} title="Invoked." class="mt-1">
                <.pre value={@invoke_result} />
              </.alert>

              <.alert
                :if={@invoke_error}
                severity={:critical}
                title={error_title(@invoke_error)}
                class="mt-1"
              >
                <pre class="ds-data text-caption whitespace-pre-wrap">{@invoke_error}</pre>
              </.alert>
            </.card>
          <% else %>
            <.state_panel mode={:empty} mark="m-tool" title="No tool selected.">
              Pick a tool on the left to see its description, introspection and invoke it.
            </.state_panel>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end

  # what happened · what to do, per the voice chapter
  defp error_title("Invalid JSON in args field"),
    do: "Args are not JSON. Fix the text and invoke again."

  defp error_title(_), do: "The tool returned an error."
end
