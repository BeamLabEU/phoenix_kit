defmodule PhoenixKit.Modules.Storage.FocalPointTest do
  @moduledoc """
  A photo's focal point: kept in the file's metadata without touching the rest of it,
  a person's choice never replaced by detection, found by libvips (the optional `vix`
  package) when nothing is stored, and absent (so the crop stays at the center) when
  detection has nothing to find.
  """
  use PhoenixKit.DataCase, async: false

  @moduletag :tmp_dir

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.FocalPoint
  alias PhoenixKit.Test.Repo
  alias PhoenixKit.Users.Auth

  defp file!(metadata \\ %{"camera" => "Canon"}) do
    n = System.unique_integer([:positive])

    {:ok, user} =
      Auth.register_user(%{
        "email" => "focal-#{n}@example.com",
        "password" => "ValidPassword123!"
      })

    {:ok, file} =
      Storage.create_file(%{
        original_file_name: "photo#{n}.jpg",
        file_name: "photo#{n}.jpg",
        file_path: "focal/#{n}",
        mime_type: "image/jpeg",
        file_type: "image",
        ext: "jpg",
        file_checksum: Ecto.UUID.generate(),
        user_file_checksum: Ecto.UUID.generate(),
        size: 100,
        status: "active",
        user_uuid: user.uuid,
        metadata: metadata
      })

    file
  end

  defp reload(file), do: Repo.get!(Storage.File, file.uuid)

  describe "put/4, get/1 and clear/1" do
    test "a photo has none until one is recorded" do
      assert FocalPoint.get(file!()) == nil
    end

    test "records a point and where it came from, leaving the other metadata alone" do
      file = file!()

      assert {:ok, {0.8, 0.25}} = FocalPoint.put(file, 0.8, 0.25, "manual")

      reloaded = reload(file)
      assert FocalPoint.get(reloaded) == {{0.8, 0.25}, "manual"}
      assert reloaded.metadata["camera"] == "Canon"
    end

    test "a file with no metadata at all can have one" do
      file = file!(nil)
      assert {:ok, {0.1, 0.9}} = FocalPoint.put(file, 0.1, 0.9, "auto")
      assert FocalPoint.get(reload(file)) == {{0.1, 0.9}, "auto"}
    end

    test "a detected point never replaces a person's" do
      file = file!()
      {:ok, _} = FocalPoint.put(file, 0.2, 0.2, "manual")

      assert {:ok, :kept} = FocalPoint.put(file, 0.9, 0.9, "auto")
      assert FocalPoint.get(reload(file)) == {{0.2, 0.2}, "manual"}
    end

    test "a person's replaces a detected one, and a detected one replaces a detected one" do
      file = file!()
      {:ok, _} = FocalPoint.put(file, 0.3, 0.3, "auto")
      assert {:ok, {0.4, 0.4}} = FocalPoint.put(file, 0.4, 0.4, "auto")
      assert {:ok, {0.7, 0.1}} = FocalPoint.put(file, 0.7, 0.1, "manual")
      assert FocalPoint.get(reload(file)) == {{0.7, 0.1}, "manual"}
    end

    test "refuses a point outside the photo, or a source it does not know" do
      file = file!()
      assert {:error, :invalid} = FocalPoint.put(file, 1.2, 0.5, "manual")
      assert {:error, :invalid} = FocalPoint.put(file, 0.5, -0.1, "manual")
      assert {:error, :invalid} = FocalPoint.put(file, 0.5, 0.5, "guess")
      assert FocalPoint.get(reload(file)) == nil
    end

    test "clear/1 forgets it, and only it" do
      file = file!()
      {:ok, _} = FocalPoint.put(file, 0.5, 0.5, "manual")

      assert :ok = FocalPoint.clear(file)

      reloaded = reload(file)
      assert FocalPoint.get(reloaded) == nil
      assert reloaded.metadata["camera"] == "Canon"
    end

    test "get/1 ignores a stored value that is not a point" do
      assert FocalPoint.get(%{metadata: %{"focal" => %{"x" => "left", "y" => 2}}}) == nil
      assert FocalPoint.get(%{metadata: %{"focal" => %{"x" => 0.5}}}) == nil
      assert FocalPoint.get(%{metadata: nil}) == nil
    end
  end

  describe "ensure/2" do
    defp imagemagick?,
      do: match?({_, 0}, System.cmd("identify", ["-version"], stderr_to_stdout: true))

    defp photo!(dir) do
      path = Path.join(dir, "subject.png")

      {_, 0} =
        System.cmd("magick", [
          "-size",
          "1600x1000",
          "xc:gray(110)",
          "-attenuate",
          "0.15",
          "+noise",
          "Gaussian",
          "-fill",
          "rgb(255,20,20)",
          "-draw",
          "rectangle 1240,160 1360,280",
          path
        ])

      path
    end

    test "gives the stored point without looking at the photo" do
      file = file!()
      {:ok, _} = FocalPoint.put(file, 0.6, 0.4, "manual")

      assert FocalPoint.ensure(file, "/no/such/file.jpg") == {0.6, 0.4}
    end

    test "a point set since the file was loaded is the one used" do
      stale = file!()
      {:ok, _} = FocalPoint.put(stale, 0.1, 0.1, "manual")

      assert FocalPoint.ensure(stale, "/no/such/file.jpg") == {0.1, 0.1}
    end

    test "with nothing stored and nothing readable, there is no point" do
      assert FocalPoint.ensure(file!(), "/no/such/file.jpg") == nil
    end

    test "finds the subject with libvips, and stores it for the next rendition", %{tmp_dir: dir} do
      if imagemagick?() and FocalPoint.detection_available?() do
        file = file!()

        assert {x, y} = FocalPoint.ensure(file, photo!(dir))
        # The red square is centered at (1300, 220) of 1600x1000.
        assert_in_delta x, 0.81, 0.06
        assert_in_delta y, 0.22, 0.06

        assert {{^x, ^y}, "auto"} = FocalPoint.get(reload(file))
      end
    end

    test "detection leaves a manual point alone", %{tmp_dir: dir} do
      if imagemagick?() and FocalPoint.detection_available?() do
        file = file!()
        {:ok, _} = FocalPoint.put(file, 0.05, 0.95, "manual")

        assert FocalPoint.ensure(file, photo!(dir)) == {0.05, 0.95}
      end
    end

    test "a featureless photo has no subject to find", %{tmp_dir: dir} do
      if imagemagick?() and FocalPoint.detection_available?() do
        flat = Path.join(dir, "flat.png")
        {_, 0} = System.cmd("magick", ["-size", "800x600", "xc:gray50", flat])

        assert FocalPoint.detect(flat) == :error
        assert FocalPoint.ensure(file!(), flat) == nil
      end
    end

    test "detect/1 answers :error for a file that is not an image", %{tmp_dir: dir} do
      text = Path.join(dir, "note.txt")
      File.write!(text, "not a photo")

      assert FocalPoint.detect(text) == :error
      assert FocalPoint.detect(Path.join(dir, "missing.png")) == :error
    end
  end
end
