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
end
