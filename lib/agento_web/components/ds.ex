defmodule AgentoWeb.DS do
  @moduledoc """
  The few things agento adds on top of gos-ui: a mapping from this app's
  outcome and status terms to the alert ramp, a native disclosure for
  collapsible payloads (the design system has no accordion), and the
  empty-state and inspected-payload sentences every view repeats.
  """
  use Phoenix.Component
  import GosUi.Components, only: [mark: 1]

  @doc "An outcome, status or truthiness as an alert-ramp step."
  def step(v) when v in ["ok", :ok, true], do: :low
  def step(v) when v in ["aborted", :aborted], do: :medium
  def step({:partial, _}), do: :medium
  def step({:error, _}), do: :critical
  def step(nil), do: :unknown
  def step(false), do: :critical
  def step(v) when is_binary(v), do: :critical
  def step(_), do: :unknown

  attr :summary, :string, required: true
  attr :step, :atom, default: nil, doc: "optional ramp step that colors the summary rule"
  attr :icon, :string, default: nil
  attr :class, :string, default: nil
  attr :rest, :global
  slot :inner_block, required: true

  @doc "A collapsible block on the native details element, chevron rotating on open."
  def disclosure(assigns) do
    ~H"""
    <details class={["border border-border rounded-lg my-0.5 bg-surface", @class]} data-step={@step} style={@step && "border-left: 3px solid var(--status-#{@step})"} {@rest}>
      <summary class="flex items-center gap-1 p-1 text-small cursor-pointer select-none">
        <.mark name="m-chevron" size={12} class="ds-chevron" />
        <.mark :if={@icon} name={@icon} size={14} />
        <span>{@summary}</span>
      </summary>
      <div class="p-1 pt-0">{render_slot(@inner_block)}</div>
    </details>
    """
  end

  attr :value, :any, required: true
  attr :class, :string, default: nil

  @doc "An inspected Elixir term as data text."
  def pre(assigns) do
    ~H"""
    <pre class={["ds-data text-caption whitespace-pre-wrap overflow-x-auto p-1 rounded-md bg-surface-raised", @class]}>{inspect(@value, pretty: true)}</pre>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  @doc "A one-sentence empty state in muted text."
  def empty(assigns) do
    ~H"""
    <p class={["text-small text-muted p-1", @class]}>{render_slot(@inner_block)}</p>
    """
  end
end
