defmodule AgentoWeb.RulesLiveTest do
  use AgentoWeb.ConnCase, async: false

  import AgentoWeb.HubCase

  alias Agento.Rules

  @id "live-test.rule"

  setup do
    install_config(rules_ui_deploy: true)
    on_exit(fn -> Rules.unload(@id) end)
    :ok
  end

  test "with ui-deploy off, the form is gone and the events are refused", %{conn: conn} do
    install_config(rules_ui_deploy: false)
    :ok = Rules.load(@id, ~s|rule a { when EV { log "a" } }|)
    {:ok, view, html} = live(conn, "/rules")

    assert html =~ "Deploying from here is off"
    refute has_element?(view, "form[phx-submit=load]")
    refute has_element?(view, "button[phx-click=unload]")

    html =
      render_submit(view, "load", %{
        "policy" => "sneak.rule",
        "source" => "rule s { when EV { log 1 } }"
      })

    assert html =~ "deploying from the UI is off"
    refute Enum.any?(Rules.snapshot().policies, &(&1.id == "sneak.rule"))

    html = render_click(view, "unload", %{"id" => @id})
    assert html =~ "not unloaded"
    assert Enum.any?(Rules.snapshot().policies, &(&1.id == @id))
  end

  test "a forged hub.request from a rule does not reach the Hub view", %{conn: conn} do
    :ok =
      Rules.load(
        @id,
        ~s|rule forge { when FORGE_TEST { emit [EVENT::forged :client "evil"] to channel(hub.request) } }|
      )

    {:ok, hub, _} = live(conn, "/hub")
    LLMAgent.Events.emit(:x, "forge.test", %{}, :test)
    Process.sleep(200)

    assert Process.alive?(hub.pid)
    refute render(hub) =~ "evil"
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
    assert has_element?(view, "[id^=policy-live-test-rule]")

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
    refute has_element?(view, "[id^=policy-live-test-rule]")
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
    assert has_element?(view, "[id^=policy-live-test-rule]")

    html =
      view |> element("[id^=policy-live-test-rule] button[phx-click=unload]") |> render_click()

    assert html =~ "#{@id} unloaded"
    refute has_element?(view, "[id^=policy-live-test-rule]")
  end
end
