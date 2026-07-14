defmodule AgentoWeb.PromptRoutingTest do
  @moduledoc """
  A prompt submitted through the chat UI must actually reach the selected
  agent. Agents register as `{:global, name}`, so ChatLive must route
  `LLMAgent.prompt/2` at that global reference — not a bare atom.

  Regression guard for the historical "prompts sent via the UI won't reach
  agents" bug.
  """
  use AgentoWeb.ConnCase

  defp eventually(fun, tries \\ 50)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, tries) do
    if fun.() do
      true
    else
      Process.sleep(100)
      eventually(fun, tries - 1)
    end
  end

  test "a prompt entered in the UI reaches the agent and gets a response", %{conn: conn} do
    {:ok, _pid} = start_test_agent(:ui_routing_probe)
    Process.sleep(200)

    {:ok, view, _html} = live(conn, "/chat?agent=ui_routing_probe")

    view
    |> form("form[phx-submit=send_prompt]", %{"prompt" => "ping-via-ui"})
    |> render_submit()

    # The user message must land in the agent's durable log...
    assert eventually(fn ->
             :ui_routing_probe
             |> LLMAgent.DurableLog.messages_for()
             |> Enum.any?(&(to_string(&1.content) =~ "ping-via-ui"))
           end)

    # ...and TestLLMClient's reply must come back through the same agent.
    assert eventually(fn ->
             :ui_routing_probe
             |> LLMAgent.DurableLog.messages_for()
             |> Enum.any?(&(to_string(&1.content) =~ "This is a test response to: ping-via-ui"))
           end)
  end
end
