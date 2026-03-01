defmodule PhoenixKit.Modules.Publishing.DualWrite do
  @moduledoc """
  Dual-write layer: mirrors filesystem writes to the database.

  Every function in this module is fail-safe — if the DB write fails,
  it logs a warning and returns `:ok`. The filesystem write (which already
  succeeded) is never blocked.

  ## Usage

  Called from `publishing.ex` after each successful filesystem operation:

      case Storage.create_post(...) do
        {:ok, post} ->
          DualWrite.sync_post_created(group_slug, post, opts)
          {:ok, post}
        error -> error
      end

  ## Feature Flag

  All operations check `publishing_storage` setting. If set to "filesystem"
  (default), dual-write is active. If set to "db", reads come from DB and
  dual-write is no longer needed (but harmless).
  """

  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Utils.Date, as: UtilsDate

  require Logger

  @doc """
  Syncs a newly created group to the database.
  """
  def sync_group_created(group_map) do
    safe_write("sync_group_created", fn ->
      DBStorage.upsert_group(%{
        name: group_map[:name] || group_map["name"],
        slug: group_map[:slug] || group_map["slug"],
        mode: to_string(group_map[:mode] || group_map["mode"] || "timestamp"),
        position: group_map[:position] || group_map["position"] || 0,
        data:
          Map.take(group_map, [
            :type,
            :item_singular,
            :item_plural,
            :description,
            :icon,
            "type",
            "item_singular",
            "item_plural",
            "description",
            "icon"
          ])
          |> stringify_keys()
      })
    end)
  end

  @doc """
  Syncs a group update to the database.
  """
  def sync_group_updated(slug, group_map) do
    safe_write("sync_group_updated", fn ->
      case DBStorage.get_group_by_slug(slug) do
        nil ->
          # Group doesn't exist in DB yet — create it
          sync_group_created(group_map)

        group ->
          DBStorage.update_group(group, %{
            name: group_map[:name] || group_map["name"] || group.name,
            slug: group_map[:slug] || group_map["slug"] || group.slug,
            mode: to_string(group_map[:mode] || group_map["mode"] || group.mode),
            position: group_map[:position] || group_map["position"] || group.position,
            data: Map.merge(group.data, extract_group_data(group_map))
          })
      end
    end)
  end

  @doc """
  Syncs a group deletion to the database.
  """
  def sync_group_deleted(slug) do
    safe_write("sync_group_deleted", fn ->
      case DBStorage.get_group_by_slug(slug) do
        nil -> :ok
        group -> DBStorage.delete_group(group)
      end
    end)
  end

  @doc """
  Syncs a newly created post to the database.

  Creates the post, its first version, and the initial content row.
  """
  def sync_post_created(group_slug, post_map, opts \\ %{}) do
    safe_write("sync_post_created", fn ->
      group = DBStorage.get_group_by_slug(group_slug)

      unless group do
        Logger.warning("[DualWrite] Group #{group_slug} not found in DB, skipping post sync")
        throw(:skip)
      end

      # Resolve user UUID for dual-write
      created_by_uuid = resolve_user_uuids(opts)

      # Create the post
      {:ok, db_post} =
        DBStorage.create_post(%{
          group_uuid: group.uuid,
          slug: post_map[:slug],
          status: post_map[:metadata][:status] || "draft",
          mode: to_string(post_map[:mode] || group.mode),
          primary_language: post_map[:primary_language] || post_map[:language] || "en",
          published_at: parse_datetime(post_map[:metadata][:published_at]),
          post_date: post_map[:date],
          post_time: post_map[:time],
          created_by_uuid: created_by_uuid,
          updated_by_uuid: created_by_uuid,
          data: extract_post_data(post_map)
        })

      # Create version 1
      version_number = post_map[:version] || 1

      {:ok, db_version} =
        DBStorage.create_version(%{
          post_uuid: db_post.uuid,
          version_number: version_number,
          status: post_map[:metadata][:status] || "draft",
          created_by_uuid: created_by_uuid
        })

      # Create content for the language
      language = post_map[:language] || "en"

      DBStorage.create_content(%{
        version_uuid: db_version.uuid,
        language: language,
        title: post_map[:metadata][:title] || "Untitled",
        content: post_map[:content],
        status: post_map[:metadata][:status] || "draft",
        url_slug: post_map[:url_slug],
        data: extract_content_data(post_map)
      })
    end)
  end

  @doc """
  Syncs a post update to the database.
  """
  def sync_post_updated(group_slug, post_map, _opts \\ %{}) do
    safe_write("sync_post_updated", fn ->
      db_post = DBStorage.get_post(group_slug, post_map[:slug])

      unless db_post do
        Logger.debug("[DualWrite] Post #{group_slug}/#{post_map[:slug]} not in DB, skipping")
        throw(:skip)
      end

      # Update post-level fields
      DBStorage.update_post(db_post, %{
        status: post_map[:metadata][:status] || db_post.status,
        published_at: parse_datetime(post_map[:metadata][:published_at]) || db_post.published_at,
        post_date: post_map[:date] || db_post.post_date,
        post_time: post_map[:time] || db_post.post_time,
        data: Map.merge(db_post.data, extract_post_data(post_map))
      })

      # Update content for the current version/language
      version = DBStorage.get_version(db_post.uuid, post_map[:version] || 1)

      if version do
        language = post_map[:language] || db_post.primary_language

        DBStorage.upsert_content(%{
          version_uuid: version.uuid,
          language: language,
          title: post_map[:metadata][:title] || "Untitled",
          content: post_map[:content],
          status: post_map[:metadata][:status] || "draft",
          url_slug: post_map[:url_slug],
          data: extract_content_data(post_map)
        })
      end
    end)
  end

  @doc """
  Syncs a new version creation to the database.
  """
  def sync_version_created(group_slug, post_map, opts \\ %{}) do
    safe_write("sync_version_created", fn ->
      db_post = DBStorage.get_post(group_slug, post_map[:slug])

      unless db_post do
        Logger.debug("[DualWrite] Post #{group_slug}/#{post_map[:slug]} not in DB, skipping")
        throw(:skip)
      end

      created_by_uuid = resolve_user_uuids(opts)
      version_number = post_map[:version] || DBStorage.next_version_number(db_post.uuid)

      {:ok, db_version} =
        DBStorage.create_version(%{
          post_uuid: db_post.uuid,
          version_number: version_number,
          status: "draft",
          created_by_uuid: created_by_uuid,
          data: %{"created_from" => opts[:source_version]}
        })

      # Create content rows for each language in the new version
      languages = post_map[:available_languages] || [post_map[:language] || "en"]

      for lang <- languages do
        DBStorage.create_content(%{
          version_uuid: db_version.uuid,
          language: lang,
          title: post_map[:metadata][:title] || "Untitled",
          content: post_map[:content],
          status: "draft",
          url_slug: post_map[:url_slug]
        })
      end
    end)
  end

  @doc """
  Syncs a language addition to the database.
  """
  def sync_language_added(group_slug, post_slug, language_code, version_number) do
    safe_write("sync_language_added", fn ->
      db_post = DBStorage.get_post(group_slug, post_slug)

      unless db_post do
        throw(:skip)
      end

      version = DBStorage.get_version(db_post.uuid, version_number || 1)

      if version do
        DBStorage.upsert_content(%{
          version_uuid: version.uuid,
          language: language_code,
          title: "Untitled",
          content: "",
          status: "draft"
        })
      end
    end)
  end

  @doc """
  Syncs a language deletion to the database.
  """
  def sync_language_deleted(group_slug, post_slug, language_code, version_number) do
    safe_write("sync_language_deleted", fn ->
      db_post = DBStorage.get_post(group_slug, post_slug)

      unless db_post do
        throw(:skip)
      end

      version = DBStorage.get_version(db_post.uuid, version_number || 1)

      if version do
        content = DBStorage.get_content(version.uuid, language_code)

        if content do
          DBStorage.update_content(content, %{status: "archived"})
        end
      end
    end)
  end

  @doc """
  Syncs a version publish to the database.
  """
  def sync_version_published(group_slug, post_slug, version_number) do
    safe_write("sync_version_published", fn ->
      db_post = DBStorage.get_post(group_slug, post_slug)

      unless db_post do
        throw(:skip)
      end

      # Archive all other versions, publish the target one
      all_versions = DBStorage.list_versions(db_post.uuid)
      Enum.each(all_versions, &publish_or_archive_version(&1, version_number))

      # Update post status and published_at
      DBStorage.update_post(db_post, %{
        status: "published",
        published_at: db_post.published_at || UtilsDate.utc_now()
      })
    end)
  end

  @doc """
  Syncs a translation status change to the database.
  """
  def sync_translation_status(group_slug, post_slug, version_number, language, status) do
    safe_write("sync_translation_status", fn ->
      db_post = DBStorage.get_post(group_slug, post_slug)

      unless db_post do
        throw(:skip)
      end

      version = DBStorage.get_version(db_post.uuid, version_number)

      if version do
        content = DBStorage.get_content(version.uuid, language)

        if content do
          DBStorage.update_content(content, %{status: status})
        end
      end
    end)
  end

  @doc """
  Syncs a post deletion (trash) to the database.
  """
  def sync_post_deleted(group_slug, post_slug) do
    safe_write("sync_post_deleted", fn ->
      db_post = DBStorage.get_post(group_slug, post_slug)

      if db_post do
        DBStorage.soft_delete_post(db_post)
      end
    end)
  end

  @doc """
  Syncs a version deletion to the database.
  """
  def sync_version_deleted(group_slug, post_slug, version_number) do
    safe_write("sync_version_deleted", fn ->
      db_post = DBStorage.get_post(group_slug, post_slug)

      unless db_post do
        throw(:skip)
      end

      version = DBStorage.get_version(db_post.uuid, version_number)

      if version do
        DBStorage.update_version(version, %{status: "archived"})
      end
    end)
  end

  @doc """
  Syncs a primary language update to the database.
  """
  def sync_primary_language(group_slug, post_slug, primary_language) do
    safe_write("sync_primary_language", fn ->
      db_post = DBStorage.get_post(group_slug, post_slug)

      if db_post do
        DBStorage.update_post(db_post, %{primary_language: primary_language})
      end
    end)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp publish_or_archive_version(version, target_number)
       when version.version_number == target_number do
    DBStorage.update_version(version, %{status: "published"})

    for c <- DBStorage.list_contents(version.uuid) do
      DBStorage.update_content(c, %{status: "published"})
    end
  end

  defp publish_or_archive_version(%{status: "published"} = version, _target_number) do
    DBStorage.update_version(version, %{status: "archived"})
  end

  defp publish_or_archive_version(_version, _target_number), do: :noop

  defp safe_write(operation, func) do
    func.()
    :ok
  rescue
    error ->
      Logger.warning("[DualWrite] #{operation} failed: #{inspect(error)}")
      :ok
  catch
    :skip -> :ok
  end

  defp resolve_user_uuids(opts) do
    opts[:user_uuid] || opts[:created_by_uuid]
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = dt), do: dt

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(_), do: nil

  defp extract_post_data(post_map) do
    metadata = post_map[:metadata] || %{}

    %{}
    |> maybe_put("allow_version_access", metadata[:allow_version_access])
    |> maybe_put("featured_image", metadata[:featured_image_uuid])
    |> maybe_put("tags", metadata[:tags])
  end

  defp extract_content_data(post_map) do
    metadata = post_map[:metadata] || %{}

    %{}
    |> maybe_put("description", metadata[:description])
    |> maybe_put("previous_url_slugs", metadata[:previous_url_slugs])
    |> maybe_put("featured_image_uuid", metadata[:featured_image_uuid])
    |> maybe_put("seo_title", metadata[:seo_title])
    |> maybe_put("excerpt", metadata[:excerpt])
  end

  defp extract_group_data(group_map) do
    %{}
    |> maybe_put("type", group_map[:type] || group_map["type"])
    |> maybe_put("item_singular", group_map[:item_singular] || group_map["item_singular"])
    |> maybe_put("item_plural", group_map[:item_plural] || group_map["item_plural"])
    |> maybe_put("description", group_map[:description] || group_map["description"])
    |> maybe_put("icon", group_map[:icon] || group_map["icon"])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end
end
