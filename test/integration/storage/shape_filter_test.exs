defmodule PhoenixKit.Integration.Storage.ShapeFilterTest do
  @moduledoc """
  The wide/tall filter against the real generated column (V212): files of every
  shape in one library, listed by shape, and the ratio Postgres keeps from the
  size — including after an edit that changes it.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Modules.Storage.Shape
  alias PhoenixKit.Users.Auth

  setup do
    {:ok, user} =
      Auth.register_user(%{
        email: "shape-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    {:ok, library} =
      Libraries.create_system_library(%{name: "Shapes #{System.unique_integer([:positive])}"})

    %{user: user, library: library}
  end

  defp file!(ctx, name, width, height, type \\ "image") do
    n = System.unique_integer([:positive])

    Repo.insert!(%StorageFile{
      original_file_name: name,
      file_name: name,
      mime_type: if(type == "image", do: "image/jpeg", else: "video/mp4"),
      file_type: type,
      ext: if(type == "image", do: "jpg", else: "mp4"),
      file_checksum: "sha256:shape-#{n}",
      user_file_checksum: "user-sha256:shape-#{n}",
      size: 10,
      width: width,
      height: height,
      status: "active",
      library_uuid: ctx.library.uuid,
      user_uuid: ctx.user.uuid
    })
  end

  defp names(ctx, shape) do
    {files, total} =
      Storage.list_files_in_scope(nil, library_uuid: ctx.library.uuid, shape: shape)

    assert total == length(files)
    files |> Enum.map(& &1.original_file_name) |> Enum.sort()
  end

  setup ctx do
    file!(ctx, "pano.jpg", 8947, 3317)
    file!(ctx, "pano_2to1.jpg", 4200, 2100)
    file!(ctx, "widescreen.jpg", 1920, 1080)
    file!(ctx, "square.jpg", 1000, 1000)
    file!(ctx, "portrait.jpg", 3024, 4032)
    file!(ctx, "pin.jpg", 1000, 2000)
    file!(ctx, "strip.jpg", 500, 3000)
    file!(ctx, "nosize.jpg", nil, nil)
    :ok
  end

  test "wide lists the 2:1 and wider pictures only", ctx do
    assert names(ctx, :wide) == ["pano.jpg", "pano_2to1.jpg"]
    assert names(ctx, "wide") == names(ctx, :wide)
  end

  test "tall lists the 1:2 and taller pictures only", ctx do
    assert names(ctx, :tall) == ["pin.jpg", "strip.jpg"]
  end

  test "no shape, nil and \"all\" list everything, a file without a size included", ctx do
    all = names(ctx, nil)
    assert length(all) == 8
    assert "nosize.jpg" in all
    assert names(ctx, "all") == all
  end

  test "a file without a size is neither wide nor tall", ctx do
    refute "nosize.jpg" in names(ctx, :wide)
    refute "nosize.jpg" in names(ctx, :tall)
  end

  test "a shape lists pictures only: a wide or tall video is neither a panorama nor a portrait",
       ctx do
    file!(ctx, "cinema.mp4", 2390, 1000, "video")
    file!(ctx, "screen_recording.mp4", 1000, 2170, "video")

    assert names(ctx, :wide) == ["pano.jpg", "pano_2to1.jpg"]
    assert names(ctx, :tall) == ["pin.jpg", "strip.jpg"]
    assert "cinema.mp4" in names(ctx, nil)
  end

  test "the ratio follows an edit of the size, with nothing to keep it right", ctx do
    file = file!(ctx, "crop_me.jpg", 3000, 2000)
    assert_in_delta Repo.reload!(file).aspect_ratio, 1.5, 1.0e-9
    refute "crop_me.jpg" in names(ctx, :wide)

    file |> Ecto.Changeset.change(width: 6000, height: 2000) |> Repo.update!()

    assert "crop_me.jpg" in names(ctx, :wide)
    assert Shape.classify(Repo.reload!(file)) == :wide
  end

  test "an unknown shape raises rather than silently listing everything", ctx do
    assert_raise FunctionClauseError, fn -> names(ctx, :panorama) end
  end
end
