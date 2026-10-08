defmodule PhoenixKit.Integration.Utils.DateSiteZoneTest do
  @moduledoc """
  The Settings-aware formatters of `PhoenixKit.Utils.Date` against the real
  settings table: an instant is shown in the site time zone, not as the
  stored UTC clock.
  """

  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Date, as: UtilsDate

  setup do
    {:ok, _} = Settings.update_setting("date_format", "d.m.Y")
    {:ok, _} = Settings.update_setting("time_format", "H:i")
    {:ok, _} = Settings.update_setting("time_zone", "Europe/Tallinn")
    :ok
  end

  # 15:31 UTC on a summer day is 18:31 in Tallinn (EEST, UTC+3).
  @summer ~U[2026-10-07 15:31:28Z]
  # 22:30 UTC in winter is 00:30 the next day in Tallinn (EET, UTC+2).
  @winter_late ~U[2026-12-31 22:30:00Z]

  describe "format_datetime_full_with_user_format/1" do
    test "shows a DateTime in the site time zone" do
      assert UtilsDate.format_datetime_full_with_user_format(@summer) == "07.10.2026 18:31"
    end

    test "reads a NaiveDateTime as UTC" do
      assert UtilsDate.format_datetime_full_with_user_format(~N[2026-10-07 15:31:28]) ==
               "07.10.2026 18:31"
    end

    test "applies the zone's offset for the instant shown, across the DST switch" do
      assert UtilsDate.format_datetime_full_with_user_format(@winter_late) == "01.01.2027 00:30"
    end

    test "a site with no zone set keeps UTC" do
      {:ok, _} = Settings.update_setting("time_zone", "0")
      assert UtilsDate.format_datetime_full_with_user_format(@summer) == "07.10.2026 15:31"
    end

    test "a legacy numeric offset still shifts by its hours" do
      {:ok, _} = Settings.update_setting("time_zone", "2")
      assert UtilsDate.format_datetime_full_with_user_format(@summer) == "07.10.2026 17:31"
    end

    test "nil is still \"Never\"" do
      assert UtilsDate.format_datetime_full_with_user_format(nil) == "Never"
    end
  end

  describe "the date-only and time-only formatters" do
    test "format_datetime_with_user_format/1 gives the local date" do
      assert UtilsDate.format_datetime_with_user_format(@winter_late) == "01.01.2027"
    end

    test "format_date_with_user_format/1 gives the local date of an instant" do
      assert UtilsDate.format_date_with_user_format(@winter_late) == "01.01.2027"
    end

    test "format_date_with_user_format/1 leaves a Date as it is" do
      assert UtilsDate.format_date_with_user_format(~D[2026-12-31]) == "31.12.2026"
    end

    test "format_time_with_user_format/1 gives the local time of an instant" do
      assert UtilsDate.format_time_with_user_format(@summer) == "18:31"
    end

    test "format_time_with_user_format/1 leaves a Time as it is" do
      assert UtilsDate.format_time_with_user_format(~T[15:31:00]) == "15:31"
    end

    test "format_short_datetime/1 is in the site time zone too" do
      assert UtilsDate.format_short_datetime(@summer) =~ ~r/^Oct 07, 2026 at 18:31$/
    end
  end
end
