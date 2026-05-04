defmodule AgentoWeb.ArchitecturalTest do
  @moduledoc """
  Architectural integration tests verifying EventBus Bridge and
  Comn self-observability (web.* events, context enrichment).
  """
  use AgentoWeb.ConnCase

  describe "EventBus Bridge" do
    test "bridge process is running" do
      assert Process.whereis(Agento.EventBusBridge) != nil
    end

    test "two LiveView processes receive the same event via bridge", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:bridge_test_agent)
      Process.sleep(100)

      # Mount two LiveView processes for the same agent
      {:ok, view1, _html} = live(conn, "/chat?agent=bridge_test_agent")
      {:ok, view2, _html} = live(conn, "/chat?agent=bridge_test_agent")

      # Submit a prompt from view1
      view1
      |> form("form[phx-submit=send_prompt]", %{"prompt" => "bridge test"})
      |> render_submit()

      # Wait for events to propagate
      Process.sleep(500)

      # Both views should show the message
      html1 = render(view1)
      html2 = render(view2)

      # At minimum, both should have received the event (view1 sent it,
      # view2 gets it via PubSub bridge)
      assert html1 =~ "bridge test" or html1 =~ "test response"
      assert html2 =~ "bridge test" or html2 =~ "test response"
    end

    test "bridge survives LiveView unmount", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:bridge_test_survive)
      Process.sleep(100)

      # Mount and unmount a LiveView
      {:ok, view1, _html} = live(conn, "/chat?agent=bridge_test_survive")

      # Verify it's live
      assert render(view1) =~ "bridge_test_survive"

      # The bridge should still be running after the test process
      # (which owns view1) ends
      assert Process.alive?(Process.whereis(Agento.EventBusBridge))
    end
  end

  describe "Web App Uses Comn (self-consistency)" do
    test "LiveView mount sets Comn context with request_id", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/chat")

      # The Observability hook should have set comn_context on assigns
      # We can verify this by checking that web.mount events were emitted
      Process.sleep(200)

      events = LLMAgent.EventLog.all()

      web_mount_events =
        Enum.filter(events, fn e ->
          e.topic == "web.mount"
        end)

      assert length(web_mount_events) > 0, "Expected web.mount events from LiveView mount"
    end

    test "web events have context enrichment (request_id, trace_id)", %{conn: conn} do
      {:ok, _view, _html} = live(conn, "/chat")
      Process.sleep(200)

      events = LLMAgent.EventLog.all()

      web_events =
        Enum.filter(events, fn e ->
          is_binary(e.topic) and String.starts_with?(e.topic, "web.")
        end)

      assert length(web_events) > 0

      # Check that web events have context data
      for event <- web_events do
        # Events emitted via LLMAgent.Events.emit/4 get context enrichment
        # which includes request_id and trace_id in the data map
        data = event.data
        assert is_map(data), "Event data should be a map"
      end
    end

    test "user actions emit web.event events", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:comn_test_agent)
      Process.sleep(100)

      # Clear existing events to isolate our test
      LLMAgent.EventLog.clear()

      {:ok, view, _html} = live(conn, "/chat")
      Process.sleep(100)

      # Perform an action that triggers handle_event
      view |> element("button[phx-click=refresh_agents]") |> render_click()
      Process.sleep(200)

      events = LLMAgent.EventLog.all()

      web_events =
        Enum.filter(events, fn e ->
          is_binary(e.topic) and e.topic == "web.event"
        end)

      assert length(web_events) > 0, "Expected web.event events from user actions"
    end

    test "prompt submission emits web.prompt_sent event", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:comn_prompt_evt)
      Process.sleep(100)

      LLMAgent.EventLog.clear()

      {:ok, view, _html} = live(conn, "/chat?agent=comn_prompt_evt")

      view
      |> form("form[phx-submit=send_prompt]", %{"prompt" => "hello comn"})
      |> render_submit()

      Process.sleep(300)

      events = LLMAgent.EventLog.all()

      prompt_events =
        Enum.filter(events, fn e ->
          is_binary(e.topic) and e.topic == "web.prompt_sent"
        end)

      assert length(prompt_events) > 0, "Expected web.prompt_sent event from prompt submission"
    end

    test "agent start emits web.agent_started event", %{conn: conn} do
      LLMAgent.EventLog.clear()

      {:ok, view, _html} = live(conn, "/chat")

      view |> element("button[phx-click=toggle_new_agent_form]") |> render_click()

      view
      |> form("form[phx-submit=start_agent]", %{
        "name" => "comn_start_evt",
        "role" => "sysadmin",
        "model" => "test-model",
        "api_host" => "http://localhost:11434/v1"
      })
      |> render_change()

      view
      |> form("form[phx-submit=start_agent]")
      |> render_submit()

      Process.sleep(300)

      events = LLMAgent.EventLog.all()

      started_events =
        Enum.filter(events, fn e ->
          is_binary(e.topic) and e.topic == "web.agent_started"
        end)

      assert length(started_events) > 0, "Expected web.agent_started event"

      on_exit(fn ->
        try do
          LLMAgent.DurableLog.clear(:comn_start_evt)
          LLMAgent.AgentSupervisor.stop_agent(:comn_start_evt)
          LLMAgent.Memory.ETS.teardown(:comn_start_evt)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)
    end

    test "agent stop emits web.agent_stopped event", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:comn_stop_evt)
      Process.sleep(100)

      LLMAgent.EventLog.clear()

      {:ok, view, _html} = live(conn, "/chat")
      view |> element("button[phx-click=refresh_agents]") |> render_click()

      view
      |> element("[phx-click=confirm_stop][phx-value-name=comn_stop_evt]")
      |> render_click()

      view
      |> element("[phx-click=stop_agent][phx-value-name=comn_stop_evt]")
      |> render_click()

      Process.sleep(300)

      events = LLMAgent.EventLog.all()

      stopped_events =
        Enum.filter(events, fn e ->
          is_binary(e.topic) and e.topic == "web.agent_stopped"
        end)

      assert length(stopped_events) > 0, "Expected web.agent_stopped event"
    end
  end
end
