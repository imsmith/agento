defmodule Agento.Hub.Router do
  @moduledoc """
  Picks the performer for a turn: which discovered `compute.llm.chat` ad a
  client's request goes to.

  The candidates are the ads the client's policy admits — the same decision
  `LLMAgent.Tool.Dispatcher` will make again when the turn is dispatched, made
  here first so that an ad the client may not use is never chosen, and never
  listed.

  Among candidates the choice is static:

    1. the one serving exactly the model the client asked for;
    2. otherwise the one on the configured default host;
    3. otherwise nothing.

  The router never picks arbitrarily, and nothing here names a model. A host
  serves whatever it serves when the turn arrives; the default is a host.
  Coding clients ask for their own vendor's model names, which no local host
  serves, so in practice rule 2 carries most turns.
  """

  alias Agento.Hub.Config
  alias LLMAgent.{ToolAd, ToolQuery}
  alias LLMAgent.Tool.Policy
  alias LLMAgent.Tools.Discovery

  @coordinate "compute.llm.chat"

  @type model_entry :: %{id: String.t(), ad_id: String.t()}

  @doc "The ad that should serve `requested_model` for `client`."
  @spec route(String.t() | nil, Config.client(), Config.t()) ::
          {:ok, ToolAd.t()} | {:error, :no_performer}
  def route(requested_model, client, %Config{default_host: default_host}) do
    candidates = candidates(client)

    serving = Enum.find(candidates, &(model(&1) == requested_model and requested_model != nil))
    default = default_host && Enum.find(candidates, &on_host?(&1, default_host))

    case serving || default do
      %ToolAd{} = ad -> {:ok, ad}
      _ -> {:error, :no_performer}
    end
  end

  @doc "The models `client` can reach right now, one entry per performer."
  @spec models(Config.client()) :: [model_entry()]
  def models(client) do
    for ad <- candidates(client), do: %{id: model(ad), ad_id: ad.id}
  end

  # Sorted so that the choice between two hosts serving the same model does
  # not depend on registry order.
  defp candidates(client) do
    {:ok, ads} = Discovery.find_all(ToolQuery.new(%{coordinate: @coordinate}))

    ads
    |> Enum.filter(&(Policy.decide(client.policy, &1, :generate, "chat") == :ok))
    |> Enum.sort_by(& &1.id)
  end

  defp model(%ToolAd{binding: {_kind, %{model: model}}}), do: model
  defp model(_ad), do: nil

  @doc """
  Whether `ad` is on `host`: the host is the hostname of its `api_host`, or
  the hostname in an mDNS ad id (`mdns:_llama._tcp:<hostname>:<port>`). Whole
  hostnames only: a name that merely contains the host does not match.
  """
  @spec on_host?(ToolAd.t(), String.t()) :: boolean()
  def on_host?(%ToolAd{id: id, binding: binding}, host) do
    mdns_host(id) == host or api_hostname(binding) == host
  end

  @doc "The name a performer is known by: its mDNS hostname, else the hostname of its `api_host`."
  @spec host(ToolAd.t()) :: String.t() | nil
  def host(%ToolAd{id: id, binding: binding}), do: mdns_host(id) || api_hostname(binding)

  defp mdns_host("mdns:" <> rest) do
    case String.split(rest, ":") do
      [_service, hostname, _port] -> hostname
      _ -> nil
    end
  end

  defp mdns_host(_id), do: nil

  defp api_hostname({_kind, %{api_host: api_host}}) when is_binary(api_host),
    do: URI.parse(api_host).host

  defp api_hostname(_binding), do: nil
end
