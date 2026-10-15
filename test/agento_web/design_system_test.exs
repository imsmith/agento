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

    for path <- ~w(/chat /events /system /tools /hub /rules),
        do: assert(html =~ ~s(href="#{path}"))

    assert html =~ ~s(aria-current="page")
    assert html =~ ~s(phx-hook="ThemeSwitch")
    assert html =~ ~s(select id="ds-theme")
    assert html =~ ~r/<form[^>]*id="ds-theme-switch"[^>]*phx-auto-recover="ignore"/
  end

  test "an error flash is a persistent critical toast", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/chat?agent=no_such_agent_xyz")

    assert has_element?(
             view,
             "#flash-toasts-error[data-severity=critical][data-duration='0']",
             "no_such_agent_xyz"
           )
  end

  test "the theme switch is ignored by LiveView patches so the client owns it", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/chat")
    assert html =~ ~s(id="theme-switch" phx-hook="ThemeSwitch" phx-update="ignore")
  end

  test "connection toasts are present, hidden, and scoped to the client/server error states", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/chat")

    for id <- ~w(client-error server-error) do
      assert html =~ ~r/id="#{id}"[^>]*data-severity="critical"/
    end

    assert html =~ ~s(.phx-client-error #client-error)
    assert html =~ ~s(.phx-server-error #server-error)
  end

  @forbidden ~w(
    btn card badge alert navbar collapse loading toast tabs tab-active menu-item
    table-zebra table-xs table-sm input-bordered select-bordered textarea-bordered
    fieldset label chat chat-bubble
    hero- bg-base- text-base-content text-xs text-sm text-lg text-xl text-2xl
    font-semibold rounded-full rounded-box opacity-
  )

  # Every class attribute, single-line (class="...") or multi-line (class={[ ... ]}),
  # read from the whole file so continuation lines are not missed.
  @class_attr ~r/class=(?:"([^"]*)"|\{\s*\[(.*?)\]\s*\})/s

  test "no off-system class vocabulary survives in the web tier" do
    offenders =
      for path <- Path.wildcard("lib/agento_web/**/*.{ex,heex}"),
          source = File.read!(path),
          [_whole | groups] <- Regex.scan(@class_attr, source),
          word <- String.split(Enum.join(groups, " "), ~r/[\s"\[\],&|?:(){}=!]+/, trim: true),
          Enum.any?(
            @forbidden,
            &(word == &1 or (String.ends_with?(&1, "-") and String.starts_with?(word, &1)))
          ),
          uniq: true,
          do: "#{path}: #{word}"

    assert offenders == [], Enum.join(["off-system classes:" | offenders], "\n  ")
  end
end
