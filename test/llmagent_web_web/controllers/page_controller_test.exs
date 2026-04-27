defmodule LlmagentWebWeb.PageControllerTest do
  use LlmagentWebWeb.ConnCase

  test "GET / redirects to /chat", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/chat"
  end
end
