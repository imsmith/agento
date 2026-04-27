defmodule LlmagentWebWeb.PageController do
  use LlmagentWebWeb, :controller

  def home(conn, _params) do
    redirect(conn, to: ~p"/chat")
  end
end
