defmodule LlmagentWebWeb.WebEvents do
  @moduledoc """
  Emits web.* events via LLMAgent.Events so the web app's own actions
  are observable in the same event infrastructure as agent activity.

  All functions are fire-and-forget and will not raise on failure.
  """

  @source __MODULE__

  @doc "Emits a web.mount event when a LiveView mounts."
  @spec emit_mount(module()) :: :ok
  def emit_mount(view) do
    LLMAgent.Events.emit(:lifecycle, "web.mount", %{view: inspect(view)}, @source)
  end

  @doc "Emits a web.event for generic LiveView handle_event calls."
  @spec emit_event(String.t(), module(), [String.t()]) :: :ok
  def emit_event(event, view, param_keys) do
    LLMAgent.Events.emit(
      :user_action,
      "web.event",
      %{event: event, view: inspect(view), params_keys: param_keys},
      @source
    )
  end

  @doc "Emits a web.prompt_sent event when a user sends a prompt."
  @spec emit_prompt_sent(atom(), String.t()) :: :ok
  def emit_prompt_sent(agent_name, content) do
    LLMAgent.Events.emit(
      :user_action,
      "web.prompt_sent",
      %{agent_id: agent_name, content_length: String.length(content)},
      @source
    )
  end

  @doc "Emits a web.agent_started event when an agent is started via the UI."
  @spec emit_agent_started(atom(), keyword()) :: :ok
  def emit_agent_started(name, opts) do
    LLMAgent.Events.emit(
      :lifecycle,
      "web.agent_started",
      %{agent_name: name, role: Keyword.get(opts, :role), model: Keyword.get(opts, :model)},
      @source
    )
  end

  @doc "Emits a web.agent_stopped event when an agent is stopped via the UI."
  @spec emit_agent_stopped(atom()) :: :ok
  def emit_agent_stopped(name) do
    LLMAgent.Events.emit(:lifecycle, "web.agent_stopped", %{agent_name: name}, @source)
  end

  @doc "Emits a web.history_cleared event when agent history is cleared via the UI."
  @spec emit_history_cleared(atom()) :: :ok
  def emit_history_cleared(agent_name) do
    LLMAgent.Events.emit(:lifecycle, "web.history_cleared", %{agent_name: agent_name}, @source)
  end
end
