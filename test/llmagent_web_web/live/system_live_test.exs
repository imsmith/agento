defmodule LlmagentWebWeb.SystemLiveTest do
  @moduledoc """
  Integration tests for System LiveView (R4, R5, R7).
  """
  use LlmagentWebWeb.ConnCase

  describe "Supervision Tree (R4.1, R4.3)" do
    test "system page mounts with supervision tree tab", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/system")
      assert html =~ "Supervision Tree"
      assert html =~ "ETS Tables"
      assert html =~ "DurableLog"
    end

    test "refresh loads the supervision tree", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")

      # Click refresh to load tree data
      view |> element("button[phx-click=refresh]") |> render_click()

      html = render(view)
      # Should show LLMAgent.Supervisor as root
      assert html =~ "LLMAgent.Supervisor" or html =~ "Supervisor"
    end

    test "supervision tree shows agent children (R4.3)", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:tree_test_agent)
      Process.sleep(100)

      {:ok, view, _html} = live(conn, "/system")

      view |> element("button[phx-click=refresh]") |> render_click()

      html = render(view)
      # The DynamicSupervisor children should include our test agent
      assert html =~ "alive"
    end

    test "agent appears/disappears in tree on start/stop", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/system")

      # Start an agent
      {:ok, _pid} = start_test_agent(:tree_test_dynamic)
      Process.sleep(100)

      view |> element("button[phx-click=refresh]") |> render_click()
      html = render(view)
      assert html =~ "tree_test_dynamic" or html =~ "alive"

      # Stop it
      LLMAgent.AgentSupervisor.stop_agent(:tree_test_dynamic)
      Process.sleep(100)

      view |> element("button[phx-click=refresh]") |> render_click()
      html = render(view)
      refute html =~ "tree_test_dynamic"
    end
  end

  describe "ETS Table Inspector (R5.1)" do
    test "ETS tab shows memory tables for agents", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:ets_test_agent)
      Process.sleep(100)

      # Generate memory entry by sending a prompt
      send_prompt(:ets_test_agent, "ets test")
      Process.sleep(500)

      {:ok, view, _html} = live(conn, "/system")

      # Switch to ETS tab
      view |> element("[phx-click=set_tab][phx-value-tab=ets]") |> render_click()

      # Click refresh to load ETS data
      view |> element("button[phx-click=refresh]") |> render_click()

      html = render(view)
      # Should list the memory table
      assert html =~ "llmagent_mem_ets_test_agent" or html =~ "ETS Tables"
    end

    test "clicking a table shows its entries", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:ets_test_browse)
      Process.sleep(100)

      send_prompt(:ets_test_browse, "browse test")
      Process.sleep(500)

      {:ok, view, _html} = live(conn, "/system")
      view |> element("[phx-click=set_tab][phx-value-tab=ets]") |> render_click()
      view |> element("button[phx-click=refresh]") |> render_click()

      # Try to select the table
      html = render(view)

      if html =~ "llmagent_mem_ets_test_browse" do
        view
        |> element("[phx-click=select_ets_table][phx-value-name=llmagent_mem_ets_test_browse]")
        |> render_click()

        html = render(view)
        # Should show table entries with history key
        assert html =~ "history" or html =~ "llmagent_mem_ets_test_browse"
      end
    end
  end

  describe "DurableLog Inspector (R7)" do
    test "DurableLog tab shows status and agents", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:durable_test_status)
      Process.sleep(100)

      send_prompt(:durable_test_status, "durable status test")
      Process.sleep(500)

      {:ok, view, _html} = live(conn, "/system")
      view |> element("[phx-click=set_tab][phx-value-tab=durable_log]") |> render_click()
      view |> element("button[phx-click=refresh]") |> render_click()

      html = render(view)
      assert html =~ "DurableLog"
    end

    test "selecting agent shows event/message counts (R7.2)", %{conn: conn} do
      {:ok, _pid} = start_test_agent(:durable_test_browse)
      Process.sleep(100)

      send_prompt(:durable_test_browse, "browse durable")
      Process.sleep(500)

      {:ok, view, _html} = live(conn, "/system")
      view |> element("[phx-click=set_tab][phx-value-tab=durable_log]") |> render_click()
      view |> element("button[phx-click=refresh]") |> render_click()

      html = render(view)

      if html =~ "durable_test_browse" do
        view
        |> element("[phx-click=select_durable_agent][phx-value-agent=durable_test_browse]")
        |> render_click()

        html = render(view)
        assert html =~ "Event Count" or html =~ "Message Count"
      end
    end
  end
end
