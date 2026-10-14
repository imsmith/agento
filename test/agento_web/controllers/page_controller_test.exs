defmodule AgentoWeb.PageControllerTest do
  use AgentoWeb.ConnCase

  test "GET / redirects to chat", %{conn: conn} do
    assert redirected_to(conn |> get(~p"/")) == "/chat"
  end

  test "the home template is the shell with a view index" do
    html = Phoenix.Template.render_to_string(AgentoWeb.PageHTML, "home", "html", flash: %{})
    assert html =~ ~s(class="ds-shell)
    for path <- ~w(/chat /events /system /tools /hub /rules), do: assert(html =~ ~s(href="#{path}"))
    refute html =~ "Phoenix Framework"
  end
end
