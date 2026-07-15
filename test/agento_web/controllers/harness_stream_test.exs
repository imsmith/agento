defmodule AgentoWeb.HarnessStreamTest do
  @moduledoc false
  use AgentoWeb.ConnCase

  defp open_session(conn), do: conn |> get("/harness") |> json_response(201)

  defp put_turn(conn, sid, fold, user) do
    conn
    |> put_req_header("content-type", "application/json")
    |> put("/harness/#{sid}", %{
      "fold" => fold,
      "context" => [%{"role" => "user", "content" => user}]
    })
  end

  defp frames(conn), do: conn.resp_body |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

  test "PUT streams an assistant message frame tagged with req_ts and fold", %{conn: conn} do
    s = open_session(conn)
    conn = put_turn(conn, s["session_id"], s["fold"], "hello there")

    assert conn.status == 200
    msg = Enum.find(frames(conn), &(&1["type"] == "message"))
    assert msg["data"]["content"] =~ "test response"
    assert is_binary(msg["req_ts"])
    assert msg["fold"] == "fold_1"
  end

  test "PUT with a tool-triggering turn streams tool_dispatch + tool_result before the message", %{conn: conn} do
    s = open_session(conn)
    conn = put_turn(conn, s["session_id"], s["fold"], "use_tool")

    assert conn.status == 200
    fs = frames(conn)
    dispatch = Enum.find(fs, &(&1["type"] == "tool_dispatch"))
    result = Enum.find(fs, &(&1["type"] == "tool_result"))
    message = Enum.find(fs, &(&1["type"] == "message"))

    assert dispatch["data"]["tool"] == "bash"
    assert result["data"]["status"] == "ok"
    assert message != nil
    # ordering: the tool frames precede the final message
    assert Enum.find_index(fs, &(&1 == dispatch)) < Enum.find_index(fs, &(&1 == message))
  end

  test "fold advances across turns", %{conn: conn} do
    s = open_session(conn)
    c1 = put_turn(conn, s["session_id"], "fold_0", "first")
    assert frames(c1) |> Enum.find(&(&1["type"] == "message")) |> Map.get("fold") == "fold_1"

    c2 = put_turn(conn, s["session_id"], "fold_1", "second")
    assert frames(c2) |> Enum.find(&(&1["type"] == "message")) |> Map.get("fold") == "fold_2"
  end

  test "PUT on an unknown session returns 404", %{conn: conn} do
    conn = put_turn(conn, "nope", "fold_0", "hi")
    assert conn.status == 404
  end
end
