defmodule LlmagentWebWeb.Discovery.Tools do
  @moduledoc """
  Wraps LLMAgent.Tools for runtime tool discovery.

  Discovers registered tools dynamically so the UI never
  hardcodes what tools exist.
  """

  @doc """
  Returns all registered tools as a list of `{atom, module}` tuples.
  """
  @spec list() :: [{atom(), module()}]
  def list do
    try do
      LLMAgent.Tools.all()
    rescue
      _ -> []
    end
  end

  @doc """
  Returns the description for a tool module via `describe/0`.
  """
  @spec describe(module()) :: String.t() | nil
  def describe(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :describe, 0) do
      module.describe()
    end
  end

  @doc """
  Checks if a tool module implements the Comn behaviour (exports recon/0).
  """
  @spec has_comn_behaviour?(module()) :: boolean()
  def has_comn_behaviour?(module) do
    Code.ensure_loaded?(module) and
      function_exported?(module, :look, 0) and
      function_exported?(module, :recon, 0) and
      function_exported?(module, :choices, 0) and
      function_exported?(module, :act, 1)
  end

  @doc """
  Returns the Comn introspection data for a module, if available.
  """
  @spec introspect(module()) :: map() | nil
  def introspect(module) do
    if has_comn_behaviour?(module) do
      %{
        look: module.look(),
        recon: module.recon(),
        choices: module.choices()
      }
    end
  end
end
