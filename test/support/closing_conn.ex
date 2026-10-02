defmodule AgentoWeb.ClosingConn do
  @moduledoc """
  A test connection whose client has hung up: every chunk write fails with
  `{:error, :closed}`, as a real listener's does once the socket is gone.
  Everything else behaves like `Plug.Adapters.Test.Conn`.
  """

  @behaviour Plug.Conn.Adapter

  alias Plug.Adapters.Test.Conn, as: TestConn

  @doc "Make `conn` one whose chunk writes fail."
  @spec wrap(Plug.Conn.t()) :: Plug.Conn.t()
  def wrap(%Plug.Conn{adapter: {TestConn, state}} = conn),
    do: %{conn | adapter: {__MODULE__, state}}

  @impl true
  def chunk(_state, _body), do: {:error, :closed}

  @impl true
  defdelegate send_resp(state, status, headers, body), to: TestConn
  @impl true
  defdelegate send_file(state, status, headers, path, offset, length), to: TestConn
  @impl true
  defdelegate send_chunked(state, status, headers), to: TestConn
  @impl true
  defdelegate read_req_body(state, opts), to: TestConn
  @impl true
  defdelegate inform(state, status, headers), to: TestConn
  @impl true
  defdelegate upgrade(state, protocol, opts), to: TestConn
  @impl true
  defdelegate push(state, path, headers), to: TestConn
  @impl true
  defdelegate get_peer_data(state), to: TestConn
  @impl true
  defdelegate get_sock_data(state), to: TestConn
  @impl true
  defdelegate get_ssl_data(state), to: TestConn
  @impl true
  defdelegate get_http_protocol(state), to: TestConn
end
