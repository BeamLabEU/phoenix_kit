defmodule PhoenixKit.Modules.Storage.Geo do
  @moduledoc """
  Photos on a map: "what was taken in this area?" as one indexed lookup.

  A photo's EXIF position is in `phoenix_kit_files.latitude` / `longitude`
  (V215). The index is a GiST index on `point(longitude, latitude)`, which
  Postgres has built in (no PostGIS), and a box on the map is

      point(longitude, latitude) <@ box(point(west, south), point(east, north))

  A **bounds** is `{south, west, north, east}` in degrees, the corners of the
  visible map: latitude -90..90, longitude -180..180. A box that crosses the
  antimeridian (the Pacific, Fiji, eastern Russia) has `west > east`, and is
  searched as two.

      Storage.list_files_in_scope(nil, bounds: {46.0, 14.0, 48.0, 16.0})
      Geo.within(File, {46.0, 14.0, 48.0, 16.0})
      Geo.parse_bounds("46,14,48,16")

  A file with no position is never inside any box.
  """

  import Ecto.Query, only: [dynamic: 2, where: 3]

  @type bounds :: {number(), number(), number(), number()}

  @doc """
  Narrows a query over files to those inside `bounds`. `nil` leaves it as it is.
  A bounds that is not four numbers raises, so a typo does not become "no filter".
  """
  @spec within(Ecto.Queryable.t(), bounds() | nil) :: Ecto.Query.t()
  def within(query, nil), do: query

  def within(query, {south, west, north, east} = bounds)
      when is_number(south) and is_number(west) and is_number(north) and is_number(east) do
    condition =
      case boxes(bounds) do
        [box] -> box_condition(box)
        [a, b] -> dynamic([f], ^box_condition(a) or ^box_condition(b))
      end

    where(query, [f], ^condition)
  end

  # The longitude ranges the box covers: one, or two when it crosses ±180 (after
  # a longitude past the edge of the world is wrapped back), or the whole world
  # when it spans it. The latitudes are clamped to the globe.
  defp boxes({south, west, north, east}) do
    south = clamp(south, -90, 90)
    north = clamp(north, -90, 90)

    if east - west >= 360 do
      [{south, -180.0, north, 180.0}]
    else
      {west, east} = {wrap(west), wrap(east)}

      if west <= east,
        do: [{south, west, north, east}],
        else: [{south, west, north, 180.0}, {south, -180.0, north, east}]
    end
  end

  defp box_condition({south, west, north, east}) do
    dynamic(
      [f],
      fragment(
        "point(?, ?) <@ box(point(?, ?), point(?, ?))",
        f.longitude,
        f.latitude,
        ^(west * 1.0),
        ^(south * 1.0),
        ^(east * 1.0),
        ^(north * 1.0)
      )
    )
  end

  defp clamp(value, low, high), do: value |> max(low) |> min(high) |> Kernel.*(1.0)

  # A longitude past ±180 (a map panned around the world) is the same place.
  defp wrap(lon) when lon > 180 or lon < -180,
    do: Float.round(:math.fmod(lon + 540.0, 360.0) - 180.0, 9)

  defp wrap(lon), do: lon * 1.0

  @doc """
  A bounds from what a URL or a form carries: `"south,west,north,east"`, a list
  of four, or a map with `"south"`, `"west"`, `"north"`, `"east"`. `nil` when it
  is not four numbers, or the south is above the north.
  """
  @spec parse_bounds(term()) :: bounds() | nil
  def parse_bounds(value) when is_binary(value), do: value |> String.split(",") |> parse_bounds()

  def parse_bounds(%{} = map) do
    parse_bounds(Enum.map(~w(south west north east), &Map.get(map, &1)))
  end

  def parse_bounds([_, _, _, _] = parts) do
    case Enum.map(parts, &to_number/1) do
      [s, w, n, e]
      when is_number(s) and is_number(w) and is_number(n) and is_number(e) and s <= n ->
        {s, w, n, e}

      _ ->
        nil
    end
  end

  def parse_bounds(_), do: nil

  defp to_number(value) when is_number(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _ -> nil
    end
  rescue
    # Float.parse/1 raises on a few hundred digits; a URL can carry them.
    ArgumentError -> nil
  end

  defp to_number(_), do: nil
end
