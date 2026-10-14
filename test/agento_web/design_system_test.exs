defmodule AgentoWeb.DesignSystemTest do
  @moduledoc "The web tier consumes imsmith/design-system through gos-ui and nothing else."
  use AgentoWeb.ConnCase

  test "root layout links the design-system stylesheet and carries a theme", %{conn: conn} do
    html = conn |> get("/chat") |> html_response(200)
    assert html =~ ~s(href="/gos-ui/styles.css")
    assert html =~ ~s(<html lang="en" data-theme="tron")
    assert html =~ ~s(<symbol id="m-agent")
  end

  test "the design-system static root is served", %{conn: conn} do
    assert conn |> get("/gos-ui/styles.css") |> response(200) =~ "@import"
  end
end
