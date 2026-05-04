defmodule AgentoWeb.ConnCase do
  @moduledoc """
  Test case for tests that require setting up a connection.

  Imports `Phoenix.ConnTest`, `Phoenix.LiveViewTest`, and the
  integration helpers needed for LLMAgent interaction.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint AgentoWeb.Endpoint

      use AgentoWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import AgentoWeb.ConnCase
      import AgentoWeb.IntegrationHelper
    end
  end

  setup _tags do
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
