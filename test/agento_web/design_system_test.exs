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

  test "the shell carries the sidebar nav, the brand mark and the theme switch", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/chat")
    assert html =~ ~s(class="ds-shell)
    assert html =~ ~s(href="#m-agent")
    for path <- ~w(/chat /events /system /tools /hub /rules), do: assert(html =~ ~s(href="#{path}"))
    assert html =~ ~s(aria-current="page")
    assert html =~ ~s(phx-hook="ThemeSwitch")
    assert html =~ ~s(select id="ds-theme")
  end

  test "an error flash is a persistent critical toast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat?agent=no_such_agent_xyz")
    html = render(view)
    assert html =~ ~s(class="ds-toast)
    assert html =~ ~s(data-severity="critical")
    assert html =~ ~s(data-duration="0")
    assert html =~ "no_such_agent_xyz"
  end

  test "the theme switch is ignored by LiveView patches so the client owns it", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/chat")
    assert html =~ ~s(id="theme-switch" phx-hook="ThemeSwitch" phx-update="ignore")
  end

  test "connection toasts are present, hidden, and scoped to the client/server error states", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/chat")
    for id <- ~w(client-error server-error) do
      assert html =~ ~s(id="#{id}")
      assert html =~ ~s(data-severity="critical")
    end
    assert html =~ ~s(.phx-client-error #client-error)
    assert html =~ ~s(.phx-server-error #server-error)
    assert html =~ ~r/id="client-error"[^>]*\shidden/
  end
end
