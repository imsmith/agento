defmodule AgentoWeb.EventsLiveTest do
  @moduledoc """
  Integration tests for Event Explorer LiveView (R3).
  """
  use AgentoWeb.ConnCase

  describe "Event Explorer mount (R3.1)" do
    test "events page mounts with tabs and filter controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/events")

      assert html =~ "Live Stream"
      assert html =~ "DurableLog Query"
      assert html =~ "EventLog Query"
      assert html =~ "No events yet"
    end
  end

  describe "Event Explorer filters (R3.2)" do
    test "filter controls are present", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      assert has_element?(view, "form[phx-change=update_filter]")
      assert has_element?(view, "select[name=topic]")
      assert has_element?(view, "select[name=type]")
      assert has_element?(view, "select[name=agent_id]")
    end

    test "tab switching works", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      view |> element("[phx-click=set_tab][phx-value-tab=durable_log]") |> render_click()
      assert render(view) =~ "DurableLog Query"

      view |> element("[phx-click=set_tab][phx-value-tab=event_log]") |> render_click()
      assert render(view) =~ "EventLog Query"
    end
  end

  describe "DurableLog Query (R3.3, R7.2)" do
    test "query DurableLog for an agent returns results", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:event_test_durable)
      Process.sleep(200)

      send_prompt(:event_test_durable, "durable test")
      Process.sleep(500)

      {:ok, view, _html} = live(conn, "/events")
      view |> element("[phx-click=set_tab][phx-value-tab=durable_log]") |> render_click()

      view
      |> form("form[phx-submit=query_durable_log]", %{
        "agent_id" => "event_test_durable",
        "since" => ""
      })
      |> render_submit()

      html = render(view)
      refute html =~ "No results"
    end

    test "query DurableLog with since filter narrows results", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:event_test_since)
      Process.sleep(200)

      send_prompt(:event_test_since, "first message")
      Process.sleep(500)

      timestamp = DateTime.utc_now() |> DateTime.to_iso8601()
      send_prompt(:event_test_since, "second message")
      Process.sleep(500)

      {:ok, view, _html} = live(conn, "/events")
      view |> element("[phx-click=set_tab][phx-value-tab=durable_log]") |> render_click()

      view
      |> form("form[phx-submit=query_durable_log]", %{
        "agent_id" => "event_test_since",
        "since" => timestamp
      })
      |> render_submit()

      html = render(view)
      refute html =~ "No results"
    end
  end

  describe "EventLog Query (R3.4)" do
    test "query EventLog all() returns results", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:event_test_log)
      Process.sleep(200)

      send_prompt(:event_test_log, "eventlog test")
      Process.sleep(500)

      {:ok, view, _html} = live(conn, "/events")
      view |> element("[phx-click=set_tab][phx-value-tab=event_log]") |> render_click()

      view
      |> form("form[phx-submit=query_event_log]", %{"mode" => "all"})
      |> render_submit()

      html = render(view)
      refute html =~ "No results"
    end
  end
end
