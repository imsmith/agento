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
    hero- bg-base- border-base- text-base-content text-xs text-sm text-lg text-xl text-2xl
    font-semibold rounded-full rounded-box opacity-
    btn- badge- alert- card- loading- menu- tab- rounded-xl rounded-2xl rounded-3xl
    text-error text-success text-warning text-info text-primary
    bg-primary bg-error bg-success bg-warning bg-info text-accent-content
  )

  # Every class attribute: class="...", class={["..."]}, class={"..."}, class={if ..., do: "..."}.
  # Read from the whole file so continuation lines are not missed.
  @class_str ~r/class="([^"]*)"/
  @class_expr ~r/class=\{([^}]*)\}/s

  defp offenders_in(source, path) do
    strings = for [_, v] <- Regex.scan(@class_str, source), do: v

    exprs =
      for [_, expr] <- Regex.scan(@class_expr, source),
          [_, lit] <- Regex.scan(~r/"([^"]*)"/, expr),
          do: lit

    for value <- strings ++ exprs,
        word <- String.split(value, ~r/[\s"\[\],&|?:(){}=!]+/, trim: true),
        token = String.replace(word, ~r/\/\d+$/, ""),
        Enum.any?(
          @forbidden,
          &(token == &1 or (String.ends_with?(&1, "-") and String.starts_with?(token, &1)))
        ),
        uniq: true,
        do: "#{path}: #{word}"
  end

  test "no off-system class vocabulary survives in the web tier" do
    offenders =
      for path <- Path.wildcard("lib/agento_web/**/*.{ex,heex}"),
          o <- offenders_in(File.read!(path), path),
          do: o

    assert offenders == [], Enum.join(["off-system classes:" | offenders], "\n  ")
  end

  test "the vocabulary lint reports each forbidden shape" do
    source = """
    <div class="btn btn-primary"></div>
    <div class={["text-base-content/60", @x && "card"]}></div>
    <div class={"badge-success"}></div>
    <div class={if @x, do: "alert-error", else: "p-1"}></div>
    <div class="rounded-xl"></div>
    <div class="hero-x-mark ds-card text-small"></div>
    """

    found = offenders_in(source, "fixture") |> Enum.join("\n")

    for tok <-
          ~w(btn btn-primary text-base-content/60 card badge-success alert-error rounded-xl hero-x-mark),
        do: assert(found =~ tok, "missing #{tok}")

    for ok <- ~w(ds-card p-1 text-small), do: refute(found =~ ok)
  end
end
