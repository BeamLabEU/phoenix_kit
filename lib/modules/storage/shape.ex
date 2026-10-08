defmodule PhoenixKit.Modules.Storage.Shape do
  @moduledoc """
  The shape of a picture: ordinary, **wide** (a horizontal panorama) or **tall**
  (a vertical one, a Pinterest pin).

  Shape is read from a file's `aspect_ratio` (width ÷ height, kept by Postgres,
  V212), never from EXIF: no camera flag is involved, and an edit that crops or
  rotates the photo changes its shape with no job to keep a flag right. Where wide
  stops and panorama starts is a taste, so the two thresholds live here and are
  the one place to change (a per-user setting would replace these constants):

    * **wide**: `aspect_ratio >= 2.0` (2:1 or wider);
    * **tall**: `aspect_ratio <= 0.5` (1:2 or taller; a phone screenshot, at
      about 1:2.16, counts as tall).

  ## Filtering

      Shape.filter(File, :wide)           # or :tall; nil / "all" leave it alone
      Storage.list_files_in_scope(nil, shape: :wide)

  A file with no usable size (`aspect_ratio` nil) is neither.
  """

  import Ecto.Query, only: [where: 3]

  @wide_min 2.0
  @tall_max 0.5

  @type t :: :wide | :tall | :normal

  @doc "The smallest `aspect_ratio` of a wide picture."
  @spec wide_min() :: float()
  def wide_min, do: @wide_min

  @doc "The largest `aspect_ratio` of a tall picture."
  @spec tall_max() :: float()
  def tall_max, do: @tall_max

  @doc """
  The shape of a ratio, a `{width, height}` pair or anything carrying them (a
  file); `nil` when there is no usable size.
  """
  @spec classify(number() | {integer(), integer()} | map() | nil) :: t() | nil
  def classify(ratio) when is_number(ratio) do
    cond do
      ratio >= @wide_min -> :wide
      ratio <= @tall_max -> :tall
      true -> :normal
    end
  end

  def classify({width, height}) when is_integer(width) and is_integer(height) do
    if width > 0 and height > 0, do: classify(width / height)
  end

  def classify(%{aspect_ratio: ratio}) when is_number(ratio), do: classify(ratio)
  def classify(%{width: width, height: height}), do: classify({width, height})
  def classify(_), do: nil

  @doc """
  Narrows a query over files (or anything with an `aspect_ratio`) to a shape.
  `nil`, `"all"` and `""` leave it unfiltered; `:wide`/`"wide"` and
  `:tall`/`"tall"` filter; anything else raises, so a typo is not silently
  "no filter".
  """
  @spec filter(Ecto.Queryable.t(), t() | String.t() | nil) :: Ecto.Query.t()
  def filter(query, shape) when shape in [nil, "", "all"], do: query

  def filter(query, shape) when shape in [:wide, "wide"],
    do: where(query, [f], f.aspect_ratio >= ^@wide_min)

  def filter(query, shape) when shape in [:tall, "tall"],
    do: where(query, [f], f.aspect_ratio <= ^@tall_max)
end
