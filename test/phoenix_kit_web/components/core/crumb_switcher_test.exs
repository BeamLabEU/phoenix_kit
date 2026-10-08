defmodule PhoenixKitWeb.Components.Core.CrumbSwitcherTest do
  @moduledoc """
  The breadcrumb switcher (GitHub's repository switcher for any trail):
  a ▾ that opens a searchable list of the things on one level, each a
  real link, the current one ticked.

  DB-free: plain assigns.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitWeb.Components.Core.CrumbSwitcher

  defp render(switcher) do
    render_component(&CrumbSwitcher.crumb_switcher/1, %{id: "sw", switcher: switcher})
  end

  defp doc(html), do: LazyHTML.from_fragment(html)

  test "every item is a real link — navigate or patch — and the current one is ticked" do
    html =
      render(%{
        title: "Switch catalogue",
        items: [
          %{label: "Kitchen", navigate: "/admin/catalogue/k", current: true},
          %{label: "Bathroom", navigate: "/admin/catalogue/b"},
          %{label: "Doors", patch: "/admin/catalogue/k?category=d"}
        ]
      })

    links = html |> doc() |> LazyHTML.query("#sw-list a")
    assert Enum.count(links) == 3

    assert links |> Enum.map(&LazyHTML.attribute(&1, "href")) |> List.flatten() ==
             ["/admin/catalogue/k", "/admin/catalogue/b", "/admin/catalogue/k?category=d"]

    assert links |> Enum.map(&LazyHTML.attribute(&1, "data-phx-link")) |> List.flatten() ==
             ["redirect", "redirect", "patch"]

    [current] =
      html |> doc() |> LazyHTML.query(~s(#sw-list a[aria-current="page"])) |> Enum.to_list()

    assert LazyHTML.text(current) =~ "Kitchen"

    # Only the current row's tick is visible.
    ticks = html |> doc() |> LazyHTML.query("#sw-list a .hero-check-mini")
    visible = Enum.reject(ticks, &(LazyHTML.attribute(&1, "class") |> hd() =~ "invisible"))
    assert length(visible) == 1
  end

  test "picking a row closes the panel from the <li>, never from the link" do
    # Placement is the whole point: on the link, a `patch` row would leave the
    # panel open over the page the patch leaves in place, and hiding the link's
    # own ancestor mid-click is what swallows the navigation.
    html = render(%{title: "Switch catalogue", items: [%{label: "Kitchen", navigate: "/x"}]})
    d = doc(html)

    [row] = d |> LazyHTML.query("#sw-list li[data-filter-text]") |> Enum.to_list()
    assert [click] = LazyHTML.attribute(row, "phx-click")
    assert click =~ "sw"

    assert d |> LazyHTML.query("#sw-list a[phx-click]") |> Enum.count() == 0
  end

  test "the list is searchable on the client, with a no-results row" do
    html = render(%{title: "Switch category", items: [%{label: "Käsitöö", navigate: "/x"}]})
    d = doc(html)

    [input] = d |> LazyHTML.query("#sw-search") |> Enum.to_list()
    assert LazyHTML.attribute(input, "phx-hook") == ["ListFilter"]
    assert LazyHTML.attribute(input, "data-filter-list") == ["#sw-list"]

    # The filter text is the label as written; the hook folds case/accents.
    assert d |> LazyHTML.query(~s(#sw-list li[data-filter-text="Käsitöö"])) |> Enum.count() == 1
    assert d |> LazyHTML.query("#sw-list li[data-filter-empty].hidden") |> Enum.count() == 1
  end

  test "the hook owns open/close: it knows its panel and its trigger, which starts collapsed" do
    html = render(%{title: "Switch catalogue", items: []})
    d = doc(html)

    [wrap] = d |> LazyHTML.query("#sw-switcher") |> Enum.to_list()
    assert LazyHTML.attribute(wrap, "phx-hook") == ["CrumbSwitcher"]
    assert LazyHTML.attribute(wrap, "data-panel") == ["sw"]

    [button] = d |> LazyHTML.query("#sw-switcher [data-switcher-trigger]") |> Enum.to_list()
    assert LazyHTML.attribute(button, "aria-expanded") == ["false"]
    assert LazyHTML.attribute(button, "aria-controls") == ["sw"]

    # Tab stays inside the open panel.
    assert d |> LazyHTML.query("#sw #sw-focus #sw-search") |> Enum.count() == 1
  end

  test "every control has a name, even in a switcher without a title" do
    html = render(%{title: "Switch catalogue", search_placeholder: "Find…", items: []})
    assert html =~ ~s(aria-label="Find…")

    untitled = render(%{items: []})
    assert untitled =~ ~s(aria-label="Search...")
    refute untitled =~ ~s(aria-label="")
  end

  test "the title labels the button and heads the panel; the placeholder has a default" do
    html = render(%{title: "Switch catalogue", items: []})

    assert html =~ ~s(aria-label="Switch catalogue")
    assert html =~ ~s(placeholder="Search...")

    custom = render(%{title: "Switch catalogue", search_placeholder: "Find…", items: []})
    assert custom =~ ~s(placeholder="Find…")
  end

  test "a hint trails its row's label, and the filter still matches the label alone" do
    html =
      render(%{
        items: [
          %{label: "Holiday", patch: "/a", hint: "Mine"},
          %{label: "Media", patch: "/b"}
        ]
      })

    [holiday, media] =
      html |> doc() |> LazyHTML.query("#sw-list li[data-filter-text]") |> Enum.to_list()

    assert LazyHTML.attribute(holiday, "data-filter-text") == ["Holiday"]
    assert LazyHTML.text(holiday) =~ "Mine"
    refute LazyHTML.text(media) =~ "Mine"
  end
end
