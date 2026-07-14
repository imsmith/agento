defmodule AgentoWeb.Discovery.Endpoints do
  @moduledoc """
  Surfaces LAN-discovered LLM chat endpoints for the UI.

  llmagent browses mDNS (`_llama._tcp`) and registers each reachable
  server as a tool ad at coordinate `compute.llm.chat`. This module reads
  those ads from `LLMAgent.Tools.Discovery` and projects each into a flat
  option map the new-agent dialog can render and submit.

  Provides a stable interface for LiveViews to query available endpoints
  without coupling directly to LLMAgent's ad internals.
  """

  @coordinate "compute.llm.chat"

  @type endpoint :: %{
          id: String.t(),
          api_host: String.t(),
          model: String.t(),
          label: String.t()
        }

  @doc """
  Returns the currently discovered LLM endpoints as option maps.

  Each map contains: id, api_host, model, label. Returns an empty list
  if discovery is unavailable.
  """
  @spec list() :: [endpoint()]
  def list do
    query_ads()
    |> Enum.map(&to_endpoint/1)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Subscribe `pid` to `compute.llm.chat` discovery changes.

  On each change llmagent's Discovery sends `pid` a message of the form
  `{event, ad_id, coordinate}` where `event` is one of `:tool_added`,
  `:tool_updated`, `:unregistered`, or `:lease_expired`. The subscriber
  should re-query `list/0` and re-render. Degrades to `:ok` (no
  subscription) if Discovery is unavailable, so a LiveView still mounts.
  """
  @spec subscribe(pid()) :: :ok
  def subscribe(pid) when is_pid(pid) do
    LLMAgent.Tools.Discovery.subscribe(
      LLMAgent.ToolQuery.new(%{coordinate: @coordinate}),
      pid
    )

    :ok
  rescue
    _e in [ArgumentError, UndefinedFunctionError] -> :ok
  end

  @doc """
  The discovery change events a subscriber may receive via `subscribe/1`.
  """
  @spec change_events() :: [atom()]
  def change_events, do: [:tool_added, :tool_updated, :unregistered, :lease_expired]

  # -- Private --

  defp query_ads do
    {:ok, ads} =
      LLMAgent.Tools.Discovery.find_all(
        LLMAgent.ToolQuery.new(%{coordinate: @coordinate})
      )

    ads
  rescue
    # Discovery ETS table absent, unexpected ad shape, or module not loaded
    # — degrade to "no endpoints" rather than crash the LiveView.
    _e in [ArgumentError, MatchError, UndefinedFunctionError] -> []
  end

  defp to_endpoint(%{id: id, binding: {:openai_chat, %{api_host: host} = payload}} = ad) do
    model = payload[:model] || get_in(ad.operational || %{}, [:model_id]) || ""
    %{id: to_string(id), api_host: host, model: model, label: "#{model} @ #{host}"}
  end

  defp to_endpoint(_), do: nil
end
