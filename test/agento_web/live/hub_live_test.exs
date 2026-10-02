defmodule AgentoWeb.HubLiveTest do
  @moduledoc false

  use AgentoWeb.ConnCase, async: false

  import AgentoWeb.HubCase

  alias Agento.Hub.TurnLog

  setup do
    reset_registry()
    install_config(default_host: "big.local")
    :ok
  end

  defp turn(overrides) do
    Map.merge(
      %{
        at: DateTime.utc_now() |> DateTime.to_iso8601(),
        client: "test-client",
        wire: "anthropic",
        requested_model: "model-#{System.unique_integer([:positive])}",
        ad_id: "mdns:_llama._tcp:big.local:8080",
        performer_model: "big.gguf",
        outcome: "ok",
        stop_reason: "end_turn",
        input_tokens: 18_256,
        output_tokens: 42,
        duration_ms: 107_169,
        error: nil,
        request_body: "the-prompt-must-not-be-shown",
        response_body: "the-reply-must-not-be-shown"
      },
      overrides
    )
  end

  test "the hub page mounts and is in the navigation", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/hub")
    assert html =~ "Private LLM hub"

    {:ok, _view, tools_html} = live(conn, "/tools")
    assert tools_html =~ ~s(href="/hub")
  end

  test "shows clients by name and never a token", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/hub")

    assert html =~ "test-client"
    assert html =~ "local performers only"
    refute html =~ token()
  end

  test "shows the performers and marks the default", %{conn: conn} do
    register(host: "big.local", model: "big.gguf")
    register(host: "small.local", model: "small.gguf")

    {:ok, view, html} = live(conn, "/hub")

    assert html =~ "big.gguf"
    assert html =~ "small.gguf"
    assert view |> element("#performer-big-local", "default") |> has_element?()
    refute view |> element("#performer-small-local", "default") |> has_element?()
  end

  test "says so when there are no performers or no clients", %{conn: conn} do
    Agento.Hub.Config.put(%{Agento.Hub.Config.get() | clients: []})
    {:ok, _view, html} = live(conn, "/hub")

    assert html =~ "No performers are advertising"
    assert html =~ "No clients are configured"
  end

  test "warns when the default host is not advertising", %{conn: conn} do
    register(host: "small.local", model: "small.gguf")
    {:ok, _view, html} = live(conn, "/hub")

    assert html =~ "big.local"
    assert html =~ "is not advertising"
  end

  test "picks up a performer that appears after the page loaded", %{conn: conn} do
    {:ok, view, html} = live(conn, "/hub")
    refute html =~ "late.gguf"

    register(host: "late.local", model: "late.gguf")
    send(view.pid, :refresh)

    assert render(view) =~ "late.gguf"
  end

  test "shows recent turns from the log, without either body", %{conn: conn} do
    recorded = turn(%{})
    TurnLog.record(recorded)
    failed = turn(%{outcome: "error", error: "performer answered 500: boom", stop_reason: nil})
    TurnLog.record(failed)

    {:ok, _view, html} = live(conn, "/hub")

    assert html =~ recorded.requested_model
    assert html =~ "18256"
    assert html =~ "107.2 s"
    assert html =~ failed.requested_model
    assert html =~ "performer answered 500: boom"

    refute html =~ "the-prompt-must-not-be-shown"
    refute html =~ "the-reply-must-not-be-shown"
  end

  # The log is in the order turns finished; the page is in the order they began.
  test "lists turns newest first by when they started", %{conn: conn} do
    stamp = fn seconds_ago ->
      DateTime.utc_now() |> DateTime.add(-seconds_ago) |> DateTime.to_iso8601()
    end

    tag = System.unique_integer([:positive])

    for {name, ago} <- [{"middle", 20}, {"newest", 10}, {"oldest", 30}],
        do: TurnLog.record(turn(%{at: stamp.(ago), requested_model: "#{name}-#{tag}"}))

    {:ok, _view, html} = live(conn, "/hub")

    [newest, middle, oldest] =
      for name <- ~w(newest middle oldest), do: :binary.match(html, "#{name}-#{tag}")

    assert newest < middle and middle < oldest
  end

  test "a turn that finishes while the page is open appears at the top", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/hub")
    summary = turn(%{}) |> Map.drop([:request_body, :response_body])

    LLMAgent.Events.emit(:request, "hub.request", summary, __MODULE__)

    assert eventually(fn -> render(view) =~ summary.requested_model end)
    assert view |> element("#turns tr:first-child", summary.requested_model) |> has_element?()
  end

  test "tells the operator how to point a client at it", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/hub")

    assert html =~ "hub-url.tcl"
    assert html =~ "ANTHROPIC_BASE_URL"
  end

  defp eventually(fun, tries \\ 20) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(25) && eventually(fun, tries - 1)
    end
  end
end
