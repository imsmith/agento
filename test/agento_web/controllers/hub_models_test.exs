defmodule AgentoWeb.HubModelsTest do
  @moduledoc false

  use AgentoWeb.ConnCase, async: false

  import AgentoWeb.HubCase

  setup %{conn: conn} do
    reset_registry()
    install_config(default_host: "big.local")
    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token()}")}
  end

  test "lists reachable models in Anthropic's shape when asked with anthropic-version", %{
    conn: conn
  } do
    register(host: "big.local", model: "big.gguf")
    register(host: "small.local", model: "small.gguf")

    body =
      conn
      |> put_req_header("anthropic-version", "2023-06-01")
      |> get("/v1/models")
      |> json_response(200)

    assert %{
             "has_more" => false,
             "first_id" => "big.gguf",
             "last_id" => "small.gguf",
             "data" => data
           } = body

    assert Enum.map(data, & &1["id"]) == ["big.gguf", "small.gguf"]

    for entry <- data do
      assert %{"type" => "model", "display_name" => name, "created_at" => created} = entry
      assert name == entry["id"]
      assert {:ok, _, _} = DateTime.from_iso8601(created)
    end
  end

  test "lists them in OpenAI's shape otherwise", %{conn: conn} do
    register(host: "big.local", model: "big.gguf")

    assert %{
             "object" => "list",
             "data" => [%{"id" => "big.gguf", "object" => "model", "owned_by" => owner}]
           } =
             conn |> get("/v1/models") |> json_response(200)

    assert is_binary(owner)
  end

  test "an empty registry is an empty list, not an error", %{conn: conn} do
    assert %{"data" => [], "has_more" => false, "first_id" => nil, "last_id" => nil} =
             conn
             |> put_req_header("anthropic-version", "2023-06-01")
             |> get("/v1/models")
             |> json_response(200)

    assert %{"object" => "list", "data" => []} = conn |> get("/v1/models") |> json_response(200)
  end

  test "a performer the client's policy does not admit is not listed", %{conn: conn} do
    register(id: "cloud.1", model: "paid.gguf", source: "hub.config")
    register(host: "big.local", model: "big.gguf")

    assert %{"data" => [%{"id" => "big.gguf"}]} = conn |> get("/v1/models") |> json_response(200)
  end
end
