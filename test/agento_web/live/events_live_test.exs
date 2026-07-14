defmodule AgentoWeb.EventsLiveTest do
  @moduledoc """
  Integration tests for Event Explorer LiveView (R3).
  """
  use AgentoWeb.ConnCase

  alias Comn.Events.EventStruct

  # Builds a live-stream message shaped like the EventBusBridge PubSub payload.
  defp stream_event(topic, type, data, timestamp) do
    {topic, %EventStruct{topic: topic, type: type, data: data, source: :test, timestamp: timestamp}}
  end

  # Finds the phx-value-index of the stream row whose timestamp cell matches ts.
  defp row_index_for(html, ts) do
    [_, idx] = Regex.run(~r/phx-value-index="(\d+)">\s*#{Regex.escape(ts)}/, html)
    idx
  end

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

  describe "Auto-scroll hook + collapsible payload (R3.1)" do
    test "event-stream div carries the AutoScroll hook and auto_scroll state", %{conn: conn} do
      {:ok, view, html} = live(conn, "/events")

      assert html =~ ~s(phx-hook="AutoScroll")
      # data attribute must reflect the current @auto_scroll assign (true by default)
      assert html =~ ~s(id="event-stream")
      assert has_element?(view, "#event-stream[data-auto-scroll=true]")

      view |> element("[phx-click=toggle_auto_scroll]") |> render_click()
      assert has_element?(view, "#event-stream[data-auto-scroll=false]")
    end

    test "a stream row can expand and collapse its data payload", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      # Use a unique past timestamp so we can locate this event's row index
      # regardless of unrelated web.* events that arrive in the live stream.
      marker_ts = "2026-07-14T12:00:00Z"
      send(view.pid, stream_event("agent.message", :message, %{secret_marker: "expand-me-123"}, marker_ts))
      # Let any in-flight web.mount from connect settle so the row index is stable.
      Process.sleep(150)
      html = render(view)

      # collapsed: payload not shown, but a toggle control exists
      refute html =~ "expand-me-123"
      assert has_element?(view, "[phx-click=toggle_row]")

      # Expand: use render_click's return value, which reflects state at the
      # click (before any async web.event from this interaction shifts indices).
      idx = row_index_for(html, marker_ts)
      expanded = view |> element("[phx-click=toggle_row][phx-value-index='#{idx}']") |> render_click()
      assert expanded =~ "expand-me-123"

      # Collapse: recompute the index against the just-rendered DOM.
      idx = row_index_for(expanded, marker_ts)
      collapsed = view |> element("[phx-click=toggle_row][phx-value-index='#{idx}']") |> render_click()
      refute collapsed =~ "expand-me-123"
    end
  end

  describe "Time-range filter (R3.2)" do
    test "filter form exposes datetime-local from/to inputs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      assert has_element?(view, "input[type=datetime-local][name=from]")
      assert has_element?(view, "input[type=datetime-local][name=to]")
    end

    test "from filter excludes events older than the boundary", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/events")

      send(view.pid, stream_event("agent.message", :message, %{tag: "old-evt"}, "2026-07-14T10:00:00Z"))
      send(view.pid, stream_event("agent.message", :message, %{tag: "new-evt"}, "2026-07-14T14:00:00Z"))
      # Both visible initially (topic is a shown column value)
      assert render(view) =~ "2026-07-14T10:00:00Z"
      assert render(view) =~ "2026-07-14T14:00:00Z"

      view
      |> form("form[phx-change=update_filter]", %{"from" => "2026-07-14T12:00"})
      |> render_change()

      html = render(view)
      refute html =~ "2026-07-14T10:00:00Z"
      assert html =~ "2026-07-14T14:00:00Z"
    end
  end

  describe "Agent dropdown merges running agents (R3.2)" do
    test "a running agent appears in the agent filter even with no events", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:event_test_running)
      Process.sleep(100)

      {:ok, view, _html} = live(conn, "/events")

      assert has_element?(view, "select[name=agent_id] option", "event_test_running")
    end
  end

  describe "Dynamic topic discovery (VA2)" do
    test "a newly observed EventLog topic is surfaced by discover_topics/0" do
      novel = "agent.brand_new_topic_va2"
      LLMAgent.EventLog.record(EventStruct.new(:probe, novel, %{}))

      assert novel in Agento.EventBusBridge.discover_topics()
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
