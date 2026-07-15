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
  alias Agento.EventBusBridge

  @idle_close_ms 1_500

  def specification(conn, _params) do
    conn
    |> put_resp_content_type("application/json")
    |> json(Spec.document())
  end

  def agents(conn, _params), do: json(conn, %{"agents" => Catalog.agents()})
  def toolbox(conn, _params), do: json(conn, %{"tools" => Catalog.toolbox()})

  def create(conn, _params) do
    agent_type = Session.negotiate_agent(get_req_header(conn, "accept"))

    case Session.open(agent_type) do
      {:ok, session} ->
        conn
        |> put_status(201)
        |> json(%{
          "session_id" => session.id,
          "agent" => to_string(session.agent_type),
          "fold" => "fold_#{session.fold}",
          "expires_at" => DateTime.to_iso8601(session.expires_at)
        })

      {:error, reason} ->
        conn
        |> put_status(502)
        |> json(error_body("agent_start_failed", nil, "could not start agent: #{inspect(reason)}"))
    end
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
        Registry.renew(session.id)
        Phoenix.PubSub.subscribe(EventBusBridge.pubsub(), EventBusBridge.pubsub_topic())
        LLMAgent.prompt({:global, session.agent}, user_content)

        conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)
        {conn, frames} = stream_live(conn, session, req_ts, [])

        hash = Session.context_hash(context)
        {:ok, _next} = Registry.commit_turn(session.id, session.fold, hash, frames)
        conn
    end
  end

  defp stream_live(conn, session, req_ts, acc) do
    receive do
      {topic, %Comn.Events.EventStruct{} = event} ->
        case frame_for(topic, event, session.agent, req_ts, session.fold + 1) do
          nil ->
            stream_live(conn, session, req_ts, acc)

          frame ->
            {:ok, conn} = chunk(conn, Jason.encode!(frame) <> "\n")
            stream_live(conn, session, req_ts, [frame | acc])
        end

      _other ->
        # Ignore unrelated mailbox messages (e.g. Plug.Test's own {ref, response}
        # delivery for earlier requests dispatched in this same test process).
        stream_live(conn, session, req_ts, acc)
    after
      @idle_close_ms -> {conn, Enum.reverse(acc)}
    end
  end

  defp stream_static(conn, frames) do
    conn = conn |> put_resp_content_type("application/x-ndjson") |> send_chunked(200)

    Enum.reduce(frames, conn, fn frame, c ->
      {:ok, c} = chunk(c, Jason.encode!(frame) <> "\n")
      c
    end)
  end

  defp frame_for(topic, event, agent, req_ts, fold) do
    data = event.data || %{}
    if agent_of(data) == agent, do: build_frame(topic, data, req_ts, fold), else: nil
  end

  defp agent_of(data), do: data[:agent_id] || data["agent_id"]

  defp build_frame("agent.tool_dispatch", data, req_ts, fold),
    do: frame("tool_dispatch", data, req_ts, fold)

  defp build_frame("agent.error", data, req_ts, fold), do: frame("error", data, req_ts, fold)

  defp build_frame("tool." <> _name, data, req_ts, fold),
    do: frame("tool_result", data, req_ts, fold)

  defp build_frame("agent.message", %{role: "assistant"} = data, req_ts, fold),
    do: frame("message", data, req_ts, fold)

  defp build_frame("agent.message", %{"role" => "assistant"} = data, req_ts, fold),
    do: frame("message", data, req_ts, fold)

  defp build_frame(_topic, _data, _req_ts, _fold), do: nil

  defp frame(type, data, req_ts, fold) do
    %{"req_ts" => req_ts, "type" => type, "data" => sanitize(data), "fold" => "fold_#{fold}"}
  end

  defp sanitize(data) when is_map(data) do
    Map.new(data, fn {k, v} -> {to_string(k), sanitize_value(v)} end)
  end

  defp sanitize_value(v) when is_binary(v) and byte_size(v) > 4_000,
    do: String.slice(v, 0, 4_000) <> "...(truncated)"

  defp sanitize_value(v) when is_atom(v) and not is_boolean(v) and not is_nil(v), do: to_string(v)
  defp sanitize_value(v), do: v

  defp error_body(reason, field, message) do
    %{"error" => %{"reason" => reason, "field" => field, "message" => message, "suggestion" => nil}}
  end
end
