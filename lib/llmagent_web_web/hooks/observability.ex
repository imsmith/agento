defmodule LlmagentWebWeb.Hooks.Observability do
  @moduledoc """
  LiveView on_mount hook that sets up Comn.Contexts for request tracing
  and emits web.* events so the web app's own actions are observable
  in the LLMAgent event infrastructure.

  Attach via `live_session :default, on_mount: {LlmagentWebWeb.Hooks.Observability, :default}`.

  Each LiveView mount gets a unique request_id and trace_id. The context
  is stored in assigns so it can be restored on each handle_event
  (LiveView processes share the process dictionary across callbacks,
  but explicit restore ensures correctness after hot code reloads).
  """

  import Phoenix.LiveView
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket) do
    request_id = generate_id("web_req")
    trace_id = generate_id("web_trace")

    ctx =
      Comn.Contexts.new(%{
        request_id: request_id,
        trace_id: trace_id,
        actor: "llmagent_web",
        env: "web"
      })

    LlmagentWebWeb.WebEvents.emit_mount(socket.view)

    socket =
      socket
      |> assign(:comn_context, ctx)
      |> attach_hook(:observability_events, :handle_event, &handle_event_hook/3)

    {:cont, socket}
  end

  defp handle_event_hook(event, params, socket) do
    if ctx = socket.assigns[:comn_context] do
      Comn.Contexts.set(ctx)
    end

    LlmagentWebWeb.WebEvents.emit_event(event, socket.view, Map.keys(params))

    {:cont, socket}
  end

  defp generate_id(prefix) do
    prefix <> "_" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  end
end
