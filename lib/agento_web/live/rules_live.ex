defmodule AgentoWeb.RulesLive do
  @moduledoc """
  The rules this machine runs: what is loaded and in what state, what the
  last events did, what a rule could call, and a way to deploy one now.

  Everything shown is read from the runtime on mount and every two seconds
  after. A deploy from the form is a deploy like any other: it replaces
  what was loaded under that name, and a file in the rules directory with
  the same name will replace it in turn on its next save.
  """
  use AgentoWeb, :live_view

  alias Agento.Rules

  @refresh_ms 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     assign(socket,
       active_nav: :rules,
       snapshot: Rules.snapshot(),
       load_id: "",
       load_source: "",
       explain_event: "",
       explain_path: "",
       explanation: nil
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, snapshot: Rules.snapshot())}
  end

  @impl true
  def handle_event("load", %{"policy" => id, "source" => source}, socket) do
    id = String.trim(id)

    socket =
      case deploy(id, source) do
        :ok ->
          socket |> put_flash(:info, "#{id} deployed") |> assign(load_source: "")

        {:partial, failures} ->
          put_flash(
            socket,
            :error,
            "#{id} deployed with inert declarations: #{inspect(failures)}"
          )

        {:error, reason} ->
          put_flash(socket, :error, "#{id} not deployed: #{describe(reason)}")
      end

    {:noreply, assign(socket, load_id: id, snapshot: Rules.snapshot())}
  end

  def handle_event("unload", %{"id" => id}, socket) do
    socket =
      case withdraw(id) do
        :ok -> put_flash(socket, :info, "#{id} unloaded")
        {:error, :not_loaded} -> put_flash(socket, :error, "#{id} is not loaded")
        {:error, reason} -> put_flash(socket, :error, "#{id} not unloaded: #{describe(reason)}")
      end

    {:noreply, assign(socket, snapshot: Rules.snapshot())}
  end

  def handle_event("explain", %{"event" => event, "path" => path}, socket) do
    event = event |> String.trim() |> String.upcase()
    path = String.trim(path)

    explanation =
      if event == "", do: nil, else: Map.put(Rules.explain(event, path), :event, event)

    {:noreply, assign(socket, explain_event: event, explain_path: path, explanation: explanation)}
  end

  # The web UI has no login. Deploying a policy is handing the runtime code,
  # so the hub configuration has to say the UI may; otherwise files only.
  # Checked here, not in the template alone: the event can be sent without
  # the form.
  defp deploy(id, source) do
    if Rules.ui_deploy?(), do: Rules.load(id, source), else: {:error, :ui_deploy_off}
  end

  defp withdraw(id) do
    if Rules.ui_deploy?(), do: Rules.unload(id), else: {:error, :ui_deploy_off}
  end

  defp describe(:ui_deploy_off),
    do: "deploying from the UI is off; set :rules {:ui-deploy true} in the hub configuration"

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(%{message: message}) when is_binary(message), do: message
  defp describe(reason), do: inspect(reason)

  defp status_text(nil), do: "loaded here"
  defp status_text(:ok), do: "from file"
  defp status_text({:partial, failures}), do: "from file, #{length(failures)} inert"
  defp status_text({:error, _}), do: "file broken, previous version running"

  # nil means deployed from this UI: not a file, so no file state; the ramp's
  # "unknown" is the honest step. :ok is a healthy file; anything else is degraded.
  defp status_step(nil), do: :unknown
  defp status_step(:ok), do: :low
  defp status_step(_), do: :medium

  defp outcome_text(:fires), do: "fires"
  defp outcome_text({:dwell, ms}), do: "arms a #{ms} ms dwell"
  defp outcome_text(:context_mismatch), do: "context does not admit it"
  defp outcome_text(other), do: to_string(other)

  defp step_text(%{rule: rule, outcome: outcome}), do: "#{rule}: #{outcome}"

  defp result_text(%{type: :log, value: value}), do: "log #{inspect(value)}"

  defp result_text(%{type: :assert, subject: s, held: held}),
    do: "assert #{s}: #{if held, do: "held", else: "failed, rule stopped"}"

  defp result_text(%{type: type, subject: s, value: value}),
    do: "#{type} #{s}: #{inspect(value, limit: 20, printable_limit: 200)}"

  defp result_text(%{type: :error, reason: reason}), do: "error #{inspect(reason)}"
  defp result_text(%{type: type}), do: to_string(type)

  defp clock(%DateTime{} = at),
    do: at |> DateTime.to_time() |> Time.truncate(:second) |> to_string()

  defp clock(_), do: ""

  # Readable, and distinct for names that differ only in punctuation.
  defp dom_id(prefix, name) do
    name = to_string(name)

    prefix <>
      "-" <>
      String.replace(name, ~r/[^A-Za-z0-9]+/, "-") <>
      "-" <> Integer.to_string(:erlang.phash2(name), 36)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app flash={@flash} active_nav={:rules}>
      <div class="space-y-2">
        <div class="flex items-baseline justify-between">
          <h1 class="text-h2">Rules</h1>
          <span class="text-small text-muted">watching <span class="ds-data">{@snapshot.dir}</span></span>
        </div>

        <.alert
          :if={!@snapshot.available}
          severity={:medium}
          title="The rules runtime is not answering."
          id="runtime-unavailable"
        >
          It is restarting, or a rule is not finishing. What is shown is the last trace; the rest fills in when it answers.
        </.alert>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-2">
          <.card
            title={"Policies (#{length(@snapshot.policies)})"}
            density={:compact}
            class="lg:col-span-2 space-y-1"
          >
            <.empty :if={@snapshot.policies == []}>
              Nothing is loaded. Save a <span class="ds-data">.rule</span>
              file in the directory above, or deploy one below.
            </.empty>
            <div :if={@snapshot.policies != []} class="overflow-x-auto">
              <table class="ds-table ds-table--compact">
                <thead>
                  <tr>
                    <th class="ds-table__th">Policy</th>
                    <th class="ds-table__th">Rules</th>
                    <th class="ds-table__th">Conditions</th>
                    <th class="ds-table__th">Schedules</th>
                    <th class="ds-table__th">Status</th>
                    <th class="ds-table__th"></th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={p <- @snapshot.policies}
                    id={dom_id("policy", p.id || "anonymous")}
                    class="ds-table__row"
                  >
                    <td class="ds-table__td">{p.id || "(anonymous)"}</td>
                    <td class="ds-table__td text-caption">{Enum.join(p.rules, ", ")}</td>
                    <td class="ds-table__td text-caption">{Enum.join(p.conditions, ", ")}</td>
                    <td class="ds-table__td text-caption">{Enum.join(p.schedules, ", ")}</td>
                    <td class="ds-table__td">
                      <.status_badge
                        step={status_step(p.status)}
                        label={status_text(p.status)}
                        size={12}
                      />
                    </td>
                    <td class="ds-table__td text-right">
                      <.button
                        :if={p.id && @snapshot.ui_deploy}
                        size={:sm}
                        phx-click="unload"
                        phx-value-id={p.id}
                        data-confirm={"Unload #{p.id}?"}
                      >unload</.button>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <p :if={!@snapshot.ui_deploy} class="text-caption text-muted" id="ui-deploy-off">
              Deploying from here is off: this UI has no login. Policies come from files in the
              directory above. To deploy and unload from here, set
              <span class="ds-data">{":rules {:ui-deploy true}"}</span>
              in the hub configuration.
            </p>
            <form :if={@snapshot.ui_deploy} phx-submit="load" class="space-y-1">
              <h3 class="ds-label">Deploy a policy</h3>
              <.input
                name="policy"
                value={@load_id}
                placeholder="policy name, e.g. garage.rule"
                required
              />
              <.textarea
                name="source"
                rows={6}
                value={@load_source}
                placeholder={~s|rule greet { when HUB_REQUEST { log ?client } }|}
                required
              />
              <.button type="submit" variant={:primary} size={:sm}>Deploy</.button>
            </form>
          </.card>

          <div class="space-y-2">
            <.card title="What would an event do?" density={:compact}>
              <form phx-submit="explain" class="space-y-1">
                <.input name="event" value={@explain_event} placeholder="HUB_REQUEST" />
                <.input name="path" value={@explain_path} placeholder="context path (optional)" />
                <.button type="submit" size={:sm}>Explain</.button>
              </form>
              <div :if={@explanation} id="explanation" class="text-caption space-y-0.5 mt-1">
                <p :if={@explanation[:unavailable]}>The runtime is not answering.</p>
                <p :if={
                  !@explanation[:unavailable] and @explanation.rules == [] and
                    @explanation.conditions == []
                }>
                  Nothing listens for <span class="ds-data">{@explanation.event}</span>.
                </p>
                <p :for={r <- @explanation.rules}>
                  <span class="ds-data">{r.rule}</span>
                  ({r.policy || "anonymous"}): {outcome_text(r.outcome)}
                </p>
                <p :for={c <- @explanation.conditions}>
                  condition <span class="ds-data">{c}</span> evaluates
                </p>
              </div>
            </.card>

            <.card title="Tools a rule may call" density={:compact}>
              <p :if={@snapshot.tools == []} class="text-caption text-muted">
                None: <span class="ds-data">{":rules {:tools [...]}"}</span>
                in the hub configuration is empty. {length(@snapshot.verbs)} verbs are discoverable.
              </p>
              <div :if={@snapshot.tools != []} class="text-caption">
                <p class="ds-data">{Enum.join(@snapshot.tools, " ")}</p>
                <p class="text-muted mt-0.5">
                  {length(@snapshot.verbs)} verbs discoverable, as <span class="ds-data">[MODULE::verb :key value]</span>.
                </p>
              </div>
            </.card>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-2">
          <.card title={"Rules (#{length(@snapshot.rules)})"} density={:compact}>
            <.empty :if={@snapshot.rules == []}>No rules loaded.</.empty>
            <div :if={@snapshot.rules != []} class="overflow-x-auto">
              <table class="ds-table ds-table--compact">
                <thead>
                  <tr>
                    <th class="ds-table__th">Rule</th>
                    <th class="ds-table__th">Listens for</th>
                    <th class="ds-table__th">Context</th>
                    <th class="ds-table__th">State</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={r <- @snapshot.rules} id={dom_id("rule", r.name)} class="ds-table__row">
                    <td class="ds-table__td">
                      <span class="ds-data">{r.name}</span>
                      <div class="text-caption text-muted">{r.policy || "anonymous"}</div>
                    </td>
                    <td class="ds-table__td text-caption">{Enum.join(r.events, ", ")}</td>
                    <td class="ds-table__td text-caption">{r.context}</td>
                    <td class="ds-table__td text-caption">
                      <div :for={{k, v} <- r.bindings}>${k} = {inspect(v)}</div>
                      <div :for={d <- r.dwell}>dwell {d.event}: {d.state}</div>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>

            <h3 :if={@snapshot.conditions != []} class="ds-label mt-2 mb-1">Conditions</h3>
            <ul :if={@snapshot.conditions != []} class="text-caption space-y-0.5">
              <li :for={c <- @snapshot.conditions} id={dom_id("condition", c.name)}>
                <span class="ds-data">{c.name}</span>
                is <span class="ds-data">{c.value}</span>
                after <span class="ds-data">{Enum.join(c.events, ", ")}</span>
              </li>
            </ul>

            <h3 :if={@snapshot.schedules != []} class="ds-label mt-2 mb-1">Schedules</h3>
            <ul :if={@snapshot.schedules != []} class="text-caption space-y-0.5">
              <li :for={s <- @snapshot.schedules} id={dom_id("schedule", s.event)}>
                <span class="ds-data">{s.event}</span>
                <span :if={s.fired_at} class="text-muted">last fired {clock(s.fired_at)} UTC</span>
              </li>
            </ul>
          </.card>

          <.card title={"Trace (#{length(@snapshot.trace)})"} density={:compact}>
            <.empty :if={@snapshot.trace == []}>No event has reached a rule yet.</.empty>
            <div :if={@snapshot.trace != []} class="overflow-x-auto">
              <table class="ds-table ds-table--dense">
                <thead>
                  <tr>
                    <th class="ds-table__th">Time (UTC)</th>
                    <th class="ds-table__th">Event</th>
                    <th class="ds-table__th">Context</th>
                    <th class="ds-table__th">Rules</th>
                    <th class="ds-table__th">Results</th>
                    <th class="ds-table__th ds-table__th--num">Took</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={t <- @snapshot.trace} class="ds-table__row">
                    <td class="ds-table__td">{clock(t.at)}</td>
                    <td class="ds-table__td">{t.event}</td>
                    <td class="ds-table__td text-muted">{t.context_path}</td>
                    <td class="ds-table__td">
                      <div :for={s <- t.steps}>{step_text(s)}</div>
                      <div :for={c <- t.conditions}>condition {c} became true</div>
                    </td>
                    <td class="ds-table__td">
                      <div :for={r <- t.results}>{result_text(r)}</div>
                    </td>
                    <td class="ds-table__td ds-table__td--num">{div(t.duration_us, 1000)} ms</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </.card>
        </div>
      </div>
    </.app>
    """
  end
end
