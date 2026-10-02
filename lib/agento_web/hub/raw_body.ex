defmodule AgentoWeb.Hub.RawBody do
  @moduledoc """
  A `Plug.Parsers` body reader that keeps the request bytes for hub requests.

  The endpoint parses JSON bodies before the router runs, and once parsed the
  original bytes are gone. The hub's turn log records each request exactly as
  the client sent it, so for paths under `/v1/` — and only those — the bytes
  are kept on the connection. Every other route pays nothing.
  """

  @doc "Read the next part of the body, keeping it when the request is the hub's."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, chunk, conn} -> {:ok, chunk, keep(conn, chunk)}
      {:more, chunk, conn} -> {:more, chunk, keep(conn, chunk)}
      {:error, _reason} = error -> error
    end
  end

  @doc "The request bytes kept for this connection, or `nil` if it is not a hub request."
  @spec get(Plug.Conn.t()) :: binary() | nil
  def get(conn), do: conn.private[:raw_body]

  defp keep(%Plug.Conn{request_path: "/v1/" <> _rest} = conn, chunk),
    do: Plug.Conn.put_private(conn, :raw_body, (conn.private[:raw_body] || "") <> chunk)

  defp keep(conn, _chunk), do: conn
end
