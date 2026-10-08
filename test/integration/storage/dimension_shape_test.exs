defmodule PhoenixKit.Integration.Storage.DimensionShapeTest do
  @moduledoc """
  A rendition made only for wide (or tall) pictures (V214): which sizes a file is
  expected to have by its shape, that a size already read from a stale struct is
  not skipped, the standard sizes always being for every picture, and the new
  Default sizes after a reset.
  """
  use PhoenixKit.DataCase, async: true

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.Dimension
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.VariantGenerator
  alias PhoenixKit.Users.Auth

  setup do
    {:ok, user} =
      Auth.register_user(%{
        email: "dim-shape-#{System.unique_integer([:positive])}@example.com",
        password: "ValidPassword123!"
      })

    n = System.unique_integer([:positive])

    {:ok, _} =
      Storage.create_dimension(%{
        name: "strip_#{n}",
        height: 200,
        quality: 80,
        applies_to: "image",
        fit_by: "height",
        shape: "wide"
      })

    {:ok, _} =
      Storage.create_dimension(%{
        name: "column_#{n}",
        width: 200,
        quality: 80,
        applies_to: "image",
        shape: "tall"
      })

    %{user: user, strip: "strip_#{n}", column: "column_#{n}"}
  end

  defp file!(ctx, width, height) do
    n = System.unique_integer([:positive])

    Repo.insert!(%StorageFile{
      original_file_name: "s#{n}.jpg",
      file_name: "s#{n}.jpg",
      mime_type: "image/jpeg",
      file_type: "image",
      ext: "jpg",
      file_path: "s/#{n}",
      file_checksum: "sha256:ds-#{n}",
      user_file_checksum: "user-sha256:ds-#{n}",
      size: 10,
      width: width,
      height: height,
      status: "active",
      user_uuid: ctx.user.uuid
    })
  end

  defp expected(file) do
    file |> VariantGenerator.expected_variants() |> Enum.map(fn {d, _name, _format} -> d.name end)
  end

  test "a wide picture is expected to have the wide size, and not the tall one", ctx do
    names = expected(file!(ctx, 6000, 2000))

    assert ctx.strip in names
    refute ctx.column in names
    assert "small" in names
  end

  test "a tall picture is expected to have the tall size, and not the wide one", ctx do
    names = expected(file!(ctx, 1000, 3000))

    assert ctx.column in names
    refute ctx.strip in names
  end

  test "an ordinary picture has neither, and keeps every size made for any picture", ctx do
    names = expected(file!(ctx, 3000, 2000))

    refute ctx.strip in names
    refute ctx.column in names
    assert Enum.all?(["thumbnail", "small", "medium", "large"], &(&1 in names))
  end

  test "a picture with no size yet has neither", ctx do
    names = expected(file!(ctx, nil, nil))

    refute ctx.strip in names
    refute ctx.column in names
  end

  test "a struct that predates the picture's size is read afresh, not skipped", ctx do
    file = file!(ctx, 6000, 2000)

    # The struct a job loaded before the metadata was read: no size, no ratio.
    stale = %{file | width: nil, height: nil, aspect_ratio: nil}

    assert ctx.strip in expected(stale)
  end

  test "a shape the schema does not know is refused" do
    changeset =
      Dimension.changeset(%Dimension{}, %{
        name: "odd",
        width: 100,
        applies_to: "image",
        shape: "round"
      })

    assert %{shape: ["is invalid"]} = errors_on(changeset)
  end

  test "clearing a shape returns a validation error instead of reaching the NOT NULL constraint",
       ctx do
    size = Storage.get_dimension_by_name(ctx.strip)

    assert {:error, changeset} = Storage.update_dimension(size, %{shape: nil})
    assert %{shape: ["can't be blank"]} = errors_on(changeset)

    assert {:error, changeset} =
             Storage.create_dimension(%{
               name: "blank_shape_#{System.unique_integer([:positive])}",
               width: 100,
               applies_to: "image",
               shape: nil
             })

    assert %{shape: ["can't be blank"]} = errors_on(changeset)

    # Ecto treats a form's empty string as the schema default, "any".
    assert {:ok, %{shape: "any"}} = Storage.update_dimension(size, %{shape: ""})
  end

  test "the standard sizes cannot be limited to wide or tall pictures" do
    large = Storage.get_dimension_by_name("large")
    assert {:error, changeset} = Storage.update_dimension(large, %{shape: "wide"})
    assert %{shape: [message]} = errors_on(changeset)
    assert message =~ "must stay on any picture"
  end

  test "a reset brings back the mini square and the three panorama sizes" do
    Storage.reset_dimensions_to_defaults()

    mini = Storage.get_dimension_by_name("mini_square")
    assert {mini.width, mini.height, mini.quality} == {64, 64, 70}
    assert {mini.maintain_aspect_ratio, mini.crop_mode, mini.shape} == {false, "focus", "any"}

    for {name, height} <- [{"thumbnail_wide", 150}, {"small_wide", 300}, {"medium_wide", 800}] do
      d = Storage.get_dimension_by_name(name)
      assert {d.width, d.height} == {nil, height}
      assert {d.maintain_aspect_ratio, d.fit_by, d.shape} == {true, "height", "wide"}
    end
  end
end
