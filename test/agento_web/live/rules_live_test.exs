defmodule AgentoWeb.RulesLiveTest do
  use AgentoWeb.ConnCase, async: false

  alias Agento.Rules

  @id "live-test.rule"

  setup do
    on_exit(fn -> Rules.unload(@id) end)
    :ok
  end

  test "mounts, is in the navigation, and names the directory", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/rules")
    assert html =~ "Rules"
    assert html =~ Rules.dir()

    {:ok, _view, hub_html} = live(conn, "/hub")
    assert hub_html =~ ~s(href="/rules")
  end

  test "deploys a policy from the form and shows its rule, state and trace", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/rules")

    html =
      view
      |> form("form[phx-submit=load]", %{
        "policy" => @id,
        "source" => ~s|rule count { when LIVE_TEST_TICK { log $seen\n set seen = "yes" } }|
      })
      |> render_submit()

    assert html =~ "#{@id} deployed"
    assert html =~ "count"
    assert has_element?(view, "#policy-live-test-rule")

    LLMAgent.Events.emit(:tick, "live.test.tick", %{}, :test)
    Process.sleep(100)
    send(view.pid, :refresh)
    html = render(view)
    assert html =~ "LIVE_TEST_TICK"
    assert html =~ ~s|$seen = &quot;yes&quot;|
  end

  test "a source that does not parse is reported and nothing changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/rules")

    html =
      view
      |> form("form[phx-submit=load]", %{"policy" => @id, "source" => "rule broken { when"})
      |> render_submit()

    assert html =~ "#{@id} not deployed"
    refute has_element?(view, "#policy-live-test-rule")
  end

  test "explains an event", %{conn: conn} do
    :ok = Rules.load(@id, ~s|rule greet { context "hub" { when HUB_REQUEST { log "hi" } } }|)
    {:ok, view, _html} = live(conn, "/rules")

    html =
      view
      |> form("form[phx-submit=explain]", %{"event" => "hub_request", "path" => "hub.request"})
      |> render_submit()

    assert html =~ "greet"
    assert html =~ "fires"

    html =
      view
      |> form("form[phx-submit=explain]", %{"event" => "HUB_REQUEST", "path" => "office"})
      |> render_submit()

    assert html =~ "context does not admit it"
  end

  test "unloads a policy", %{conn: conn} do
    :ok = Rules.load(@id, ~s|rule a { when EV { log "a" } }|)
    {:ok, view, _html} = live(conn, "/rules")
    assert has_element?(view, "#policy-live-test-rule")

    html = view |> element("#policy-live-test-rule button[phx-click=unload]") |> render_click()
    assert html =~ "#{@id} unloaded"
    refute has_element?(view, "#policy-live-test-rule")
  end
end
