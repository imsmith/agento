defmodule AgentoWeb.CoreComponents do
  @moduledoc """
  What is left after the design system: error translation for forms.
  Components come from `GosUi.Components` and `AgentoWeb.DS`.
  """
  use Phoenix.Component

  @doc "Translates an error message using gettext."
  def translate_error({msg, opts}) do
    if count = opts[:count] do
      Gettext.dngettext(AgentoWeb.Gettext, "errors", msg, msg, count, opts)
    else
      Gettext.dgettext(AgentoWeb.Gettext, "errors", msg, opts)
    end
  end

  @doc "Translates the errors for a field from a keyword list of errors."
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
