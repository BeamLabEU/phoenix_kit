defmodule PhoenixKit.Modules.Storage.WatermarkVariantsTest do
  @moduledoc """
  A variant set's watermark (V237) at variant generation: the sizes it names are
  drawn on (a strip makes them taller), the others and the original stay as they
  were; their spec hash says so; a change to the watermark bumps the set's
  revision and the reconciler remakes exactly the sizes whose pixels change; a
  watermark that cannot be drawn leaves a clean size and a logged error, never a
  failed upload; and a renamed size keeps its place in the watermark.
  """
  use PhoenixKit.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    Libraries,
    Manager,
    ProcessFileJob,
    Profiles,
    Reconciler,
    VariantSets
  }

  alias PhoenixKit.Users.Auth

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_watermark_#{n}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "watermark-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, profile} = Profiles.create_profile(%{name: "Watermark #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})
    {:ok, set} = VariantSets.create_variant_set(%{name: "Marked #{n}"})
    {:ok, library} = Libraries.create_system_library(%{name: "Marked #{n}"})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)
    {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid)

    {:ok, big} =
      Storage.create_dimension(
        %{name: "wm_big", width: 300, quality: 90, applies_to: "image", format: "png"},
        set.uuid
      )

    {:ok, small} =
      Storage.create_dimension(
        %{name: "wm_small", width: 100, quality: 90, applies_to: "image", format: "png"},
        set.uuid
      )

    {:ok, user} =
      Auth.register_user(%{
        "email" => "watermark-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{set: set, library: library, user: user, dir: root, big: big, small: small}
  end

  defp upload!(ctx) do
    dir = Path.join(ctx.dir, "src")
    File.mkdir_p!(dir)
    path = Path.join(dir, "p#{System.unique_integer([:positive])}.png")
    {_, 0} = System.cmd("convert", ["-size", "400x200", "xc:red", path])
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "p.png",
        library_uuid: ctx.library.uuid
      )

    :ok =
      ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => file.uuid, "filename" => "p.png"}})

    {Storage.get_file(file.uuid), File.read!(path)}
  end

  defp instance(file, name), do: Storage.get_file_instance_by_name(file.uuid, name)
  defp size(file, name), do: {instance(file, name).width, instance(file, name).height}

  defp stored_size(file, name) do
    {:ok, path} = Manager.retrieve_file(instance(file, name).file_name)
    {out, 0} = System.cmd("identify", ["-format", "%w %h", path])
    out |> String.split() |> Enum.map(&String.to_integer/1) |> List.to_tuple()
  end

  defp watermark!(ctx, attrs) do
    {:ok, set} =
      VariantSets.update_watermark(
        VariantSets.get_variant_set(ctx.set.uuid),
        Map.merge(%{"enabled" => "true", "text" => "example.com"}, attrs)
      )

    set
  end

  test "only the sizes it names are watermarked; the others and the original are not", ctx do
    set = watermark!(ctx, %{"dimensions" => ["wm_big"]})
    {file, source} = upload!(ctx)

    # 300x150, then a strip of 24 px (6% of 300 is less than the least).
    assert size(file, "wm_big") == {300, 174}
    assert stored_size(file, "wm_big") == {300, 174}
    assert size(file, "wm_small") == {100, 50}
    assert stored_size(file, "wm_small") == {100, 50}

    {:ok, original} = Manager.retrieve_file(instance(file, "original").file_name)
    assert File.read!(original) == source

    marked = %{ctx.big | watermark: set.watermark}
    assert instance(file, "wm_big").spec_hash == VariantSets.spec_hash(marked)
    refute instance(file, "wm_big").spec_hash == VariantSets.spec_hash(ctx.big)
    assert instance(file, "wm_small").spec_hash == VariantSets.spec_hash(ctx.small)
    assert file.placed_variant_revision == set.revision
  end

  test "a change bumps the revision and the reconciler remakes the sizes it touches", ctx do
    watermark!(ctx, %{"dimensions" => ["wm_big"]})
    {file, _source} = upload!(ctx)
    small_key = instance(file, "wm_small").file_name

    before = VariantSets.get_variant_set(ctx.set.uuid).revision
    set = watermark!(ctx, %{"dimensions" => ["wm_small"]})
    assert set.revision > before

    assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled

    assert size(file, "wm_big") == {300, 150}
    assert size(file, "wm_small") == {100, 74}
    refute instance(file, "wm_small").file_name == small_key
    assert instance(file, "wm_big").spec_hash == VariantSets.spec_hash(ctx.big)

    # Turned off: the sizes go back to clean.
    {:ok, _} =
      VariantSets.update_watermark(VariantSets.get_variant_set(ctx.set.uuid), %{
        "enabled" => "false"
      })

    assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled
    assert size(file, "wm_small") == {100, 50}
  end

  test "a watermark that cannot be drawn leaves a clean size, a logged error and a working upload",
       ctx do
    watermark!(ctx, %{
      "text" => "",
      "logo_file_uuid" => Ecto.UUID.generate(),
      "dimensions" => ["wm_big"]
    })

    log = capture_log(fn -> send(self(), {:uploaded, upload!(ctx)}) end)
    assert_received {:uploaded, {file, _source}}

    assert log =~ "Watermark of wm_big"
    assert size(file, "wm_big") == {300, 150}
    # Recorded as the clean size: a later check of the set's files tries again.
    assert instance(file, "wm_big").spec_hash == VariantSets.spec_hash(ctx.big)
  end

  test "a logo from storage is drawn", ctx do
    dir = Path.join(ctx.dir, "logo")
    File.mkdir_p!(dir)
    path = Path.join(dir, "logo.png")
    {_, 0} = System.cmd("convert", ["-size", "60x60", "xc:blue", path])
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, logo} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "logo.png",
        library_uuid: ctx.library.uuid
      )

    watermark!(ctx, %{
      "mode" => "corner",
      "corner" => "top_left",
      "text" => "",
      "logo_file_uuid" => logo.uuid,
      "opacity" => "100",
      "margin_percent" => "0",
      "dimensions" => ["wm_big"]
    })

    {file, _source} = upload!(ctx)
    assert size(file, "wm_big") == {300, 150}

    {:ok, big} = Manager.retrieve_file(instance(file, "wm_big").file_name)

    {out, 0} =
      System.cmd("convert", [big, "-crop", "20x20+5+5", "-format", "%[fx:mean.b]", "info:"])

    assert String.to_float(String.trim(out)) > 0.9
  end

  test "a renamed size keeps its place in the watermark", ctx do
    watermark!(ctx, %{"dimensions" => ["wm_big"]})
    {:ok, _} = Storage.update_dimension(ctx.big, %{name: "wm_huge"})
    assert VariantSets.get_variant_set(ctx.set.uuid).watermark.dimensions == ["wm_huge"]
  end

  test "an invalid watermark is not saved", ctx do
    set = VariantSets.get_variant_set(ctx.set.uuid)

    assert {:error, changeset} =
             VariantSets.update_watermark(set, %{
               "enabled" => "true",
               "text" => "x",
               "background_color" => "red",
               "dimensions" => ["wm_big"]
             })

    assert changeset.changes.watermark.errors[:background_color]
    assert VariantSets.get_variant_set(ctx.set.uuid).watermark == nil
  end
end
