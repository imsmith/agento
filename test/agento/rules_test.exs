defmodule Agento.RulesTest do
  use ExUnit.Case, async: false

  alias Agento.Rules

  @id "rules-test.rule"

  setup do
    on_exit(fn -> Rules.unload(@id) end)
    :ok
  end

  test "the runtime is up, watching the test directory, with the substrate attached" do
    snapshot = Rules.snapshot()
    assert snapshot.available
    assert snapshot.dir == Application.get_env(:agento, :rules_dir)
    assert "EVENT" in snapshot.modules
    assert snapshot.tools == []
    assert is_list(snapshot.verbs)
  end

  test "load, explain, dispatch, trace, unload" do
    assert :ok =
             Rules.load(
               @id,
               ~s|rule greet { context "hub" { when HUB_REQUEST { log ?client } } }|
             )

    assert %{rules: [%{rule: "greet", policy: @id, outcome: :fires}]} =
             Rules.explain("HUB_REQUEST", "hub.request")

    assert %{rules: [%{outcome: :context_mismatch}]} = Rules.explain("HUB_REQUEST", "elsewhere")

    LLMAgent.Events.emit(:turn, "hub.request", %{client: "pi"}, :test)

    await(fn ->
      Enum.any?(
        Rules.snapshot().trace,
        &(&1.event == "HUB_REQUEST" and &1.results == [%{type: :log, value: "pi"}])
      )
    end)

    assert [%{id: @id, rules: ["greet"], status: nil}] =
             Enum.filter(Rules.snapshot().policies, &(&1.id == @id))

    assert :ok = Rules.unload(@id)
    assert Rules.explain("HUB_REQUEST", "") == %{rules: [], conditions: []}
  end

  test "a file in the directory is deployed and shows as such" do
    path = Path.join(Rules.dir(), "from-file.rule")
    File.mkdir_p!(Rules.dir())
    File.write!(path, ~s|rule filed { when NEVER_SENT { log "x" } }|)
    on_exit(fn -> File.rm(path) end)

    await(fn -> Enum.any?(Rules.snapshot().policies, &(&1.id == "from-file.rule")) end, 300)

    assert [%{status: :ok, rules: ["filed"]}] =
             Enum.filter(Rules.snapshot().policies, &(&1.id == "from-file.rule"))

    File.rm!(path)
    await(fn -> not Enum.any?(Rules.snapshot().policies, &(&1.id == "from-file.rule")) end, 300)
  end

  test "a runtime that does not answer leaves the snapshot readable" do
    dispatcher = Process.whereis(:"#{Rules.runtime()}.dispatcher")
    :sys.suspend(dispatcher)

    try do
      snapshot = Rules.snapshot()
      refute snapshot.available
      assert is_list(snapshot.trace)
      assert %{unavailable: true} = Rules.explain("ANYTHING", "")
    after
      :sys.resume(dispatcher)
    end
  end

  defp await(fun, tries \\ 100) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("never happened")
      true -> Process.sleep(10) && await(fun, tries - 1)
    end
  end
end
