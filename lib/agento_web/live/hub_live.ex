defmodule AgentoWeb.HubLive do
  @moduledoc """
  The private LLM hub at a glance: where it is, who may connect, which
  performers it can route to, and the turns it has served.

  Turns arrive live from `hub.request` events. Performers are re-read every
  few seconds, since they come and go with their leases.

  This view needs no login, like the rest of the web UI. It therefore shows
  the facts of each turn and never its bodies, and clients by name and never
  their tokens. What was said in a turn stays in the turn log.
  """
  use AgentoWeb, :live_view

  alias Agento.EventBusBridge
  alias Agento.Hub.{Status, TurnLog}

  @refresh_ms 5_000
  @max_turns 100

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(EventBusBridge.pubsub(), EventBusBridge.pubsub_topic())
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, active_nav: :hub, status: Status.snapshot(), turns: recent_turns())}
  end

  @impl true
  def handle_info({"hub.request", event}, socket) do
    turns = Enum.take([event.data | socket.assigns.turns], @max_turns)
    {:noreply, assign(socket, turns: turns)}
  end

  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, status: Status.snapshot())}
  end

  def handle_info(_other, socket), do: {:noreply, socket}

  # The turn log may be down; the page still loads.
  defp recent_turns do
    @max_turns
    |> TurnLog.recent()
    |> Enum.map(&Map.drop(&1, [:request_body, :response_body]))
    |> Enum.sort_by(& &1.at, :desc)
  catch
    :exit, _reason -> []
  end

  defp clock(at) when is_binary(at), do: String.slice(at, 11, 8)
  defp clock(_at), do: ""

  defp duration(ms) when is_integer(ms) and ms >= 1_000, do: "#{Float.round(ms / 1_000, 1)} s"
  defp duration(ms) when is_integer(ms), do: "#{ms} ms"
  defp duration(_ms), do: ""

  defp outcome_class("ok"), do: "badge badge-success badge-sm"
  defp outcome_class("aborted"), do: "badge badge-warning badge-sm"
  defp outcome_class(_error), do: "badge badge-error badge-sm"

  defp dom_id(prefix, name),
    do: prefix <> "-" <> String.replace(to_string(name), ~r/[^A-Za-z0-9]+/, "-")

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:hub}>
      <div class="h-full overflow-y-auto p-4 space-y-4">
        <div class="flex items-baseline justify-between">
          <h1 class="text-xl font-bold">Private LLM hub</h1>
          <span class="text-sm text-base-content/60">
            <%= if @status.listening do %>
              listening on <span class="font-mono">{@status.listening}</span>,
            <% else %>
              not serving HTTP,
            <% end %>
            registered with busybody as <span class="font-mono">{@status.busybody_name}</span>
          </span>
        </div>

        <%= if @status.default_host && !@status.default_reachable do %>
          <div class="alert alert-warning text-sm">
            <.icon name="hero-exclamation-triangle-mini" class="size-4" /> The default host
            <span class="font-mono">{@status.default_host}</span>
            is not advertising. Requests for a model no host serves, which is every
            request a coding client makes, will get a 404.
          </div>
        <% end %>

        <%= if is_nil(@status.default_host) do %>
          <div class="alert alert-warning text-sm">
            <.icon name="hero-exclamation-triangle-mini" class="size-4" />
            No default host is configured. Only requests naming a model a host serves will route.
          </div>
        <% end %>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div class="card bg-base-200 p-4 lg:col-span-2">
            <h2 class="font-semibold text-sm mb-2">Performers ({length(@status.performers)})</h2>
            <%= if @status.performers == [] do %>
              <p class="text-sm text-base-content/50">
                No performers are advertising on the network.
              </p>
            <% else %>
              <table class="table table-sm">
                <thead>
                  <tr>
                    <th>Host</th>
                    <th>Serving</th>
                    <th class="text-right">Context</th>
                    <th class="text-right">Slots</th>
                    <th>Found by</th>
                    <th class="text-right">Lease</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={p <- @status.performers} id={dom_id("performer", p.host || p.id)}>
                    <td>
                      <span class="font-mono">{p.host}</span>
                      <span :if={p.default} class="badge badge-primary badge-sm ml-1">default</span>
                      <div class="text-xs text-base-content/50 font-mono">{p.address}</div>
                    </td>
                    <td class="font-mono text-xs">{p.model}</td>
                    <td class="text-right font-mono">{p.context}</td>
                    <td class="text-right font-mono">{p.slots}</td>
                    <td class="text-xs">{p.source}</td>
                    <td class="text-right font-mono text-xs">{p.lease}</td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>

          <div class="space-y-4">
            <div class="card bg-base-200 p-4">
              <h2 class="font-semibold text-sm mb-2">Clients ({length(@status.clients)})</h2>
              <%= if @status.clients == [] do %>
                <p class="text-sm text-base-content/50">
                  No clients are configured, so every request is refused. Add one to <span class="font-mono">{@status.config_path}</span>.
                </p>
              <% else %>
                <ul class="text-sm space-y-1">
                  <li
                    :for={c <- @status.clients}
                    id={dom_id("client", c.name)}
                    class="flex justify-between"
                  >
                    <span class="font-mono">{c.name}</span>
                    <span class="text-xs text-base-content/60">{c.reach}</span>
                  </li>
                </ul>
              <% end %>
            </div>

            <div class="card bg-base-200 p-4 text-sm">
              <h2 class="font-semibold text-sm mb-2">Settings</h2>
              <dl class="grid grid-cols-2 gap-x-2 gap-y-1 text-xs">
                <dt class="text-base-content/60">Default host</dt>
                <dd class="font-mono">{@status.default_host || "none"}</dd>
                <dt class="text-base-content/60">Performer timeout</dt>
                <dd class="font-mono">{@status.performer_timeout_s} s</dd>
                <dt class="text-base-content/60">Turn log kept</dt>
                <dd class="font-mono">{@status.retention_days} days</dd>
                <dt class="text-base-content/60">Config</dt>
                <dd class="font-mono break-all">{@status.config_path}</dd>
              </dl>
            </div>
          </div>
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold text-sm mb-2">Point a client at it</h2>
          <pre class="text-xs font-mono bg-base-300 p-2 rounded whitespace-pre-wrap">export ANTHROPIC_BASE_URL=$(tclsh scripts/hub-url.tcl)
    export ANTHROPIC_AUTH_TOKEN=&lt;the client's token from the hub config&gt;</pre>
          <p class="text-xs text-base-content/60 mt-2">
            The hub takes a free port each time it starts. The script asks busybody where it is now.
          </p>
        </div>

        <div class="card bg-base-200 p-4">
          <h2 class="font-semibold text-sm mb-2">Recent turns ({length(@turns)})</h2>
          <%= if @turns == [] do %>
            <p class="text-sm text-base-content/50">No turns yet.</p>
          <% else %>
            <table class="table table-sm">
              <thead>
                <tr>
                  <th>Time (UTC)</th>
                  <th>Client</th>
                  <th>Asked for</th>
                  <th>Served by</th>
                  <th>Outcome</th>
                  <th class="text-right">Tokens in</th>
                  <th class="text-right">Tokens out</th>
                  <th class="text-right">Took</th>
                </tr>
              </thead>
              <tbody id="turns">
                <tr :for={t <- @turns}>
                  <td class="font-mono text-xs">{clock(t.at)}</td>
                  <td class="font-mono text-xs">{t.client}</td>
                  <td class="font-mono text-xs">{t.requested_model}</td>
                  <td class="font-mono text-xs">{t.performer_model}</td>
                  <td>
                    <span class={outcome_class(t.outcome)}>{t.outcome}</span>
                    <span :if={t.stop_reason} class="text-xs text-base-content/60 ml-1">
                      {t.stop_reason}
                    </span>
                    <div :if={t.error} class="text-xs text-error">{t.error}</div>
                  </td>
                  <td class="text-right font-mono">{t.input_tokens}</td>
                  <td class="text-right font-mono">{t.output_tokens}</td>
                  <td class="text-right font-mono text-xs">{duration(t.duration_ms)}</td>
                </tr>
              </tbody>
            </table>
          <% end %>
        </div>
      </div>
    </.app>
    """
  end
end
