defmodule AgentoWeb.PageController do
  use AgentoWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/chat")
  end
end
