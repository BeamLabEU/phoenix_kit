defmodule PhoenixKit.Modules.Storage.HdrVariantsTest do
  @moduledoc """
  An HDR photo's larger renditions keep the gain map; its thumbnails, a plain photo's
  renditions and a photo whose map cannot be carried over are made the ordinary way.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.Hdr
  alias PhoenixKit.Modules.Storage.HeifHdr
  alias PhoenixKit.Modules.Storage.ProcessFileJob
  alias PhoenixKit.Modules.Storage.Providers.Local
  alias PhoenixKit.Modules.Storage.VariantSets
  alias PhoenixKit.TestSupport.GainMapJpeg
  alias PhoenixKit.TestSupport.HeifGainMap
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

  defp upload!(ctx, path, ext \\ "jpg") do
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    file =
      case Storage.store_file_in_buckets(
             path,
             "image",
             ctx.user.uuid,
             sha,
             ext,
             "photo." <> ext
           ) do
        {:ok, file} -> file
        {:ok, file, _} -> file
      end

    :ok =
      ProcessFileJob.perform(%Oban.Job{
        args: %{"file_uuid" => file.uuid, "filename" => "photo." <> ext}
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

  test "a size cropped to a box keeps the gain map too, cut where the picture is", ctx do
    import Ecto.Query
    alias PhoenixKit.Modules.Storage.Dimension
    alias PhoenixKit.Modules.Storage.VariantSets

    square =
      Repo.one!(
        from d in Dimension,
          where: d.name == "small_square" and d.variant_set_uuid == ^VariantSets.default_uuid()
      )

    refute square.maintain_aspect_ratio
    {:ok, _} = Storage.update_dimension(square, %{keep_hdr: true})

    path = Path.join(ctx.tmp, "hdr.jpg")
    GainMapJpeg.build(path, width: 2400, height: 1800)
    file = upload!(ctx, path)

    assert %{"gain_map" => true, "kinds" => ["ultrahdr"]} =
             Hdr.read(stored(ctx, file, "small_square"))

    assert %{width: 300, height: 300} =
             Storage.get_file_instance_by_name(file.uuid, "small_square")

    # the other crops, with the setting off, are ordinary pictures
    assert Hdr.read(stored(ctx, file, "thumbnail_square")) == %{}
  end

  test "renditions leave the camera's metadata out, unless a size says otherwise", ctx do
    import Ecto.Query
    alias PhoenixKit.Modules.Storage.Dimension
    alias PhoenixKit.Modules.Storage.VariantSets
    alias PhoenixKit.Test.ExifFixture

    {:ok, _} =
      Storage.update_dimension(
        Repo.one!(
          from d in Dimension,
            where: d.name == "small" and d.variant_set_uuid == ^VariantSets.default_uuid()
        ),
        %{strip_metadata: false}
      )

    path = Path.join(ctx.tmp, "hdr.jpg")
    GainMapJpeg.build(path, width: 2400, height: 1800, exif: ExifFixture.segment(%{make: "Cam"}))
    file = upload!(ctx, path)

    make = fn name ->
      {out, 0} =
        System.cmd(
          "identify",
          ["-quiet", "-format", "%[EXIF:Make]", stored(ctx, file, name) <> "[0]"],
          stderr_to_stdout: true
        )

      String.trim(out)
    end

    # medium is an HDR rendition, thumbnail an ordinary one: both are stripped.
    assert %{"gain_map" => true} = Hdr.read(stored(ctx, file, "medium"))
    refute make.("medium") == "Cam"
    refute make.("thumbnail") == "Cam"
    # small was told to keep it.
    assert make.("small") == "Cam"
  end

  test "a turned HDR crop records the dimensions viewers display", ctx do
    import Ecto.Query
    alias PhoenixKit.Modules.Storage.{Dimension, ImageProcessor, VariantSets}
    alias PhoenixKit.Test.ExifFixture

    crop =
      Repo.one!(
        from d in Dimension,
          where: d.name == "small_square" and d.variant_set_uuid == ^VariantSets.default_uuid()
      )

    {:ok, _} = Storage.update_dimension(crop, %{keep_hdr: true, width: 300, height: 100})

    path = Path.join(ctx.tmp, "turned.jpg")
    GainMapJpeg.build(path, exif: ExifFixture.segment(%{orientation: 6}))
    file = upload!(ctx, path)
    output = stored(ctx, file, "small_square")

    assert %{"gain_map" => true} = Hdr.read(output)
    assert {:ok, {300, 100, _}} = ImageProcessor.oriented_info(output)

    assert %{width: 300, height: 100} =
             Storage.get_file_instance_by_name(file.uuid, "small_square")
  end

  test "a plain photo's renditions are as they always were", ctx do
    path = Path.join(ctx.tmp, "plain.jpg")
    {_, 0} = System.cmd("convert", ["-size", "2400x1800", "gradient:white-black", path])
    file = upload!(ctx, path)

    assert file.metadata["hdr"] == %{}
    assert Hdr.read(stored(ctx, file, "large")) == %{}
  end

  test "an unreadable HDR XMP packet falls back to an ordinary rendition", ctx do
    path = Path.join(ctx.tmp, "invalid-xmp.jpg")

    GainMapJpeg.build(path,
      primary_xmp: ~s(<x:xmpmeta xmlns:hdrgm="http://ns.adobe.com/hdr-gain-map/1.0/"><broken>)
    )

    file = upload!(ctx, path)
    assert %{"gain_map" => true} = file.metadata["hdr"]

    for name <- ~w(medium large) do
      assert %{processing_status: "completed"} =
               Storage.get_file_instance_by_name(file.uuid, name)

      assert Hdr.read(stored(ctx, file, name)) == %{}
    end
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

  # A HEIC or AVIF with a gain map goes through ffmpeg and ImageMagick like a real one.
  defp heif_tools?, do: HeifGainMap.available?() and HeifHdr.available?()

  test "a HEIF gain-map photo's medium and large keep the map as an Ultra HDR JPEG", ctx do
    if heif_tools?() do
      path = Path.join(ctx.tmp, "hdr.avif")
      HeifGainMap.build(path, width: 2400, height: 1800)
      file = upload!(ctx, path, "avif")

      assert %{"gain_map" => true, "container" => "avif"} = file.metadata["hdr"]

      for name <- ~w(medium large) do
        assert %{"gain_map" => true, "container" => "jpeg", "kinds" => ["ultrahdr"]} =
                 Hdr.read(stored(ctx, file, name)),
               "#{name} keeps the map"
      end

      for name <- ~w(small thumbnail) do
        assert Hdr.read(stored(ctx, file, name)) == %{}, "#{name} is an ordinary JPEG"
      end

      assert %{width: 800} = Storage.get_file_instance_by_name(file.uuid, "medium")
    end
  end

  test "remake_hdr_renditions marks only the HDR sizes of files with a gain map", ctx do
    if heif_tools?() do
      avif = Path.join(ctx.tmp, "hdr.avif")
      HeifGainMap.build(avif, width: 2400, height: 1800)
      heif_file = upload!(ctx, avif, "avif")

      jpeg = Path.join(ctx.tmp, "hdr.jpg")
      GainMapJpeg.build(jpeg, width: 2400, height: 1800)
      jpeg_file = upload!(ctx, jpeg)

      plain = Path.join(ctx.tmp, "plain.jpg")
      {_, 0} = System.cmd("convert", ["-size", "2400x1800", "gradient:white-black", plain])
      plain_file = upload!(ctx, plain)

      marker = fn file, name ->
        Storage.get_file_instance_by_name(file.uuid, name).spec_hash == "remake:hdr"
      end

      assert {:ok, %{files: 1, sizes: sizes}} = VariantSets.remake_hdr_renditions()
      assert sizes >= 2

      # the HEIF's HDR sizes, and only those
      assert marker.(heif_file, "medium")
      assert marker.(heif_file, "large")
      refute marker.(heif_file, "small")
      refute marker.(heif_file, "thumbnail")
      assert Storage.get_file(heif_file.uuid).placed_variant_revision == 0

      # a JPEG already keeps its map, and a plain photo has none to keep
      refute marker.(jpeg_file, "medium")
      refute marker.(plain_file, "medium")
      refute Storage.get_file(plain_file.uuid).placed_variant_revision == 0

      # JPEGs on request
      assert {:ok, %{files: 2}} = VariantSets.remake_hdr_renditions(containers: ["jpeg", "avif"])
      assert marker.(jpeg_file, "medium")
    end
  end
end
