defmodule AgentoWeb.HarnessStreamTest do
  @moduledoc false
  use AgentoWeb.ConnCase

  defp open_session(conn) do
    conn |> get("/harness") |> json_response(201)
  end

  defp on_exit_stop_agent(session_id) do
    ExUnit.Callbacks.on_exit(fn ->
      case AgentoWeb.Harness.Registry.lookup(session_id) do
        {:ok, %{agent: agent}} ->
          try do
            LLMAgent.AgentSupervisor.stop_agent(agent)
          rescue
            # Agent may already be gone by teardown time; not worth failing the suite over.
            _e in [RuntimeError, ArgumentError] -> :ok
          catch
            _, _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  test "PUT streams an assistant message frame tagged with req_ts and fold", %{conn: conn} do
    s = open_session(conn)
    on_exit_stop_agent(s["session_id"])

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put("/harness/#{s["session_id"]}", %{
        "fold" => s["fold"],
        "context" => [%{"role" => "user", "content" => "hello there"}]
      })

    assert conn.status == 200
    frames = conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)
    msg = Enum.find(frames, &(&1["type"] == "message"))
    assert msg["data"]["content"] =~ "test response"
    assert is_binary(msg["req_ts"])
    assert msg["fold"] == "fold_1"
  end

  test "PUT on an unknown session returns 404", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put("/harness/nope", %{"fold" => "fold_0", "context" => []})

    assert conn.status == 404
  end
end
