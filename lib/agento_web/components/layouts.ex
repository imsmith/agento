defmodule AgentoWeb.Layouts do
  @moduledoc """
  The app shell: brand, sidebar navigation, theme switch, flash toasts.
  All of it is the design system's `app_shell`; this module only names the
  six views and wires the flash map.
  """
  use AgentoWeb, :html

  embed_templates "layouts/*"

  @nav [
    %{id: :chat, label: "CHAT", icon: "m-chat", navigate: "/chat"},
    %{id: :events, label: "EVENTS", icon: "m-event", navigate: "/events"},
    %{id: :system, label: "SYSTEM", icon: "m-system", navigate: "/system"},
    %{id: :tools, label: "TOOLS", icon: "m-tool", navigate: "/tools"},
    %{id: :hub, label: "HUB", icon: "m-hub", navigate: "/hub"},
    %{id: :rules, label: "RULES", icon: "m-event", navigate: "/rules"}
  ]

  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_scope, :map, default: nil
  attr :active_nav, :atom, default: :chat, doc: "the currently active navigation section"
  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav, @nav)

    ~H"""
    <.app_shell nav_width="160px" class="flex-1 min-h-0">
      <:brand>
        <a href="/" class="flex items-center gap-1"><.mark name="m-agent" size={18} /> LLMAgent</a>
      </:brand>
      <:actions>
        <div id="theme-switch" phx-hook="ThemeSwitch" phx-update="ignore">
          <.theme_switch theme={:tron} mode={:dark} on_change={JS.dispatch("gos:theme")} />
        </div>
      </:actions>
      <:nav><.menu variant={:sidebar} label="Views" items={@nav} selected={@active_nav} /></:nav>
      {render_slot(@inner_block)}
    </.app_shell>

    <.flash_toasts flash={@flash} />
    <.toast_stack id="connection-toasts">
      <.toast
        id="client-error"
        severity={:critical}
        title="Connection lost."
        hidden
        phx-disconnected={JS.show(to: ".phx-client-error #client-error")}
        phx-connected={JS.hide(to: "#client-error")}
      >
        The browser cannot reach the server. Reconnecting; nothing to do.
      </.toast>
      <.toast
        id="server-error"
        severity={:critical}
        title="Server error."
        hidden
        phx-disconnected={JS.show(to: ".phx-server-error #server-error")}
        phx-connected={JS.hide(to: "#server-error")}
      >
        The view crashed and is restarting. If it repeats, check the server log.
      </.toast>
    </.toast_stack>
    """
  end
end
