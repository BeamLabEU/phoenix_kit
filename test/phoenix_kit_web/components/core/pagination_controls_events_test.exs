defmodule PhoenixKitWeb.Components.Core.PaginationControlsEventsTest do
  @moduledoc """
  `pagination_controls` has two modes: patch links (`build_url`, the markup it
  always had) and, with `on_page`, buttons that send an event to a target.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhoenixKitWeb.Components.Core.Pagination

  # What the component rendered before `on_page` existed (page 3 of 7).
  @links_before ~s|<div class="join ">\n  \n    <a href="/x?page=2" data-phx-link="patch" data-phx-link-state="push" class="join-item btn btn-sm">\n      « Prev\n    </a>\n  \n\n  \n    <a href="/x?page=1" data-phx-link="patch" data-phx-link-state="push" class="join-item btn btn-sm">\n      1\n    </a>\n  \n    <a href="/x?page=2" data-phx-link="patch" data-phx-link-state="push" class="join-item btn btn-sm">\n      2\n    </a>\n  \n    <a href="/x?page=3" data-phx-link="patch" data-phx-link-state="push" class="join-item btn btn-sm btn-active">\n      3\n    </a>\n  \n    <a href="/x?page=4" data-phx-link="patch" data-phx-link-state="push" class="join-item btn btn-sm">\n      4\n    </a>\n  \n    <a href="/x?page=5" data-phx-link="patch" data-phx-link-state="push" class="join-item btn btn-sm">\n      5\n    </a>\n  \n\n  \n    <a href="/x?page=4" data-phx-link="patch" data-phx-link-state="push" class="join-item btn btn-sm">\n      Next »\n    </a>\n  \n</div>|

  defp url(n), do: "/x?page=#{n}"

  test "without on_page the markup is what it always was" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Pagination.pagination_controls page={3} total_pages={7} build_url={&url/1} />
      """)

    assert String.trim(html) == @links_before
  end

  test "with on_page every page is a button for the event, aimed at the target" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Pagination.pagination_controls
        page={3}
        total_pages={7}
        on_page="set_page"
        target="#browser"
      />
      """)

    doc = LazyHTML.from_fragment(html)

    buttons =
      LazyHTML.query(doc, "button[phx-click=set_page][phx-target='#browser'][type=button]")

    assert LazyHTML.attribute(buttons, "phx-value-page") == ~w(2 1 2 3 4 5 4)
    assert doc |> LazyHTML.query("a") |> Enum.count() == 0

    active = LazyHTML.query(doc, "button.btn-active")
    assert LazyHTML.attribute(active, "phx-value-page") == ["3"]
    assert active |> LazyHTML.text() |> String.trim() == "3"
  end

  test "events mode needs no build_url, and one page shows nothing" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <Pagination.pagination_controls page={1} total_pages={1} on_page="set_page" />
      """)

    assert String.trim(html) == ""
  end

  test "the first page has no Prev and the last no Next" do
    assigns = %{}

    first =
      rendered_to_string(~H"""
      <Pagination.pagination_controls page={1} total_pages={3} on_page="p" />
      """)

    last =
      rendered_to_string(~H"""
      <Pagination.pagination_controls page={3} total_pages={3} on_page="p" />
      """)

    refute first =~ "Prev"
    assert first =~ "Next"
    assert last =~ "Prev"
    refute last =~ "Next"
  end

  test "neither build_url nor on_page is an error that says so" do
    assigns = %{}

    assert_raise ArgumentError, ~r/build_url.*on_page/, fn ->
      rendered_to_string(~H"""
      <Pagination.pagination_controls page={2} total_pages={3} />
      """)
    end
  end

  test "Prev and Next of the events mode follow the language" do
    assigns = %{}

    html =
      Gettext.with_locale(PhoenixKitWeb.Gettext, "ru", fn ->
        rendered_to_string(~H"""
        <Pagination.pagination_controls page={2} total_pages={3} on_page="p" />
        """)
      end)

    refute html =~ "Prev"
    refute html =~ "Next"
  end
end
