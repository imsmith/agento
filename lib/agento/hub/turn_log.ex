defmodule Agento.Hub.TurnLog do
  @moduledoc """
  The hub's record of every turn: who asked, which performer served it, how
  it ended, what it cost in tokens, and both bodies.

  One SQLite database, `<data_dir>/hub_turns.sqlite`, one row per turn. The
  two body columns hold the client's request and the final assistant message
  exactly as they crossed the wire. Those are the vendors' payloads kept
  verbatim, not a storage format this project chose.

  ## What is in it

  Whatever the clients sent, including anything pasted into a prompt. The
  directory is created owner-only and the database file is forced to mode
  0600. Bodies go here and nowhere else: never onto the event bus, the event
  log, or the durable log.

  ## It never gets in the way

  A turn log that cannot be written must not cost anyone a turn. `record/2`
  is a cast and returns `:ok` whatever happens: if the process is not
  running, if the database could not be opened, if the write fails. Failures
  are logged and the row is dropped.

  Rows older than the retention are deleted at start and hourly after that.

  A turn whose connection process was killed is not recorded: the summary is
  built by that process, and it is gone.
  """

  use GenServer

  require Logger

  alias Exqlite.Sqlite3

  @file_name "hub_turns.sqlite"
  @prune_every_ms 3_600_000

  @columns ~w(at client wire requested_model ad_id performer_model outcome stop_reason
              input_tokens output_tokens duration_ms error request_body response_body)a
  @blobs [:request_body, :response_body]

  @schema """
  CREATE TABLE IF NOT EXISTS turns (
    id INTEGER PRIMARY KEY,
    at TEXT NOT NULL,
    client TEXT NOT NULL,
    wire TEXT NOT NULL,
    requested_model TEXT,
    ad_id TEXT,
    performer_model TEXT,
    outcome TEXT NOT NULL,
    stop_reason TEXT,
    input_tokens INTEGER,
    output_tokens INTEGER,
    duration_ms INTEGER,
    error TEXT,
    request_body BLOB,
    response_body BLOB
  );
  CREATE INDEX IF NOT EXISTS turns_at ON turns (at);
  """

  @typedoc "A turn as recorded; see `t:AgentoWeb.Hub.Turn.summary/0`."
  @type row :: map()

  @typedoc "A running turn log: its registered name or pid."
  @type server :: GenServer.server()

  # --- API ---

  @doc """
  Start a turn log. Options: `:name` (default `#{inspect(__MODULE__)}`),
  `:data_dir`, `:retention_days`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Record a turn. Always `:ok`; never blocks, never raises."
  @spec record(row(), server()) :: :ok
  def record(row, server \\ __MODULE__) when is_map(row), do: GenServer.cast(server, {:record, row})

  @doc "The most recent turns, newest first."
  @spec recent(pos_integer(), server()) :: [row()]
  def recent(limit, server \\ __MODULE__) when is_integer(limit) and limit > 0,
    do: GenServer.call(server, {:recent, limit})

  @doc "Delete turns older than the retention, counted back from `now`."
  @spec prune(DateTime.t(), server()) :: {:ok, non_neg_integer()}
  def prune(%DateTime{} = now, server \\ __MODULE__), do: GenServer.call(server, {:prune, now})

  # --- server ---

  @impl true
  def init(opts) do
    state = %{db: open(Keyword.fetch!(opts, :data_dir)), retention_days: Keyword.get(opts, :retention_days, 30)}
    {_count, state} = do_prune(state, DateTime.utc_now())
    Process.send_after(self(), :prune, @prune_every_ms)
    {:ok, state}
  end

  @impl true
  def handle_cast({:record, _row}, %{db: nil} = state), do: {:noreply, state}

  def handle_cast({:record, row}, state) do
    case insert(state.db, row) do
      :ok -> :ok
      {:error, reason} -> Logger.error("turn log: could not record a turn, dropping it: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  @impl true
  def handle_call({:recent, _limit}, _from, %{db: nil} = state), do: {:reply, [], state}

  def handle_call({:recent, limit}, _from, state) do
    sql = "SELECT id, #{Enum.join(@columns, ", ")} FROM turns ORDER BY id DESC LIMIT ?1"

    rows =
      case query(state.db, sql, [limit]) do
        {:ok, rows} -> Enum.map(rows, &to_row/1)
        {:error, _reason} -> []
      end

    {:reply, rows, state}
  end

  def handle_call({:prune, now}, _from, state) do
    {count, state} = do_prune(state, now)
    {:reply, {:ok, count}, state}
  end

  @impl true
  def handle_info(:prune, state) do
    {_count, state} = do_prune(state, DateTime.utc_now())
    Process.send_after(self(), :prune, @prune_every_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{db: nil}), do: :ok
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  # --- database ---

  # Returns the connection, or nil when the database cannot be used. The hub
  # keeps serving either way.
  defp open(data_dir) do
    path = Path.join(data_dir, @file_name)

    with :ok <- ensure_dir(data_dir),
         :ok <- File.touch(path),
         :ok <- File.chmod(path, 0o600),
         {:ok, db} <- Sqlite3.open(path),
         :ok <- Sqlite3.execute(db, "PRAGMA journal_mode=WAL;"),
         :ok <- Sqlite3.execute(db, @schema) do
      db
    else
      error ->
        Logger.error("turn log: cannot use #{path}, turns will not be recorded: #{inspect(error)}")
        nil
    end
  end

  defp ensure_dir(dir) do
    if File.dir?(dir) do
      :ok
    else
      with :ok <- File.mkdir_p(dir), do: File.chmod(dir, 0o700)
    end
  end

  defp insert(db, row) do
    placeholders = Enum.map_join(1..length(@columns), ", ", &"?#{&1}")
    sql = "INSERT INTO turns (#{Enum.join(@columns, ", ")}) VALUES (#{placeholders})"

    case query(db, sql, Enum.map(@columns, &bind_value(&1, Map.get(row, &1)))) do
      {:ok, _rows} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp bind_value(_column, nil), do: nil
  defp bind_value(column, value) when column in @blobs, do: {:blob, value}
  defp bind_value(_column, value), do: value

  defp to_row([id | values]), do: @columns |> Enum.zip(values) |> Map.new() |> Map.put(:id, id)

  defp do_prune(%{db: nil} = state, _now), do: {0, state}

  defp do_prune(state, now) do
    cutoff = now |> DateTime.add(-state.retention_days * 86_400) |> DateTime.to_iso8601()

    count =
      with {:ok, _} <- query(state.db, "DELETE FROM turns WHERE at < ?1", [cutoff]),
           {:ok, [[count]]} <- query(state.db, "SELECT changes()", []) do
        count
      else
        {:error, reason} ->
          Logger.error("turn log: prune failed: #{inspect(reason)}")
          0
      end

    {count, state}
  end

  # Prepare, bind, step to completion, release. Returns the rows.
  defp query(db, sql, params) do
    with {:ok, statement} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(statement, params), do: steps(db, statement, [])
      after
        Sqlite3.release(db, statement)
      end
    end
  end

  defp steps(db, statement, acc) do
    case Sqlite3.step(db, statement) do
      {:row, row} -> steps(db, statement, [row | acc])
      :done -> {:ok, Enum.reverse(acc)}
      :busy -> {:error, :busy}
      {:error, _reason} = error -> error
    end
  end
end
