defmodule AgentoWeb.DSTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias AgentoWeb.DS

  test "outcome and status words map to alert-ramp steps" do
    assert DS.step("ok") == :low
    assert DS.step(:ok) == :low
    assert DS.step("aborted") == :medium
    assert DS.step({:partial, [1]}) == :medium
    assert DS.step({:error, :x}) == :critical
    assert DS.step("boom") == :critical
    assert DS.step(nil) == :unknown
    assert DS.step(true) == :low
    assert DS.step(false) == :critical
  end

  test "disclosure renders a native details element with the chevron" do
    html = render_component(&DS.disclosure/1, summary: "Tool: x / y", inner_block: [%{inner_block: fn _, _ -> "body" end}])
    assert html =~ "<details"
    assert html =~ "<summary"
    assert html =~ ~s(href="#m-chevron")
    assert html =~ "body"
  end

  test "pre inspects its value" do
    html = render_component(&DS.pre/1, value: %{a: 1})
    assert html =~ "a: 1"
    assert html =~ ~s(class="ds-data)
  end
end
