defmodule AgentoWeb.HubCase do
  @moduledoc """
  Shared setup for hub tests: a clean tool registry, ads shaped like the ones
  llmagent's mDNS shim registers, and a hub configuration with one client.
  """

  alias Agento.Hub.Config
  alias LLMAgent.ToolAd
  alias LLMAgent.Tools.Discovery

  @token "test-token-0123456789abcdef"

  @doc "The bearer token of the client `install_config/1` creates."
  @spec token() :: String.t()
  def token, do: @token

  @doc "Empty the tool registry."
  @spec reset_registry() :: :ok
  def reset_registry do
    Discovery.reset!()
    LLMAgent.Tool.Bindings.init_registry()
    LLMAgent.Tool.Kinds.init_registry()
    :ok
  end

  @doc """
  Install a hub config with one client, `test-client`, restoring the previous
  config when the test ends. `overrides` replaces struct fields.
  """
  @spec install_config(keyword()) :: Config.t()
  def install_config(overrides \\ []) do
    previous = Config.get()
    {:ok, base} = Config.load("/nonexistent/hub.edn")
    {:ok, with_client} = client_config()

    config = struct!(%{base | clients: with_client.clients}, overrides)
    Config.put(config)
    ExUnit.Callbacks.on_exit(fn -> Config.put(previous) end)
    config
  end

  defp client_config do
    dir = Path.join(System.tmp_dir!(), "hubcase_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "hub.edn")
    File.write!(path, ~s({:clients [{:name "test-client" :token "#{@token}"}]}))
    File.chmod!(path, 0o600)
    result = Config.load(path)
    File.rm_rf!(dir)
    result
  end

  @doc """
  An ad as `priv/discovery/avahi-llama.tcl` builds it. Options: `:host`
  (mDNS hostname), `:api_host`, `:model`, `:source` (provenance), `:id`.
  """
  @spec llama_ad(keyword()) :: ToolAd.t()
  def llama_ad(opts \\ []) do
    host = Keyword.get(opts, :host, "skynet-test.local")
    model = Keyword.get(opts, :model, "test-model.gguf")

    ToolAd.new(%{
      id: Keyword.get(opts, :id, "mdns:_llama._tcp:#{host}:8080"),
      coordinate: "compute.llm.chat",
      kinds: [:generate],
      binding: {:openai_chat, %{api_host: Keyword.get(opts, :api_host, "http://10.0.0.1:8080"), model: model}},
      operational: %{actions: %{"chat" => %{concurrency: 4}}, model_id: model},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [%{intent: :long_context, n_ctx: 32_768}], learned: [], open: true},
      fidelity: :authoritative,
      provenance: %{
        source: Keyword.get(opts, :source, "mdns/_llama._tcp"),
        produced_at: DateTime.utc_now(),
        based_on: [],
        signature: nil
      },
      lease: :permanent
    })
  end

  @doc "Register an ad built by `llama_ad/1`."
  @spec register(keyword()) :: ToolAd.t()
  def register(opts \\ []) do
    ad = llama_ad(opts)
    :ok = Discovery.register(ad)
    ad
  end
end
