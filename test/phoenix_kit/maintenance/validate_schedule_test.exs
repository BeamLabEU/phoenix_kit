defmodule PhoenixKit.Modules.Maintenance.ValidateScheduleTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Maintenance

  # Helper: a DateTime N seconds from now
  defp future(seconds), do: DateTime.add(DateTime.utc_now(), seconds, :second)
  defp past(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  describe "validate_schedule/2 — empty input" do
    test "rejects both nil" do
      assert {:error, :empty} = Maintenance.validate_schedule(nil, nil)
    end
  end

  describe "validate_schedule/2 — past dates" do
    test "rejects start in the past" do
      assert {:error, :start_in_past} = Maintenance.validate_schedule(past(3600), nil)
    end

    test "rejects end in the past" do
      assert {:error, :end_in_past} = Maintenance.validate_schedule(nil, past(3600))
    end

    test "rejects start in past when end is also given" do
      assert {:error, :start_in_past} =
               Maintenance.validate_schedule(past(3600), future(7200))
    end
  end

  describe "validate_schedule/2 — tolerance for clock drift and minute precision" do
    test "allows start 30 seconds in the past (within tolerance)" do
      assert :ok = Maintenance.validate_schedule(past(30), future(3600))
    end

    test "allows end 30 seconds in the past (within tolerance)" do
      # End barely in past is still allowed by 60s tolerance, but then end_before_start
      # or end_in_past might kick in. Test with only end, within tolerance:
      assert :ok = Maintenance.validate_schedule(nil, past(30))
    end

    test "rejects start 61 seconds in the past (outside tolerance)" do
      assert {:error, :start_in_past} = Maintenance.validate_schedule(past(61), nil)
    end
  end

  describe "validate_schedule/2 — ordering" do
    test "rejects end before start" do
      assert {:error, :end_before_start} =
               Maintenance.validate_schedule(future(7200), future(3600))
    end

    test "rejects end equal to start" do
      dt = future(3600)
      assert {:error, :end_before_start} = Maintenance.validate_schedule(dt, dt)
    end

    test "accepts end after start" do
      assert :ok = Maintenance.validate_schedule(future(3600), future(7200))
    end
  end

  describe "validate_schedule/2 — upper bound" do
    test "rejects start more than a year in the future" do
      too_far = 366 * 24 * 60 * 60
      assert {:error, :too_far_future} = Maintenance.validate_schedule(future(too_far), nil)
    end

    test "rejects end more than a year in the future" do
      too_far = 366 * 24 * 60 * 60
      assert {:error, :too_far_future} = Maintenance.validate_schedule(nil, future(too_far))
    end

    test "accepts dates exactly 365 days out" do
      one_year = 365 * 24 * 60 * 60 - 60
      assert :ok = Maintenance.validate_schedule(nil, future(one_year))
    end
  end

  describe "validate_schedule/2 — happy paths" do
    test "accepts start only" do
      assert :ok = Maintenance.validate_schedule(future(3600), nil)
    end

    test "accepts end only" do
      assert :ok = Maintenance.validate_schedule(nil, future(3600))
    end

    test "accepts both" do
      assert :ok = Maintenance.validate_schedule(future(3600), future(7200))
    end
  end
end
