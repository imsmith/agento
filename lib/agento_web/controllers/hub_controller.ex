defmodule AgentoWeb.HubController do
  @moduledoc """
  HTTP boundary for the private LLM hub: the routes coding clients call in
  place of a vendor's API. Requests arrive already identified by
  `AgentoWeb.Hub.Auth`. No orchestration logic lives here.
  """
  use AgentoWeb, :controller

  alias Agento.Hub.Config
  alias Agento.Hub.Router
  alias AgentoWeb.Hub.Turn
  alias LLMAgent.Codec.Anthropic

  @doc """
  One turn in Anthropic's Messages format: decode it, pick a performer, run
  it. Streams when the request asks for a stream.
  """
  def messages(conn, _params) do
    client = conn.assigns.hub_client
    config = Config.get()

    with {:ok, turn} <- Anthropic.decode_request(conn.body_params),
         {:route, turn, {:ok, ad}} <- {:route, turn, Router.route(turn.model, client, config)} do
      {conn, _summary} = Turn.run(conn, turn, ad, client, config)
      conn
    else
      {:error, {_kind, what}} ->
        error(conn, 400, what)

      {:route, turn, {:error, :no_performer}} ->
        error(conn, 404, "no performer is available for model #{inspect(turn.model)}")
    end
  end

  defp error(conn, status, message) do
    conn |> put_status(status) |> json(Anthropic.encode_error(status, message))
  end

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
