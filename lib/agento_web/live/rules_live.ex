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

  defp status_class(:ok), do: "badge badge-success badge-sm"
  defp status_class(nil), do: "badge badge-info badge-sm"
  defp status_class(_), do: "badge badge-warning badge-sm"

  defp outcome_text(:fires), do: "fires"
  defp outcome_text({:dwell, ms}), do: "arms a #{ms} ms dwell"
  defp outcome_text(:context_mismatch), do: "context does not admit it"
  defp outcome_text(other), do: to_string(other)

  defp step_text(%{rule: rule, outcome: outcome}), do: "#{rule}: #{outcome}"

  defp result_text(%{type: :log, value: value}), do: "log #{inspect(value)}"
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
      <div class="h-full overflow-y-auto p-4 space-y-4">
        <div class="flex items-baseline justify-between">
          <h1 class="text-xl font-bold">Rules</h1>
          <span class="text-sm text-base-content/60">
            watching <span class="font-mono">{@snapshot.dir}</span>
          </span>
        </div>

        <div :if={!@snapshot.available} class="alert alert-warning text-sm" id="runtime-unavailable">
          <.icon name="hero-exclamation-triangle-mini" class="size-4" />
          The rules runtime is not answering: it is restarting, or a rule is not finishing.
          What is shown is the last trace; the rest will fill in when it answers.
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <div class="card bg-base-200 p-4 lg:col-span-2 space-y-3">
            <h2 class="font-semibold text-sm">Policies ({length(@snapshot.policies)})</h2>
            <p :if={@snapshot.policies == []} class="text-sm text-base-content/50">
              Nothing is loaded. Save a <span class="font-mono">.rule</span>
              file in the directory above, or deploy one below.
            </p>
            <table :if={@snapshot.policies != []} class="table table-sm">
              <thead>
                <tr>
                  <th>Policy</th>
                  <th>Rules</th>
                  <th>Conditions</th>
                  <th>Schedules</th>
                  <th>Status</th>
                  <th></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={p <- @snapshot.policies} id={dom_id("policy", p.id || "anonymous")}>
                  <td class="font-mono">{p.id || "(anonymous)"}</td>
                  <td class="font-mono text-xs">{Enum.join(p.rules, ", ")}</td>
                  <td class="font-mono text-xs">{Enum.join(p.conditions, ", ")}</td>
                  <td class="font-mono text-xs">{Enum.join(p.schedules, ", ")}</td>
                  <td><span class={status_class(p.status)}>{status_text(p.status)}</span></td>
                  <td class="text-right">
                    <button
                      :if={p.id && @snapshot.ui_deploy}
                      phx-click="unload"
                      phx-value-id={p.id}
                      class="btn btn-ghost btn-xs"
                      data-confirm={"Unload #{p.id}?"}
                    >
                      unload
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>

            <p :if={!@snapshot.ui_deploy} class="text-xs text-base-content/60" id="ui-deploy-off">
              Deploying from here is off: this UI has no login. Policies come from files in the
              directory above. To deploy and unload from here, set
              <span class="font-mono">{":rules {:ui-deploy true}"}</span>
              in the hub configuration.
            </p>
            <form :if={@snapshot.ui_deploy} phx-submit="load" class="space-y-2">
              <h3 class="font-semibold text-xs text-base-content/60">Deploy a policy</h3>
              <input
                type="text"
                name="policy"
                value={@load_id}
                placeholder="policy name, e.g. garage.rule"
                class="input input-sm input-bordered w-full font-mono"
                required
              />
              <textarea
                name="source"
                rows="6"
                placeholder={~s|rule greet { when HUB_REQUEST { log ?client } }|}
                class="textarea textarea-bordered w-full font-mono text-xs"
                required
              >{@load_source}</textarea>
              <button type="submit" class="btn btn-primary btn-sm">Deploy</button>
            </form>
          </div>

          <div class="space-y-4">
            <div class="card bg-base-200 p-4 text-sm space-y-2">
              <h2 class="font-semibold text-sm">What would an event do?</h2>
              <form phx-submit="explain" class="space-y-2">
                <input
                  type="text"
                  name="event"
                  value={@explain_event}
                  placeholder="HUB_REQUEST"
                  class="input input-sm input-bordered w-full font-mono"
                />
                <input
                  type="text"
                  name="path"
                  value={@explain_path}
                  placeholder="context path (optional)"
                  class="input input-sm input-bordered w-full font-mono"
                />
                <button type="submit" class="btn btn-sm">Explain</button>
              </form>
              <div :if={@explanation} id="explanation" class="text-xs space-y-1">
                <p :if={@explanation[:unavailable]}>The runtime is not answering.</p>
                <p :if={
                  !@explanation[:unavailable] and @explanation.rules == [] and
                    @explanation.conditions == []
                }>
                  Nothing listens for <span class="font-mono">{@explanation.event}</span>.
                </p>
                <p :for={r <- @explanation.rules}>
                  <span class="font-mono">{r.rule}</span>
                  ({r.policy || "anonymous"}): {outcome_text(r.outcome)}
                </p>
                <p :for={c <- @explanation.conditions}>
                  condition <span class="font-mono">{c}</span> evaluates
                </p>
              </div>
            </div>

            <div class="card bg-base-200 p-4 text-sm">
              <h2 class="font-semibold text-sm mb-2">Tools a rule may call</h2>
              <p :if={@snapshot.tools == []} class="text-xs text-base-content/60">
                None: <span class="font-mono">{":rules {:tools [...]}"}</span>
                in the hub configuration is empty. {length(@snapshot.verbs)} verbs are discoverable.
              </p>
              <div :if={@snapshot.tools != []} class="text-xs">
                <p class="font-mono">{Enum.join(@snapshot.tools, " ")}</p>
                <p class="text-base-content/60 mt-1">
                  {length(@snapshot.verbs)} verbs discoverable, as <span class="font-mono">[MODULE::verb :key value]</span>.
                </p>
              </div>
            </div>
          </div>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <div class="card bg-base-200 p-4">
            <h2 class="font-semibold text-sm mb-2">Rules ({length(@snapshot.rules)})</h2>
            <p :if={@snapshot.rules == []} class="text-sm text-base-content/50">No rules loaded.</p>
            <table :if={@snapshot.rules != []} class="table table-sm">
              <thead>
                <tr>
                  <th>Rule</th>
                  <th>Listens for</th>
                  <th>Context</th>
                  <th>State</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={r <- @snapshot.rules} id={dom_id("rule", r.name)}>
                  <td>
                    <span class="font-mono">{r.name}</span>
                    <div class="text-xs text-base-content/50">{r.policy || "anonymous"}</div>
                  </td>
                  <td class="font-mono text-xs">{Enum.join(r.events, ", ")}</td>
                  <td class="font-mono text-xs">{r.context}</td>
                  <td class="font-mono text-xs">
                    <div :for={{k, v} <- r.bindings}>${k} = {inspect(v)}</div>
                    <div :for={d <- r.dwell}>dwell {d.event}: {d.state}</div>
                  </td>
                </tr>
              </tbody>
            </table>

            <h2 :if={@snapshot.conditions != []} class="font-semibold text-sm mt-4 mb-2">
              Conditions
            </h2>
            <ul :if={@snapshot.conditions != []} class="text-xs space-y-1">
              <li :for={c <- @snapshot.conditions} id={dom_id("condition", c.name)}>
                <span class="font-mono">{c.name}</span>
                is <span class="font-mono">{c.value}</span>
                after <span class="font-mono">{Enum.join(c.events, ", ")}</span>
              </li>
            </ul>

            <h2 :if={@snapshot.schedules != []} class="font-semibold text-sm mt-4 mb-2">
              Schedules
            </h2>
            <ul :if={@snapshot.schedules != []} class="text-xs space-y-1">
              <li :for={s <- @snapshot.schedules} id={dom_id("schedule", s.event)}>
                <span class="font-mono">{s.event}</span>
                <span :if={s.fired_at} class="text-base-content/60">
                  last fired {clock(s.fired_at)} UTC
                </span>
              </li>
            </ul>
          </div>

          <div class="card bg-base-200 p-4">
            <h2 class="font-semibold text-sm mb-2">Trace ({length(@snapshot.trace)})</h2>
            <p :if={@snapshot.trace == []} class="text-sm text-base-content/50">
              No event has reached a rule yet.
            </p>
            <table :if={@snapshot.trace != []} class="table table-xs">
              <thead>
                <tr>
                  <th>Time (UTC)</th>
                  <th>Event</th>
                  <th>Context</th>
                  <th>Rules</th>
                  <th>Results</th>
                  <th class="text-right">Took</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={t <- @snapshot.trace}>
                  <td class="font-mono">{clock(t.at)}</td>
                  <td class="font-mono">{t.event}</td>
                  <td class="font-mono text-base-content/60">{t.context_path}</td>
                  <td class="font-mono">
                    <div :for={s <- t.steps}>{step_text(s)}</div>
                    <div :for={c <- t.conditions}>condition {c} became true</div>
                  </td>
                  <td class="font-mono">
                    <div :for={r <- t.results}>{result_text(r)}</div>
                  </td>
                  <td class="text-right font-mono">{div(t.duration_us, 1000)} ms</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </.app>
    """
  end
end
