defmodule PhoenixKit.Modules.Storage.DimensionOptions do
  @moduledoc """
  The options of a rendition (`Dimension`), kept as one JSON object in
  `phoenix_kit_storage_dimensions.options` (V217) and loaded as this struct, so each
  option has a type, a default and validation while a new one needs no migration.

    * `crop_mode` — how a fixed box is cropped: `"center"` (the middle) or `"focus"`
      (around the photo's subject). Nothing for a size that keeps proportions.
    * `fit_by` — the side a size that keeps proportions fixes: `"width"` or `"height"`
      (a horizontal panorama).
    * `shape` — which pictures it is made for: `"any"`, `"wide"` or `"tall"`.
    * `keep_hdr` — whether a photo with an HDR gain map keeps the map in this size
      (`Storage.HdrResize`).
    * `strip_metadata` — whether the camera's metadata (EXIF with the device, the time
      and the GPS position, XMP, maker notes) is left out of the rendition. The colour
      profile stays and the orientation is applied to the pixels, so the picture looks
      the same. On unless a size says otherwise: a thumbnail of a phone photo is
      otherwise mostly metadata (about 100 KB of a 113 KB file).

  `crop_mode`, `fit_by` and `shape` used to be columns of their own (V210, V211,
  V214). V217 copied them in here and emptied the columns, which stay for a few
  releases before they are dropped; nothing reads them any more.

  A key a newer release wrote that this struct does not know is not carried through a
  save here: add the field before a release writes it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @crop_modes ~w(center focus)
  @fit_sides ~w(width height)
  @shapes ~w(any wide tall)

  @primary_key false
  embedded_schema do
    field :crop_mode, :string, default: "center"
    field :fit_by, :string, default: "width"
    field :shape, :string, default: "any"
    field :keep_hdr, :boolean, default: false
    field :strip_metadata, :boolean, default: true
  end

  @type t :: %__MODULE__{
          crop_mode: String.t(),
          fit_by: String.t(),
          shape: String.t(),
          keep_hdr: boolean(),
          strip_metadata: boolean()
        }

  @doc "The option names."
  @spec keys() :: [atom()]
  def keys, do: [:crop_mode, :fit_by, :shape, :keep_hdr, :strip_metadata]

  @doc false
  def changeset(options, attrs) do
    options
    |> cast(attrs, keys())
    |> validate_required(keys())
    |> validate_inclusion(:crop_mode, @crop_modes)
    |> validate_inclusion(:fit_by, @fit_sides)
    |> validate_inclusion(:shape, @shapes)
  end
end
