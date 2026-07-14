defmodule AgentoWeb.Discovery.EndpointsTest do
  @moduledoc """
  Endpoints projects discovered `compute.llm.chat` ads into option maps for
  the new-agent dropdown. It must produce URLs that are actually dialable:
  IPv6 literals bracketed, and unroutable IPv6 link-local addresses dropped.
  """
  use ExUnit.Case, async: false

  alias AgentoWeb.Discovery.Endpoints
  alias LLMAgent.{ToolAd, Tools.Discovery}

  defp register_llm_ad(host, model) do
    ad =
      ToolAd.new(%{
        id: "endpoints-test:" <> Integer.to_string(System.unique_integer([:positive])),
        coordinate: "compute.llm.chat",
        kinds: [:generate],
        binding: {:openai_chat, %{api_host: host, model: model}},
        operational: %{actions: %{}},
        constraint: %{idempotency: %{}, blast_radius: %{}},
        affordance: %{declared: [], learned: [], open: false},
        fidelity: :authoritative,
        provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
        lease: :permanent
      })

    :ok = Discovery.register(ad)
    ad.id
  end

  defp endpoint_for(model), do: Enum.find(Endpoints.list(), &(&1.model == model))

  test "IPv4 host passes through unchanged" do
    model = "ipv4-#{System.unique_integer([:positive])}.gguf"
    register_llm_ad("http://10.10.1.226:8080", model)

    assert %{api_host: "http://10.10.1.226:8080"} = endpoint_for(model)
  end

  test "global IPv6 host is bracketed so the URL is valid" do
    model = "ipv6-#{System.unique_integer([:positive])}.gguf"
    register_llm_ad("http://2001:db8::1:8080", model)

    assert %{api_host: "http://[2001:db8::1]:8080"} = endpoint_for(model)
  end

  test "IPv6 link-local host is dropped (unroutable without a zone id)" do
    model = "linklocal-#{System.unique_integer([:positive])}.gguf"
    register_llm_ad("http://fe80::d15:3902:1f24:c596:8080", model)

    assert endpoint_for(model) == nil
  end
end
