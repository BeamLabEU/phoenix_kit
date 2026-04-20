defmodule PhoenixKit.Utils.Date.TimezoneTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Utils.Date, as: DateUtils

  doctest PhoenixKit.Utils.Date,
    only: [
      offset_to_seconds: 1,
      parse_datetime_local: 2,
      format_datetime_local: 2
    ]

  describe "offset_to_seconds/1" do
    test "handles zero" do
      assert DateUtils.offset_to_seconds("0") == 0
    end

    test "handles positive hour offsets" do
      assert DateUtils.offset_to_seconds("1") == 3600
      assert DateUtils.offset_to_seconds("14") == 50_400
    end

    test "handles negative hour offsets" do
      assert DateUtils.offset_to_seconds("-1") == -3600
      assert DateUtils.offset_to_seconds("-12") == -43_200
    end

    test "handles fractional offsets like UTC+5:30" do
      assert DateUtils.offset_to_seconds("5.5") == 19_800
      assert DateUtils.offset_to_seconds("5.75") == 20_700
      assert DateUtils.offset_to_seconds("-3.5") == -12_600
    end

    test "returns 0 for invalid input" do
      assert DateUtils.offset_to_seconds("not-a-number") == 0
      assert DateUtils.offset_to_seconds("") == 0
    end

    test "returns 0 for non-string input" do
      assert DateUtils.offset_to_seconds(nil) == 0
      assert DateUtils.offset_to_seconds(5) == 0
    end
  end

  describe "shift_to_offset/2" do
    test "UTC+0 offset leaves DateTime unchanged" do
      dt = ~U[2026-04-14 12:00:00Z]
      assert DateUtils.shift_to_offset(dt, "0") == dt
    end

    test "UTC+2 shifts forward by 2 hours" do
      dt = ~U[2026-04-14 12:00:00Z]
      result = DateUtils.shift_to_offset(dt, "2")
      assert result.hour == 14
    end

    test "UTC-5 shifts back by 5 hours" do
      dt = ~U[2026-04-14 12:00:00Z]
      result = DateUtils.shift_to_offset(dt, "-5")
      assert result.hour == 7
    end

    test "UTC+5:30 shifts forward by 5.5 hours" do
      dt = ~U[2026-04-14 12:00:00Z]
      result = DateUtils.shift_to_offset(dt, "5.5")
      assert result.hour == 17
      assert result.minute == 30
    end
  end

  describe "parse_datetime_local/2" do
    test "parses minute-precision input without seconds" do
      assert {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T12:00", "0")
      assert DateTime.to_iso8601(dt) == "2026-04-14T12:00:00Z"
    end

    test "parses seconds-precision input" do
      assert {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T12:00:30", "0")
      assert DateTime.to_iso8601(dt) == "2026-04-14T12:00:30Z"
    end

    test "converts to UTC by subtracting positive offset" do
      # User at UTC+2 picks 12:00 local → stored as 10:00 UTC
      assert {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T12:00", "2")
      assert DateTime.to_iso8601(dt) == "2026-04-14T10:00:00Z"
    end

    test "converts to UTC by adding negative offset" do
      # User at UTC-5 picks 12:00 local → stored as 17:00 UTC
      assert {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T12:00", "-5")
      assert DateTime.to_iso8601(dt) == "2026-04-14T17:00:00Z"
    end

    test "handles fractional offsets (UTC+5:30)" do
      assert {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T12:00", "5.5")
      assert DateTime.to_iso8601(dt) == "2026-04-14T06:30:00Z"
    end

    test "returns :empty for empty string" do
      assert {:error, :empty} = DateUtils.parse_datetime_local("", "0")
    end

    test "returns :empty for nil" do
      assert {:error, :empty} = DateUtils.parse_datetime_local(nil, "0")
    end

    test "returns :invalid_format for malformed input" do
      assert {:error, :invalid_format} = DateUtils.parse_datetime_local("not-a-date", "0")
      assert {:error, :invalid_format} = DateUtils.parse_datetime_local("2026-13-40T99:99", "0")
      assert {:error, :invalid_format} = DateUtils.parse_datetime_local("2026-04-14", "0")
    end

    test "day boundary crossing works correctly" do
      # User at UTC+2 picks 00:30 local → stored as 22:30 UTC on previous day
      assert {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T00:30", "2")
      assert DateTime.to_iso8601(dt) == "2026-04-13T22:30:00Z"
    end
  end

  describe "format_datetime_local/2" do
    test "formats UTC DateTime for UTC+0 input" do
      dt = ~U[2026-04-14 12:00:00Z]
      assert DateUtils.format_datetime_local(dt, "0") == "2026-04-14T12:00"
    end

    test "shifts forward for positive offset" do
      dt = ~U[2026-04-14 12:00:00Z]
      assert DateUtils.format_datetime_local(dt, "2") == "2026-04-14T14:00"
    end

    test "shifts back for negative offset" do
      dt = ~U[2026-04-14 12:00:00Z]
      assert DateUtils.format_datetime_local(dt, "-5") == "2026-04-14T07:00"
    end

    test "handles fractional offsets" do
      dt = ~U[2026-04-14 12:00:00Z]
      assert DateUtils.format_datetime_local(dt, "5.5") == "2026-04-14T17:30"
    end

    test "returns empty string for nil input" do
      assert DateUtils.format_datetime_local(nil, "0") == ""
      assert DateUtils.format_datetime_local(nil, "2") == ""
    end

    test "strips seconds (datetime-local minute precision)" do
      dt = ~U[2026-04-14 12:00:45Z]
      assert DateUtils.format_datetime_local(dt, "0") == "2026-04-14T12:00"
    end

    test "day boundary: UTC midnight viewed in UTC+2" do
      dt = ~U[2026-04-14 00:00:00Z]
      assert DateUtils.format_datetime_local(dt, "2") == "2026-04-14T02:00"
    end

    test "day boundary: UTC early morning viewed in UTC-5" do
      dt = ~U[2026-04-14 03:00:00Z]
      assert DateUtils.format_datetime_local(dt, "-5") == "2026-04-13T22:00"
    end
  end

  describe "round-trip: parse then format" do
    test "preserves the local time" do
      # User at UTC+2 picks 2026-04-14T15:30
      {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T15:30", "2")
      # Formatting back should return the exact same local time
      assert DateUtils.format_datetime_local(dt, "2") == "2026-04-14T15:30"
    end

    test "preserves local time across day boundaries" do
      {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T00:15", "2")
      assert DateUtils.format_datetime_local(dt, "2") == "2026-04-14T00:15"
    end

    test "preserves local time for negative offsets" do
      {:ok, dt} = DateUtils.parse_datetime_local("2026-04-14T23:45", "-8")
      assert DateUtils.format_datetime_local(dt, "-8") == "2026-04-14T23:45"
    end
  end
end
