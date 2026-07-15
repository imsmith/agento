defmodule AgentoWeb.HarnessControllerTest do
  @moduledoc false
  use AgentoWeb.ConnCase

  describe "specification" do
    test "GET /specification returns an OpenAPI 3.x document", %{conn: conn} do
      body = conn |> get("/specification") |> json_response(200)
      assert body["openapi"] =~ ~r/^3\./
      assert get_in(body, ["paths", "/harness"]) != nil
      assert get_in(body, ["paths", "/harness/{session_id}"]) != nil
    end

    test "OPTIONS / returns the same specification", %{conn: conn} do
      body = conn |> options("/") |> json_response(200)
      assert body["openapi"] =~ ~r/^3\./
    end
  end

  describe "catalogs" do
    test "GET /agents lists instantiable agent types with id and name", %{conn: conn} do
      body = conn |> get("/agents") |> json_response(200)
      ids = Enum.map(body["agents"], & &1["id"])
      assert "default" in ids
      assert Enum.all?(body["agents"], &is_binary(&1["name"]))
    end

    test "GET /toolbox lists tools with name and module", %{conn: conn} do
      body = conn |> get("/toolbox") |> json_response(200)
      assert is_list(body["tools"])
      assert Enum.all?(body["tools"], &(is_binary(&1["name"]) and is_binary(&1["module"])))
    end
  end

  describe "spec matches routes" do
    test "every documented path is a live route", %{conn: conn} do
      body = conn |> get("/specification") |> json_response(200)
      documented = body["paths"] |> Map.keys() |> Enum.reject(&String.contains?(&1, "{"))
      routes = AgentoWeb.Router.__routes__() |> Enum.map(& &1.path)
      for path <- documented, do: assert(path in routes, "#{path} documented but not routed")
    end
  end

  describe "GET /harness" do
    test "provisions a session record with a default agent and a fold", %{conn: conn} do
      body = conn |> get("/harness") |> json_response(201)
      assert is_binary(body["session_id"])
      assert body["agent"] == "default"
      assert body["fold"] == "fold_0"
      assert is_binary(body["expires_at"])
    end

    test "negotiates the agent type via the Accept header", %{conn: conn} do
      body =
        conn
        |> put_req_header("accept", "sysadmin")
        |> get("/harness")
        |> json_response(201)

      assert body["agent"] == "sysadmin"
    end
  end
end
