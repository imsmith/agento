defmodule AgentoWeb.FakeHTTP do
  @moduledoc """
  A Bypass-shaped local HTTP server on Bandit: `open/0`, `expect_once/4`,
  `stub/4`, `down/1`. Handlers are plain `Plug.Conn` functions; a handler
  that raises (an `assert`, a `flunk`) fails the test that opened the
  server, and an `expect_once` route that is not hit exactly once does too.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  defmodule Plug do
    @moduledoc false
    @behaviour Elixir.Plug
    import Elixir.Plug.Conn

    @impl true
    def init(routes), do: routes

    @impl true
    def call(conn, routes) do
      key = {conn.method, conn.request_path}

      case Agent.get_and_update(routes, &take(&1, key)) do
        nil ->
          send_resp(conn, 404, "no FakeHTTP route for #{conn.method} #{conn.request_path}")

        fun ->
          try do
            conn = fun.(conn)
            if conn.state == :set, do: send_resp(conn), else: conn
          rescue
            e ->
              Agent.update(
                routes,
                &Map.update!(&1, :errors, fn es -> [{e, __STACKTRACE__} | es] end)
              )

              send_resp(conn, 500, "handler raised")
          end
      end
    end

    defp take(state, key) do
      case Map.fetch(state, key) do
        {:ok, {fun, mode, n}} -> {fun, Map.put(state, key, {fun, mode, n + 1})}
        :error -> {nil, state}
      end
    end
  end

  def open do
    {:ok, routes} = Agent.start(fn -> %{errors: []} end)

    {:ok, pid} =
      Bandit.start_link(
        plug: {__MODULE__.Plug, routes},
        ip: :loopback,
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    ExUnit.Callbacks.on_exit(fn -> verify(routes) end)
    %{pid: pid, port: port, routes: routes}
  end

  def expect_once(server, method, path, fun), do: route(server, method, path, fun, :once)
  def stub(server, method, path, fun), do: route(server, method, path, fun, :stub)

  def down(%{pid: pid}), do: Supervisor.stop(pid)

  defp route(%{routes: routes}, method, path, fun, mode),
    do: Agent.update(routes, &Map.put(&1, {method, path}, {fun, mode, 0}))

  defp verify(routes) do
    state = Agent.get(routes, & &1)
    Agent.stop(routes)

    case state.errors do
      [{e, st} | _] -> reraise e, st
      [] -> :ok
    end

    for {{method, path}, {_fun, :once, n}} <- state, n != 1 do
      flunk("FakeHTTP expected #{method} #{path} once, got #{n}")
    end
  end
end
