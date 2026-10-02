defmodule AgentoWeb.HubMessagesTest do
  @moduledoc """
  `POST /v1/messages` against a fake performer serving streams recorded from
  the live llama-servers, with request bodies captured from a real Claude
  Code client.
  """

  use AgentoWeb.ConnCase, async: false

  import AgentoWeb.HubCase

  alias AgentoWeb.Hub.Turn
  alias LLMAgent.Codec.Anthropic
  alias LLMAgent.Tool.Policy

  setup %{conn: conn} do
    reset_registry()
    config = install_config(default_host: "skynet-test.local")
    bypass = Bypass.open()
    ad = register(api_host: "http://localhost:#{bypass.port}", model: "performer.gguf")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token()}")
      |> put_req_header("content-type", "application/json")

    {:ok, conn: conn, bypass: bypass, ad: ad, config: config, client: hd(config.clients)}
  end

  defp serve(bypass, fixture_name, opts \\ []) do
    test = self()

    Bypass.expect_once(bypass, "POST", "/chat/completions", fn conn ->
      {:ok, request, conn} = Plug.Conn.read_body(conn)
      send(test, {:performer_request, Jason.decode!(request)})
      if delay = opts[:delay], do: Process.sleep(delay)

      conn
      |> Plug.Conn.put_resp_content_type(Keyword.get(opts, :content_type, "text/event-stream"))
      |> Plug.Conn.resp(Keyword.get(opts, :status, 200), Keyword.get(opts, :body) || fixture(fixture_name))
    end)
  end

  defp never_contacted(bypass) do
    Bypass.stub(bypass, "POST", "/chat/completions", fn _conn -> flunk("the performer was contacted") end)
  end

  defp error_body(conn, status) do
    assert %{"type" => "error", "error" => %{"type" => type, "message" => message}} = json_response(conn, status)
    {type, message}
  end

  describe "a streaming turn" do
    test "returns the performer's reply as an Anthropic event stream", ctx do
      serve(ctx.bypass, "openai_tool_stream.sse")
      conn = post(ctx.conn, "/v1/messages?beta=true", fixture("claude_code_request.json"))

      assert conn.status == 200
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/event-stream"
      assert get_resp_header(conn, "x-hub-performer") == [ctx.ad.id]
      assert get_resp_header(conn, "x-hub-billing") == ["local"]

      frames = sse_frames(conn.resp_body)
      assert {"message_start", start} = hd(frames)
      assert [{"message_delta", delta}, {"message_stop", _}] = Enum.take(frames, -2)

      requested = Jason.decode!(fixture("claude_code_request.json"))["model"]
      assert start["message"]["model"] == requested
      assert delta["delta"]["stop_reason"] == "tool_use"

      assert [%{"type" => "tool_use", "name" => "get_weather"}] =
               for({"content_block_start", %{"content_block" => %{"type" => "tool_use"} = block}} <- frames, do: block)
    end

    test "sends the performer its own model and a leading system message", ctx do
      serve(ctx.bypass, "openai_text_stream.sse")
      post(ctx.conn, "/v1/messages", fixture("claude_code_request.json"))

      assert_received {:performer_request, request}
      assert request["model"] == "performer.gguf"
      assert request["stream"] == true
      assert hd(request["messages"])["role"] == "system"
      assert length(request["tools"]) == length(Jason.decode!(fixture("claude_code_request.json"))["tools"])
    end

    test "carries a follow-up turn with a tool result", ctx do
      serve(ctx.bypass, "openai_text_stream.sse")
      conn = post(ctx.conn, "/v1/messages", fixture("claude_code_followup_request.json"))

      text =
        for {"content_block_delta", %{"delta" => %{"type" => "text_delta", "text" => text}}} <-
              sse_frames(conn.resp_body),
            into: "",
            do: text

      assert text == "hello there"

      assert_received {:performer_request, request}
      assert Enum.any?(request["messages"], &(&1["role"] == "tool"))
    end

    test "waits out a performer that is slow to its first byte", ctx do
      serve(ctx.bypass, "openai_text_stream.sse", delay: 1_500)
      conn = post(ctx.conn, "/v1/messages", fixture("claude_code_request.json"))

      assert conn.status == 200
      assert {"message_stop", _} = conn.resp_body |> sse_frames() |> List.last()
    end

    test "ends with an error frame when the performer's reply is cut short", ctx do
      whole = fixture("openai_tool_stream.sse")
      serve(ctx.bypass, nil, body: binary_part(whole, 0, div(byte_size(whole), 2)))
      conn = post(ctx.conn, "/v1/messages", fixture("claude_code_request.json"))

      assert conn.status == 200
      frames = sse_frames(conn.resp_body)
      assert {"message_start", _} = hd(frames)
      assert {"error", %{"error" => %{"type" => "api_error"}}} = List.last(frames)
    end
  end

  describe "a non-streaming turn" do
    test "returns one JSON message", ctx do
      serve(ctx.bypass, "openai_text_stream.sse")
      body = "claude_code_followup_request.json" |> fixture() |> Jason.decode!() |> Map.put("stream", false)
      conn = post(ctx.conn, "/v1/messages", Jason.encode!(body))

      assert %{"type" => "message", "role" => "assistant", "content" => content, "usage" => usage} =
               json_response(conn, 200)

      assert %{"type" => "text", "text" => "hello there"} = List.last(content)
      assert is_integer(usage["input_tokens"]) and is_integer(usage["output_tokens"])
      assert json_response(conn, 200)["model"] == body["model"]
      assert get_resp_header(conn, "x-hub-billing") == ["local"]
    end
  end

  describe "a request the hub refuses" do
    test "an unknown content block is a 400 naming it, and the performer is not contacted", ctx do
      never_contacted(ctx.bypass)

      body =
        "claude_code_request.json"
        |> fixture()
        |> Jason.decode!()
        |> Map.update!("messages", &(&1 ++ [%{"role" => "assistant", "content" => [%{"type" => "server_tool_use"}]}]))

      assert {"invalid_request_error", message} = ctx.conn |> post("/v1/messages", Jason.encode!(body)) |> error_body(400)
      assert message =~ "server_tool_use"
    end

    test "a body that is not a Messages request is a 400", ctx do
      never_contacted(ctx.bypass)
      assert {"invalid_request_error", _} = ctx.conn |> post("/v1/messages", ~s({"model": "m"})) |> error_body(400)
    end

    test "malformed JSON is a 400", ctx do
      never_contacted(ctx.bypass)
      assert_error_sent 400, fn -> post(ctx.conn, "/v1/messages", ~s({"model": )) end
    end

    test "no token is a 401 before anything else", ctx do
      never_contacted(ctx.bypass)
      conn = ctx.conn |> delete_req_header("authorization") |> post("/v1/messages", fixture("claude_code_request.json"))
      assert {"authentication_error", _} = error_body(conn, 401)
    end

    test "with no performer the answer is a 404 naming the model", ctx do
      reset_registry()
      never_contacted(ctx.bypass)

      assert {"not_found_error", message} =
               ctx.conn |> post("/v1/messages", fixture("claude_code_request.json")) |> error_body(404)

      assert message =~ Jason.decode!(fixture("claude_code_request.json"))["model"]
    end
  end

  describe "a performer that fails before replying" do
    test "a chat-template failure is a 502 carrying the performer's message, as JSON", ctx do
      serve(ctx.bypass, "openai_error_500_template.json", status: 500, content_type: "application/json")
      conn = post(ctx.conn, "/v1/messages", fixture("claude_code_request.json"))

      assert {"api_error", message} = error_body(conn, 502)
      assert message =~ Jason.decode!(fixture("openai_error_500_template.json"))["error"]["message"] |> String.slice(0, 40)
      assert hd(get_resp_header(conn, "content-type")) =~ "application/json"
      assert get_resp_header(conn, "x-hub-performer") == [ctx.ad.id]
    end

    test "a performer that is down is a 502", ctx do
      Bypass.down(ctx.bypass)
      assert {"api_error", _} = ctx.conn |> post("/v1/messages", fixture("claude_code_request.json")) |> error_body(502)
    end

    test "an empty reply is a 502, not an empty stream", ctx do
      serve(ctx.bypass, nil, body: "")
      assert {"api_error", _} = ctx.conn |> post("/v1/messages", fixture("claude_code_request.json")) |> error_body(502)
    end

    test "a performer silent past the timeout is a 504", ctx do
      reset_registry()
      {host, performer} = stalling_performer()
      register(api_host: host, model: "performer.gguf")
      install_config(default_host: "skynet-test.local", performer_timeout_ms: 200)

      assert {"api_error", message} =
               ctx.conn |> post("/v1/messages", fixture("claude_code_request.json")) |> error_body(504)

      assert message =~ "timed out"
      assert Task.await(performer, 6_000) == :closed
    end
  end

  describe "the turn log" do
    alias Agento.Hub.TurnLog

    # A model name no other test uses, so the newest row is unambiguously ours.
    defp unique_request(name \\ "claude_code_request.json") do
      model = "model-#{System.unique_integer([:positive])}"
      # Keep the whitespace odd, to prove the stored bytes are the sent bytes.
      body = name |> fixture() |> Jason.decode!() |> Map.put("model", model) |> Jason.encode!(pretty: true)
      {model, body}
    end

    test "a successful turn is recorded with both bodies, the request byte for byte", ctx do
      serve(ctx.bypass, "openai_text_stream.sse")
      {model, body} = unique_request()
      assert post(ctx.conn, "/v1/messages?beta=true", body).status == 200

      assert [row] = TurnLog.recent(1)

      assert %{
               requested_model: ^model,
               client: "test-client",
               wire: "anthropic",
               outcome: "ok",
               stop_reason: "end_turn",
               error: nil
             } = row

      assert row.ad_id == ctx.ad.id
      assert is_binary(row.performer_model)
      assert is_integer(row.input_tokens) and is_integer(row.output_tokens)
      assert row.request_body == body
      assert %{"type" => "message", "content" => content} = Jason.decode!(row.response_body)
      assert %{"type" => "text", "text" => "hello there"} = List.last(content)
    end

    test "a turn with no performer is recorded as an error with no ad", ctx do
      reset_registry()
      {model, body} = unique_request()
      assert post(ctx.conn, "/v1/messages", body).status == 404

      assert [%{requested_model: ^model, outcome: "error", ad_id: nil, response_body: nil} = row] = TurnLog.recent(1)
      assert row.error =~ model
      assert row.request_body == body
    end

    test "a turn the performer failed is recorded as an error", ctx do
      Bypass.down(ctx.bypass)
      {model, body} = unique_request()
      assert post(ctx.conn, "/v1/messages", body).status == 502

      assert [%{requested_model: ^model, outcome: "error", response_body: nil} = row] = TurnLog.recent(1)
      assert row.ad_id == ctx.ad.id
      assert is_binary(row.error)
    end

    test "a request the hub could not decode is not recorded", ctx do
      {model, _body} = unique_request()
      assert post(ctx.conn, "/v1/messages", Jason.encode!(%{"model" => model})).status == 400

      refute Enum.any?(TurnLog.recent(5), &(&1.requested_model == model))
    end

    test "the client is served even when the turn log is not running", ctx do
      :ok = Supervisor.terminate_child(Agento.Supervisor, TurnLog)
      on_exit(fn -> Supervisor.restart_child(Agento.Supervisor, TurnLog) end)

      serve(ctx.bypass, "openai_text_stream.sse")
      conn = post(ctx.conn, "/v1/messages", fixture("claude_code_request.json"))

      assert conn.status == 200
      assert {"message_stop", _} = conn.resp_body |> sse_frames() |> List.last()
    end
  end

  describe "Turn.run/5" do
    defp turn(name \\ "claude_code_request.json") do
      {:ok, turn} = name |> fixture() |> Jason.decode!() |> Anthropic.decode_request()
      turn
    end

    defp test_conn(body) do
      Phoenix.ConnTest.build_conn(:post, "/v1/messages", body) |> Plug.Conn.put_private(:raw_body, body)
    end

    test "summarises a successful turn", ctx do
      serve(ctx.bypass, "openai_tool_stream.sse")
      body = fixture("claude_code_request.json")

      assert {conn, summary} = Turn.run(test_conn(body), turn(), ctx.ad, ctx.client, ctx.config)
      assert conn.status == 200

      assert %{
               client: "test-client",
               wire: "anthropic",
               ad_id: ad_id,
               performer_model: performer_model,
               outcome: "ok",
               stop_reason: "tool_use",
               error: nil
             } = summary

      assert ad_id == ctx.ad.id
      assert is_binary(performer_model)
      assert summary.requested_model == turn().model
      assert is_integer(summary.input_tokens) and is_integer(summary.output_tokens)
      assert is_integer(summary.duration_ms) and summary.duration_ms >= 0
      assert {:ok, _, _} = DateTime.from_iso8601(summary.at)
      assert summary.request_body == body
      assert %{"type" => "message", "stop_reason" => "tool_use"} = Jason.decode!(summary.response_body)
    end

    test "summarises a failed turn", ctx do
      Bypass.down(ctx.bypass)

      assert {conn, summary} = Turn.run(test_conn("{}"), turn(), ctx.ad, ctx.client, ctx.config)
      assert conn.status == 502
      assert %{outcome: "error", stop_reason: nil, response_body: nil, input_tokens: nil} = summary
      assert is_binary(summary.error)
    end

    test "a client whose policy allows nothing is a 403 and the performer is not contacted", ctx do
      never_contacted(ctx.bypass)
      client = %{ctx.client | policy: %Policy{}}

      assert {conn, summary} = Turn.run(test_conn("{}"), turn(), ctx.ad, client, ctx.config)
      assert {"permission_error", _} = error_body(conn, 403)
      assert summary.outcome == "error"
    end

    test "when the client's process dies mid-stream the performer is cut off and nothing is left running", ctx do
      whole = fixture("openai_text_stream.sse")
      {host, performer} = stalling_performer(binary_part(whole, 0, div(byte_size(whole), 2)))
      ad = llama_ad(id: "stalling.1", api_host: host, model: "performer.gguf")
      before = Task.Supervisor.children(LLMAgent.TaskSup)

      caller = spawn(fn -> Turn.run(test_conn("{}"), turn(), ad, ctx.client, ctx.config) end)
      Process.sleep(400)
      assert Task.Supervisor.children(LLMAgent.TaskSup) -- before != []

      Process.exit(caller, :kill)

      assert Task.await(performer, 6_000) == :closed
      Process.sleep(100)
      assert Task.Supervisor.children(LLMAgent.TaskSup) -- before == []
    end
  end
end
