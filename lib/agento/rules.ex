defmodule Agento.Rules do
  @moduledoc """
  Agento's Anemos runtime: the rules this machine runs, and the view's way
  in.

  One `Anemos.Runtime`, named `:agento`, watching the rules directory from
  the hub configuration (`:rules {:dir ...}`): saving a `.rule` file there
  deploys it, deleting it unloads it. `LLMAgent.Anemos` attaches the
  substrate: every discovered tool is a module a rule can call, under the
  policy whose allow list is `:rules {:tools [...]}` — empty by default, so
  no rule calls any tool until that says so — and every substrate event is
  an event a rule can wait for.

  `snapshot/0` is what the Rules view shows; `load/2`, `unload/1` and
  `explain/2` are what it can do.
  """

  alias Agento.Hub.Config
  alias Anemos.Runtime.Watcher
  alias LLMAgent.Tool.Policy

  @runtime :agento

  @doc "The runtime's name."
  @spec runtime() :: atom()
  def runtime, do: @runtime

  @doc "The directory of `.rule` files kept deployed."
  @spec dir() :: String.t()
  def dir, do: Application.get_env(:agento, :rules_dir) || Config.get().rules_dir

  @doc "The policy a rule's tool calls are judged by."
  @spec policy() :: Policy.t()
  def policy, do: %Policy{allow: Config.get().rules_tools, fidelity_min: :authoritative}

  @doc false
  def runtime_spec, do: {Anemos.Runtime, name: @runtime, watch: dir()}

  @doc false
  def attachment_spec, do: {LLMAgent.Anemos, runtime: @runtime, policy: policy()}

  @doc "Everything loaded, with its state, the last dispatches, and what a rule could call."
  @spec snapshot() :: map()
  def snapshot do
    description = Anemos.Runtime.describe(@runtime)
    status = watcher_status()

    description
    |> Map.put(:dir, dir())
    |> Map.put(:tools, Config.get().rules_tools)
    |> Map.put(:verbs, LLMAgent.Anemos.verbs())
    |> Map.put(:trace, Anemos.Runtime.trace(@runtime, 50))
    |> Map.update!(:policies, fn policies ->
      Enum.map(policies, &Map.put(&1, :status, Map.get(status, &1.id)))
    end)
  end

  @doc "Deploy `source` as the policy `id`, over whatever was loaded under it."
  @spec load(String.t(), String.t()) ::
          :ok | {:partial, [Anemos.Runtime.load_failure()]} | {:error, term()}
  def load(id, source), do: Anemos.Runtime.load(@runtime, source, policy: id)

  @doc "Remove the policy `id` and everything it declared."
  @spec unload(String.t()) :: :ok | {:error, :not_loaded}
  def unload(id), do: Anemos.Runtime.unload(@runtime, id)

  @doc "What dispatching `event` with `context_path` would do, without doing it."
  @spec explain(String.t(), String.t() | nil) :: %{rules: [map()], conditions: [String.t()]}
  def explain(event, context_path),
    do: Anemos.Runtime.explain(@runtime, event, %{context_path: blank_to_nil(context_path)})

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(path), do: path

  # The watcher restarts with the dispatcher; between the two the page
  # still loads.
  defp watcher_status do
    Watcher.status(Anemos.Runtime.watcher_name(@runtime))
  catch
    :exit, _ -> %{}
  end
end
