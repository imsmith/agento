defmodule Agento do
  @moduledoc """
  Agento is a Phoenix LiveView web UI over LLMAgent.

  It holds no domain logic of its own. The application-level plumbing
  (`Agento.EventBusBridge`) bridges LLMAgent's EventBus onto `Phoenix.PubSub`;
  the UI-facing boundary modules live under `AgentoWeb.Discovery.*` and project
  LLMAgent's public API into shapes the LiveViews can render.
  """
end
