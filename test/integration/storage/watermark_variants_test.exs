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
    Library,
    Manager,
    ProcessFileJob,
    Profiles,
    Reconciler,
    VariantSets,
    Watermark
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

  # Writes the watermark as it is, past the checks of a save: what a logo whose
  # file has changed since it was saved looks like at drawing time.
  defp force_watermark!(ctx, attrs) do
    {:ok, watermark} =
      %Watermark{}
      |> Watermark.changeset(Map.merge(%{"enabled" => "true", "text" => "example.com"}, attrs))
      |> Ecto.Changeset.apply_action(:insert)

    ctx.set.uuid
    |> VariantSets.get_variant_set()
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.put_embed(:watermark, watermark)
    |> PhoenixKit.RepoHelper.repo().update!()
  end

  defp move_to_library!(file, library_uuid) do
    {1, _} =
      PhoenixKit.RepoHelper.repo().update_all(
        Ecto.Query.from(f in Storage.File, where: f.uuid == ^file.uuid),
        set: [library_uuid: library_uuid]
      )
  end

  defp hidden_library! do
    n = System.unique_integer([:positive])

    {:ok, hidden} =
      Libraries.create_system_library(%{name: "Hidden #{n}", slug: "hidden-wm-#{n}"},
        hidden: true
      )

    hidden
  end

  defp user_library!(user) do
    n = System.unique_integer([:positive])

    PhoenixKit.RepoHelper.repo().insert!(%Library{
      name: "Mine #{n}",
      slug: "mine-wm-#{n}",
      kind: "user",
      visibility: "private",
      owner_uuid: user.uuid,
      key_prefix: "u#{n}"
    })
  end

  defp logo_error(changeset) do
    {message, _} = changeset.changes.watermark.errors[:logo_file_uuid]
    message
  end

  test "a watermark that cannot be drawn leaves a clean size, a logged error and a working upload",
       ctx do
    force_watermark!(ctx, %{
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

  defp store_logo!(ctx, colour, library_uuid \\ nil) do
    dir = Path.join(ctx.dir, "logo")
    File.mkdir_p!(dir)
    path = Path.join(dir, "logo#{System.unique_integer([:positive])}.png")
    # A comment of its own: two logos of one colour are two files, not a duplicate.
    {_, 0} =
      System.cmd("convert", ["-size", "60x60", "xc:#{colour}", "-set", "comment", path, path])

    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, logo} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "logo.png",
        library_uuid: library_uuid || ctx.library.uuid
      )

    logo
  end

  defp corner_logo!(ctx, logo) do
    watermark!(ctx, %{
      "mode" => "corner",
      "corner" => "top_left",
      "text" => "",
      "logo_file_uuid" => logo.uuid,
      "opacity" => "100",
      "margin_percent" => "0",
      "dimensions" => ["wm_big"]
    })
  end

  # The mean of one channel (0-1) of the top-left corner of `file`'s `wm_big`.
  defp corner_mean(file, channel) do
    {:ok, big} = Manager.retrieve_file(instance(file, "wm_big").file_name)

    {out, 0} =
      System.cmd("convert", [
        big,
        "-crop",
        "20x20+5+5",
        "-format",
        "%[fx:mean.#{channel}]",
        "info:"
      ])

    {mean, _} = out |> String.trim() |> Float.parse()
    mean
  end

  test "a logo from storage is drawn", ctx do
    corner_logo!(ctx, store_logo!(ctx, "blue"))

    {file, _source} = upload!(ctx)
    assert size(file, "wm_big") == {300, 150}
    assert corner_mean(file, "b") > 0.9
  end

  test "a logo whose pixels change under the same file is redrawn on the next check", ctx do
    logo = store_logo!(ctx, "blue")
    set = corner_logo!(ctx, logo)
    {file, _source} = upload!(ctx)
    assert corner_mean(file, "b") > 0.9
    old_key = instance(file, "wm_big").file_name

    # The logo edited in place, as an image edit does: new bytes under its
    # original's key... (here written over the object) and a new checksum.
    original = instance(logo, "original")
    green = Path.join(ctx.dir, "green.png")
    {_, 0} = System.cmd("convert", ["-size", "60x60", "xc:lime", green])
    File.cp!(green, Path.join(ctx.dir, original.file_name))
    sha = :sha256 |> :crypto.hash(File.read!(green)) |> Base.encode16(case: :lower)

    {1, _} =
      PhoenixKit.RepoHelper.repo().update_all(
        Ecto.Query.from(f in Storage.File, where: f.uuid == ^logo.uuid),
        set: [file_checksum: sha]
      )

    :ok = VariantSets.check_files(set)
    assert Reconciler.reconcile_file(Storage.get_file(file.uuid)) == :reconciled

    refute instance(file, "wm_big").file_name == old_key
    assert corner_mean(file, "g") > 0.9
    assert corner_mean(file, "b") < 0.1
  end

  describe "the logo must be one anyone may see" do
    test "a missing file, a file that is not an image, a user's or a hidden library's is refused at save",
         ctx do
      set = VariantSets.get_variant_set(ctx.set.uuid)

      attrs =
        &%{"enabled" => "true", "text" => "", "logo_file_uuid" => &1, "dimensions" => ["wm_big"]}

      assert {:error, cs} = VariantSets.update_watermark(set, attrs.(Ecto.UUID.generate()))
      assert logo_error(cs) =~ "no stored file"

      {:ok, doc} =
        Storage.store_file_in_buckets(
          Path.join(File.cwd!(), "mix.exs"),
          "document",
          ctx.user.uuid,
          String.duplicate("d", 64),
          "txt",
          "notes.txt",
          library_uuid: ctx.library.uuid
        )

      assert {:error, cs} = VariantSets.update_watermark(set, attrs.(doc.uuid))
      assert logo_error(cs) =~ "must be an image"

      hidden_logo = store_logo!(ctx, "blue")
      move_to_library!(hidden_logo, hidden_library!().uuid)
      assert {:error, cs} = VariantSets.update_watermark(set, attrs.(hidden_logo.uuid))
      assert logo_error(cs) =~ "site library everyone can see"

      user_logo = store_logo!(ctx, "blue")
      move_to_library!(user_logo, user_library!(ctx.user).uuid)
      assert {:error, cs} = VariantSets.update_watermark(set, attrs.(user_logo.uuid))
      assert logo_error(cs) =~ "site library everyone can see"

      assert VariantSets.get_variant_set(ctx.set.uuid).watermark == nil

      # Off, it is not checked (nothing is drawn); a site library's image is fine.
      assert {:ok, _} =
               VariantSets.update_watermark(set, %{
                 attrs.(user_logo.uuid)
                 | "enabled" => "false"
               })

      assert {:ok, _} =
               VariantSets.update_watermark(
                 VariantSets.get_variant_set(ctx.set.uuid),
                 attrs.(store_logo!(ctx, "blue").uuid)
               )
    end

    test "a trashed logo cannot be used in a public rendition", ctx do
      logo = store_logo!(ctx, "blue")
      {:ok, _} = Storage.trash_file(logo)
      assert {:error, :logo_not_found} = VariantSets.watermark_logo(logo.uuid)
    end

    test "a logo that has become private since it was saved is not drawn", ctx do
      logo = store_logo!(ctx, "blue")
      corner_logo!(ctx, logo)
      move_to_library!(logo, hidden_library!().uuid)

      log = capture_log(fn -> send(self(), {:uploaded, upload!(ctx)}) end)
      assert_received {:uploaded, {file, _source}}

      assert log =~ "logo_refused"
      assert log =~ "logo_not_public"
      # The clean size, under its clean hash.
      assert instance(file, "wm_big").spec_hash == VariantSets.spec_hash(ctx.big)
      assert corner_mean(file, "b") < 0.1
    end
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
