defmodule AgentoWeb.EndpointDiscoveryRefreshTest do
  @moduledoc """
  The new-agent endpoint dropdown must reflect LLM servers discovered
  *after* the page has mounted. llmagent's Tools.Discovery notifies
  subscribers when a `compute.llm.chat` ad appears; the ChatLive dropdown
  must subscribe and re-render, not snapshot once at mount.

  Integration test against the live Discovery registry with a fake ad as
  the discovery source.
  """
  use AgentoWeb.ConnCase

  alias LLMAgent.{ToolAd, Tools.Discovery}

  # A fake compute.llm.chat ad shaped like the mDNS adapter's output.
  defp fake_llm_ad(host, model) do
    ToolAd.new(%{
      id: "test-endpoint:" <> Integer.to_string(System.unique_integer([:positive])),
      coordinate: "compute.llm.chat",
      kinds: [:compute],
      binding: {:openai_chat, %{api_host: host, model: model}},
      operational: %{actions: %{}},
      constraint: %{idempotency: %{}, blast_radius: %{}},
      affordance: %{declared: [], learned: [], open: false},
      fidelity: :authoritative,
      provenance: %{source: "test", produced_at: DateTime.utc_now(), based_on: [], signature: nil},
      lease: :permanent
    })
  end

  test "endpoint discovered after mount appears in the new-agent dropdown", %{conn: conn} do
    host = "http://10.10.1.250:9999"
    model = "late-arriving-model-#{System.unique_integer([:positive])}.gguf"

    {:ok, view, _html} = live(conn, "/chat")
    view |> element("button[phx-click=toggle_new_agent_form]") |> render_click()

    # Not present before the ad is registered.
    refute render(view) =~ model

    # A new llama server is discovered while the page is open.
    :ok = Discovery.register(fake_llm_ad(host, model))

    # The dropdown must now include it.
    assert render(view) =~ model
  end
end
