defmodule PhoenixKit.Modules.Storage.RepairStorageModuleTest do
  @moduledoc """
  The Media settings' "Repair Media Module" tool on an install with more
  than one bucket: it keeps the Default profile's redundancy, lowers it
  only past what the profile's buckets can hold, puts the enabled buckets
  back into a Default profile left with none to write to, and clears a
  default-bucket setting pointing at a disabled bucket.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Profiles
  alias PhoenixKit.Settings

  defp bucket!(attrs \\ %{}) do
    {:ok, bucket} =
      Storage.create_bucket(
        Map.merge(
          %{
            name: "repair-#{System.unique_integer([:positive])}",
            provider: "local",
            endpoint: Path.join(System.tmp_dir!(), "pk_repair"),
            enabled: true,
            priority: 0
          },
          attrs
        )
      )

    bucket
  end

  defp writable_count do
    Enum.count(
      Profiles.default_profile().buckets,
      &(&1.status == "active" and &1.bucket.enabled)
    )
  end

  test "keeps a redundancy the Default profile's buckets can hold" do
    bucket!()
    bucket!()
    {:ok, _} = Storage.set_redundancy_copies(2)

    assert {:ok, repairs} = Storage.repair_storage_module()

    assert Storage.redundancy_copies() == 2
    refute Enum.any?(repairs, &match?({:copies_lowered, _}, &1))
    assert {:dimensions_reset, 10} in repairs
  end

  test "lowers a redundancy past the Default profile's writable buckets" do
    bucket!()
    bucket!()
    writable = writable_count()
    {:ok, _} = Storage.set_redundancy_copies(min(writable + 1, 5))

    assert {:ok, repairs} = Storage.repair_storage_module()

    assert Storage.redundancy_copies() == writable
    assert {:copies_lowered, writable} in repairs
  end

  test "puts enabled buckets back into a Default profile with none to write to" do
    bucket = bucket!()

    default = Profiles.default_profile()
    for row <- default.buckets, do: :ok = Profiles.remove_bucket(default, row.bucket_uuid)

    assert writable_count() == 0

    assert {:ok, repairs} = Storage.repair_storage_module()

    assert Enum.any?(repairs, &match?({:buckets_added_to_default, _}, &1))
    assert bucket.uuid in Enum.map(Profiles.default_profile().buckets, & &1.bucket_uuid)
  end

  test "clears a default bucket setting that points at a disabled bucket" do
    bucket!()
    disabled = bucket!(%{enabled: false})
    Settings.update_setting("storage_default_bucket_uuid", disabled.uuid)

    assert {:ok, repairs} = Storage.repair_storage_module()

    assert :default_bucket_cleared in repairs
    assert Settings.get_setting("storage_default_bucket_uuid", nil) in [nil, ""]
  end
end
