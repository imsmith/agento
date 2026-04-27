defmodule LlmagentWeb.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      LlmagentWebWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:llmagent_web, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: LlmagentWeb.PubSub},
      LlmagentWebWeb.Discovery.Events,
      LlmagentWeb.EventBusBridge,
      LlmagentWebWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: LlmagentWeb.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    LlmagentWebWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
