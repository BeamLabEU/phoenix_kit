defmodule PhoenixKitWeb.Components.Core.AccordionTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.Accordion

  defp render_accordion(extra) do
    render_component(
      &Accordion.accordion/1,
      [
        id: "acc",
        title: [%{inner_block: fn _, _ -> "Title" end}],
        content: [%{inner_block: fn _, _ -> "Body" end}]
      ] ++ extra
    )
  end

  test "draws a visible edge by default, like core's cards (base-300 border + small shadow)" do
    html = render_accordion([])

    assert html =~
             ~s(class="collapse collapse-arrow border border-base-300 bg-base-100 shadow-sm)

    refute html =~ "border-base-200"
  end

  test "caller classes are appended after the defaults" do
    html = render_accordion(class: "bg-base-200 border-0")
    assert html =~ "shadow-sm bg-base-200 border-0\""
  end
end
