defmodule AgentoWeb.Hub.Auth do
  @moduledoc """
  Identifies the client behind a hub request by its bearer token.

  The token is read from `Authorization: Bearer <token>`, else from
  `x-api-key` — the two places Anthropic- and OpenAI-protocol clients put it.
  A request with no token, or one no configured client owns, is answered 401
  and goes no further. There is no anonymous client.

  On success the client record — its name and its `%LLMAgent.Tool.Policy{}` —
  is assigned as `:hub_client`. The token authenticates the client to the
  hub and is never sent on to a performer.
  """

  @behaviour Plug

  import Plug.Conn

  alias Agento.Hub.Config
  alias LLMAgent.Codec.Anthropic

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case Config.client_for_token(Config.get(), token(conn)) do
      {:ok, client} ->
        assign(conn, :hub_client, client)

      :error ->
        body = Anthropic.encode_error(401, "missing or unknown hub token")

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(body))
        |> halt()
    end
  end

  defp token(conn) do
    case get_req_header(conn, "authorization") do
      [value | _] -> bearer(value)
      [] -> conn |> get_req_header("x-api-key") |> List.first()
    end
  end

  defp bearer(value) do
    case String.split(value, " ", parts: 2) do
      [scheme, token] -> if String.downcase(scheme) == "bearer", do: String.trim(token)
      _ -> nil
    end
  end
end
