defmodule PhoenixKit.Modules.Storage.FocalPointDetectorTest do
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Storage.FocalPoint

  @moduletag :tmp_dir

  defmodule Faces do
    alias PhoenixKit.Modules.Storage.ImageProcessor

    def detect(path) do
      # The callback must receive an oriented, bounded JPEG, not the source.
      {:ok, {width, height}} = ImageProcessor.extract_dimensions(path)

      if max(width, height) <= 512 and Path.extname(path) == ".jpg",
        do: {:ok, {0.25, 0.4}},
        else: raise("unbounded preview")
    end
  end

  defmodule Invalid do
    def detect(_), do: {:ok, {-1.0, 2.0}}
  end

  defmodule Crashes do
    def detect(_), do: raise("detector unavailable")
  end

  defmodule NoFaces do
    def detect(_), do: :error
  end

  setup %{tmp_dir: dir} do
    previous = Application.get_env(:phoenix_kit, :focal_point_detector)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit, :focal_point_detector, previous),
        else: Application.delete_env(:phoenix_kit, :focal_point_detector)
    end)

    path = Path.join(dir, "photo.png")
    {_, 0} = System.cmd("convert", ["-size", "800x600", "xc:gray50", path])
    %{path: path}
  end

  test "a preferred detector wins over attention", %{path: path} do
    Application.put_env(:phoenix_kit, :focal_point_detector, Faces)
    assert FocalPoint.detect(path) == {:ok, {0.25, 0.4}}
  end

  test "invalid coordinates and exceptions fall back to attention", %{path: path} do
    Application.delete_env(:phoenix_kit, :focal_point_detector)
    baseline = FocalPoint.detect(path)

    for detector <- [Invalid, Crashes, NoFaces] do
      Application.put_env(:phoenix_kit, :focal_point_detector, detector)
      assert FocalPoint.detect(path) == baseline
    end
  end
end
