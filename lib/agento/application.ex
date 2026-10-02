defmodule Agento.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    load_hub_config!()

    children = [
      AgentoWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:agento, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Agento.PubSub},
      AgentoWeb.Discovery.Events,
      Agento.EventBusBridge,
      AgentoWeb.Harness.Registry,
      AgentoWeb.Endpoint
    ] ++ busybody_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Agento.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # A hub configuration that cannot be trusted stops the node: serving with
  # the wrong clients, or none of the intended limits, is worse than not
  # serving.
  defp load_hub_config! do
    case Agento.Hub.Config.load(Agento.Hub.Config.path()) do
      {:ok, config} -> Agento.Hub.Config.put(config)
      {:error, message} -> raise "agento hub configuration: #{message}"
    end
  end

  defp busybody_children do
    if Code.ensure_loaded?(Busybody.Client) do
      [{Busybody.Client, name: "agento", endpoint: AgentoWeb.Endpoint}]
    else
      []
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    AgentoWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
