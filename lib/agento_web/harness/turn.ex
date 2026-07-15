defmodule AgentoWeb.Harness.Turn do
  @moduledoc """
  Runs one harness turn over a session's conversation — statelessly, in the
  caller's process (or a task it spawns). This is the "backend as a work pool"
  side of the harness: the session lives as a record in `Harness.Registry`; a
  turn composes LLMAgent's standalone competence (the LLM client, the tool
  registry) over that record and streams frames out via an `emit` callback.

  No per-session process, no registered name — the turn is a function call.
  """

  alias Comn.Errors.ErrorStruct

  @max_tool_rounds 8
  @default_timeout_ms 120_000

  @typedoc "Turn configuration pulled from the session record."
  @type config :: %{
          required(:model) => String.t(),
          required(:api_host) => String.t(),
          required(:llm_client) => module(),
          required(:allowed_tools) => :all | [atom()],
          optional(:timeout) => pos_integer()
        }

  @doc """
  Run a turn: append `user_content` to `history`, drive the LLM/tool loop, and
  call `emit.(frame)` for each result frame produced. `frame` is a string-keyed
  map `%{"type" => ..., "data" => ...}` (the caller wraps it with req_ts/fold).
  Returns `{:ok, new_history}` — the updated canonical conversation.
  """
  @spec run(config(), [map()], String.t(), (map() -> any())) :: {:ok, [map()]}
  def run(config, history, user_content, emit) when is_function(emit, 1) do
    messages = history ++ [%{role: "user", content: user_content}]
    loop(messages, config, emit, @max_tool_rounds)
  end

  # -- Loop --

  defp loop(messages, _config, emit, 0) do
    emit.(%{
      "type" => "error",
      "data" => %{"reason" => "max_tool_rounds", "message" => "tool loop exceeded #{@max_tool_rounds} rounds"}
    })

    {:ok, messages}
  end

  defp loop(messages, config, emit, rounds) do
    opts = %{
      api_host: config.api_host,
      model: config.model,
      timeout: Map.get(config, :timeout, @default_timeout_ms)
    }

    case config.llm_client.chat(messages, opts) do
      {:ok, content} ->
        handle_content(content, messages, config, emit, rounds)

      {:error, reason} ->
        emit.(%{
          "type" => "error",
          "data" => %{"reason" => "llm_request_failed", "message" => inspect(reason)}
        })

        {:ok, messages}
    end
  end

  defp handle_content(content, messages, config, emit, rounds) do
    case parse_tool_call(content) do
      {:tool_call, tool, action, args} ->
        emit.(%{"type" => "tool_dispatch", "data" => %{"tool" => to_string(tool), "action" => action}})

        result = dispatch(tool, action, args, config.allowed_tools)
        emit.(%{"type" => "tool_result", "data" => result_frame_data(result)})

        messages =
          messages ++
            [
              %{role: "assistant", content: content},
              %{role: "function", content: format_result(result)}
            ]

        loop(messages, config, emit, rounds - 1)

      :not_a_tool_call ->
        emit.(%{"type" => "message", "data" => %{"role" => "assistant", "content" => content}})
        {:ok, messages ++ [%{role: "assistant", content: content}]}
    end
  end

  # -- Tool dispatch (public registry, gated by the session's allow-list) --

  defp dispatch(tool, action, args, allowed) do
    if allowed?(tool, allowed) do
      case LLMAgent.Tools.get(tool) do
        {:ok, mod} -> perform(mod, action, args)
        {:error, :not_found} -> {:error, {:not_found, tool}}
      end
    else
      {:error, {:not_permitted, tool}}
    end
  end

  defp perform(mod, action, args) do
    mod.perform(action, args)
  rescue
    # A tool that raises should surface as a tool error, not crash the turn.
    e in [ArgumentError, RuntimeError, KeyError, MatchError] ->
      {:error, {:exception, Exception.message(e)}}
  end

  defp allowed?(_tool, :all), do: true
  defp allowed?(tool, list) when is_list(list), do: tool in list
  defp allowed?(_tool, _), do: false

  # -- Tool-call parsing (bounded: to_existing_atom, so no atom growth) --

  defp parse_tool_call(content) do
    case Jason.decode(strip_code_fences(content)) do
      {:ok, %{"tool" => tool, "action" => action, "args" => args}} when is_binary(tool) ->
        to_tool_call(tool, action, args)

      _ ->
        :not_a_tool_call
    end
  end

  defp to_tool_call(tool, action, args) do
    {:tool_call, String.to_existing_atom(tool), action, args}
  rescue
    # Unknown tool name from the model — not a real tool, so not a tool call.
    # `to_existing_atom` also means a hallucinated name never mints a new atom.
    ArgumentError -> :not_a_tool_call
  end

  # Small models often wrap tool-call JSON in a markdown code fence; strip a
  # single leading/trailing fence so the payload decodes.
  defp strip_code_fences(content) when is_binary(content) do
    trimmed = String.trim(content)

    case Regex.run(~r/\A```(?:[a-zA-Z0-9_-]+)?\n(.*)\n```\z/s, trimmed) do
      [_, inner] -> String.trim(inner)
      _ -> trimmed
    end
  end

  defp strip_code_fences(content), do: content

  # -- Result shaping --

  # Fed back to the LLM as the "function" message content (a JSON string).
  defp format_result({:ok, %{output: output, metadata: metadata}}) do
    Jason.encode!(%{status: "ok", output: output, metadata: metadata})
  end

  defp format_result({:error, %ErrorStruct{} = err}) do
    Jason.encode!(%{status: "error", error: %{reason: err.reason, message: err.message}})
  end

  defp format_result({:error, other}) do
    Jason.encode!(%{status: "error", error: inspect(other)})
  end

  # Emitted to the client as the tool_result frame data (string-keyed).
  defp result_frame_data({:ok, %{output: output, metadata: metadata}}) do
    %{"status" => "ok", "output" => truncate(output), "metadata" => stringify(metadata)}
  end

  defp result_frame_data({:error, %ErrorStruct{} = err}) do
    %{"status" => "error", "reason" => err.reason, "message" => err.message}
  end

  defp result_frame_data({:error, other}) do
    %{"status" => "error", "reason" => inspect(other)}
  end

  defp truncate(v) when is_binary(v) and byte_size(v) > 4_000,
    do: String.slice(v, 0, 4_000) <> "...(truncated)"

  defp truncate(v), do: v

  defp stringify(m) when is_map(m), do: Map.new(m, fn {k, v} -> {to_string(k), v} end)
  defp stringify(v), do: v
end
