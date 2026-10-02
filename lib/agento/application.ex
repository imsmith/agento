defmodule Agento.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    load_hub_config!()

    children =
      [
        AgentoWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:agento, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Agento.PubSub},
        AgentoWeb.Discovery.Events,
        Agento.EventBusBridge,
        AgentoWeb.Harness.Registry,
        # The rules runtime and its attachment to the substrate, in this
        # order: the attachment binds into the runtime at start.
        Agento.Rules.runtime_spec(),
        Agento.Rules.attachment_spec(),
        hub_turn_log(),
        AgentoWeb.Endpoint
      ] ++ busybody_children()

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Agento.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp hub_turn_log do
    config = Agento.Hub.Config.get()

    {Agento.Hub.TurnLog,
     data_dir: Application.get_env(:agento, :hub_data_dir) || config.data_dir,
     retention_days: config.retention_days}
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
      [{Busybody.Client, busybody_options()}]
    else
      []
    end
  end

  # Agento has no fixed address: the endpoint takes a free port and busybody
  # is told where it ended up. AGENTO_BUSYBODY_NAME is the name it registers
  # under; BUSYBODY_URL is where busybody is, when not on this machine.
  defp busybody_options do
    [name: System.get_env("AGENTO_BUSYBODY_NAME", "agento"), endpoint: AgentoWeb.Endpoint] ++
      case System.get_env("BUSYBODY_URL") do
        nil -> []
        url -> [registry_url: url]
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
