defmodule PhoenixKitWeb.Components.Core.DateNavTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.Core.DateNav

  alias PhoenixKitWeb.Components.Core.DateNav

  defp render_nav(date, extra \\ %{}) do
    assigns =
      Map.merge(
        %{date: date, today: ~D[2026-09-30], max: nil, min: nil, path: &"/stats?date=#{&1}"},
        extra
      )

    rendered_to_string(~H"""
    <.date_nav date={@date} today={@today} min={@min} max={@max} path={@path} />
    """)
  end

  test "previous and next patch to the neighbouring days" do
    html = render_nav(~D[2026-09-20])
    assert html =~ ~s(href="/stats?date=2026-09-19")
    assert html =~ ~s(href="/stats?date=2026-09-21")
    assert html =~ ~s(data-phx-link="patch")
  end

  test "next is disabled at max, previous at min" do
    html = render_nav(~D[2026-09-30], %{max: ~D[2026-09-30], min: ~D[2026-09-30]})
    refute html =~ "2026-10-01"
    refute html =~ "2026-09-29"
    assert length(String.split(html, "btn-disabled")) == 3
  end

  test "Today links back only when not on today" do
    assert render_nav(~D[2026-09-20]) =~ ~s(href="/stats?date=2026-09-30")
    refute render_nav(~D[2026-09-30]) =~ ~s(href="/stats?date=2026-09-30")
  end

  test "the picker is a form (a bare date input never reaches the server)" do
    html = render_nav(~D[2026-09-20])
    assert html =~ ~r/<form[^>]*phx-change="date_nav_pick"/
    # The picker is a date_input: the date as text, and the form's `date`
    # field is the ISO value element.
    assert html =~ ~s(phx-hook="PkDateInput")
    assert html =~ ~r/<input[^>]*type="date"[^>]*name="date"[^>]*value="2026-09-20"/
    assert html =~ ~r/<input[^>]*type="text"[^>]*id="date-nav-date"/
  end

  test "the picker is required (clearing it would only mean today) and bounded by min/max" do
    html = render_nav(~D[2026-09-20], %{min: ~D[2026-09-01], max: ~D[2026-09-30]})
    assert html =~ ~r/<input[^>]*type="text"[^>]*\brequired\b/
    refute html =~ "data-clear"
    assert html =~ ~s(data-min="2026-09-01")
    assert html =~ ~s(data-max="2026-09-30")
  end

  test "the day picker's change event follows `target`, like the arrows" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <.date_nav date={~D[2026-09-20]} event="sheet_day" target="#sheet" />
      """)

    assert html =~ ~r/<form[^>]*phx-change="date_nav_pick"[^>]*phx-target="#sheet"/
  end

  describe "parse_param/2" do
    test "reads a date, and anything else is today" do
      today = ~D[2026-09-30]
      assert DateNav.parse_param("2026-09-01", today: today) == ~D[2026-09-01]
      assert DateNav.parse_param("garbage", today: today) == today
      assert DateNav.parse_param(nil, today: today) == today
      assert DateNav.parse_param(%{"x" => 1}, today: today) == today
    end

    test "clamps to min and max" do
      assert DateNav.parse_param("2030-01-01", max: ~D[2026-09-30]) == ~D[2026-09-30]
      assert DateNav.parse_param("2000-01-01", min: ~D[2026-01-01]) == ~D[2026-01-01]
    end
  end

  describe "a week at a time, with no URL" do
    defp render_week(extra) do
      assigns =
        Map.merge(
          %{date: ~D[2026-10-12], today: ~D[2026-10-12], label: "Oct 12 – Oct 18"},
          extra
        )

      rendered_to_string(~H"""
      <.date_nav
        date={@date}
        today={@today}
        step={7}
        label={@label}
        today_label="This week"
        event="sheet_week"
      />
      """)
    end

    test "the arrows send the event a week either side" do
      html = render_week(%{})
      assert html =~ ~s(phx-click="sheet_week")
      assert html =~ ~s(phx-value-date="2026-10-05")
      assert html =~ ~s(phx-value-date="2026-10-19")
      refute html =~ "data-phx-link"
      assert html =~ "Previous"
      refute html =~ "Previous day"
    end

    test "the label stands between the arrows, without the day picker" do
      html = render_week(%{})
      assert html =~ "Oct 12 – Oct 18"
      refute html =~ ~s(type="date")
    end

    test "the way back to today is a button with its own word" do
      html = render_week(%{date: ~D[2026-09-28]})
      assert html =~ ~s(phx-value-date="2026-10-12")
      assert html =~ "This week"
      refute render_week(%{}) =~ "This week</button>"
    end
  end
end
