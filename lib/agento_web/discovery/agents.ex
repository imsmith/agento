defmodule AgentoWeb.Discovery.Agents do
  @moduledoc """
  Wraps LLMAgent.AgentSupervisor API for agent discovery.

  Provides a stable interface for LiveViews to query running agents
  without coupling directly to LLMAgent internals.
  """

  @doc """
  Returns a list of maps describing all running agents.

  Each map contains: pid, name, role, model, api_host, history_length.
  """
  @spec list() :: [map()]
  def list do
    try do
      LLMAgent.AgentSupervisor.list_agents_with_state()
    rescue
      _ -> []
    end
  end

  @doc """
  Returns agent state for the given name, or nil if not found.
  """
  @spec get(atom()) :: map() | nil
  def get(name) do
    list()
    |> Enum.find(&(&1.name == name))
  end

  @doc """
  Starts a new agent with the given options.
  """
  @spec start(keyword()) :: {:ok, pid()} | {:error, term()}
  def start(opts) do
    LLMAgent.AgentSupervisor.start_agent(opts)
  end

  @doc """
  Stops an agent by name.
  """
  @spec stop(atom()) :: :ok | {:error, :not_found}
  def stop(name) do
    LLMAgent.AgentSupervisor.stop_agent(name)
  end
end
