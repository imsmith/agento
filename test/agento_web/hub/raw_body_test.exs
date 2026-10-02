defmodule AgentoWeb.Hub.RawBodyTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Plug.Test

  alias AgentoWeb.Hub.RawBody

  @body ~s({ "model" : "m",\n  "messages": [ ] , "note": "héllo" })

  defp read_all(conn, opts, acc \\ "") do
    case RawBody.read_body(conn, opts) do
      {:ok, chunk, conn} -> {acc <> chunk, conn}
      {:more, chunk, conn} -> read_all(conn, opts, acc <> chunk)
    end
  end

  test "keeps the bytes of a request under /v1/ exactly as sent" do
    {read, conn} = :post |> conn("/v1/messages?beta=true", @body) |> read_all([])

    assert read == @body
    assert RawBody.get(conn) == @body
  end

  test "keeps a body that arrives in several reads whole" do
    {read, conn} = :post |> conn("/v1/messages", @body) |> read_all(length: 8, read_length: 8)

    assert read == @body
    assert RawBody.get(conn) == @body
  end

  test "keeps nothing for any other path" do
    {read, conn} = :post |> conn("/harness/abc", @body) |> read_all([])

    assert read == @body
    assert RawBody.get(conn) == nil
    refute Map.has_key?(conn.private, :raw_body)
  end

  test "a path that only starts like /v1 is not kept" do
    {_read, conn} = :post |> conn("/v1beta/thing", @body) |> read_all([])
    assert RawBody.get(conn) == nil
  end
end
