defmodule LlmagentWebWeb.ExportControllerTest do
  @moduledoc false
  use LlmagentWebWeb.ConnCase

  alias LlmagentWebWeb.IntegrationHelper

  describe "GET /export/:agent (R7.3)" do
    test "downloads events as JSON with attachment disposition", %{conn: conn} do
      {:ok, _pid} = IntegrationHelper.start_test_agent(:export_events_test)
      LLMAgent.prompt({:global, :export_events_test}, "hello")
      :timer.sleep(200)

      conn = get(conn, ~p"/export/export_events_test?kind=events")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"

      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(attachment)
      assert disposition =~ ~s(export_events_test-events.json)

      decoded = Jason.decode!(conn.resp_body)
      assert is_list(decoded)
    end

    test "downloads messages as JSON", %{conn: conn} do
      {:ok, _pid} = IntegrationHelper.start_test_agent(:export_messages_test)

      conn = get(conn, ~p"/export/export_messages_test?kind=messages")

      assert response(conn, 200)
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ ~s(export_messages_test-messages.json)
      assert is_list(Jason.decode!(conn.resp_body))
    end

    test "defaults kind to events when omitted", %{conn: conn} do
      {:ok, _pid} = IntegrationHelper.start_test_agent(:export_default_test)

      conn = get(conn, ~p"/export/export_default_test")

      assert response(conn, 200)
      [disposition] = get_resp_header(conn, "content-disposition")
      assert disposition =~ "events.json"
    end

    test "returns 400 for unknown kind", %{conn: conn} do
      {:ok, _pid} = IntegrationHelper.start_test_agent(:export_bad_kind_test)

      conn = get(conn, ~p"/export/export_bad_kind_test?kind=garbage")

      assert response(conn, 400)
    end

    test "returns 404 for unknown agent", %{conn: conn} do
      conn = get(conn, ~p"/export/totally_nonexistent_agent_zzz?kind=events")
      assert response(conn, 404)
    end
  end
end
