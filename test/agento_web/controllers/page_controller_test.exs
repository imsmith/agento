defmodule AgentoWeb.PageControllerTest do
  use AgentoWeb.ConnCase

  test "GET / redirects to chat", %{conn: conn} do
    assert redirected_to(conn |> get(~p"/")) == "/chat"
  end

  test "the home template is the shell with a view index" do
    html = Phoenix.Template.render_to_string(AgentoWeb.PageHTML, "home", "html", flash: %{})
    assert html =~ ~s(class="ds-shell)

    for title <- ~w(Chat Events System Tools Hub Rules),
        do: assert(html =~ ~s(class="ds-card__title">#{title}</h3>))

    assert length(
             Regex.scan(
               ~r/<a href="\/(chat|events|system|tools|hub|rules)" class="ds-btn ds-btn--text ds-btn--sm">/,
               html
             )
           ) == 6

    refute html =~ "Phoenix Framework"
  end
end
