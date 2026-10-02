defmodule AgentoWeb.Hub.AuthTest do
  @moduledoc false

  use AgentoWeb.ConnCase, async: false

  import AgentoWeb.HubCase

  setup do
    reset_registry()
    install_config()
    :ok
  end

  defp unauthorized(conn) do
    assert %{"type" => "error", "error" => %{"type" => "authentication_error", "message" => message}} =
             json_response(conn, 401)

    assert is_binary(message)
    refute message =~ token()
  end

  test "a request with no token is refused", %{conn: conn} do
    conn |> get("/v1/models") |> unauthorized()
  end

  test "a request with an unknown token is refused", %{conn: conn} do
    conn |> put_req_header("authorization", "Bearer not-the-token-at-all-000") |> get("/v1/models") |> unauthorized()
    conn |> put_req_header("x-api-key", "not-the-token-at-all-000") |> get("/v1/models") |> unauthorized()
  end

  test "the right token under the wrong scheme is refused", %{conn: conn} do
    conn |> put_req_header("authorization", "Basic #{token()}") |> get("/v1/models") |> unauthorized()
    conn |> put_req_header("authorization", token()) |> get("/v1/models") |> unauthorized()
  end

  test "a bearer token identifies the client", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "Bearer #{token()}") |> get("/v1/models")

    assert conn.status == 200
    assert conn.assigns.hub_client.name == "test-client"
  end

  test "the scheme name is case-insensitive", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "bearer #{token()}") |> get("/v1/models")
    assert conn.status == 200
  end

  test "x-api-key identifies the client too", %{conn: conn} do
    conn = conn |> put_req_header("x-api-key", token()) |> get("/v1/models")

    assert conn.status == 200
    assert conn.assigns.hub_client.name == "test-client"
  end

  test "with no clients configured every request is refused", %{conn: conn} do
    Agento.Hub.Config.put(%{Agento.Hub.Config.get() | clients: []})
    conn |> put_req_header("authorization", "Bearer #{token()}") |> get("/v1/models") |> unauthorized()
  end

  test "the existing routes need no token", %{conn: conn} do
    assert conn |> get("/agents") |> json_response(200)
  end
end
