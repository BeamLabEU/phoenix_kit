defmodule PhoenixKit.Modules.Storage.VariantSharedSourceTest do
  @moduledoc """
  A file's sizes are made from one fetch of its original, and the page hears
  as soon as the small ones are stored.

  `ProcessFileJob` fetched the original once to read it and then once more per
  size (eight downloads for a set of seven, of a video too), and said the file
  was processed only when the last size was stored, so a photo waited for its
  largest size and a video for its renditions before a grid could show it.
  """

  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.{Libraries, ProcessFileJob, Profiles, VariantGenerator}
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.Users.Auth

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_shared_source_#{n}")
    bucket_root = Path.join(root, "bucket")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "shared-source-#{n}",
        provider: "local",
        endpoint: bucket_root,
        enabled: true,
        priority: 0
      })

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, profile} = Profiles.create_profile(%{name: "Shared #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})
    {:ok, set} = VariantSets.create_variant_set(%{name: "Shared #{n}"})
    {:ok, library} = Libraries.create_system_library(%{name: "Shared #{n}"})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)
    {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "shared-source-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{set: set, library: library, user: user, dir: root, bucket_root: bucket_root}
  end

  defp imagemagick? do
    match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))
  rescue
    _ -> false
  end

  defp store!(ctx) do
    src = Path.join(ctx.dir, "src")
    File.mkdir_p!(src)
    path = Path.join(src, "p#{System.unique_integer([:positive])}.jpg")

    {_, 0} =
      System.cmd("convert", ["-size", "2400x1200", "gradient:red-blue", "jpg:" <> path],
        stderr_to_stdout: true
      )

    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "jpg", "p.jpg",
        library_uuid: ctx.library.uuid
      )

    {file, path}
  end

  defp names(file),
    do: file.uuid |> Storage.list_file_instances() |> Enum.map(& &1.variant_name) |> Enum.sort()

  test "early_size?/3: small stills, not big ones, not a video's renditions" do
    image = %{file_type: "image"}
    video = %{file_type: "video"}

    assert VariantGenerator.early_size?(image, %{width: 300, height: 300, format: "jpg"})
    assert VariantGenerator.early_size?(image, %{width: 800, height: nil, format: nil})
    refute VariantGenerator.early_size?(image, %{width: 1920, height: nil, format: "jpg"})
    refute VariantGenerator.early_size?(image, %{width: nil, height: nil, format: "jpg"})
    assert VariantGenerator.early_size?(video, %{width: 300, height: nil, format: "jpg"})
    refute VariantGenerator.early_size?(video, %{width: 300, height: nil, format: "mp4"})
    refute VariantGenerator.early_size?(video, %{width: nil, height: 720, format: nil})
  end

  test "every size is made from the copy the caller holds: the original is not fetched", ctx do
    if imagemagick?() do
      {file, path} = store!(ctx)

      original = Storage.get_file_instance_by_name(file.uuid, "original")
      # Nothing can be fetched from the bucket any more.
      stored = Path.join(ctx.bucket_root, original.file_name)
      assert File.exists?(stored)
      File.rm!(stored)

      assert {:ok, variants} =
               VariantGenerator.generate_variants(file, source: {path, original.file_name})

      assert variants != []
      # The set a library starts with: thumbnail, small, medium, large.
      assert names(file) == ~w(large medium original small thumbnail)
      # The caller's copy is the caller's to remove.
      assert File.exists?(path)
    end
  end

  test "on_early is called once, when the small sizes are stored and a big one is not", ctx do
    if imagemagick?() do
      {file, _path} = store!(ctx)
      test = self()

      assert {:ok, _} =
               VariantGenerator.generate_variants(file,
                 on_early: fn -> send(test, {:early, names(file)}) end
               )

      assert_received {:early, seen}
      assert "thumbnail" in seen and "small" in seen and "medium" in seen
      refute_received {:early, _}
    end
  end

  test "on_early is not called when no bigger size follows", ctx do
    if imagemagick?() do
      {file, _path} = store!(ctx)
      test = self()

      assert {:ok, [_]} =
               VariantGenerator.generate_variants(file,
                 dimensions: ["small"],
                 on_early: fn -> send(test, :early) end
               )

      refute_received :early
    end
  end

  test "read_metadata/2 makes a new file active from a local copy, and says so", ctx do
    if imagemagick?() do
      {file, path} = store!(ctx)
      uuid = file.uuid
      assert file.status == "processing"
      Storage.subscribe_to_file_events()

      assert ProcessFileJob.read_metadata(uuid, path) == :ok
      assert_received {:phoenix_kit_file_processed, ^uuid}

      assert %{status: "active", width: 2400, height: 1200} = Storage.get_file(uuid)
      # Its sizes are still to be made: that is the job's work.
      assert names(file) == ~w(original)

      # Not a second time, and not for a file that is not there.
      assert ProcessFileJob.read_metadata(uuid, path) == :skipped
      assert ProcessFileJob.read_metadata(Ecto.UUID.generate(), path) == :skipped
      refute_received {:phoenix_kit_file_processed, ^uuid}

      # The job after it says nothing until the small sizes are in.
      :ok =
        ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => uuid, "filename" => "p.jpg"}})

      assert_received {:phoenix_kit_file_processed, ^uuid}
      assert_received {:phoenix_kit_file_processed, ^uuid}
      refute_received {:phoenix_kit_file_processed, ^uuid}
    end
  end

  test "read_metadata/2 leaves a file it cannot read to the job", ctx do
    if imagemagick?() do
      {file, _path} = store!(ctx)
      missing = Path.join(ctx.dir, "gone.jpg")
      assert ProcessFileJob.read_metadata(file.uuid, missing) == :skipped
      assert Storage.get_file(file.uuid).status == "processing"
    end
  end

  test "the job says the file is processed early and again at the end", ctx do
    if imagemagick?() do
      {file, _path} = store!(ctx)
      uuid = file.uuid
      Storage.subscribe_to_file_events()

      :ok =
        ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => uuid, "filename" => "p.jpg"}})

      # When its metadata is in, when its small sizes are, and at the end.
      assert_received {:phoenix_kit_file_processed, ^uuid}
      assert_received {:phoenix_kit_file_processed, ^uuid}
      assert_received {:phoenix_kit_file_processed, ^uuid}
      assert Storage.get_file(uuid).status == "active"
      assert names(file) == ~w(large medium original small thumbnail)
    end
  end
end
