defmodule PhoenixKit.Modules.Publishing.DBImporter do
  @moduledoc """
  Synchronous filesystem-to-database importer for Publishing content.

  Reads groups/posts/versions/contents from the filesystem and upserts them
  into the database tables created by migration V59. Designed to be called
  from LiveView event handlers (admin UI buttons).

  Idempotent: safe to run multiple times. Uses deterministic upsert keys
  (`group_slug`, `group_id + post_slug`, `post_id + version_number`,
  `version_id + language`).
  """

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage

  @type stats :: %{
          groups: non_neg_integer(),
          posts: non_neg_integer(),
          versions: non_neg_integer(),
          contents: non_neg_integer(),
          errors: non_neg_integer()
        }

  @doc """
  Imports all publishing groups and their content from filesystem to database.

  Returns `{:ok, stats}` with aggregate counts.
  """
  @spec import_all_groups() :: {:ok, stats()}
  def import_all_groups do
    groups = Publishing.list_groups()
    Logger.info("[DBImporter] Importing #{length(groups)} groups from filesystem")

    stats =
      Enum.reduce(groups, %{groups: 0, posts: 0, versions: 0, contents: 0, errors: 0}, fn group,
                                                                                          acc ->
        # Each group broadcasts its own start/complete so listing pages update per-group
        case import_group(group, _broadcast: true) do
          {:ok, group_stats} ->
            %{
              acc
              | groups: acc.groups + 1,
                posts: acc.posts + group_stats.posts,
                versions: acc.versions + group_stats.versions,
                contents: acc.contents + group_stats.contents,
                errors: acc.errors + group_stats.errors
            }

          {:error, reason} ->
            Logger.warning(
              "[DBImporter] Failed to import group #{group["slug"]}: #{inspect(reason)}"
            )

            %{acc | errors: acc.errors + 1}
        end
      end)

    Logger.info(
      "[DBImporter] Import complete: #{stats.groups} groups, #{stats.posts} posts, " <>
        "#{stats.versions} versions, #{stats.contents} contents, #{stats.errors} errors"
    )

    # Auto-enable DB storage now that all groups have been imported
    if stats.errors == 0, do: Publishing.enable_db_storage!()

    {:ok, stats}
  end

  @doc """
  Imports a single publishing group and all its posts from filesystem to database.

  Accepts either a group map (from `Publishing.list_groups()`) or a group slug string.

  Returns `{:ok, stats}` or `{:error, reason}`.
  """
  @spec import_group(map() | String.t()) :: {:ok, stats()} | {:error, any()}
  def import_group(group_slug) when is_binary(group_slug) do
    case Publishing.get_group(group_slug) do
      {:ok, group} -> import_group(group)
      {:error, _} = error -> error
    end
  end

  def import_group(group) when is_map(group) do
    import_group(group, _broadcast: true)
  end

  # Internal: accepts _broadcast option to avoid double-broadcasting from import_all_groups
  defp import_group(group, opts) when is_map(group) do
    slug = group["slug"]
    mode = group["mode"] || "timestamp"
    broadcast? = Keyword.get(opts, :_broadcast, true)
    Logger.info("[DBImporter] Importing group: #{slug} (mode: #{mode})")

    if broadcast?, do: PublishingPubSub.broadcast_db_import_started(slug, :sync)

    # Upsert the group record
    {:ok, db_group} =
      DBStorage.upsert_group(%{
        name: group["name"] || slug,
        slug: slug,
        mode: to_string(mode),
        position: group["position"] || 0,
        data: extract_group_data(group)
      })

    # List all posts from filesystem
    posts =
      case mode do
        "slug" -> Storage.list_posts_slug_mode(slug)
        _ -> Storage.list_posts(slug)
      end

    stats =
      Enum.reduce(posts, %{posts: 0, versions: 0, contents: 0, errors: 0}, fn post, acc ->
        case import_post(db_group, slug, post, mode) do
          {:ok, post_stats} ->
            %{
              acc
              | posts: acc.posts + 1,
                versions: acc.versions + post_stats.versions,
                contents: acc.contents + post_stats.contents,
                errors: acc.errors + post_stats.errors
            }

          {:error, reason} ->
            Logger.warning(
              "[DBImporter] Failed to import post #{slug}/#{post[:slug]}: #{inspect(reason)}"
            )

            %{acc | errors: acc.errors + 1}
        end
      end)

    Logger.info(
      "[DBImporter] Group #{slug}: #{stats.posts} posts, " <>
        "#{stats.versions} versions, #{stats.contents} contents"
    )

    if broadcast?, do: PublishingPubSub.broadcast_db_import_completed(slug, stats, :sync)

    # Auto-enable DB storage if all groups have been imported
    maybe_enable_db_storage()

    {:ok, stats}
  rescue
    error ->
      {:error, error}
  end

  @doc """
  Returns the DB import status for a group: whether it exists in the DB and how many posts it has.
  """
  @spec group_db_status(String.t()) :: %{exists: boolean(), post_count: non_neg_integer()}
  def group_db_status(group_slug) do
    case DBStorage.get_group_by_slug(group_slug) do
      nil ->
        %{exists: false, post_count: 0}

      _group ->
        posts = DBStorage.list_posts(group_slug)
        %{exists: true, post_count: length(posts)}
    end
  end

  @doc """
  Checks if all publishing groups have been imported to the database and
  enables DB storage mode if so.
  """
  def maybe_enable_db_storage do
    if Publishing.db_storage?() do
      :already_enabled
    else
      groups = Publishing.list_groups()
      all_imported = Enum.all?(groups, fn g -> group_db_status(g["slug"]).exists end)

      if all_imported do
        Publishing.enable_db_storage!()
        Logger.info("[DBImporter] All groups imported — enabled DB storage mode")
        :enabled
      else
        :pending
      end
    end
  rescue
    _ -> :error
  end

  # ---------------------------------------------------------------------------
  # Post Import
  # ---------------------------------------------------------------------------

  defp import_post(db_group, group_slug, post, mode) do
    # Read full post data to get all versions and languages
    full_post = read_full_post(group_slug, post, mode)
    effective_post = full_post || post

    # Upsert the post record
    {:ok, db_post} = upsert_post(db_group, effective_post)

    # Import all versions
    available_versions = effective_post[:available_versions] || [1]
    version_statuses = effective_post[:version_statuses] || %{}

    stats =
      Enum.reduce(available_versions, %{versions: 0, contents: 0, errors: 0}, fn version_num,
                                                                                 acc ->
        case import_version(
               db_post,
               group_slug,
               effective_post,
               version_num,
               version_statuses,
               mode
             ) do
          {:ok, content_count} ->
            %{acc | versions: acc.versions + 1, contents: acc.contents + content_count}

          {:error, reason} ->
            Logger.warning(
              "[DBImporter] Failed to import version #{group_slug}/#{post[:slug]}/v#{version_num}: #{inspect(reason)}"
            )

            %{acc | errors: acc.errors + 1}
        end
      end)

    {:ok, stats}
  rescue
    error ->
      {:error, error}
  end

  defp read_full_post(group_slug, post, mode) do
    result =
      case mode do
        "slug" -> Storage.read_post_slug_mode(group_slug, post[:slug])
        _ -> Storage.read_post(group_slug, post[:path])
      end

    case result do
      {:ok, full} -> full
      _ -> nil
    end
  end

  defp upsert_post(db_group, post) do
    existing = DBStorage.get_post(db_group.slug, post[:slug])

    attrs = %{
      group_uuid: db_group.uuid,
      slug: post[:slug],
      status: post[:metadata][:status] || "draft",
      mode: to_string(post[:mode] || db_group.mode),
      primary_language: post[:primary_language] || post[:language] || "en",
      published_at: parse_datetime(post[:metadata][:published_at]),
      post_date: post[:date],
      post_time: post[:time],
      data: extract_post_data(post)
    }

    case existing do
      nil -> DBStorage.create_post(attrs)
      db_post -> DBStorage.update_post(db_post, attrs)
    end
  end

  # ---------------------------------------------------------------------------
  # Version Import
  # ---------------------------------------------------------------------------

  defp import_version(db_post, group_slug, post, version_num, version_statuses, mode) do
    existing_version = DBStorage.get_version(db_post.uuid, version_num)
    status = Map.get(version_statuses, version_num, "draft")

    version_attrs = %{
      post_uuid: db_post.uuid,
      version_number: version_num,
      status: to_string(status)
    }

    {:ok, db_version} =
      case existing_version do
        nil -> DBStorage.create_version(version_attrs)
        v -> DBStorage.update_version(v, version_attrs)
      end

    # Use available_languages from the full post data (already loaded)
    # Fall back to filesystem discovery if not available
    languages =
      post[:available_languages] || discover_languages(group_slug, post, version_num, mode)

    content_count =
      Enum.reduce(languages, 0, fn lang, count ->
        case import_content(db_version, group_slug, post, version_num, lang, mode) do
          :ok -> count + 1
          {:error, _} -> count
        end
      end)

    {:ok, content_count}
  rescue
    error ->
      {:error, error}
  end

  defp discover_languages(group_slug, post, version_num, mode) do
    result =
      case mode do
        "slug" -> Storage.read_post_slug_mode(group_slug, post[:slug], nil, version_num)
        _ -> Storage.read_post(group_slug, post[:path])
      end

    case result do
      {:ok, read_post} -> read_post[:available_languages] || ["en"]
      _ -> ["en"]
    end
  end

  # ---------------------------------------------------------------------------
  # Content Import
  # ---------------------------------------------------------------------------

  defp import_content(db_version, group_slug, post, version_num, language, mode) do
    result =
      case mode do
        "slug" ->
          Storage.read_post_slug_mode(group_slug, post[:slug], language, version_num)

        _ ->
          # For timestamp mode, build the language-specific path from the post path
          read_timestamp_post_language(group_slug, post, version_num, language)
      end

    case result do
      {:ok, read_post} ->
        DBStorage.upsert_content(%{
          version_uuid: db_version.uuid,
          language: language,
          title: read_post[:metadata][:title] || "Untitled",
          content: read_post[:content] || "",
          status: to_string(read_post[:metadata][:status] || "draft"),
          url_slug: read_post[:url_slug],
          data: extract_content_data(read_post)
        })

        :ok

      {:error, reason} ->
        Logger.warning(
          "[DBImporter] Could not read #{group_slug}/#{post[:slug]}/v#{version_num}/#{language}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp read_timestamp_post_language(_group_slug, post, version_num, language) do
    original_path = post[:path]

    with true <- is_binary(original_path) || {:error, :no_path},
         dir = Path.dirname(Path.dirname(original_path)),
         new_path = Path.join([dir, "v#{version_num}", "#{language}.phk"]),
         full_path = Storage.Paths.absolute_path(new_path),
         true <- File.exists?(full_path) || {:error, :not_found},
         {:ok, file_content} <- File.read(full_path),
         {:ok, metadata, content} <- Publishing.Metadata.parse_with_content(file_content) do
      {:ok,
       %{
         metadata: metadata,
         content: content,
         language: language,
         url_slug: metadata[:url_slug] || post[:slug]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, :read_failed}
    end
  end

  # ---------------------------------------------------------------------------
  # Data Extraction Helpers
  # ---------------------------------------------------------------------------

  defp extract_group_data(group) do
    %{}
    |> maybe_put("type", group["type"])
    |> maybe_put("item_singular", group["item_singular"])
    |> maybe_put("item_plural", group["item_plural"])
    |> maybe_put("description", group["description"])
    |> maybe_put("icon", group["icon"])
  end

  defp extract_post_data(post) do
    metadata = post[:metadata] || %{}

    %{}
    |> maybe_put("allow_version_access", metadata[:allow_version_access])
    |> maybe_put("featured_image", metadata[:featured_image_uuid])
    |> maybe_put("tags", metadata[:tags])
  end

  defp extract_content_data(post) do
    metadata = post[:metadata] || %{}

    %{}
    |> maybe_put("description", metadata[:description])
    |> maybe_put("previous_url_slugs", metadata[:previous_url_slugs])
    |> maybe_put("featured_image_uuid", metadata[:featured_image_uuid])
    |> maybe_put("seo_title", metadata[:seo_title])
    |> maybe_put("excerpt", metadata[:excerpt])
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

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
