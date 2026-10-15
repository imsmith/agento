defmodule AgentoWeb.PageController do
  use AgentoWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
