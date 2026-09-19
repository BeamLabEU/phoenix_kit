defmodule PhoenixKitWeb.Components.Core.TableRowMenuTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import PhoenixKitWeb.Components.Core.TableRowMenu

  defp trigger_html(extra_attrs) do
    assigns = %{extra: extra_attrs}

    html =
      rendered_to_string(~H"""
      <.table_row_menu id="m1" {@extra}>
        <.table_row_menu_button phx-click="x" label="X" />
      </.table_row_menu>
      """)

    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[data-row-menu-trigger]")
  end

  defp trigger_class(extra_attrs) do
    extra_attrs |> trigger_html() |> LazyHTML.attribute("class") |> hd()
  end

  defp trigger_icon_class(extra_attrs) do
    extra_attrs
    |> trigger_html()
    |> LazyHTML.query("span")
    |> LazyHTML.attribute("class")
    |> hd()
  end

  describe "trigger_size" do
    test "defaults to xs: the same classes in the same order, and the same icon, as before" do
      # Same tokens as the trigger rendered before `trigger_size` existed. (The
      # old class attribute also ended in a space, `"... btn-circle "`; that
      # whitespace is not reproduced.)
      assert trigger_class([]) |> String.split() == ~w(btn btn-xs btn-ghost btn-circle)
      assert trigger_icon_class([]) == "hero-ellipsis-vertical w-4 h-4"

      # and asking for "xs" is asking for the default
      assert trigger_html(trigger_size: "xs") |> LazyHTML.to_html() ==
               trigger_html([]) |> LazyHTML.to_html()
    end

    test "sm and md swap the size class instead of adding to btn-xs" do
      # In the built CSS `.btn-xs` sorts after `.btn-sm`, so a trigger carrying
      # both renders 24px: the size has to be REPLACED, never appended.
      sm = trigger_class(trigger_size: "sm")
      assert sm =~ "btn-sm"
      refute sm =~ "btn-xs"

      md = trigger_class(trigger_size: "md")
      assert md =~ "btn-md"
      refute md =~ "btn-xs"
      refute md =~ "btn-sm"
    end

    test "the icon grows with the trigger" do
      assert trigger_icon_class([]) =~ "w-4 h-4"
      assert trigger_icon_class(trigger_size: "sm") =~ "w-5 h-5"
      assert trigger_icon_class(trigger_size: "md") =~ "w-6 h-6"
    end

    test "trigger_class is still appended after the size class" do
      assert trigger_class(trigger_size: "sm", trigger_class: "extra-x") =~ "btn-sm"
      assert trigger_class(trigger_size: "sm", trigger_class: "extra-x") =~ "extra-x"
    end

    test "the size classes are literals in the source, so Tailwind's scanner sees them" do
      source = File.read!("lib/phoenix_kit_web/components/core/table_row_menu.ex")

      for size <- ["btn-xs", "btn-sm", "btn-md"] do
        literal = "btn #{size} btn-ghost btn-circle"
        assert source =~ ~s("#{literal}"), "expected the literal #{literal} in table_row_menu.ex"
      end
    end
  end
end
