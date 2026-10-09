defmodule PhoenixKitWeb.Components.Core.FileDetailsFieldsTest do
  @moduledoc """
  The tabbed title / alt text / description fields: a panel per language with its
  own inputs, tabs that only show and hide (in the browser), the primary
  language's text as a placeholder, and no tabs on a one-language site.

  DB-free: plain assigns.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitWeb.Components.Core.FileDetailsFields

  @tabs [
    %{code: "en", name: "English", flag: "🇬🇧", is_primary: true, short_code: "EN"},
    %{code: "et", name: "Estonian", flag: "🇪🇪", is_primary: false, short_code: "ET"}
  ]

  @values %{
    "en" => %{title: "Harbour", alt: "Boats", description: "A harbour."},
    "et" => %{title: "", alt: "", description: ""}
  }

  defp render(assigns) do
    render_component(
      &FileDetailsFields.file_details_fields/1,
      Map.merge(
        %{
          id: "f",
          languages: @tabs,
          lang: "en",
          values: @values,
          placeholders: %{title: "Harbour", alt: "Boats", description: "A harbour."}
        },
        assigns
      )
    )
  end

  defp doc(html), do: LazyHTML.from_fragment(html)
  defp query(html, selector), do: html |> doc() |> LazyHTML.query(selector) |> Enum.to_list()

  test "a tab and a panel per language, each with the language's own inputs" do
    html = render(%{})

    assert length(query(html, ~s([role="tab"]))) == 2
    assert length(query(html, ~s([role="tabpanel"]))) == 2

    for lang <- ["en", "et"], field <- ["title", "alt", "description"] do
      assert [_] = query(html, ~s([name="details[#{lang}][#{field}]"]))
    end
  end

  test "each panel shows its language's own text, and the primary's is only a placeholder" do
    html = render(%{})

    assert [en] = query(html, ~s(input[name="details[en][title]"]))
    assert LazyHTML.attribute(en, "value") == ["Harbour"]

    assert [et] = query(html, ~s(input[name="details[et][title]"]))
    assert LazyHTML.attribute(et, "value") == [""]
    assert LazyHTML.attribute(et, "placeholder") == ["Harbour"]
  end

  test "the selected language is shown and the others are hidden until their tab is picked" do
    html = render(%{lang: "et"})

    [en_panel, et_panel] = query(html, ~s([role="tabpanel"]))
    assert LazyHTML.attribute(en_panel, "class") |> hd() =~ "hidden"
    refute LazyHTML.attribute(et_panel, "class") |> hd() =~ "hidden"

    [en_tab, et_tab] = query(html, ~s([role="tab"]))
    refute LazyHTML.attribute(en_tab, "class") |> hd() =~ "tab-active"
    assert LazyHTML.attribute(et_tab, "class") |> hd() =~ "tab-active"
  end

  test "switching a tab is a client-side command: nothing is sent to the server" do
    html = render(%{})
    [tab | _] = query(html, ~s([role="tab"]))

    [click] = LazyHTML.attribute(tab, "phx-click")
    assert click =~ ~s("show")
    assert click =~ ~s("hide")
    refute click =~ ~s("push")
  end

  test "a language with no text yet carries a dot, and the primary a star" do
    html = render(%{})
    [en_tab, et_tab] = query(html, ~s([role="tab"]))

    refute LazyHTML.to_html(en_tab) =~ "No translation yet"
    assert LazyHTML.to_html(et_tab) =~ "No translation yet"
    assert LazyHTML.to_html(en_tab) =~ "hero-star-mini"
    refute LazyHTML.to_html(et_tab) =~ "hero-star-mini"
  end

  test "a one-language site has no tabs, only its one panel" do
    html = render(%{languages: [], lang: "en", values: %{"en" => @values["en"]}})

    assert query(html, ~s([role="tab"])) == []
    assert [panel] = query(html, ~s([role="tabpanel"]))
    refute LazyHTML.attribute(panel, "class") |> hd() =~ "hidden"
    assert [_] = query(html, ~s([name="details[en][title]"]))
  end

  test "alt text is only asked for an image" do
    assert query(render(%{show_alt: false}), ~s([name="details[en][alt]"])) == []
    assert [_] = query(render(%{show_alt: true}), ~s([name="details[en][alt]"]))
  end

  test "the field prefix is the caller's" do
    assert [_] = query(render(%{name: "meta"}), ~s([name="meta[et][description]"]))
  end
end
