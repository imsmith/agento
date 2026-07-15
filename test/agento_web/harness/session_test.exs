defmodule AgentoWeb.Harness.SessionTest do
  @moduledoc false
  use ExUnit.Case, async: false

  alias AgentoWeb.Harness.{Registry, Session}

  test "fold token round-trips" do
    assert Session.fold_token(3) == "fold_3"
    assert Session.parse_fold("fold_3") == {:ok, 3}
    assert Session.parse_fold("garbage") == :error
  end

  test "reconcile: current fold → process the last user turn" do
    {:ok, s} = Registry.create(:sess_test_a, 60_000)
    ctx = [%{"role" => "user", "content" => "hello"}]
    assert {:process, "hello"} = Session.reconcile(s.id, "fold_0", ctx)
  end

  test "reconcile: stale-but-matching fold → replay stored frames" do
    {:ok, s} = Registry.create(:sess_test_b, 60_000)
    ctx = [%{"role" => "user", "content" => "hi"}]
    hash = Session.context_hash(ctx)
    frames = [%{"type" => "message"}]
    {:ok, 1} = Registry.commit_turn(s.id, 0, hash, frames)
    assert {:replay, ^frames} = Session.reconcile(s.id, "fold_0", ctx)
  end

  test "reconcile: stale non-matching fold → diverged with current fold" do
    {:ok, s} = Registry.create(:sess_test_c, 60_000)
    {:ok, 1} = Registry.commit_turn(s.id, 0, "otherhash", [])
    ctx = [%{"role" => "user", "content" => "new"}]
    assert {:diverged, "fold_1"} = Session.reconcile(s.id, "fold_0", ctx)
  end

  test "reconcile: unknown session with malformed fold → error not_found" do
    assert {:error, :not_found} = Session.reconcile("no_such_session", "garbage", [])
  end

  test "reconcile: known session with malformed fold → diverged with real current fold" do
    {:ok, s} = Registry.create(:sess_test_d, 60_000)
    {:ok, 1} = Registry.commit_turn(s.id, 0, "otherhash", [])
    ctx = [%{"role" => "user", "content" => "new"}]
    assert {:diverged, "fold_1"} = Session.reconcile(s.id, "garbage", ctx)
  end
end
