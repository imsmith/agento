defmodule AgentoWeb.PageControllerTest do
  use AgentoWeb.ConnCase

  test "GET / is the view index inside the shell", %{conn: conn} do
    html = conn |> get(~p"/") |> html_response(200)
    assert html =~ ~s(class="ds-shell)
    assert html =~ ~s(class="ds-card__title">Chat</h3>)
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
