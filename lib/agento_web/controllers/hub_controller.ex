defmodule AgentoWeb.HubController do
  @moduledoc """
  HTTP boundary for the private LLM hub: the routes coding clients call in
  place of a vendor's API. Requests arrive already identified by
  `AgentoWeb.Hub.Auth`. No orchestration logic lives here.
  """
  use AgentoWeb, :controller

  alias Agento.Hub.Router

  @doc """
  The models the calling client can reach right now — whatever the admitted
  performers are serving. Anthropic's list shape when the request carries an
  `anthropic-version` header, OpenAI's otherwise.
  """
  def models(conn, _params) do
    ids = conn.assigns.hub_client |> Router.models() |> Enum.map(& &1.id)

    case get_req_header(conn, "anthropic-version") do
      [] -> json(conn, openai_models(ids))
      _ -> json(conn, anthropic_models(ids))
    end
  end

  defp anthropic_models(ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    %{
      "data" => for(id <- ids, do: %{"type" => "model", "id" => id, "display_name" => id, "created_at" => now}),
      "has_more" => false,
      "first_id" => List.first(ids),
      "last_id" => List.last(ids)
    }
  end

  defp openai_models(ids) do
    %{"object" => "list", "data" => for(id <- ids, do: %{"id" => id, "object" => "model", "owned_by" => "agento"})}
  end
end
