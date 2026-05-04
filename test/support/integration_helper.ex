defmodule AgentoWeb.IntegrationHelper do
  @moduledoc """
  Helpers for integration tests that interact with the live LLMAgent
  supervision tree using `TestLLMClient`.
  """

  @default_opts [
    role: :sysadmin,
    model: "test-model",
    api_host: "http://localhost:11434/v1",
    llm_client: AgentoWeb.TestLLMClient,
    memory: LLMAgent.Memory.ETS
  ]

  @doc """
  Start an agent under `LLMAgent.AgentSupervisor` with `TestLLMClient`.

  Returns `{:ok, pid}`. The agent is automatically stopped in the ExUnit
  `on_exit` callback so tests don't leak processes.

  ## Options

  All fields in `@default_opts` can be overridden. `:name` is required.
  """
  def start_test_agent(name, opts \\ []) do
    merged =
      @default_opts
      |> Keyword.merge(opts)
      |> Keyword.put(:name, name)

    case LLMAgent.AgentSupervisor.start_agent(merged) do
      {:ok, pid} ->
        ExUnit.Callbacks.on_exit(fn ->
          try do
            LLMAgent.DurableLog.clear(name)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end

          try do
            LLMAgent.AgentSupervisor.stop_agent(name)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end

          try do
            LLMAgent.Memory.ETS.teardown(name)
          rescue
            _ -> :ok
          catch
            _, _ -> :ok
          end
        end)

        {:ok, pid}

      error ->
        error
    end
  end

  @doc """
  Subscribe the current process to a Phoenix.PubSub topic used by
  `EventBusBridge` and return `:ok`.
  """
  def subscribe_to_events do
    Phoenix.PubSub.subscribe(
      Agento.PubSub,
      Agento.EventBusBridge.pubsub_topic()
    )
  end

  @doc """
  Subscribe directly to an LLMAgent.EventBus topic from the test process.
  Useful for tests that want raw EventBus messages rather than the PubSub relay.
  """
  def subscribe_to_event_bus(topic) do
    LLMAgent.EventBus.subscribe(topic)
  end

  @doc """
  Wait for an event matching the given criteria on the Phoenix.PubSub bridge.

  Returns `{topic, event}` or raises on timeout.

  ## Options

    * `:topic` — required string, e.g. `"agent.message"`
    * `:match` — optional function `(event) -> boolean` for filtering
    * `:timeout` — milliseconds, default 5_000
  """
  def wait_for_event(opts) do
    topic = Keyword.fetch!(opts, :topic)
    match_fn = Keyword.get(opts, :match, fn _ -> true end)
    timeout = Keyword.get(opts, :timeout, 5_000)

    wait_for_event_loop(topic, match_fn, timeout)
  end

  defp wait_for_event_loop(topic, match_fn, timeout) do
    receive do
      {^topic, event} ->
        if match_fn.(event) do
          {topic, event}
        else
          wait_for_event_loop(topic, match_fn, timeout)
        end

      # Also handle raw EventBus messages
      {:event, ^topic, event} ->
        if match_fn.(event) do
          {topic, event}
        else
          wait_for_event_loop(topic, match_fn, timeout)
        end
    after
      timeout ->
        raise "Timed out waiting for event on topic #{inspect(topic)} after #{timeout}ms"
    end
  end

  @doc """
  Wait for an `agent.message` event with specific role and optional content match.
  Convenience wrapper around `wait_for_event/1`.
  """
  def wait_for_message(opts \\ []) do
    role = Keyword.get(opts, :role)
    content_match = Keyword.get(opts, :content)
    agent_id = Keyword.get(opts, :agent_id)
    timeout = Keyword.get(opts, :timeout, 5_000)

    match_fn = fn event ->
      data = event.data

      (is_nil(role) or data[:role] == role or data["role"] == role) and
        (is_nil(content_match) or
           String.contains?(to_string(data[:content] || data["content"]), content_match)) and
        (is_nil(agent_id) or
           data[:agent_id] == agent_id or data["agent_id"] == to_string(agent_id))
    end

    wait_for_event(topic: "agent.message", match: match_fn, timeout: timeout)
  end

  @doc """
  Send a prompt to an agent and return `:ok`. This is `LLMAgent.prompt/2`
  but with the name coerced to a global-registered reference.
  """
  def send_prompt(agent_name, content) do
    LLMAgent.prompt({:global, agent_name}, content)
  end
end
