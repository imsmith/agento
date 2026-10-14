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
  alias AgentoWeb.DS
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

  # Only what the hub itself recorded. A rule can emit on any topic, this
  # one included; its events carry its own source and another shape.
  @impl true
  def handle_info(
        {"hub.request", %{source: AgentoWeb.HubController, data: %{at: _} = turn}},
        socket
      ) do
    turns = Enum.take([turn | socket.assigns.turns], @max_turns)
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

  defp dom_id(prefix, name),
    do: prefix <> "-" <> String.replace(to_string(name), ~r/[^A-Za-z0-9]+/, "-")

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:hub}>
      <div class="space-y-2">
        <div class="flex items-baseline justify-between">
          <h1 class="text-h2">Private LLM hub</h1>
          <span class="text-small text-muted">
            <%= if @status.listening do %>
              listening on <span class="ds-data">{@status.listening}</span>,
            <% else %>
              not serving HTTP,
            <% end %>
            registered with busybody as <span class="ds-data">{@status.busybody_name}</span>
          </span>
        </div>

        <.alert
          :if={@status.default_host && !@status.default_reachable}
          severity={:medium}
          title={"The default host #{@status.default_host} is not advertising."}
        >
          Requests for a model no host serves, which is every request a coding client makes, get a 404. Start that host or change the default.
        </.alert>

        <.alert
          :if={is_nil(@status.default_host)}
          severity={:medium}
          title="No default host is configured."
        >
          Only requests naming a model a host serves will route. Set one in the hub configuration.
        </.alert>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-2">
          <.card
            title={"Performers (#{length(@status.performers)})"}
            density={:compact}
            class="lg:col-span-2"
          >
            <.empty :if={@status.performers == []}>
              No performers are advertising on the network.
            </.empty>
            <table :if={@status.performers != []} class="ds-table ds-table--compact">
              <thead>
                <tr>
                  <th class="ds-table__th">Host</th>
                  <th class="ds-table__th">Serving</th>
                  <th class="ds-table__th ds-table__th--num">Context</th>
                  <th class="ds-table__th ds-table__th--num">Slots</th>
                  <th class="ds-table__th">Found by</th>
                  <th class="ds-table__th ds-table__th--num">Lease</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={p <- @status.performers}
                  id={dom_id("performer", p.host || p.id)}
                  class="ds-table__row"
                >
                  <td class="ds-table__td">
                    <span class="ds-data">{p.host}</span>
                    <.tag :if={p.default} accent class="ml-0.5">default</.tag>
                    <div class="text-caption text-muted ds-data">{p.address}</div>
                  </td>
                  <td class="ds-table__td"><span class="ds-data text-caption">{p.model}</span></td>
                  <td class="ds-table__td ds-table__td--num">{p.context}</td>
                  <td class="ds-table__td ds-table__td--num">{p.slots}</td>
                  <td class="ds-table__td"><span class="text-caption">{p.source}</span></td>
                  <td class="ds-table__td ds-table__td--num">
                    <span class="text-caption">{p.lease}</span>
                  </td>
                </tr>
              </tbody>
            </table>
          </.card>

          <div class="space-y-2">
            <.card title={"Clients (#{length(@status.clients)})"} density={:compact}>
              <.empty :if={@status.clients == []}>
                No clients are configured, so every request is refused. Add one to <span class="ds-data">{@status.config_path}</span>.
              </.empty>
              <ul :if={@status.clients != []} class="text-small space-y-0.5">
                <li
                  :for={c <- @status.clients}
                  id={dom_id("client", c.name)}
                  class="flex justify-between"
                >
                  <span class="ds-data">{c.name}</span>
                  <span class="text-caption text-muted">{c.reach}</span>
                </li>
              </ul>
            </.card>

            <.card title="Settings" density={:compact}>
              <.key_value density={:dense}>
                <:item key="Default host">{@status.default_host || "none"}</:item>
                <:item key="Performer timeout" num>{@status.performer_timeout_s} s</:item>
                <:item key="Turn log kept" num>{@status.retention_days} days</:item>
                <:item key="Config"><span class="break-all">{@status.config_path}</span></:item>
              </.key_value>
            </.card>
          </div>
        </div>

        <.card title="Point a client at it" density={:compact}>
          <pre class="ds-data text-caption bg-surface-raised p-1 rounded-md whitespace-pre-wrap">export ANTHROPIC_BASE_URL=$(tclsh scripts/hub-url.tcl)
    export ANTHROPIC_AUTH_TOKEN=&lt;the client's token from the hub config&gt;</pre>
          <p class="text-caption text-muted mt-1">
            The hub takes a free port each time it starts. The script asks busybody where it is now.
          </p>
        </.card>

        <.card title={"Recent turns (#{length(@turns)})"} density={:compact}>
          <.empty :if={@turns == []}>No turns yet.</.empty>
          <table :if={@turns != []} class="ds-table ds-table--dense">
            <thead>
              <tr>
                <th class="ds-table__th">Time (UTC)</th>
                <th class="ds-table__th">Client</th>
                <th class="ds-table__th">Asked for</th>
                <th class="ds-table__th">Served by</th>
                <th class="ds-table__th">Outcome</th>
                <th class="ds-table__th ds-table__th--num">Tokens in</th>
                <th class="ds-table__th ds-table__th--num">Tokens out</th>
                <th class="ds-table__th ds-table__th--num">Took</th>
              </tr>
            </thead>
            <tbody id="turns">
              <tr :for={t <- @turns} class="ds-table__row">
                <td class="ds-table__td">{clock(t.at)}</td>
                <td class="ds-table__td">{t.client}</td>
                <td class="ds-table__td">{t.requested_model}</td>
                <td class="ds-table__td">{t.performer_model}</td>
                <td class="ds-table__td">
                  <.status_badge step={DS.step(t.outcome)} label={outcome_word(t.outcome)} size={12} />
                  <span :if={t.stop_reason} class="text-caption text-muted ml-0.5">{t.stop_reason}</span>
                  <div :if={t.error} class="text-caption text-status-critical">{t.error}</div>
                </td>
                <td class="ds-table__td ds-table__td--num">{t.input_tokens}</td>
                <td class="ds-table__td ds-table__td--num">{t.output_tokens}</td>
                <td class="ds-table__td ds-table__td--num">{duration(t.duration_ms)}</td>
              </tr>
            </tbody>
          </table>
        </.card>
      </div>
    </.app>
    """
  end

  # The lexicon word is the chrome; the hub's own outcome string stays visible as a label
  # only where it adds information beyond the step.
  defp outcome_word("ok"), do: "OK"
  defp outcome_word("aborted"), do: "ABORTED"
  defp outcome_word(_error), do: "DOWN"
end
