defmodule AgentoWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use AgentoWeb, :html

  embed_templates "page_html/*"

  def views do
    [
      {"/chat", "m-chat", "Chat", "Talk to a running agent; start and stop agents."},
      {"/events", "m-event", "Events", "The live event stream, and the durable and in-memory logs."},
      {"/system", "m-system", "System", "Supervision tree, ETS, contexts, errors, modules, DurableLog."},
      {"/tools", "m-tool", "Tools", "The tool registry; describe and invoke a tool by hand."},
      {"/hub", "m-hub", "Hub", "The private LLM hub: performers, clients, recent turns."},
      {"/rules", "m-event", "Rules", "Loaded policies, what an event would do, the trace."}
    ]
  end
end
