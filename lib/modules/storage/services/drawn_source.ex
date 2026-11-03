defmodule PhoenixKit.Modules.Storage.DrawnSource do
  @moduledoc """
  The picture an image's metadata and renditions are read from, when that is not the
  file itself: an SVG is drawn into a PNG (`SvgRaster`), a camera raw file developed
  into a JPEG (`CameraRaw`). Every other image is its own picture.
  `ProcessFileJob` and `VariantGenerator` read pixels only through here.
  """

  alias PhoenixKit.Modules.Storage.{CameraRaw, SvgRaster}

  @doc "Whether files of this MIME type are read through a drawn picture."
  @spec drawn?(String.t() | nil) :: boolean()
  def drawn?(mime), do: SvgRaster.svg?(mime) or CameraRaw.mime?(mime)

  @doc """
  The picture of the file of type `mime` at `path`: `{:ok, path}` itself, or
  `{:ok, new_path}` for a drawn one, which the caller removes.
  """
  @spec picture(String.t() | nil, Path.t()) :: {:ok, Path.t()} | {:error, term()}
  def picture(mime, path) do
    cond do
      SvgRaster.svg?(mime) -> SvgRaster.to_png(path)
      CameraRaw.mime?(mime) -> CameraRaw.develop(path)
      true -> {:ok, path}
    end
  end
end
