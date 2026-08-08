defmodule PhoenixKit.Migrations.Repair.CommentPolicyTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Migrations.Repair.CommentPolicy

  # `floor` is deliberately NOT `PhoenixKit.Migrations.Postgres.initial_version/0`
  # (currently 1 on the un-squashed chain) anywhere in this file — the whole
  # point of `CommentPolicy` is to be correct for the POST-squash floor too
  # (see the module's moduledoc). 121 is the spec's own running floor
  # candidate; 151 mirrors the current `current_version/0`.
  @floor 121
  @current 151

  describe "classify/3" do
    test "table absent → :not_installed" do
      assert CommentPolicy.classify(:absent, @floor, @current) == :not_installed
    end

    test "comment NULL (table exists) → :adopt_required" do
      assert CommentPolicy.classify(nil, @floor, @current) == :adopt_required
    end

    test "phantom comment 0 is treated the same as NULL → :adopt_required" do
      assert CommentPolicy.classify(0, @floor, @current) == :adopt_required
    end

    test "0 < comment < floor → :below_floor" do
      assert CommentPolicy.classify(1, @floor, @current) == {:below_floor, 1}
      assert CommentPolicy.classify(@floor - 1, @floor, @current) == {:below_floor, @floor - 1}
    end

    test "comment == floor → in range (boundary inclusive)" do
      assert CommentPolicy.classify(@floor, @floor, @current) == {:in_range, @floor}
    end

    test "floor < comment < current → :in_range" do
      mid = div(@floor + @current, 2)
      assert CommentPolicy.classify(mid, @floor, @current) == {:in_range, mid}
    end

    test "comment == current → in range (boundary inclusive)" do
      assert CommentPolicy.classify(@current, @floor, @current) == {:in_range, @current}
    end

    test "comment > current → :above_current" do
      assert CommentPolicy.classify(@current + 1, @floor, @current) ==
               {:above_current, @current + 1}
    end

    test "unreachable today (floor == 1): the same boundary values that trigger :below_floor at floor 121 do not at floor 1" do
      # `PhoenixKit.Migrations.Postgres.initial_version/0` is 1 on the
      # current, un-squashed chain — no integer satisfies `0 < comment < 1`,
      # so :below_floor is provably unreachable there today. The 121-floor
      # tests above are what actually exercise the branch; this test only
      # confirms the two candidate boundary values fall through to the
      # OTHER branches instead of somehow still matching :below_floor.
      assert CommentPolicy.classify(0, 1, @current) == :adopt_required
      assert CommentPolicy.classify(1, 1, @current) == {:in_range, 1}
    end
  end

  describe "marker_cross_check/2" do
    test "schema ahead of comment → :stale_low" do
      assert CommentPolicy.marker_cross_check(135, 140) == {:stale_low, 140}
    end

    test "schema behind comment → :ahead_of_schema" do
      assert CommentPolicy.marker_cross_check(135, 130) == {:ahead_of_schema, 130}
    end

    test "agreement → :consistent" do
      assert CommentPolicy.marker_cross_check(135, 135) == :consistent
    end
  end

  describe "highest_fully_present_version/1" do
    test "stops at the first gap, regardless of what is present after it" do
      presence = [{53, true}, {114, true}, {137, false}, {142, true}]
      assert CommentPolicy.highest_fully_present_version(presence) == 114
    end

    test "unordered input is sorted before scanning" do
      presence = [{142, true}, {53, true}, {114, true}]
      assert CommentPolicy.highest_fully_present_version(presence) == 142
    end

    test "everything present" do
      assert CommentPolicy.highest_fully_present_version([{1, true}, {2, true}]) == 2
    end

    test "nothing present at all → 0" do
      assert CommentPolicy.highest_fully_present_version([{1, false}]) == 0
    end

    test "empty input → 0" do
      assert CommentPolicy.highest_fully_present_version([]) == 0
    end
  end

  describe "should_heal_comment?/2" do
    test "stale_low + flag → heals to the target" do
      assert CommentPolicy.should_heal_comment?({:stale_low, 140}, true) == {:heal, 140}
    end

    test "stale_low without the flag → no heal (requires explicit opt-in)" do
      assert CommentPolicy.should_heal_comment?({:stale_low, 140}, false) == :no_heal
    end

    test "consistent, even with the flag → no heal (nothing to heal)" do
      assert CommentPolicy.should_heal_comment?(:consistent, true) == :no_heal
    end

    test "ahead_of_schema, even with the flag → no heal (R1: never implicitly lower the comment)" do
      assert CommentPolicy.should_heal_comment?({:ahead_of_schema, 130}, true) == :no_heal
    end
  end

  describe "adopt_outcome/2" do
    test "clean → stamps the floor" do
      assert CommentPolicy.adopt_outcome(true, @floor) == {:stamp, @floor}
    end

    test "not clean → no stamp" do
      assert CommentPolicy.adopt_outcome(false, @floor) == :no_stamp
    end
  end

  describe "floor_verify_clean?/1" do
    test "no findings → clean" do
      assert CommentPolicy.floor_verify_clean?([])
    end

    test "only info-severity findings → clean" do
      findings = [
        %{kind: :pending, severity: :info},
        %{kind: :legacy_optional_absent, severity: :info}
      ]

      assert CommentPolicy.floor_verify_clean?(findings)
    end

    test "a :missing finding (dry-run adopt preview) → not clean, even though its severity is :repairable" do
      findings = [%{kind: :missing, severity: :repairable}]
      refute CommentPolicy.floor_verify_clean?(findings)
    end

    test "any error-severity finding → not clean" do
      findings = [%{kind: :wrong_shape, severity: :error}]
      refute CommentPolicy.floor_verify_clean?(findings)
    end

    test "a real (non-dry-run) :repaired finding does not itself block cleanliness" do
      findings = [%{kind: :repaired, severity: :repairable}]
      assert CommentPolicy.floor_verify_clean?(findings)
    end
  end

  describe "concurrent_migration?/2" do
    test "identical reads → false" do
      refute CommentPolicy.concurrent_migration?(135, 135)
      refute CommentPolicy.concurrent_migration?(nil, nil)
      refute CommentPolicy.concurrent_migration?(:absent, :absent)
    end

    test "an increase between reads → true (a concurrent up/1 advanced the comment)" do
      assert CommentPolicy.concurrent_migration?(135, 142)
    end

    test "a decrease between reads → true (a concurrent down/1 rolled it back)" do
      assert CommentPolicy.concurrent_migration?(142, 135)
    end

    test "NULL → numeric between reads → true" do
      assert CommentPolicy.concurrent_migration?(nil, 121)
    end
  end

  doctest CommentPolicy
end
