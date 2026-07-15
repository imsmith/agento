defmodule AgentoWeb.HarnessController do
  @moduledoc """
  HTTP boundary for the harness API. Parses/validates requests, delegates to
  `AgentoWeb.Harness.*`, and maps results to responses. No orchestration logic.
  """
  use AgentoWeb, :controller

  alias AgentoWeb.Harness.Catalog
  alias AgentoWeb.Harness.Registry
  alias AgentoWeb.Harness.Session
  alias AgentoWeb.Harness.Spec
  alias AgentoWeb.Harness.Turn

  # Safety ceiling on how long the controller waits for a turn to finish before
  # closing the stream. Not a completion heuristic — the turn signals done.
  @turn_timeout_ms 180_000

  def specification(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Spec.document())
  end

  def agents(conn, _params), do: json(conn, %{"agents" => Catalog.agents()})
  def toolbox(conn, _params), do: json(conn, %{"tools" => Catalog.toolbox()})

  def create(conn, _params) do
    agent_type = Session.negotiate_agent(get_req_header(conn, "accept"))
    {:ok, session} = Session.open(agent_type)

    conn
    |> put_status(201)
    |> json(%{
      "session_id" => session.id,
      "agent" => to_string(session.config.agent_type),
      "fold" => "fold_#{session.fold}",
      "expires_at" => DateTime.to_iso8601(session.expires_at)
    })
  end

  def interact(conn, %{"session_id" => sid} = params) do
    req_ts = DateTime.utc_now() |> DateTime.to_iso8601()
    fold_str = Map.get(params, "fold", "fold_0")
    context = Map.get(params, "context", [])

    case Registry.lookup(sid) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(error_body("unknown_session", "session_id", "no such session"))

      {:ok, session} ->
        do_interact(conn, session, fold_str, context, req_ts)
    end
  end

  defp do_interact(conn, session, fold_str, context, req_ts) do
    case Session.reconcile(session.id, fold_str, context) do
      {:error, :not_found} ->
        conn |> put_status(404) |> json(error_body("unknown_session", "session_id", "no such session"))

      {:diverged, current} ->
        conn
        |> put_status(409)
        |> json(%{"error" => %{"reason" => "fold_diverged"}, "fold" => current})

      {:replay, frames} ->
        stream_static(conn, frames)

      {:process, user_content} ->
        run_turn(conn, session, context, user_content, req_ts)
    end
  end

  # Run the turn in a task, streaming each frame to this process, then commit.
  defp run_turn(conn, session, context, user_content, req_ts) do
    Registry.renew(session.id)
    fold_str = "fold_#{session.fold + 1}"
    parent = self()

    Task.start(fn ->
      emit = fn frame -> send(parent, {:frame, frame}) end
      {:ok, history} = Turn.run(session.config, session.history, user_content, emit)
      send(parent, {:turn_done, history})
    end)

    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)
    {conn, frames, history} = collect(conn, req_ts, fold_str, [])

    # Only commit when the turn actually completed (history present). On a
    # mid-stream client disconnect we leave the session untouched so a retry
    # reprocesses rather than committing a partial turn.
    if history do
      hash = Session.context_hash(context)
      {:ok, _next} = Registry.commit_turn(session.id, session.fold, hash, frames, history)
    end

    conn
  end

  defp collect(conn, req_ts, fold_str, acc) do
    receive do
      {:frame, frame} ->
        wrapped = Map.merge(frame, %{"req_ts" => req_ts, "fold" => fold_str})

        case chunk(conn, Jason.encode!(wrapped) <> "\n") do
          {:ok, conn} -> collect(conn, req_ts, fold_str, [wrapped | acc])
          # Client disconnected mid-stream — stop; do not commit (history nil).
          {:error, _reason} -> {conn, Enum.reverse(acc), nil}
        end

      {:turn_done, history} ->
        {conn, Enum.reverse(acc), history}
    after
      @turn_timeout_ms -> {conn, Enum.reverse(acc), nil}
    end
  end

  defp stream_static(conn, frames) do
    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

    Enum.reduce(frames, conn, fn frame, c ->
      {:ok, c} = chunk(c, Jason.encode!(frame) <> "\n")
      c
    end)
  end

  defp error_body(reason, field, message) do
    %{"error" => %{"reason" => reason, "field" => field, "message" => message, "suggestion" => nil}}
  end
end
