defmodule AgentoWeb.PageControllerTest do
  use AgentoWeb.ConnCase

  test "GET / redirects to /chat", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/chat"
  end
end
