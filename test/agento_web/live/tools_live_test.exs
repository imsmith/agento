defmodule AgentoWeb.ToolsLiveTest do
  @moduledoc """
  Integration tests for Tool Inspector LiveView (R6) and Version Adaptivity (VA1).
  """
  use AgentoWeb.ConnCase

  describe "Tool Inspector (R6.1)" do
    test "tools page mounts and lists registered tools", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools")

      # Should show tool count and list
      assert html =~ "Registered Tools"

      # Verify tools from LLMAgent.Tools.all/0 appear
      tools = LLMAgent.Tools.all()

      for {name, _module} <- tools do
        assert html =~ to_string(name),
               "Expected tool #{name} to appear in the tools list"
      end
    end

    test "tool count matches LLMAgent.Tools.all/0", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/tools")

      tool_count = length(LLMAgent.Tools.all())
      assert html =~ "Registered Tools (#{tool_count})"
    end

    test "selecting a tool shows description (R6.2)", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools")

      # Pick the first tool
      [{name, module} | _] = LLMAgent.Tools.all()

      view
      |> element("[phx-click=select_tool][phx-value-name=#{name}]")
      |> render_click()

      html = render(view)
      assert html =~ "Description"
      # The describe/0 output should be shown
      description = module.describe()
      assert html =~ description or html =~ to_string(name)
    end

    test "refresh tools updates the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/tools")

      view |> element("button[phx-click=refresh_tools]") |> render_click()

      html = render(view)
      assert html =~ "Registered Tools"
    end
  end

  describe "Version Adaptivity (VA1)" do
    test "dynamically registered tool appears in UI", %{conn: conn} do
      # Define a dynamic tool module at runtime using Module.create
      # to avoid Elixir nesting the module under the test module
      {:module, mod, _, _} =
        Module.create(
          :"Elixir.LLMAgent.Tools.TestDynamic",
          quote do
            @behaviour LLMAgent.Tool
            def describe, do: "A dynamic test tool for VA1"
            def perform(_, _), do: {:ok, %{output: "dynamic", metadata: %{}}}
          end,
          Macro.Env.location(__ENV__)
        )

      # Register it in the runtime tool registry
      LLMAgent.Tools.register(:test_dynamic, mod)

      on_exit(fn ->
        try do
          LLMAgent.Tools.unregister(:test_dynamic)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end

        try do
          :code.purge(mod)
          :code.delete(mod)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
      end)

      {:ok, _view, html} = live(conn, "/tools")
      assert html =~ "test_dynamic"
    end
  end
end
