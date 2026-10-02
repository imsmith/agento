defmodule Agento.Hub.Router do
  @moduledoc """
  Picks the performer for a turn: which discovered `compute.llm.chat` ad a
  client's request goes to.

  The candidates are the ads the client's policy admits — the same decision
  `LLMAgent.Tool.Dispatcher` will make again when the turn is dispatched, made
  here first so that an ad the client may not use is never chosen, and never
  listed.

  The rules decide first. Every turn is dispatched into the `:agento`
  runtime as `HUB_ROUTE` (context path `hub.route`) with the client, the
  requested model, the host serving exactly that model, the default host
  if it is advertising, and the candidate hosts and models as facts. A rule
  answers with `[HUB::route :host "x"]` (or `:model`, or `:ad_id`), or
  `[HUB::refuse :because "..."]`; the first answer wins. See
  `priv/rules/hub-routing.rule`, which says the built-in routing in rules.

  When no rule answers — none loaded, none matched, or the runtime did not
  answer in time — the choice is the built-in one:

    1. the candidate serving exactly the model the client asked for;
    2. otherwise the one on the configured default host;
    3. otherwise nothing.

  The router never picks arbitrarily, and nothing here names a model. A host
  serves whatever it serves when the turn arrives; the default is a host.
  Coding clients ask for their own vendor's model names, which no local host
  serves, so in practice rule 2 carries most turns.

  A rule's answer is held to the same candidates: a host or model the
  client's policy does not admit cannot be routed to by naming it.
  """

  require Logger

  alias Agento.Hub.Config
  alias LLMAgent.{ToolAd, ToolQuery}
  alias LLMAgent.Tool.Policy
  alias LLMAgent.Tools.Discovery

  @coordinate "compute.llm.chat"

  @type model_entry :: %{id: String.t(), ad_id: String.t()}

  @doc "The ad that should serve `requested_model` for `client`."
  @spec route(String.t() | nil, Config.client(), Config.t()) ::
          {:ok, ToolAd.t()} | {:error, :no_performer | {:refused, String.t()}}
  def route(requested_model, client, %Config{default_host: default_host}) do
    candidates = candidates(client)

    serving = Enum.find(candidates, &(model(&1) == requested_model and requested_model != nil))
    default = default_host && Enum.find(candidates, &on_host?(&1, default_host))

    facts = %{
      "client" => client.name,
      "requested_model" => requested_model || "",
      "serving_host" => (serving && host(serving)) || "",
      "default_host" => (default && host(default)) || "",
      "hosts" => candidates |> Enum.map(&host/1) |> Enum.reject(&is_nil/1) |> Enum.uniq(),
      "models" => candidates |> Enum.map(&model/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    }

    case ask_rules(facts, candidates) do
      {:ok, %ToolAd{} = ad} ->
        {:ok, ad}

      {:refused, reason} ->
        {:error, {:refused, reason}}

      :undecided ->
        case serving || default do
          %ToolAd{} = ad -> {:ok, ad}
          _ -> {:error, :no_performer}
        end
    end
  end

  # The first answer a rule gave, applied to the candidates. An answer
  # naming nothing among them is ignored, with a line in the log: a rule
  # cannot widen what the client may reach, only choose within it.
  defp ask_rules(facts, candidates) do
    context = %{context_path: "hub.route", context_data: facts}

    case Anemos.Runtime.dispatch(Agento.Rules.runtime(), "HUB_ROUTE", context, timeout: 1_000) do
      {:ok, results} -> Enum.find_value(results, :undecided, &answer(&1, candidates))
    end
  catch
    :exit, reason ->
      Logger.warning("[hub] the rules did not answer HUB_ROUTE: #{inspect(elem_or(reason))}")
      :undecided
  end

  defp answer(%{refuse: reason}, _candidates) when is_binary(reason), do: {:refused, reason}

  defp answer(%{route: choice}, candidates) do
    found =
      case choice do
        %{"host" => h} -> Enum.find(candidates, &on_host?(&1, h))
        %{"model" => m} -> Enum.find(candidates, &(model(&1) == m))
        %{"ad_id" => id} -> Enum.find(candidates, &(&1.id == id))
        _ -> nil
      end

    if found do
      {:ok, found}
    else
      Logger.warning("[hub] a rule routed to #{inspect(choice)}, which the client cannot reach")
      nil
    end
  end

  defp answer(_other, _candidates), do: nil

  defp elem_or({tag, _}) when is_atom(tag), do: tag
  defp elem_or(other), do: other

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
