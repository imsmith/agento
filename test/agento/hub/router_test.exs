defmodule Agento.Hub.RouterTest do
  @moduledoc false

  use ExUnit.Case, async: false

  import AgentoWeb.HubCase

  alias Agento.Hub.Router
  alias LLMAgent.Tools.Discovery

  setup do
    reset_registry()
    config = install_config(default_host: "big.local")
    {:ok, config: config, client: hd(config.clients)}
  end

  test "a requested model that a host advertises routes to that host", ctx do
    register(host: "big.local", model: "big.gguf")
    small = register(host: "small.local", model: "small.gguf")

    assert {:ok, ad} = Router.route("small.gguf", ctx.client, ctx.config)
    assert ad.id == small.id
  end

  test "a model nobody serves routes to the default host, matched by mDNS hostname", ctx do
    big = register(host: "big.local", model: "big.gguf")
    register(host: "small.local", model: "small.gguf")

    assert {:ok, ad} = Router.route("claude-sonnet-5-5", ctx.client, ctx.config)
    assert ad.id == big.id
  end

  test "the default host is matched by api_host when the ad id is not an mDNS id", ctx do
    plain = register(id: "manual.1", api_host: "http://big.local:9000", model: "x.gguf")

    assert {:ok, ad} = Router.route("unknown", ctx.client, ctx.config)
    assert ad.id == plain.id
  end

  test "a hostname that merely contains the default host does not match", ctx do
    register(host: "notbig.local", model: "x.gguf")
    register(id: "manual.2", api_host: "http://big.local.evil.example:9000", model: "y.gguf")

    assert {:error, :no_performer} = Router.route("unknown", ctx.client, ctx.config)
  end

  test "with no default host, a model nobody serves has no performer", ctx do
    register(host: "big.local", model: "big.gguf")
    config = %{ctx.config | default_host: nil}

    assert {:error, :no_performer} = Router.route("unknown", ctx.client, config)
    assert {:ok, _} = Router.route("big.gguf", ctx.client, config)
  end

  test "a default host that is not advertising has no performer", ctx do
    register(host: "small.local", model: "small.gguf")
    assert {:error, :no_performer} = Router.route("unknown", ctx.client, ctx.config)
  end

  test "an ad the client's policy does not admit is never routed to or listed", ctx do
    register(
      id: "cloud.1",
      api_host: "http://big.local:1",
      model: "paid.gguf",
      source: "hub.config"
    )

    assert {:error, :no_performer} = Router.route("paid.gguf", ctx.client, ctx.config)
    assert {:error, :no_performer} = Router.route("unknown", ctx.client, ctx.config)
    assert Router.models(ctx.client) == []
  end

  test "a host that changes its model is listed and routed by the new model only", ctx do
    register(host: "big.local", model: "old.gguf")
    register(host: "small.local", model: "small.gguf")
    :ok = Discovery.update(llama_ad(host: "big.local", model: "new.gguf"))

    assert Enum.map(Router.models(ctx.client), & &1.id) == ["new.gguf", "small.gguf"]

    assert {:ok, %{id: "mdns:_llama._tcp:big.local:8080"}} =
             Router.route("new.gguf", ctx.client, ctx.config)

    # The old name is now just an unknown model: it falls to the default host.
    assert {:ok, ad} = Router.route("old.gguf", ctx.client, ctx.config)
    assert {:openai_chat, %{model: "new.gguf"}} = ad.binding
  end

  test "models/1 lists each admitted performer's model and ad id", ctx do
    big = register(host: "big.local", model: "big.gguf")
    small = register(host: "small.local", model: "small.gguf")

    assert Router.models(ctx.client) == [
             %{id: "big.gguf", ad_id: big.id},
             %{id: "small.gguf", ad_id: small.id}
           ]
  end

  test "an empty registry has no performer and no models", ctx do
    assert {:error, :no_performer} = Router.route("anything", ctx.client, ctx.config)
    assert Router.models(ctx.client) == []
  end

  test "a missing model name falls to the default host", ctx do
    big = register(host: "big.local", model: "big.gguf")
    assert {:ok, %{id: id}} = Router.route(nil, ctx.client, ctx.config)
    assert id == big.id
  end
end

defmodule Agento.Hub.RouterRulesTest do
  @moduledoc "Routing decided by rules first, the built-in choice after."

  use ExUnit.Case, async: false

  import AgentoWeb.HubCase

  alias Agento.{Hub.Router, Rules}

  @policy "router-rules-test.rule"

  setup do
    reset_registry()
    config = install_config(default_host: "big.local")
    big = register(host: "big.local", model: "big.gguf")
    small = register(host: "small.local", model: "small.gguf")
    on_exit(fn -> Rules.unload(@policy) end)
    {:ok, config: config, client: hd(config.clients), big: big, small: small}
  end

  test "a rule routes by host, and sees the facts", ctx do
    :ok =
      Rules.load(@policy, """
      rule small-for-pi {
        context "hub" {
          when HUB_ROUTE {
            if ?client == "test-client" { [HUB::route :host "small.local"] }
          }
        }
      }
      """)

    assert {:ok, %{id: id}} = Router.route("whatever", ctx.client, ctx.config)
    assert id == ctx.small.id
  end

  test "a rule routes by model, and refuses", ctx do
    :ok =
      Rules.load(@policy, """
      rule by-model {
        context "hub" {
          when HUB_ROUTE {
            if ?requested_model == "big.gguf" { [HUB::refuse :because "big is resting"] }
            if ?requested_model != "big.gguf" { [HUB::route :model "small.gguf"] }
          }
        }
      }
      """)

    assert {:error, {:refused, "big is resting"}} =
             Router.route("big.gguf", ctx.client, ctx.config)

    assert {:ok, %{id: id}} = Router.route("other", ctx.client, ctx.config)
    assert id == ctx.small.id
  end

  test "a rule cannot route to a host the client cannot reach; the built-in choice stands", ctx do
    :ok =
      Rules.load(@policy, """
      rule elsewhere { context "hub" { when HUB_ROUTE { [HUB::route :host "cloud.example"] } } }
      """)

    assert {:ok, %{id: id}} = Router.route("small.gguf", ctx.client, ctx.config)
    assert id == ctx.small.id
  end

  test "the shipped routing rule says the built-in routing", ctx do
    :ok = Rules.load(@policy, File.read!("priv/rules/hub-routing.rule"))

    assert {:ok, %{id: id}} = Router.route("small.gguf", ctx.client, ctx.config)
    assert id == ctx.small.id

    assert {:ok, %{id: id}} = Router.route("claude-opus-5-5", ctx.client, ctx.config)
    assert id == ctx.big.id

    :ok = LLMAgent.Tools.Discovery.unregister(ctx.big.id)
    assert {:error, :no_performer} = Router.route("claude-opus-5-5", ctx.client, ctx.config)
  end
end
