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

  @wire_fixtures Path.expand("../../../llmagent/test/fixtures/wire", __DIR__)

  @doc """
  Raw bytes of a fixture recorded in llmagent's `test/fixtures/wire/`: streams
  from the live llama-servers and requests captured from a real Claude Code.
  """
  @spec fixture(String.t()) :: binary()
  def fixture(name), do: File.read!(Path.join(@wire_fixtures, name))

  @doc "Split an SSE body into `{event, decoded_json}` pairs."
  @spec sse_frames(binary()) :: [{String.t(), map()}]
  def sse_frames(body) do
    {frames, _state} = LLMAgent.Codec.SSE.feed(LLMAgent.Codec.SSE.new(), body)
    Enum.map(frames, &{&1.event, Jason.decode!(&1.data)})
  end

  @doc """
  A performer on a bare socket, for the cases Bypass cannot play: it accepts
  one request, optionally sends `head` as the start of a chunked event
  stream, then never finishes. The task's result is how its connection
  ended (`:closed` when the caller hung up).
  """
  @spec stalling_performer(binary() | nil) :: {String.t(), Task.t()}
  def stalling_performer(head \\ nil) do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(listen)

    task =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen, 5_000)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 5_000)

        if head do
          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\ntransfer-encoding: chunked\r\n\r\n",
              Integer.to_string(byte_size(head), 16),
              "\r\n",
              head,
              "\r\n"
            ])
        end

        drain(socket)
      end)

    {"http://localhost:#{port}", task}
  end

  defp drain(socket) do
    case :gen_tcp.recv(socket, 0, 4_000) do
      {:ok, _more} -> drain(socket)
      {:error, reason} -> reason
    end
  end

  @doc "Register an ad built by `llama_ad/1`."
  @spec register(keyword()) :: ToolAd.t()
  def register(opts \\ []) do
    ad = llama_ad(opts)
    :ok = Discovery.register(ad)
    ad
  end
end
