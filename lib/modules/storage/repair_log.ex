defmodule PhoenixKit.Modules.Storage.RepairLog do
  @moduledoc """
  The trail of storage that went wrong, read back for people: every copy found
  missing or damaged (`storage.copy.damaged`) and every repair of a file
  (`storage.file.repaired`), with the file, the library and the bucket each
  concerns, so a page can link to all three.

  The entries are written by `PhoenixKit.Modules.Storage.Audit.log_damage/3` and
  `log_repair/4` into the Activity log; this module is the reading side. It
  filters (`:file_uuid`, `:bucket_uuid`, `:library_uuid`, `:kind`), pages, and
  resolves what each entry points at: a file or bucket that is gone is a name
  without a link, and an entry written before library names were recorded finds
  its library through the file.

  Options of `list/1`: `:file_uuid`, `:bucket_uuid`, `:library_uuid`, `:kind`
  (`:damaged` or `:repaired`), `:page` (1) and `:per_page` (25).
  Returns `%{rows, page, total_pages, total}`; a row is

      %{uuid, at, kind, actor, file: %{uuid, name, exists?}, library: %{uuid, name, site?},
        bucket: %{uuid, name} | nil, rendition, problem, found_by,
        actions: [%{rendition, kind, bucket, from}], problems_left}
  """

  import Ecto.Query

  alias PhoenixKit.Activity
  alias PhoenixKit.Activity.Entry
  alias PhoenixKit.Modules.Storage.Bucket
  alias PhoenixKit.Modules.Storage.File, as: StorageFile
  alias PhoenixKit.Modules.Storage.Library

  @damaged "storage.copy.damaged"
  @repaired "storage.file.repaired"

  @spec list(keyword()) :: map()
  def list(opts \\ []) do
    result =
      Activity.list(
        query: query(opts),
        page: Keyword.get(opts, :page, 1),
        per_page: Keyword.get(opts, :per_page, 25),
        preload: [:actor]
      )

    %{
      rows: rows(result.entries),
      page: result.page,
      total_pages: result.total_pages,
      total: result.total
    }
  end

  @doc "The entry actions this log reads."
  @spec actions() :: [String.t()]
  def actions, do: [@damaged, @repaired]

  defp query(opts) do
    from(e in Entry, where: e.action in ^actions())
    |> kind(opts[:kind])
    |> file(opts[:file_uuid])
    |> bucket(opts[:bucket_uuid])
    |> library(opts[:library_uuid])
  end

  defp kind(query, :damaged), do: where(query, [e], e.action == ^@damaged)
  defp kind(query, :repaired), do: where(query, [e], e.action == ^@repaired)
  defp kind(query, _), do: query

  defp file(query, nil), do: query

  defp file(query, uuid) do
    uuid = to_string(uuid)

    where(
      query,
      [e],
      (e.resource_type == "file" and e.resource_uuid == ^uuid) or
        fragment("?->>'file_uuid' = ?", e.metadata, ^uuid)
    )
  end

  # A damaged copy is filed against its bucket; a repair names the buckets it
  # touched in the entry.
  defp bucket(query, nil), do: query

  defp bucket(query, uuid) do
    uuid = to_string(uuid)
    touched = %{"bucket_uuids" => [uuid]}

    where(
      query,
      [e],
      (e.resource_type == "bucket" and e.resource_uuid == ^uuid) or
        fragment("? @> ?", e.metadata, type(^touched, :map))
    )
  end

  defp library(query, nil), do: query

  defp library(query, uuid),
    do: where(query, [e], fragment("?->>'library_uuid' = ?", e.metadata, ^to_string(uuid)))

  # ── rows ──────────────────────────────────────────────────────

  defp rows(entries) do
    files = files_by_uuid(entries)
    libraries = libraries_by_uuid(entries, files)
    buckets = buckets_by_uuid(entries)

    Enum.map(entries, &row(&1, files, libraries, buckets))
  end

  defp row(%Entry{} = entry, files, libraries, buckets) do
    meta = entry.metadata || %{}
    file_uuid = if entry.resource_type == "file", do: entry.resource_uuid, else: meta["file_uuid"]
    file = Map.get(files, file_uuid)

    library_uuid =
      meta["library_uuid"] || (file && file.library_uuid && to_string(file.library_uuid))

    %{
      uuid: entry.uuid,
      at: entry.inserted_at,
      kind: if(entry.action == @damaged, do: :damaged, else: :repaired),
      actor: entry.actor,
      file: %{
        uuid: file_uuid,
        name: (file && file.name) || meta["file_name"],
        exists?: file != nil
      },
      library: library_ref(library_uuid, libraries),
      bucket: if(entry.resource_type == "bucket", do: bucket(entry, buckets, meta)),
      rendition: meta["rendition"],
      problem: meta["problem"],
      found_by: meta["found_by"],
      actions: actions(meta["actions"], buckets),
      problems_left: meta["problems_left"]
    }
  end

  defp library_ref(nil, _libraries), do: nil

  defp library_ref(uuid, libraries) do
    case Map.get(libraries, uuid) do
      nil -> %{uuid: uuid, name: nil, site?: false}
      library -> library
    end
  end

  defp bucket(entry, buckets, meta) do
    current = Map.get(buckets, entry.resource_uuid)

    %{
      uuid: entry.resource_uuid,
      name: (current && current.name) || meta["bucket"],
      exists?: current != nil
    }
  end

  defp actions(nil, _buckets), do: []

  defp actions(list, buckets) when is_list(list) do
    Enum.map(list, fn a ->
      %{
        rendition: a["rendition"],
        kind: a["kind"],
        bucket: a["bucket"],
        bucket_uuid: a["bucket_uuid"],
        bucket_exists?: Map.has_key?(buckets, a["bucket_uuid"]),
        from: a["from"],
        from_uuid: a["from_uuid"]
      }
    end)
  end

  defp actions(_other, _buckets), do: []

  # ── lookups, one query each for the whole page ─────────────────

  defp files_by_uuid(entries) do
    uuids =
      for e <- entries,
          uuid =
            if(e.resource_type == "file",
              do: e.resource_uuid,
              else: (e.metadata || %{})["file_uuid"]
            ),
          uniq: true,
          do: uuid

    if uuids == [] do
      %{}
    else
      from(f in StorageFile,
        where: f.uuid in ^uuids,
        select:
          {f.uuid,
           %{library_uuid: f.library_uuid, name: coalesce(f.original_file_name, f.file_name)}}
      )
      |> repo().all()
      |> Map.new(fn {uuid, file} -> {to_string(uuid), file} end)
    end
  end

  defp libraries_by_uuid(entries, files) do
    uuids =
      (for(e <- entries, uuid = (e.metadata || %{})["library_uuid"], do: uuid) ++
         for({_uuid, %{library_uuid: uuid}} <- files, uuid != nil, do: to_string(uuid)))
      |> Enum.uniq()

    if uuids == [] do
      %{}
    else
      from(l in Library,
        where: l.uuid in ^uuids,
        select: {l.uuid, %{name: l.name, kind: l.kind}}
      )
      |> repo().all()
      |> Map.new(fn {uuid, l} ->
        uuid = to_string(uuid)
        {uuid, %{uuid: uuid, name: l.name, site?: l.kind == "system"}}
      end)
    end
  end

  defp buckets_by_uuid(entries) do
    uuids =
      Enum.flat_map(entries, fn e ->
        meta = e.metadata || %{}

        [if(e.resource_type == "bucket", do: e.resource_uuid)] ++
          Enum.flat_map(meta["actions"] || [], &[&1["bucket_uuid"], &1["from_uuid"]])
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if uuids == [] do
      %{}
    else
      from(b in Bucket,
        where: b.uuid in ^uuids and is_nil(b.owner_uuid),
        select: {b.uuid, %{name: b.name}}
      )
      |> repo().all()
      |> Map.new(fn {uuid, b} -> {to_string(uuid), b} end)
    end
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
