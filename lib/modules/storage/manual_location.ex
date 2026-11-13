defmodule PhoenixKit.Modules.Storage.ManualLocation do
  @moduledoc """
  Where a photo was taken, as a person says.

  A photo is placed automatically from its EXIF GPS (`Storage.Exif`, written to the
  `latitude` / `longitude` columns a map searches, `Storage.Geo`). A person can say
  otherwise: a scan of an old print has no GPS, a camera without one put nothing, a
  phone put the wrong town. `set/4` writes that place and marks it as set by hand
  (`metadata["location_source"] = "manual"`), and no automatic writer replaces a place
  set by hand: reading the file's EXIF again (`Storage.read_exif/1`, a reprocess) keeps
  it, through `admit/2`. `clear/2` removes a place, also by hand, so the EXIF does not
  bring it back; `reset/2` is the way back to the EXIF's own place, or to none.

  `set/4` takes several files: they all get the one place. A place may carry a name
  (`"Tallinn, Estonia"`, what a search found), kept in `metadata["place"]` with the
  position it names, so a name is never shown for a position it does not belong to
  (`place_name/1`).

  Who may: someone who may edit every file (`Libraries.can?/3` with `:edit`). Each
  change is announced on the file-changes topic (`Storage.subscribe_to_file_changes/0`).
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Libraries
  alias PhoenixKit.Users.Auth.Scope

  @source_key "location_source"
  @place_key "place"
  @max_name 300

  @type reason :: :not_found | :forbidden | :invalid_position
  @type position :: {number(), number()}

  @doc """
  Places `file_uuids` at `{latitude, longitude}` (decimal degrees), set by hand.

  Options: `:name` — what the place is called, kept with the position (at most 300
  characters; blank is none).

  Returns `{:ok, file_uuids}`, or `{:error, reason}`: `:not_found`, `:forbidden`, or
  `:invalid_position` for a position off the globe.
  """
  @spec set([String.t()], position(), Scope.t() | nil, keyword()) ::
          {:ok, [String.t()]} | {:error, reason()}
  def set(file_uuids, position, scope, opts \\ [])

  def set(file_uuids, {lat, lon}, scope, opts) when is_number(lat) and is_number(lon) do
    if valid?(lat, lon) do
      lat = round_degrees(lat)
      lon = round_degrees(lon)
      name = clean_name(opts[:name])

      write(file_uuids, scope, fn file ->
        metadata =
          (file.metadata || %{})
          |> Map.put(@source_key, "manual")
          |> put_place(name, lat, lon)

        %{latitude: lat, longitude: lon, metadata: metadata}
      end)
    else
      {:error, :invalid_position}
    end
  end

  def set(_file_uuids, _position, _scope, _opts), do: {:error, :invalid_position}

  @doc """
  Removes the place of `file_uuids`, by hand: they are on no map, and reading their
  EXIF again does not put them back. `reset/2` undoes it.
  """
  @spec clear([String.t()], Scope.t() | nil) :: {:ok, [String.t()]} | {:error, reason()}
  def clear(file_uuids, scope) do
    write(file_uuids, scope, fn file ->
      metadata =
        (file.metadata || %{})
        |> Map.put(@source_key, "manual")
        |> Map.delete(@place_key)

      %{latitude: nil, longitude: nil, metadata: metadata}
    end)
  end

  @doc """
  Gives files placed (or cleared) by hand their own place back: the GPS position their
  EXIF summary recorded (`metadata["exif"]["gps"]`), or none. Files whose place was not
  set by hand are left alone. Returns `{:ok, file_uuids}` (the files that were reset).
  """
  @spec reset([String.t()], Scope.t() | nil) :: {:ok, [String.t()]} | {:error, reason()}
  def reset(file_uuids, scope) do
    write(file_uuids, scope, fn file ->
      if manual?(file) do
        {lat, lon} = exif_position(file)

        metadata =
          (file.metadata || %{})
          |> Map.delete(@source_key)
          |> Map.delete(@place_key)

        %{latitude: lat, longitude: lon, metadata: metadata}
      end
    end)
  end

  @doc "Whether the place of `file` (or its absence) was set by hand."
  @spec manual?(StorageFile.t() | map()) :: boolean()
  def manual?(%{metadata: %{@source_key => "manual"}}), do: true
  def manual?(_file), do: false

  @doc """
  The name of the place `file` is at, or nil: only a name kept with the very position
  the file has now.
  """
  @spec place_name(StorageFile.t() | map()) :: String.t() | nil
  def place_name(%{latitude: lat, longitude: lon, metadata: %{@place_key => %{} = place}})
      when is_number(lat) and is_number(lon) do
    with name when is_binary(name) and name != "" <- place["name"],
         true <- same?(place["latitude"], lat) and same?(place["longitude"], lon) do
      name
    else
      _ -> nil
    end
  end

  def place_name(_file), do: nil

  @doc """
  The attributes an automatic writer (a processing job, an EXIF re-read) may put on
  `current`: without `latitude` / `longitude` when its place was set by hand.
  Accepts atom or string keys.
  """
  @spec admit(map(), StorageFile.t() | map() | nil) :: map()
  def admit(attrs, current) do
    if manual?(current),
      do: Map.drop(attrs, [:latitude, :longitude, "latitude", "longitude"]),
      else: attrs
  end

  # ---------------------------------------------------------------------------

  # Locks the files, checks the person may edit every one, and writes what `change`
  # gives each (nil leaves a file as it is). All or none.
  defp write(file_uuids, scope, change) do
    uuids = file_uuids |> List.wrap() |> Enum.map(&to_string/1) |> Enum.uniq()

    repo().transaction(fn ->
      with {:ok, files} <- load(uuids),
           :ok <- check_edit(files, scope) do
        for file <- files, attrs = change.(file), attrs != nil do
          file |> Ecto.Changeset.change(attrs) |> repo().update!()
          file.uuid
        end
      else
        {:error, reason} -> repo().rollback(reason)
      end
    end)
    |> announce()
  end

  defp load(uuids) do
    valid = for u <- uuids, {:ok, uuid} <- [Ecto.UUID.cast(u)], do: uuid

    found =
      from(f in StorageFile, where: f.uuid in ^valid, lock: "FOR UPDATE")
      |> repo().all()
      |> Map.new(&{&1.uuid, &1})

    files = for u <- valid, file = found[u], do: file

    if valid != [] and length(files) == length(uuids),
      do: {:ok, files},
      else: {:error, :not_found}
  end

  defp check_edit(files, scope) do
    if Enum.all?(files, &Libraries.can?(scope, &1, :edit)), do: :ok, else: {:error, :forbidden}
  end

  defp valid?(lat, lon), do: lat >= -90 and lat <= 90 and lon >= -180 and lon <= 180

  # Six decimals is about 10 cm: more is noise a map pin cannot have meant.
  defp round_degrees(value), do: Float.round(value * 1.0, 6)

  defp clean_name(name) when is_binary(name) do
    case name |> String.trim() |> String.slice(0, @max_name) do
      "" -> nil
      name -> name
    end
  end

  defp clean_name(_name), do: nil

  defp put_place(metadata, nil, _lat, _lon), do: Map.delete(metadata, @place_key)

  defp put_place(metadata, name, lat, lon),
    do: Map.put(metadata, @place_key, %{"name" => name, "latitude" => lat, "longitude" => lon})

  defp same?(a, b) when is_number(a) and is_number(b), do: abs(a - b) < 1.0e-6
  defp same?(_a, _b), do: false

  defp exif_position(%{metadata: %{"exif" => %{"gps" => %{} = gps}}}) do
    case {gps["latitude"], gps["longitude"]} do
      {lat, lon} when is_number(lat) and is_number(lon) -> {lat * 1.0, lon * 1.0}
      _ -> {nil, nil}
    end
  end

  defp exif_position(_file), do: {nil, nil}

  defp announce({:ok, file_uuids}) do
    if file_uuids != [], do: Storage.broadcast_files_changed(file_uuids)
    {:ok, file_uuids}
  end

  defp announce({:error, _reason} = error), do: error

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
