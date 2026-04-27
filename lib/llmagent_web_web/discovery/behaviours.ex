defmodule LlmagentWebWeb.Discovery.Behaviours do
  @moduledoc """
  Scans loaded modules for behaviour implementations.

  Used for version-adaptive discovery of LLM client implementations,
  memory backends, role prompts, and Comn behaviour modules.
  """

  @doc """
  Returns modules implementing LLMAgent.LLMClient behaviour.
  """
  @spec llm_clients() :: [module()]
  def llm_clients do
    scan_for_callbacks([:chat, 2])
    |> Enum.filter(&String.contains?(to_string(&1), "LLMClient"))
  end

  @doc """
  Returns modules implementing LLMAgent.Memory behaviour.
  """
  @spec memory_backends() :: [module()]
  def memory_backends do
    scan_for_callbacks([:init, 2, :store, 3, :fetch, 2])
    |> Enum.filter(&String.contains?(to_string(&1), "Memory"))
  end

  @doc """
  Returns all loaded modules that implement the Comn behaviour
  (export look/0, recon/0, choices/0, act/1).
  """
  @spec comn_modules() :: [module()]
  def comn_modules do
    for {mod, _} <- :code.all_loaded(),
        Code.ensure_loaded?(mod),
        function_exported?(mod, :look, 0),
        function_exported?(mod, :recon, 0),
        function_exported?(mod, :choices, 0),
        function_exported?(mod, :act, 1) do
      mod
    end
    |> Enum.sort()
  end

  @doc """
  Returns all loaded modules matching a given behaviour module,
  by checking if the module declares @behaviour for it.
  """
  @spec implementations_of(module()) :: [module()]
  def implementations_of(behaviour) do
    for {mod, _} <- :code.all_loaded(),
        Code.ensure_loaded?(mod),
        declares_behaviour?(mod, behaviour) do
      mod
    end
    |> Enum.sort()
  end

  # -- Private --

  defp scan_for_callbacks(callback_specs) do
    callback_specs
    |> Enum.chunk_every(2)
    |> then(fn pairs ->
      for {mod, _} <- :code.all_loaded(),
          Code.ensure_loaded?(mod),
          Enum.all?(pairs, fn [fun, arity] ->
            function_exported?(mod, fun, arity)
          end) do
        mod
      end
    end)
  end

  defp declares_behaviour?(module, behaviour) do
    case module.module_info(:attributes) |> Keyword.get_values(:behaviour) do
      behaviours ->
        behaviour in List.flatten(behaviours)
    end
  rescue
    _ -> false
  end
end
