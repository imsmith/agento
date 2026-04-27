defmodule LlmagentWebWeb.ConnCase do
  @moduledoc """
  Test case for tests that require setting up a connection.

  Imports `Phoenix.ConnTest`, `Phoenix.LiveViewTest`, and the
  integration helpers needed for LLMAgent interaction.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint LlmagentWebWeb.Endpoint

      use LlmagentWebWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import LlmagentWebWeb.ConnCase
      import LlmagentWebWeb.IntegrationHelper
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
