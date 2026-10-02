defmodule AgentoWeb.Hub.Turn do
  @moduledoc """
  Runs one hub turn: dispatches a canonical turn to a performer through
  `LLMAgent.Tool.Dispatcher.generate/4` and writes the reply to the client in
  Anthropic's wire format.

  A turn is a function call over the connection. Nothing is kept between
  requests.

  ## Two processes

  The response must be written by the process that owns the connection, and
  the dispatcher's `into` callback runs wherever `generate/4` runs. So the
  dispatch runs in a task and the connection process writes: for each
  canonical event the task sends it here and waits for `:cont` or `:halt`.
  That gives backpressure, and lets a failed write halt the performer.

  The two processes watch each other rather than link. A real listener's
  connection process traps exits, so a link would neither kill it nor tell
  it anything it is waiting for:

    * if the task dies — a crash inside the dispatch — the connection
      process sees the monitor's `:DOWN` and answers with an error instead
      of waiting forever;
    * if the connection process dies, a watcher kills the task, which closes
      its connection to the performer, so a client that vanishes does not
      leave a performer generating for nobody.

  One case is not caught: a client that hangs up while nothing is being
  written — while the performer is still silent, between its chunks, or
  during a non-streaming turn. Nothing fails until the next write, so the
  turn runs on until then.

  ## When the response starts

  Nothing is sent until the performer's first event arrives. Until then a
  failure is still an ordinary error response with a truthful status — 403
  refused by policy, 502 performer failure, 504 performer timeout. After the
  stream has started the status is already 200, so a failure becomes an
  `error` frame.

  ## Summary

  `run/5` also returns a summary of the turn — who asked, which performer
  served it, how it ended, what it cost in tokens, and both bodies — which
  is what the turn log records.
  """

  import Plug.Conn

  alias Agento.Hub.Config
  alias AgentoWeb.Hub.RawBody
  alias LLMAgent.Codec.Anthropic
  alias LLMAgent.{ToolAd, Turn}
  alias LLMAgent.Tool.Dispatcher
  alias LLMAgent.Turn.Fold

  @typedoc "One turn as the turn log records it."
  @type summary :: %{
          at: String.t(),
          client: String.t(),
          wire: String.t(),
          requested_model: String.t() | nil,
          ad_id: String.t() | nil,
          performer_model: String.t() | nil,
          outcome: String.t(),
          stop_reason: String.t() | nil,
          input_tokens: integer() | nil,
          output_tokens: integer() | nil,
          duration_ms: non_neg_integer(),
          error: String.t() | nil,
          request_body: binary(),
          response_body: binary() | nil
        }

  @doc "Run `turn` against `ad` for `client`, replying on `conn`."
  @spec run(Plug.Conn.t(), Turn.t(), ToolAd.t(), Config.client(), Config.t()) ::
          {Plug.Conn.t(), summary()}
  def run(conn, %Turn{} = turn, %ToolAd{} = ad, client, %Config{} = config) do
    started = System.monotonic_time(:millisecond)
    at = now()
    ref = make_ref()
    owner = self()

    conn =
      conn
      |> put_resp_header("x-hub-performer", ad.id)
      |> put_resp_header("x-hub-billing", billing(ad))

    task =
      Task.Supervisor.async_nolink(LLMAgent.TaskSup, fn ->
        kill_when_gone(owner, self())

        into = fn event ->
          send(owner, {ref, :event, event, self()})

          receive do
            {^ref, verdict} -> verdict
          end
        end

        Dispatcher.generate(ad, "chat", %{turn: turn},
          policy: client.policy,
          into: into,
          timeout: config.performer_timeout_ms
        )
      end)

    state = %{
      conn: conn,
      ref: ref,
      task: task,
      stream: turn.stream,
      started: false,
      aborted: false,
      encoder: Anthropic.stream_encoder(model: turn.model),
      fold: Fold.new()
    }

    {state, result} = await(state)
    {conn, outcome, error} = conclude(state, result, turn)

    summary =
      base_summary(conn, turn, client, at, started)
      |> Map.merge(%{ad_id: ad.id, outcome: outcome, error: error})
      |> Map.merge(folded(state.fold, turn))

    {conn, summary}
  end

  @doc """
  The summary of a turn that was refused before any performer was chosen,
  for example because none could serve it.
  """
  @spec refused(Plug.Conn.t(), Turn.t(), Config.client(), String.t()) :: summary()
  def refused(conn, %Turn{} = turn, client, error) do
    conn
    |> base_summary(turn, client, now(), System.monotonic_time(:millisecond))
    |> Map.merge(%{outcome: "error", error: error})
  end

  # Says "local" only for a performer the mDNS shim found on this network.
  # Anything else is reached with a credential and billed to it.
  defp billing(%ToolAd{provenance: %{source: "mdns/" <> _}}), do: "local"
  defp billing(%ToolAd{}), do: "api-key"

  # Kills `task` if `owner` dies first; goes away quietly when the task ends.
  defp kill_when_gone(owner, task) do
    spawn(fn ->
      owner_ref = Process.monitor(owner)
      task_ref = Process.monitor(task)

      receive do
        {:DOWN, ^owner_ref, :process, _pid, _reason} -> Process.exit(task, :kill)
        {:DOWN, ^task_ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  defp base_summary(conn, turn, client, at, started) do
    %{
      at: at,
      client: client.name,
      wire: "anthropic",
      requested_model: turn.model,
      ad_id: nil,
      performer_model: nil,
      outcome: "error",
      stop_reason: nil,
      input_tokens: nil,
      output_tokens: nil,
      duration_ms: System.monotonic_time(:millisecond) - started,
      error: nil,
      request_body: RawBody.get(conn) || "",
      response_body: nil
    }
  end

  defp now, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # --- the connection process's side of the conversation with the task ---

  defp await(%{ref: ref, task: %Task{ref: task_ref}} = state) do
    receive do
      {^ref, :event, event, from} ->
        {state, verdict} = handle_event(state, event)
        send(from, {ref, verdict})
        await(state)

      {^task_ref, result} ->
        Process.demonitor(task_ref, [:flush])
        {state, result}

      {:DOWN, ^task_ref, :process, _pid, reason} ->
        {state, {:error, {:dispatch_crashed, reason}}}
    end
  end

  defp handle_event(state, event) do
    state = %{state | fold: Fold.step(state.fold, event)}

    cond do
      not state.stream -> {state, :cont}
      # An error before anything was sent can still be a proper error response.
      not state.started and match?({:error, _}, event) -> {state, :cont}
      true -> write(open(state), event)
    end
  end

  defp open(%{started: true} = state), do: state

  defp open(state) do
    conn = state.conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)
    %{state | conn: conn, started: true}
  end

  defp write(state, event) do
    {frames, encoder} = Anthropic.encode_stream(state.encoder, event)
    state = %{state | encoder: encoder}

    case chunk(state.conn, frames) do
      {:ok, conn} -> {%{state | conn: conn}, :cont}
      {:error, _closed} -> {%{state | aborted: true}, :halt}
    end
  end

  # --- turning the dispatcher's result into the end of the response ---

  defp conclude(%{aborted: true} = state, _result, _turn),
    do: {state.conn, "aborted", "client disconnected"}

  defp conclude(%{started: true} = state, {:ok, _message, _provenance}, _turn),
    do: {state.conn, "ok", nil}

  # The stream is open and the performer failed. Usually the error frame went
  # out when the error event arrived; a failure that produced no event gets
  # its frame here, so the stream never just stops. The encoder ignores
  # everything after its first error, which makes this safe to do always.
  defp conclude(%{started: true} = state, error, _turn) do
    reason = reason(error)
    {state, _verdict} = write(state, {:error, describe(reason)})
    {state.conn, "error", describe(reason)}
  end

  defp conclude(state, {:ok, _message, _provenance}, turn) do
    {:ok, result} = Fold.result(state.fold)
    body = Anthropic.encode_response(result, model: turn.model)
    {send_json(state.conn, 200, body), "ok", nil}
  end

  defp conclude(state, error, _turn) do
    reason = reason(error)
    {status, message} = status_for(reason)

    {send_json(state.conn, status, Anthropic.encode_error(status, message)), "error",
     describe(reason)}
  end

  defp reason({:error, :forbidden, why}), do: {:forbidden, why}
  defp reason({:error, reason}), do: reason
  defp reason(other), do: other

  defp status_for({:forbidden, _why}),
    do: {403, "this client's policy does not permit that performer"}

  defp status_for({:http_error, status, body}),
    do: {502, "the performer answered #{status}: #{performer_message(body)}"}

  defp status_for(%{reason: :timeout}), do: {504, "the performer timed out before replying"}

  defp status_for(:incomplete_stream),
    do: {502, "the performer ended its reply without finishing"}

  defp status_for(%{__exception__: true} = error),
    do: {502, "the performer could not be reached: #{Exception.message(error)}"}

  defp status_for(_other), do: {502, "the performer failed"}

  defp performer_message(%{"error" => %{"message" => message}}) when is_binary(message),
    do: String.slice(message, 0, 500)

  defp performer_message(body) when is_binary(body), do: String.slice(body, 0, 500)
  defp performer_message(_body), do: "no message"

  # What the turn log keeps: short, and free of internal structure.
  defp describe({:forbidden, why}), do: "forbidden: #{why}"
  defp describe({:dispatch_crashed, _reason}), do: "the dispatch crashed"

  defp describe({:http_error, status, body}),
    do: "performer answered #{status}: #{performer_message(body)}"

  defp describe(%{__exception__: true} = error), do: Exception.message(error)
  defp describe(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(reason) when is_binary(reason), do: reason

  defp describe(reason),
    do: reason |> inspect(limit: 5, printable_limit: 200) |> String.slice(0, 300)

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp folded(fold, turn) do
    case Fold.result(fold) do
      {:ok, result} ->
        %{
          performer_model: result.model,
          stop_reason: Atom.to_string(result.stop_reason),
          input_tokens: result.usage.input_tokens,
          output_tokens: result.usage.output_tokens,
          response_body: result |> Anthropic.encode_response(model: turn.model) |> Jason.encode!()
        }

      {:error, _reason} ->
        %{}
    end
  end
end
