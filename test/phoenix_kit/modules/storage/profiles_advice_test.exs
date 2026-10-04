defmodule PhoenixKit.Modules.Storage.ProfilesAdviceTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Storage.{ProfileBucket, Profiles, StorageProfile}

  defp row(name, role, opts \\ []) do
    %ProfileBucket{
      role: role,
      status: Keyword.get(opts, :status, "active"),
      stores: Keyword.get(opts, :stores, "all"),
      bucket: %{name: name, enabled: Keyword.get(opts, :enabled, true)}
    }
  end

  defp profile(rows, copies), do: %StorageProfile{buckets: rows, copies_originals: copies}

  test "one primary and a replica at one copy: the replica is idle and 2 is recommended" do
    advice = Profiles.copies_advice(profile([row("A", "primary"), row("B", "replica")], 1))

    assert %{writable: 2, primaries: 1, copies: 1, idle: ["B"], recommended: 2} = advice
  end

  test "a backup counts the same way" do
    assert %{idle: ["B"], recommended: 2} =
             Profiles.copies_advice(profile([row("A", "primary"), row("B", "backup")], 1))
  end

  test "two copies reach the replica: nothing idle, nothing to recommend" do
    assert %{idle: [], recommended: nil} =
             Profiles.copies_advice(profile([row("A", "primary"), row("B", "replica")], 2))
  end

  test "several primaries: the replica is idle but no count is recommended" do
    advice =
      Profiles.copies_advice(
        profile([row("A", "primary"), row("B", "primary"), row("C", "replica")], 1)
      )

    assert %{primaries: 2, idle: ["C"], recommended: nil} = advice
  end

  test "primaries only: nothing is idle" do
    assert %{writable: 2, primaries: 2, idle: [], recommended: nil} =
             Profiles.copies_advice(profile([row("A", "primary"), row("B", "primary")], 1))
  end

  test "a bucket that cannot take originals does not count" do
    advice =
      Profiles.copies_advice(
        profile(
          [
            row("A", "primary"),
            row("B", "replica", status: "read_only"),
            row("C", "replica", stores: "derived"),
            row("D", "replica", enabled: false)
          ],
          1
        )
      )

    assert %{writable: 1, idle: [], recommended: nil} = advice
  end
end
