defmodule PhoenixKit.Modules.Storage.ProfilesAdviceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{ProfileBucket, Profiles, StorageProfile}

  defp row(name, role, opts \\ []) do
    %ProfileBucket{
      role: role,
      status: Keyword.get(opts, :status, "active"),
      bucket: %{
        name: name,
        provider: Keyword.get(opts, :provider, "local"),
        enabled: Keyword.get(opts, :enabled, true)
      }
    }
  end

  defp cloud(name, role, opts \\ []), do: row(name, role, Keyword.put(opts, :provider, "r2"))

  defp profile(rows, local, cloud \\ 0),
    do: %StorageProfile{buckets: rows, copies_local: local, copies_cloud: cloud}

  test "the counts are per kind of bucket, and the total is their sum" do
    profile = profile([row("A", "primary"), cloud("B", "primary")], 1, 1)

    assert Profiles.copies(profile, :local) == 1
    assert Profiles.copies(profile, :cloud) == 1
    assert Profiles.copies_total(profile) == 2

    assert %{writable: 2, copies: 2, local: %{buckets: 1}, cloud: %{buckets: 1}} =
             Profiles.copies_advice(profile)
  end

  test "a replica of a kind is idle while that kind's count stays within its primaries" do
    advice = Profiles.copies_advice(profile([row("A", "primary"), row("B", "replica")], 1))

    assert %{local: %{buckets: 2, primaries: 1, copies: 1, idle: ["B"]}} = advice
  end

  test "a backup counts the same way" do
    assert %{local: %{idle: ["B"]}} =
             Profiles.copies_advice(profile([row("A", "primary"), row("B", "backup")], 1))
  end

  test "two local copies reach the replica: nothing idle" do
    assert %{local: %{idle: []}} =
             Profiles.copies_advice(profile([row("A", "primary"), row("B", "replica")], 2))
  end

  test "each kind has its own idle buckets" do
    advice =
      Profiles.copies_advice(
        profile(
          [row("A", "primary"), row("B", "replica"), cloud("C", "primary"), cloud("D", "backup")],
          1,
          1
        )
      )

    assert %{local: %{idle: ["B"]}, cloud: %{idle: ["D"]}} = advice
  end

  test "a kind with no copies wanted has no idle buckets: none of it is written at all" do
    assert %{cloud: %{idle: [], copies: 0, buckets: 2}} =
             Profiles.copies_advice(
               profile([row("A", "primary"), cloud("B", "primary"), cloud("C", "replica")], 1)
             )
  end

  test "a bucket that cannot take new files does not count" do
    advice =
      Profiles.copies_advice(
        profile(
          [
            row("A", "primary"),
            row("B", "replica", status: "read_only"),
            row("D", "replica", enabled: false)
          ],
          1
        )
      )

    assert %{writable: 1, local: %{buckets: 1, idle: []}} = advice
  end

  describe "split_copies/2 (a count that knows no kinds)" do
    test "local first, the rest on the cloud buckets there are" do
      p = profile([row("A", "primary"), cloud("B", "primary"), cloud("C", "primary")], 1)

      assert %{copies_local: 1, copies_cloud: 0} = Profiles.split_copies(p, 1)
      assert %{copies_local: 1, copies_cloud: 1} = Profiles.split_copies(p, 2)
      assert %{copies_local: 1, copies_cloud: 2} = Profiles.split_copies(p, 3)
      # More than the buckets: the surplus stays local, where it will be capped.
      assert %{copies_local: 2, copies_cloud: 2} = Profiles.split_copies(p, 4)
    end

    test "only cloud buckets: all cloud" do
      p = profile([cloud("A", "primary"), cloud("B", "primary")], 1)
      assert %{copies_local: 0, copies_cloud: 2} = Profiles.split_copies(p, 2)
    end

    test "a bucket that cannot take files is not counted" do
      p = profile([row("A", "primary"), cloud("B", "primary", status: "read_only")], 1)
      assert %{copies_local: 2, copies_cloud: 0} = Profiles.split_copies(p, 2)
    end
  end

  describe "fit_copies/1" do
    test "each count is lowered to the buckets of its kind, never raised" do
      p = profile([row("A", "primary"), cloud("B", "primary")], 3, 2)
      assert %{copies_local: 1, copies_cloud: 1} = Profiles.fit_copies(p)

      p = profile([row("A", "primary"), row("B", "primary"), cloud("C", "primary")], 1, 1)
      assert %{copies_local: 1, copies_cloud: 1} = Profiles.fit_copies(p)
    end

    test "a profile that wants only a kind it has no bucket of is split over what it has" do
      p = profile([cloud("A", "primary"), cloud("B", "primary")], 2, 0)
      assert %{copies_local: 0, copies_cloud: 2} = Profiles.fit_copies(p)
    end
  end
end
