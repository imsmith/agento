defmodule AgentoWeb.TestLLMClient do
  @moduledoc """
  Mock LLM client for integration tests.

  Implements `LLMAgent.LLMClient` behaviour with predictable responses
  driven by keywords in the last message content. Runs against the live
  LLMAgent supervision tree — no mocks of agent internals.
  """

  @behaviour LLMAgent.LLMClient

  @impl true
  def chat(messages, _opts) do
    last = List.last(messages)

    cond do
      last.content =~ "use_tool" ->
        {:ok,
         Jason.encode!(%{
           "tool" => "bash",
           "action" => "exec",
           "args" => %{"command" => "echo test_output"}
         })}

      last.content =~ "fail_tool" ->
        {:ok,
         Jason.encode!(%{
           "tool" => "bash",
           "action" => "exec",
           "args" => %{"command" => "exit 1"}
         })}

      last.content =~ "error_response" ->
        {:error, :simulated_failure}

      # Tool result followups get a plain text response (ends the loop)
      last.role == "user" && last.content =~ "status" ->
        {:ok, "The tool completed successfully."}

      true ->
        {:ok, "This is a test response to: #{last.content}"}
    end
  end
end
