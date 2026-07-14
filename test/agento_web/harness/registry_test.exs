defmodule AgentoWeb.Harness.RegistryTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias AgentoWeb.Harness.Registry

  test "create returns a session with a fold of 0 and a lease" do
    {:ok, s} = Registry.create(:reg_test_a, 60_000)
    assert is_binary(s.id)
    assert s.fold == 0
    assert %DateTime{} = s.expires_at
    assert {:ok, ^s} = Registry.lookup(s.id)
  end

  test "unknown session is not found" do
    assert {:error, :not_found} = Registry.lookup("nope")
  end

  test "commit_turn advances the fold and memoizes frames for replay" do
    {:ok, s} = Registry.create(:reg_test_b, 60_000)
    frames = [%{"type" => "message", "data" => %{"content" => "hi"}}]
    {:ok, next} = Registry.commit_turn(s.id, 0, "hash0", frames)
    assert next == 1
    assert {:ok, 1} = Registry.current_fold(s.id)
    assert {:ok, ^frames} = Registry.replay(s.id, 0, "hash0")
    assert :miss = Registry.replay(s.id, 0, "other")
  end
end
