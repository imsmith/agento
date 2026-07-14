defmodule AgentoWeb.HarnessController do
  @moduledoc """
  HTTP boundary for the harness API. Parses/validates requests, delegates to
  `AgentoWeb.Harness.*`, and maps results to responses. No orchestration logic.
  """
  use AgentoWeb, :controller

  alias AgentoWeb.Harness.Catalog
  alias AgentoWeb.Harness.Session
  alias AgentoWeb.Harness.Spec

  def specification(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Spec.document())
  end

  def agents(conn, _params), do: json(conn, %{"agents" => Catalog.agents()})
  def toolbox(conn, _params), do: json(conn, %{"tools" => Catalog.toolbox()})

  def create(conn, _params) do
    agent_type = Session.negotiate_agent(get_req_header(conn, "accept"))

    case Session.open(agent_type) do
      {:ok, session} ->
        conn
        |> put_status(201)
        |> json(%{
          "session_id" => session.id,
          "agent" => to_string(session.agent_type),
          "fold" => "fold_#{session.fold}",
          "expires_at" => DateTime.to_iso8601(session.expires_at)
        })

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(error_body("agent_start_failed", nil, "could not start agent: #{inspect(reason)}"))
    end
  end

  def interact(conn, _params), do: send_resp(conn, 501, "not implemented")

  defp error_body(reason, field, message) do
    %{"error" => %{"reason" => reason, "field" => field, "message" => message, "suggestion" => nil}}
  end
end
