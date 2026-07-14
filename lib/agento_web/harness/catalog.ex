defmodule AgentoWeb.Harness.Catalog do
  @moduledoc """
  Read-only catalogs surfaced by the harness API: instantiable agent types
  (from `LLMAgent.RolePrompt`) and available tools (via `Discovery.Tools`).
  """

  @spec agents() :: [%{id: String.t(), name: String.t()}]
  def agents do
    LLMAgent.RolePrompt.roles()
    |> Enum.map(fn role ->
      %{id: to_string(role), name: humanize(role)}
    end)
  rescue
    # RolePrompt not loaded — no catalog rather than a crash.
    _e in [UndefinedFunctionError, ArgumentError] -> []
  end

  @spec agent_ids() :: [String.t()]
  def agent_ids, do: Enum.map(agents(), & &1.id)

  @spec toolbox() :: [%{name: String.t(), module: String.t(), describe: String.t() | nil}]
  def toolbox do
    AgentoWeb.Discovery.Tools.list()
    |> Enum.map(fn {name, module} ->
      %{
        name: to_string(name),
        module: inspect(module),
        describe: AgentoWeb.Discovery.Tools.describe(module)
      }
    end)
  end

  defp humanize(role) do
    role |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end
end
