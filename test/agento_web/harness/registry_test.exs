defmodule AgentoWeb.Harness.RegistryTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias AgentoWeb.Harness.Registry

  defp config, do: %{agent_type: :default, model: "m", api_host: "h", allowed_tools: :all, llm_client: Stub}

  test "create returns a session with config, history, a fold of 0, and a lease" do
    {:ok, s} = Registry.create(config(), [%{role: "system", content: "sys"}], 60_000)
    assert is_binary(s.id)
    assert s.fold == 0
    assert s.config.agent_type == :default
    assert s.history == [%{role: "system", content: "sys"}]
    assert %DateTime{} = s.expires_at
    assert {:ok, ^s} = Registry.lookup(s.id)
  end

  test "unknown session is not found" do
    assert {:error, :not_found} = Registry.lookup("nope")
  end

  test "commit_turn advances the fold, sets history, and memoizes frames for replay" do
    {:ok, s} = Registry.create(config(), [], 60_000)
    frames = [%{"type" => "message", "data" => %{"content" => "hi"}}]
    history = [%{role: "user", content: "hi"}, %{role: "assistant", content: "yo"}]
    {:ok, next} = Registry.commit_turn(s.id, 0, "hash0", frames, history)
    assert next == 1
    assert {:ok, 1} = Registry.current_fold(s.id)
    assert {:ok, s2} = Registry.lookup(s.id)
    assert s2.history == history
    assert {:ok, ^frames} = Registry.replay(s.id, 0, "hash0")
    assert :miss = Registry.replay(s.id, 0, "other")
  end

  test "commit_turn advances from the session's actual fold, not a stale caller-supplied fold" do
    {:ok, s} = Registry.create(config(), [], 60_000)
    frames1 = [%{"type" => "message", "data" => %{"content" => "one"}}]
    frames2 = [%{"type" => "message", "data" => %{"content" => "two"}}]

    {:ok, next1} = Registry.commit_turn(s.id, 0, "h0", frames1, [])
    assert next1 == 1

    # Caller races/goes stale and re-sends fold 0. The session's real fold is
    # 1, so the commit must advance to 2, not fall back to 1.
    {:ok, next2} = Registry.commit_turn(s.id, 0, "h1", frames2, [])
    assert next2 == 2

    assert {:ok, 2} = Registry.current_fold(s.id)
  end
end
