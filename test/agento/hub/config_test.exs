defmodule Agento.Hub.ConfigTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Agento.Hub.Config
  alias LLMAgent.Tool.Policy
  alias LLMAgent.ToolAd

  @token_a "token-aaaaaaaaaaaaaaaaaaaaaaaa"
  @token_b "token-bbbbbbbbbbbbbbbbbbbbbbbb"

  setup do
    dir = Path.join(System.tmp_dir!(), "hubcfg_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write(dir, edn, mode \\ 0o600) do
    path = Path.join(dir, "hub.edn")
    File.write!(path, edn)
    File.chmod!(path, mode)
    path
  end

  defp two_clients do
    ~s({:clients [{:name "claude-code" :token "#{@token_a}"} {:name "pi" :token "#{@token_b}"}]
        :default-host "skynet001.local"})
  end

  defp ad(source) do
    ToolAd.new(%{
      id: "x.#{System.unique_integer([:positive])}",
      coordinate: "compute.llm.chat",
      kinds: [:generate],
      binding: {:openai_chat, %{api_host: "http://h:1", model: "m"}},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: true},
      fidelity: :authoritative,
      provenance: %{source: source, produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease: :permanent
    })
  end

  describe "load/1" do
    test "a valid file loads its clients, with defaults for omitted keys", %{dir: dir} do
      assert {:ok, %Config{} = config} = Config.load(write(dir, two_clients()))

      assert Enum.map(config.clients, & &1.name) == ["claude-code", "pi"]
      assert config.default_host == "skynet001.local"
      assert config.retention_days == 30
      assert config.performer_timeout_ms == 900_000
      assert config.data_dir == Path.expand("~/.local/share/agento")
    end

    test "explicit values override the defaults", %{dir: dir} do
      edn = ~s({:clients [] :retention-days 7 :performer-timeout-seconds 60 :data-dir "/tmp/hub-data"})
      assert {:ok, config} = Config.load(write(dir, edn))

      assert config.retention_days == 7
      assert config.performer_timeout_ms == 60_000
      assert config.data_dir == "/tmp/hub-data"
      assert config.default_host == nil
    end

    test "a missing file is a config with no clients", %{dir: dir} do
      assert {:ok, %Config{clients: [], retention_days: 30}} = Config.load(Path.join(dir, "absent.edn"))
    end

    test "every client is pinned to local mDNS performers", %{dir: dir} do
      {:ok, config} = Config.load(write(dir, two_clients()))

      for client <- config.clients do
        assert %Policy{allow: ["compute.llm.chat"], fidelity_min: :authoritative} = client.policy
        assert client.policy.provenance == %{source: ["mdns/_llama._tcp"], signed: false}

        assert :ok = Policy.decide(client.policy, ad("mdns/_llama._tcp"), :generate, "chat")
        assert {:error, :forbidden, :provenance} = Policy.decide(client.policy, ad("hub.config"), :generate, "chat")
      end
    end

    test "a file readable by group or others is refused; owner-only loads", %{dir: dir} do
      for mode <- [0o640, 0o604, 0o660, 0o644] do
        assert {:error, message} = Config.load(write(dir, two_clients(), mode))
        assert message =~ Integer.to_string(mode, 8)
      end

      assert {:ok, _} = Config.load(write(dir, two_clients(), 0o600))
      assert {:ok, _} = Config.load(write(dir, two_clients(), 0o400))
    end

    test "malformed edn is refused", %{dir: dir} do
      assert {:error, message} = Config.load(write(dir, "{:clients ["))
      assert message =~ "edn"

      assert {:error, message} = Config.load(write(dir, "[1 2 3]"))
      assert message =~ "map"
    end

    test "each bad client is refused with a message naming the problem", %{dir: dir} do
      cases = [
        {~s({:clients [{:token "#{@token_a}"}]}), "name"},
        {~s({:clients [{:name "short" :token "tooshort"}]}), "short"},
        {~s({:clients [{:name "nameonly"}]}), "nameonly"},
        {~s({:clients [{:name "a" :token "#{@token_a}"} {:name "b" :token "#{@token_a}"}]}), "token"},
        {~s({:clients [{:name "dup" :token "#{@token_a}"} {:name "dup" :token "#{@token_b}"}]}), "dup"},
        {~s({:clients [{:name "cloudy" :token "#{@token_a}" :cloud true}]}), "cloud"},
        {~s({:clients [{:name "odd" :token "#{@token_a}" :admin true}]}), "admin"},
        {~s({:clients "nope"}), "clients"}
      ]

      for {edn, mention} <- cases do
        assert {:error, message} = Config.load(write(dir, edn)), edn
        assert message =~ mention, "#{inspect(message)} should mention #{mention}"
      end
    end

    test "a client may say :cloud false", %{dir: dir} do
      edn = ~s({:clients [{:name "plain" :token "#{@token_a}" :cloud false}]})
      assert {:ok, %Config{clients: [%{name: "plain"}]}} = Config.load(write(dir, edn))
    end

    test "bad settings are refused with a message naming the key", %{dir: dir} do
      cases = [
        {~s({:retention-days 0}), "retention-days"},
        {~s({:retention-days "thirty"}), "retention-days"},
        {~s({:performer-timeout-seconds -5}), "performer-timeout-seconds"},
        {~s({:default-host 7}), "default-host"},
        {~s({:data-dir 7}), "data-dir"},
        {~s({:listen {:port 1}}), "listen"}
      ]

      for {edn, mention} <- cases do
        assert {:error, message} = Config.load(write(dir, edn)), edn
        assert message =~ mention
      end
    end

    test "a token never appears in an error message", %{dir: dir} do
      edn = ~s({:clients [{:name "a" :token "#{@token_a}"} {:name "b" :token "#{@token_a}"}]})
      assert {:error, message} = Config.load(write(dir, edn))
      refute message =~ @token_a
    end

    test "the shipped example loads", %{dir: dir} do
      example = File.read!(Application.app_dir(:agento, "priv/hub.example.edn"))
      assert {:ok, %Config{clients: [_ | _]}} = Config.load(write(dir, example))
    end
  end

  describe "client_for_token/2" do
    setup %{dir: dir} do
      {:ok, config} = Config.load(write(dir, two_clients()))
      {:ok, config: config}
    end

    test "finds each client by its token", %{config: config} do
      assert {:ok, %{name: "claude-code"}} = Config.client_for_token(config, @token_a)
      assert {:ok, %{name: "pi"}} = Config.client_for_token(config, @token_b)
    end

    test "rejects anything else", %{config: config} do
      for bad <- ["", "nope", String.slice(@token_a, 0, 10), @token_a <> "x", nil] do
        assert :error = Config.client_for_token(config, bad), inspect(bad)
      end
    end
  end

  describe "get/0 and put/1" do
    test "the application booted with a config, and put/1 replaces it" do
      original = Config.get()
      assert %Config{} = original

      replacement = %{original | default_host: "elsewhere.local"}
      Config.put(replacement)
      on_exit(fn -> Config.put(original) end)

      assert Config.get().default_host == "elsewhere.local"
    end
  end
end
