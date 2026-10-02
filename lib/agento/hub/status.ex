defmodule Agento.Hub.Status do
  @moduledoc """
  A snapshot of the hub for people to look at: where it is listening, who may
  connect, which performers it can route to right now, and the settings in
  force.

  It is what the Hub view renders. The web UI needs no login, so nothing
  here may be a secret: clients appear by name, never with their token.
  """

  alias Agento.Hub.{Config, Router}
  alias LLMAgent.{ToolAd, ToolQuery}
  alias LLMAgent.Tools.Discovery

  @local_sources ["mdns/_llama._tcp"]

  @type performer :: %{
          id: String.t(),
          host: String.t() | nil,
          model: String.t() | nil,
          address: String.t() | nil,
          context: integer() | nil,
          slots: integer() | nil,
          source: String.t() | nil,
          default: boolean(),
          lease: String.t()
        }

  @type t :: %{
          listening: String.t() | nil,
          busybody_name: String.t(),
          config_path: String.t(),
          default_host: String.t() | nil,
          default_reachable: boolean(),
          retention_days: pos_integer(),
          performer_timeout_s: pos_integer(),
          clients: [%{name: String.t(), reach: String.t()}],
          performers: [performer()]
        }

  @doc "The hub as it is at this moment."
  @spec snapshot() :: t()
  def snapshot do
    config = Config.get()
    performers = performers(config)

    %{
      listening: listening(),
      busybody_name: System.get_env("AGENTO_BUSYBODY_NAME", "agento"),
      config_path: Config.path(),
      default_host: config.default_host,
      default_reachable: Enum.any?(performers, & &1.default),
      retention_days: config.retention_days,
      performer_timeout_s: div(config.performer_timeout_ms, 1000),
      clients:
        for(client <- config.clients, do: %{name: client.name, reach: reach(client.policy)}),
      performers: performers
    }
  end

  # The address the endpoint actually bound, or nil when it is not serving.
  defp listening do
    case AgentoWeb.Endpoint.server_info(:http) do
      {:ok, {ip, port}} -> "#{:inet.ntoa(ip)}:#{port}"
      _ -> nil
    end
  end

  defp reach(%{provenance: %{source: @local_sources}}), do: "local performers only"
  defp reach(_policy), do: "local and cloud performers"

  defp performers(config) do
    {:ok, ads} = Discovery.find_all(ToolQuery.new(%{coordinate: "compute.llm.chat"}))

    ads
    |> Enum.sort_by(& &1.id)
    |> Enum.map(fn %ToolAd{} = ad ->
      %{
        id: ad.id,
        host: Router.host(ad),
        model: binding_value(ad, :model),
        address: binding_value(ad, :api_host),
        context: context(ad),
        slots: slots(ad),
        source: get_in(ad.provenance, [:source]),
        default: is_binary(config.default_host) and Router.on_host?(ad, config.default_host),
        lease: lease(ad.lease)
      }
    end)
  end

  defp binding_value(%ToolAd{binding: {_kind, %{} = payload}}, key), do: Map.get(payload, key)
  defp binding_value(_ad, _key), do: nil

  defp context(%ToolAd{affordance: %{declared: declared}}) when is_list(declared) do
    Enum.find_value(declared, fn
      %{n_ctx: n} when is_integer(n) -> n
      _ -> nil
    end)
  end

  defp context(_ad), do: nil

  defp slots(%ToolAd{operational: %{actions: %{"chat" => %{concurrency: n}}}}) when is_integer(n),
    do: n

  defp slots(_ad), do: nil

  defp lease(:permanent), do: "permanent"

  defp lease({:expires_at, %DateTime{} = at}),
    do: "#{max(DateTime.diff(at, DateTime.utc_now()), 0)} s"

  defp lease(_other), do: "unknown"
end
