defmodule PhoenixKit.Modules.Storage.HdrVariantsTest do
  @moduledoc """
  An HDR photo's larger renditions keep the gain map; its thumbnails, a plain photo's
  renditions and a photo whose map cannot be carried over are made the ordinary way.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.TestSupport.GainMapJpeg
  alias PhoenixKit.Users.Auth

  @moduletag :tmp_dir
  @buckets_cache :phoenix_kit_buckets_cache

  unless System.find_executable("convert") && System.find_executable("identify"),
    do: @moduletag(skip: "ImageMagick (convert, identify) is not installed")

  setup %{tmp_dir: tmp} do
    :persistent_term.erase(@buckets_cache)
    n = System.unique_integer([:positive])
    Repo.update_all(Bucket, set: [enabled: false])
    on_exit(fn -> :persistent_term.erase(@buckets_cache) end)

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "hdrv-#{n}",
        provider: "local",
        endpoint: Path.join(tmp, "bucket"),
        enabled: true,
        priority: 0
      })

    {:ok, user} =
      Auth.register_user(%{"email" => "hdrv-#{n}@example.com", "password" => "ValidPassword123!"})

    %{tmp: tmp, user: user, bucket: bucket}
  end

  defp upload!(ctx, path) do
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    file =
      case Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "jpg", "photo.jpg") do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    :ok =
      ProcessFileJob.perform(%Oban.Job{
        args: %{"file_uuid" => file.uuid, "filename" => "photo.jpg"}
      })

    Storage.get_file(file.uuid)
  end

  defp stored(ctx, file, name) do
    instance = Storage.get_file_instance_by_name(file.uuid, name)
    Path.join(Local.root(ctx.bucket), instance.file_name)
  end

  test "by default an HDR photo's medium and large keep the gain map; its small sizes do not",
       ctx do
    path = Path.join(ctx.tmp, "hdr.jpg")
    GainMapJpeg.build(path, width: 2400, height: 1800)
    file = upload!(ctx, path)

    assert %{"gain_map" => true} = file.metadata["hdr"]

    for name <- ~w(medium large) do
      assert %{"gain_map" => true, "kinds" => ["ultrahdr"]} = Hdr.read(stored(ctx, file, name)),
             "#{name} keeps the map"
    end

    for name <- ~w(small thumbnail) do
      assert Hdr.read(stored(ctx, file, name)) == %{}, "#{name} is an ordinary JPEG"
    end

    # The rendition is a normal picture to the rest of the app.
    assert %{width: 800} = Storage.get_file_instance_by_name(file.uuid, "medium")
  end

  test "which sizes keep the map is the size's own setting", ctx do
    import Ecto.Query
    alias PhoenixKit.Modules.Storage.Dimension
    alias PhoenixKit.Modules.Storage.VariantSets

    set = fn name ->
      Repo.one!(
        from d in Dimension,
          where: d.name == ^name and d.variant_set_uuid == ^VariantSets.default_uuid()
      )
    end

    # large off, small on: the reverse of the standard sizes.
    {:ok, _} = Storage.update_dimension(set.("large"), %{keep_hdr: false})
    {:ok, _} = Storage.update_dimension(set.("small"), %{keep_hdr: true})

    path = Path.join(ctx.tmp, "hdr.jpg")
    GainMapJpeg.build(path, width: 2400, height: 1800)
    file = upload!(ctx, path)

    assert %{"gain_map" => true} = Hdr.read(stored(ctx, file, "small"))
    assert %{"gain_map" => true} = Hdr.read(stored(ctx, file, "medium"))
    assert Hdr.read(stored(ctx, file, "large")) == %{}
    assert Hdr.read(stored(ctx, file, "thumbnail")) == %{}
  end

  test "a plain photo's renditions are as they always were", ctx do
    path = Path.join(ctx.tmp, "plain.jpg")
    {_, 0} = System.cmd("convert", ["-size", "2400x1800", "gradient:white-black", path])
    file = upload!(ctx, path)

    assert file.metadata["hdr"] == %{}
    assert Hdr.read(stored(ctx, file, "large")) == %{}
  end

  test "with hdr_renditions off every size is ordinary", ctx do
    Application.put_env(:phoenix_kit, :hdr_renditions, false)
    on_exit(fn -> Application.delete_env(:phoenix_kit, :hdr_renditions) end)

    path = Path.join(ctx.tmp, "hdr.jpg")
    GainMapJpeg.build(path, width: 2400, height: 1800)
    file = upload!(ctx, path)

    assert %{"gain_map" => true} = file.metadata["hdr"]
    assert Hdr.read(stored(ctx, file, "large")) == %{}
  end
end
