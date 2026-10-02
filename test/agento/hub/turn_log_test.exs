defmodule Agento.Hub.TurnLogTest do
  @moduledoc false

  use ExUnit.Case, async: true

  import Bitwise
  import ExUnit.CaptureLog

  alias Agento.Hub.TurnLog

  setup do
    dir = Path.join(System.tmp_dir!(), "turnlog_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp start(dir, opts \\ []) do
    name = :"turn_log_#{System.unique_integer([:positive])}"
    start_supervised!({TurnLog, [name: name, data_dir: dir] ++ opts}, id: name)
    name
  end

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        at: DateTime.utc_now() |> DateTime.to_iso8601(),
        client: "claude-code",
        wire: "anthropic",
        requested_model: "claude-sonnet-5-5",
        ad_id: "mdns:_llama._tcp:big.local:8080",
        performer_model: "big.gguf",
        outcome: "ok",
        stop_reason: "end_turn",
        input_tokens: 18_256,
        output_tokens: 6,
        duration_ms: 107_169,
        error: nil,
        request_body: <<"{\"a\":1} ", 255, 0, 254>>,
        response_body: ~s({"type":"message"})
      },
      overrides
    )
  end

  defp days_ago(days), do: DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.to_iso8601()

  defp mode(path), do: File.stat!(path).mode &&& 0o777

  test "a recorded turn comes back with every field, bodies byte for byte", %{dir: dir} do
    log = start(dir)
    recorded = row()

    assert :ok = TurnLog.record(recorded, log)
    assert [stored] = TurnLog.recent(10, log)
    assert Map.delete(stored, :id) == recorded
    assert is_integer(stored.id)
  end

  test "absent values stay absent", %{dir: dir} do
    log = start(dir)
    refused = row(%{ad_id: nil, performer_model: nil, stop_reason: nil, input_tokens: nil, output_tokens: nil,
                    outcome: "error", error: "no performer", response_body: nil})

    TurnLog.record(refused, log)
    assert [stored] = TurnLog.recent(10, log)
    assert Map.delete(stored, :id) == refused
  end

  test "the database is readable by its owner only", %{dir: dir} do
    start(dir)

    assert mode(dir) == 0o700
    assert mode(Path.join(dir, "hub_turns.sqlite")) == 0o600
  end

  test "an existing database with a wider mode is tightened", %{dir: dir} do
    File.mkdir_p!(dir)
    path = Path.join(dir, "hub_turns.sqlite")
    File.touch!(path)
    File.chmod!(path, 0o644)

    start(dir)
    assert mode(path) == 0o600
  end

  test "turns survive a restart", %{dir: dir} do
    name = :"turn_log_restart_#{System.unique_integer([:positive])}"
    start_supervised!({TurnLog, name: name, data_dir: dir}, id: name)
    TurnLog.record(row(), name)
    assert [_] = TurnLog.recent(10, name)
    stop_supervised!(name)

    again = start(dir)
    assert [%{client: "claude-code"}] = TurnLog.recent(10, again)
  end

  test "recent/2 is newest first and honours the limit", %{dir: dir} do
    log = start(dir)
    for model <- ~w(first second third), do: TurnLog.record(row(%{requested_model: model}), log)

    assert Enum.map(TurnLog.recent(10, log), & &1.requested_model) == ~w(third second first)
    assert Enum.map(TurnLog.recent(2, log), & &1.requested_model) == ~w(third second)
  end

  test "prune/2 deletes only rows older than the retention", %{dir: dir} do
    log = start(dir, retention_days: 30)

    for {days, model} <- [{40, "old"}, {20, "recent"}, {0, "now"}],
        do: TurnLog.record(row(%{at: days_ago(days), requested_model: model}), log)

    assert {:ok, 1} = TurnLog.prune(DateTime.utc_now(), log)
    assert Enum.map(TurnLog.recent(10, log), & &1.requested_model) |> Enum.sort() == ~w(now recent)
    assert {:ok, 0} = TurnLog.prune(DateTime.utc_now(), log)
  end

  test "old rows are pruned when the log starts", %{dir: dir} do
    name = :"turn_log_prune_#{System.unique_integer([:positive])}"
    start_supervised!({TurnLog, name: name, data_dir: dir, retention_days: 30}, id: name)
    TurnLog.record(row(%{at: days_ago(45), requested_model: "old"}), name)
    TurnLog.record(row(%{requested_model: "now"}), name)
    assert length(TurnLog.recent(10, name)) == 2
    stop_supervised!(name)

    again = start(dir, retention_days: 30)
    assert [%{requested_model: "now"}] = TurnLog.recent(10, again)
  end

  test "a data directory that cannot be created does not stop the hub", %{dir: dir} do
    File.mkdir_p!(dir)
    blocker = Path.join(dir, "a-file")
    File.write!(blocker, "x")

    log =
      capture_log(fn ->
        log = start(Path.join(blocker, "data"))
        send(self(), {:log, log})
      end)

    assert log =~ "turn log"
    assert_received {:log, name}

    assert :ok = TurnLog.record(row(), name)
    assert TurnLog.recent(10, name) == []
    assert {:ok, 0} = TurnLog.prune(DateTime.utc_now(), name)
  end

  test "recording to a log that is not running returns :ok" do
    assert :ok = TurnLog.record(row(), :no_such_turn_log)
  end

  test "a row the database rejects is logged and dropped, and the log keeps working", %{dir: dir} do
    log = start(dir)

    output =
      capture_log(fn ->
        TurnLog.record(row(%{client: nil}), log)
        assert TurnLog.recent(10, log) == []
      end)

    assert output =~ "turn log"

    TurnLog.record(row(), log)
    assert [_] = TurnLog.recent(10, log)
  end
end
