defmodule AgentoWeb.HarnessController do
  @moduledoc """
  HTTP boundary for the harness API. Parses/validates requests, delegates to
  `AgentoWeb.Harness.*`, and maps results to responses. No orchestration logic.
  """
  use AgentoWeb, :controller

  alias AgentoWeb.Harness.Spec

  def specification(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Spec.document())
  end

  def agents(conn, _params), do: json(conn, %{"agents" => []})
  def toolbox(conn, _params), do: json(conn, %{"tools" => []})
  def create(conn, _params), do: send_resp(conn, 501, "not implemented")
  def interact(conn, _params), do: send_resp(conn, 501, "not implemented")
end
