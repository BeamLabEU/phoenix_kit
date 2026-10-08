defmodule PhoenixKit.Modules.Storage.VariantSetGenerationTest do
  @moduledoc """
  Variants follow the variant set (V205, step 4): an upload gets its
  library's set's sizes, each recorded with the spec hash of the size that
  made it, and the file records the set it was made by; a set that makes
  no sizes makes none; a size change bumps the set's revision (a reorder
  does not); the standard sizes cannot be deleted or renamed and
  small/medium/large keep the aspect ratio; a missing size stands in as the
  nearest smaller one or a placeholder, never a full original; and
  `variant_for/2` picks a size by purpose.
  """
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Modules.Storage

  alias PhoenixKit.Modules.Storage.{
    Dimension,
    FileInstance,
    Libraries,
    ProcessFileJob,
    Profiles,
    VariantGenerator,
    VariantSets
  }

  alias PhoenixKit.Users.Auth
  alias PhoenixKitWeb.FileController

  setup do
    n = System.unique_integer([:positive])
    root = Path.join(System.tmp_dir!(), "pk_variant_sets_#{n}")

    {:ok, bucket} =
      Storage.create_bucket(%{
        name: "variant-sets-#{n}",
        provider: "local",
        endpoint: root,
        enabled: true,
        priority: 0
      })

    on_exit(fn -> File.rm_rf(root) end)

    {:ok, profile} = Profiles.create_profile(%{name: "Variant sets #{n}"})
    {:ok, _} = Profiles.put_bucket(profile, bucket.uuid, %{})
    {:ok, set} = VariantSets.create_variant_set(%{name: "Photos #{n}"})
    {:ok, library} = Libraries.create_system_library(%{name: "Photos #{n}"})
    {:ok, library} = Profiles.set_library_profile(library, profile.uuid)
    {:ok, library} = VariantSets.set_library_variant_set(library, set.uuid)

    {:ok, user} =
      Auth.register_user(%{
        "email" => "variant-sets-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    %{set: set, library: library, user: user, dir: root}
  end

  defp image!(dir, name, width) do
    File.mkdir_p!(dir)
    path = Path.join(dir, name)

    {_, 0} =
      System.cmd("convert", ["-size", "#{width}x#{div(width, 2)}", "xc:red", path],
        stderr_to_stdout: true
      )

    path
  end

  defp upload!(ctx, width \\ 400) do
    path = image!(Path.join(ctx.dir, "src"), "p#{System.unique_integer([:positive])}.png", width)
    sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

    {:ok, file} =
      Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "p.png",
        library_uuid: ctx.library.uuid
      )

    :ok =
      ProcessFileJob.perform(%Oban.Job{args: %{"file_uuid" => file.uuid, "filename" => "p.png"}})

    Storage.get_file(file.uuid)
  end

  defp names(file), do: file.uuid |> Storage.list_file_instances() |> Enum.map(& &1.variant_name)

  describe "generation" do
    test "an upload gets its library's set's sizes, each with its spec hash", ctx do
      {:ok, grid} =
        Storage.create_dimension(
          %{name: "grid_2x", width: 64, quality: 80, applies_to: "image", format: "jpg"},
          ctx.set.uuid
        )

      file = upload!(ctx)

      assert "grid_2x" in names(file)
      assert "thumbnail" in names(file)

      instance = Storage.get_file_instance_by_name(file.uuid, "grid_2x")
      assert instance.spec_hash == VariantSets.spec_hash(grid)
      assert Storage.get_file_instance_by_name(file.uuid, "original").spec_hash == nil

      set = VariantSets.get_variant_set(ctx.set.uuid)
      assert file.placed_variant_set_uuid == set.uuid
      assert file.placed_variant_revision == set.revision
    end

    test "a size of another set is not made", ctx do
      {:ok, _} =
        Storage.create_dimension(%{
          name: "default_only",
          width: 32,
          quality: 80,
          applies_to: "image"
        })

      refute "default_only" in names(upload!(ctx))
    end

    test "a set that makes no sizes makes none, and the file is up to date", ctx do
      {:ok, set} = VariantSets.update_variant_set(ctx.set, %{generate_variants: false})
      file = upload!(ctx)

      assert names(file) == ["original"]

      assert {file.placed_variant_set_uuid, file.placed_variant_revision} ==
               {set.uuid, set.revision}
    end
  end

  describe "cropping around the subject" do
    alias PhoenixKit.Modules.Storage.{FocalPoint, Manager}

    # 1600x1000 grey noise with a red 120x120 square centered at (1300, 220).
    defp photo!(dir, name) do
      File.mkdir_p!(dir)
      path = Path.join(dir, name)

      {_, 0} =
        System.cmd(
          "magick",
          ["-size", "1600x1000", "xc:gray(110)", "-attenuate", "0.15", "+noise", "Gaussian"] ++
            [
              "-fill",
              "rgb(255,20,20)",
              "-draw",
              "rectangle 1240,160 1360,280",
              "-alpha",
              "off",
              path
            ]
        )

      path
    end

    defp upload_photo!(ctx) do
      path = photo!(Path.join(ctx.dir, "src"), "s#{System.unique_integer([:positive])}.png")
      sha = :sha256 |> :crypto.hash(File.read!(path)) |> Base.encode16(case: :lower)

      {:ok, file} =
        Storage.store_file_in_buckets(path, "image", ctx.user.uuid, sha, "png", "s.png",
          library_uuid: ctx.library.uuid
        )

      :ok =
        ProcessFileJob.perform(%Oban.Job{
          args: %{"file_uuid" => file.uuid, "filename" => "s.png"}
        })

      Storage.get_file(file.uuid)
    end

    defp red_share(file, variant) do
      instance = Storage.get_file_instance_by_name(file.uuid, variant)
      {:ok, path} = Manager.retrieve_file(instance.file_name)

      {out, 0} =
        System.cmd("magick", [
          path,
          "-fx",
          "r>0.7&&g<0.45&&b<0.45?1:0",
          "-format",
          "%[fx:mean]",
          "info:"
        ])

      out |> String.trim() |> Float.parse() |> elem(0)
    end

    defp square_dimension!(ctx, name, crop_mode) do
      {:ok, dimension} =
        Storage.create_dimension(
          %{
            name: name,
            width: 200,
            height: 200,
            quality: 85,
            applies_to: "image",
            format: "jpg",
            maintain_aspect_ratio: false,
            crop_mode: crop_mode
          },
          ctx.set.uuid
        )

      dimension
    end

    test "a focus rendition keeps the subject the middle crop cuts off, and records the point",
         ctx do
      if FocalPoint.detection_available?() and System.find_executable("magick") do
        square_dimension!(ctx, "square_middle", "center")
        focus = square_dimension!(ctx, "square_focus", "focus")

        file = upload_photo!(ctx)

        # Found once, kept with the photo, and where the square is.
        assert {{x, y}, "auto"} = FocalPoint.get(file)
        assert_in_delta x, 0.81, 0.06
        assert_in_delta y, 0.22, 0.06

        # The same photo, two crops of the same size: the focus one has the whole square.
        assert red_share(file, "square_focus") > red_share(file, "square_middle") * 1.8

        # Its spec hash says it is a focus crop, so the reconciler tells the two apart.
        assert Storage.get_file_instance_by_name(file.uuid, "square_focus").spec_hash ==
                 VariantSets.spec_hash(focus)
      end
    end

    test "a person's point is the one used, and detection leaves it alone", ctx do
      if System.find_executable("magick") do
        square_dimension!(ctx, "square_focus", "focus")

        file = upload_photo!(ctx)
        {:ok, _} = FocalPoint.put(file, 0.05, 0.9, "manual")

        # Made again from the point a person set: the bottom-left corner, where
        # there is no square.
        dimension = Storage.get_dimension_by_name("square_focus", ctx.set.uuid)

        assert {:ok, _} =
                 VariantGenerator.generate_variant(Storage.get_file(file.uuid), dimension)

        assert red_share(file, "square_focus") == 0.0
        assert {{0.05, 0.9}, "manual"} = FocalPoint.get(Storage.get_file(file.uuid))
      end
    end

    test "a photo with no point found is cropped at the middle, not refused", ctx do
      if System.find_executable("magick") do
        square_dimension!(ctx, "square_focus", "focus")

        flat =
          image!(Path.join(ctx.dir, "src"), "flat#{System.unique_integer([:positive])}.png", 800)

        sha = :sha256 |> :crypto.hash(File.read!(flat)) |> Base.encode16(case: :lower)

        {:ok, file} =
          Storage.store_file_in_buckets(flat, "image", ctx.user.uuid, sha, "png", "flat.png",
            library_uuid: ctx.library.uuid
          )

        :ok =
          ProcessFileJob.perform(%Oban.Job{
            args: %{"file_uuid" => file.uuid, "filename" => "flat.png"}
          })

        assert Storage.get_file_instance_by_name(file.uuid, "square_focus")
        assert FocalPoint.get(Storage.get_file(file.uuid)) == nil
      end
    end
  end

  describe "revisions" do
    test "a size change bumps its set's revision; a reorder does not", ctx do
      revision = fn -> VariantSets.get_variant_set(ctx.set.uuid).revision end
      start = revision.()

      {:ok, size} =
        Storage.create_dimension(
          %{name: "extra", width: 50, quality: 80, applies_to: "image"},
          ctx.set.uuid
        )

      assert revision.() == start + 1

      {:ok, size} = Storage.update_dimension(size, %{order: 42})
      assert revision.() == start + 1

      {:ok, size} = Storage.update_dimension(size, %{width: 60})
      assert revision.() == start + 2

      {:ok, _} = Storage.delete_dimension(size)
      assert revision.() == start + 3
    end
  end

  describe "standard sizes" do
    test "cannot be deleted or renamed", ctx do
      thumbnail = Storage.get_dimension_by_name("thumbnail", ctx.set.uuid)

      assert {:error, :standard_slot} = Storage.delete_dimension(thumbnail)
      assert {:error, changeset} = Storage.update_dimension(thumbnail, %{name: "thumb"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "small, medium and large keep the aspect ratio; thumbnail may be cropped", ctx do
      small = Storage.get_dimension_by_name("small", ctx.set.uuid)
      thumbnail = Storage.get_dimension_by_name("thumbnail", ctx.set.uuid)

      assert {:error, changeset} =
               Storage.update_dimension(small, %{maintain_aspect_ratio: false, height: 300})

      assert %{maintain_aspect_ratio: [_]} = errors_on(changeset)

      assert {:ok, _} =
               Storage.update_dimension(thumbnail, %{maintain_aspect_ratio: false, height: 150})
    end

    test "a custom size may be deleted", ctx do
      {:ok, size} =
        Storage.create_dimension(
          %{name: "custom", width: 50, quality: 80, applies_to: "image"},
          ctx.set.uuid
        )

      assert {:ok, _} = Storage.delete_dimension(size)
    end
  end

  describe "a missing size (G17)" do
    defp instance(variant, width, extra \\ %{}) do
      struct(
        FileInstance,
        Map.merge(
          %{variant_name: variant, width: width, mime_type: "image/jpeg", spec_hash: "x"},
          extra
        )
      )
    end

    defp file(ctx, width),
      do: %Storage.File{library_uuid: ctx.library.uuid, file_type: "image", width: width}

    test "stands in as the nearest smaller size the file has", ctx do
      instances = [instance("thumbnail", 150), instance("small", 300), instance("large", 1920)]

      assert {:instance, %{variant_name: "small"}} =
               VariantSets.stand_in(file(ctx, 4000), "medium", instances)
    end

    test "a render or annotation is never a stand-in", ctx do
      instances = [instance("thumbnail_annotated", 150, %{spec_hash: nil})]
      assert :placeholder = VariantSets.stand_in(file(ctx, 4000), "medium", instances)
    end

    test "with nothing smaller, a placeholder, unless the original is no larger", ctx do
      assert :placeholder = VariantSets.stand_in(file(ctx, 4000), "thumbnail", [])
      assert :original = VariantSets.stand_in(file(ctx, 100), "thumbnail", [])
    end

    test "a name that is not an image size gets the original, as before", ctx do
      assert :original = VariantSets.stand_in(file(ctx, 4000), "not_a_size", [])
      assert :original = VariantSets.stand_in(file(ctx, 4000), "original", [])
    end

    test "the controller serves the stand-in or asks for the placeholder", ctx do
      {:ok, set} = VariantSets.update_variant_set(ctx.set, %{generate_variants: false})
      assert set.generate_variants == false
      file = upload!(ctx, 1200)

      # Nothing is coming while the set makes no sizes: the original, as before.
      assert {:ok, %{variant_name: "original"}, :pending} =
               FileController.get_file_instance(file.uuid, "thumbnail")

      {:ok, _} = VariantSets.update_variant_set(set, %{generate_variants: true})
      assert {:error, :placeholder} = FileController.get_file_instance(file.uuid, "thumbnail")

      thumbnail = Storage.get_dimension_by_name("thumbnail", ctx.set.uuid)
      {:ok, _} = Storage.VariantGenerator.generate_variant(Storage.get_file(file.uuid), thumbnail)

      assert {:ok, %{variant_name: "thumbnail"}, :pending} =
               FileController.get_file_instance(file.uuid, "medium")
    end
  end

  describe "variant_for/2" do
    test "the narrowest size at least as wide as asked, of the right aspect", ctx do
      {:ok, _} =
        Storage.create_dimension(
          %{
            name: "square_400",
            width: 400,
            height: 400,
            maintain_aspect_ratio: false,
            quality: 80,
            applies_to: "image"
          },
          ctx.set.uuid
        )

      file = %Storage.File{library_uuid: ctx.library.uuid, file_type: "image"}
      widths = Map.new(VariantSets.list_dimensions(ctx.set.uuid), &{&1.name, &1.width})

      preserve = Storage.variant_for(file, min_width: 350, aspect: :preserve)
      assert widths[preserve] >= 350
      assert Storage.get_dimension_by_name(preserve, ctx.set.uuid).maintain_aspect_ratio

      assert Storage.variant_for(file, min_width: 350, aspect: :crop) == "square_400"
      assert Storage.variant_for(file, min_width: 100_000) == "large"
    end

    test "a size made for a shape is offered to files of that shape only", ctx do
      {:ok, _} =
        Storage.create_dimension(
          %{
            name: "banner_1200",
            width: 1200,
            height: 300,
            maintain_aspect_ratio: false,
            quality: 80,
            applies_to: "image",
            shape: "wide"
          },
          ctx.set.uuid
        )

      base = %Storage.File{library_uuid: ctx.library.uuid, file_type: "image"}
      wide = %{base | width: 4000, height: 1500}
      portrait = %{base | width: 1500, height: 4000}

      assert Storage.variant_for(wide, aspect: :crop, min_width: 1000) == "banner_1200"
      assert Storage.variant_for(portrait, aspect: :crop, min_width: 1000) == "original"
    end

    test "a file whose set has no fitting size gets the original", ctx do
      file = %Storage.File{library_uuid: ctx.library.uuid, file_type: "image"}
      assert Storage.variant_for(file, aspect: :crop, min_width: 100_000) == "original"
    end
  end

  test "Dimension knows the standard sizes" do
    assert Dimension.standard_slot?(%Dimension{name: "video_thumbnail"})
    refute Dimension.standard_slot?(%Dimension{name: "grid_2x"})
  end
end
