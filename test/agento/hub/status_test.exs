defmodule Agento.Hub.StatusTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import AgentoWeb.HubCase

  alias Agento.Hub.Status

  setup do
    reset_registry()
    {:ok, config: install_config(default_host: "big.local")}
  end

  test "lists clients by name and never carries a token" do
    snapshot = Status.snapshot()

    assert [%{name: "test-client", reach: "local performers only"}] = snapshot.clients
    refute inspect(snapshot, limit: :infinity, printable_limit: :infinity) =~ token()
  end

  test "lists performers with what they advertise, the default one marked" do
    register(host: "big.local", model: "big.gguf", api_host: "http://10.0.0.1:8080")
    register(host: "small.local", model: "small.gguf", api_host: "http://10.0.0.2:8080")

    assert [big, small] = Status.snapshot().performers

    assert %{host: "big.local", model: "big.gguf", address: "http://10.0.0.1:8080", default: true} =
             big

    assert %{host: "small.local", model: "small.gguf", default: false} = small
    assert big.context == 32_768
    assert big.slots == 4
    assert big.source == "mdns/_llama._tcp"
    assert big.lease == "permanent"
  end

  test "a performer with a lease shows the seconds it has left" do
    ad = llama_ad(host: "big.local", model: "big.gguf")

    :ok =
      LLMAgent.Tools.Discovery.register(%{
        ad
        | lease: {:expires_at, DateTime.add(DateTime.utc_now(), 45)}
      })

    assert [%{lease: lease}] = Status.snapshot().performers
    assert lease =~ ~r/^\d+ s$/
  end

  test "with no performers the list is empty and no default is reachable" do
    snapshot = Status.snapshot()
    assert snapshot.performers == []
    assert snapshot.default_host == "big.local"
    assert snapshot.default_reachable == false
  end

  test "says whether the default host is reachable" do
    register(host: "big.local", model: "big.gguf")
    assert Status.snapshot().default_reachable == true
  end

  test "reports the settings in force", %{config: config} do
    snapshot = Status.snapshot()

    assert snapshot.retention_days == config.retention_days
    assert snapshot.performer_timeout_s == div(config.performer_timeout_ms, 1000)
    assert snapshot.config_path == Agento.Hub.Config.path()
    assert is_binary(snapshot.busybody_name)
    # The endpoint does not serve in tests.
    assert snapshot.listening == nil
  end
end
