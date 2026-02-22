defmodule PhoenixKit.Modules.Publishing.Workers.MigrateToDatabaseWorker do
  @moduledoc """
  Oban worker that backfills all filesystem publishing content into the database.

  Reads groups from Settings, then for each group scans the filesystem for posts.
  Each post, its versions, and its language content rows are upserted into the
  database tables created by migration V59.

  Idempotent: safe to run multiple times. Uses deterministic upsert keys
  (`group_slug`, `group_id + post_slug`, `post_id + version_number`,
  `version_id + language`).

  ## Usage

      MigrateToDatabaseWorker.enqueue()

  ## PubSub Events

  Broadcasts to the publishing groups topic:

  - `{:db_migration_started, total_groups}`
  - `{:db_migration_group_progress, group_slug, posts_migrated, total_posts}`
  - `{:db_migration_completed, stats}`
  """

  use Oban.Worker, queue: :default, max_attempts: 3

  require Logger

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[MigrateToDB] Starting filesystem → database migration")

    groups = Publishing.list_groups()

    broadcast_migration_started(length(groups))

    stats =
      Enum.reduce(groups, %{groups: 0, posts: 0, versions: 0, contents: 0, errors: 0}, fn group,
                                                                                          acc ->
        slug = group["slug"]
        Logger.info("[MigrateToDB] Migrating group: #{slug}")

        case migrate_group(group) do
          {:ok, group_stats} ->
            broadcast_group_progress(slug, group_stats.posts, group_stats.posts)

            %{
              acc
              | groups: acc.groups + 1,
                posts: acc.posts + group_stats.posts,
                versions: acc.versions + group_stats.versions,
                contents: acc.contents + group_stats.contents,
                errors: acc.errors + group_stats.errors
            }

          {:error, reason} ->
            Logger.warning("[MigrateToDB] Failed to migrate group #{slug}: #{inspect(reason)}")
            %{acc | errors: acc.errors + 1}
        end
      end)

    broadcast_migration_completed(stats)

    Logger.info(
      "[MigrateToDB] Migration complete: " <>
        "#{stats.groups} groups, #{stats.posts} posts, " <>
        "#{stats.versions} versions, #{stats.contents} contents, " <>
        "#{stats.errors} errors"
    )

    :ok
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(30)

  # ---------------------------------------------------------------------------
  # Group Migration
  # ---------------------------------------------------------------------------

  defp migrate_group(group) do
    slug = group["slug"]
    mode = group["mode"] || "timestamp"

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
        case migrate_post(db_group, slug, post, mode) do
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
              "[MigrateToDB] Failed to migrate post #{slug}/#{post[:slug]}: #{inspect(reason)}"
            )

            %{acc | errors: acc.errors + 1}
        end
      end)

    {:ok, stats}
  rescue
    error ->
      {:error, error}
  end

  # ---------------------------------------------------------------------------
  # Post Migration
  # ---------------------------------------------------------------------------

  defp migrate_post(db_group, group_slug, post, mode) do
    repo = PhoenixKit.RepoHelper.repo()

    repo.transaction(fn ->
      post_slug = post[:slug]

      # Read full post data to get all versions and languages
      full_post = read_full_post(group_slug, post, mode)

      # Upsert the post record
      {:ok, db_post} =
        upsert_post(db_group, full_post || post)

      # Migrate all versions
      available_versions = (full_post || post)[:available_versions] || [1]
      version_statuses = (full_post || post)[:version_statuses] || %{}

      Enum.reduce(available_versions, %{versions: 0, contents: 0, errors: 0}, fn version_num,
                                                                                 acc ->
        case migrate_version(db_post, group_slug, post_slug, version_num, version_statuses, mode) do
          {:ok, content_count} ->
            %{acc | versions: acc.versions + 1, contents: acc.contents + content_count}

          {:error, reason} ->
            Logger.warning(
              "[MigrateToDB] Failed to migrate version #{group_slug}/#{post_slug}/v#{version_num}: #{inspect(reason)}"
            )

            %{acc | errors: acc.errors + 1}
        end
      end)
    end)
  rescue
    error ->
      {:error, error}
  end

  defp read_full_post(group_slug, post, mode) do
    result =
      case mode do
        "slug" ->
          Storage.read_post_slug_mode(group_slug, post[:slug])

        _ ->
          # For timestamp mode, use the path
          Storage.read_post(group_slug, post[:path])
      end

    case result do
      {:ok, full} -> full
      _ -> nil
    end
  end

  defp upsert_post(db_group, post) do
    existing = DBStorage.get_post(db_group.slug, post[:slug])

    attrs = %{
      group_id: db_group.uuid,
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
  # Version Migration
  # ---------------------------------------------------------------------------

  defp migrate_version(db_post, group_slug, post_slug, version_num, version_statuses, mode) do
    # Upsert the version
    existing_version = DBStorage.get_version(db_post.uuid, version_num)
    status = Map.get(version_statuses, version_num, "draft")

    version_attrs = %{
      post_id: db_post.uuid,
      version_number: version_num,
      status: to_string(status)
    }

    {:ok, db_version} =
      case existing_version do
        nil -> DBStorage.create_version(version_attrs)
        v -> DBStorage.update_version(v, version_attrs)
      end

    # Get all languages for this version by reading the post at each version
    languages = discover_languages(group_slug, post_slug, version_num, mode)

    content_count =
      Enum.reduce(languages, 0, fn lang, count ->
        case migrate_content(db_version, group_slug, post_slug, version_num, lang, mode) do
          :ok -> count + 1
          {:error, _} -> count
        end
      end)

    {:ok, content_count}
  rescue
    error ->
      {:error, error}
  end

  defp discover_languages(group_slug, post_slug, version_num, mode) do
    result =
      case mode do
        "slug" ->
          Storage.read_post_slug_mode(group_slug, post_slug, nil, version_num)

        _ ->
          # For timestamp mode, this is trickier — read with default language first
          Storage.read_post(group_slug, post_slug)
      end

    case result do
      {:ok, post} -> post[:available_languages] || ["en"]
      _ -> ["en"]
    end
  end

  # ---------------------------------------------------------------------------
  # Content Migration
  # ---------------------------------------------------------------------------

  defp migrate_content(db_version, group_slug, post_slug, version_num, language, mode) do
    # Read the specific language content
    result =
      case mode do
        "slug" ->
          Storage.read_post_slug_mode(group_slug, post_slug, language, version_num)

        _ ->
          Storage.read_post(group_slug, post_slug)
      end

    case result do
      {:ok, post} ->
        DBStorage.upsert_content(%{
          version_id: db_version.uuid,
          language: language,
          title: post[:metadata][:title] || "Untitled",
          content: post[:content] || "",
          status: to_string(post[:metadata][:status] || "draft"),
          url_slug: post[:url_slug],
          data: extract_content_data(post)
        })

        :ok

      {:error, reason} ->
        Logger.warning(
          "[MigrateToDB] Could not read #{group_slug}/#{post_slug}/v#{version_num}/#{language}: #{inspect(reason)}"
        )

        {:error, reason}
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
    |> maybe_put("featured_image", metadata[:featured_image_id])
    |> maybe_put("tags", metadata[:tags])
  end

  defp extract_content_data(post) do
    metadata = post[:metadata] || %{}

    %{}
    |> maybe_put("description", metadata[:description])
    |> maybe_put("previous_url_slugs", metadata[:previous_url_slugs])
    |> maybe_put("featured_image_id", metadata[:featured_image_id])
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

  # ---------------------------------------------------------------------------
  # PubSub Broadcasting
  # ---------------------------------------------------------------------------

  defp broadcast_migration_started(total_groups) do
    PublishingPubSub.broadcast_db_migration_started(total_groups)
  rescue
    _ -> :ok
  end

  defp broadcast_group_progress(group_slug, posts_migrated, total_posts) do
    PublishingPubSub.broadcast_db_migration_group_progress(
      group_slug,
      posts_migrated,
      total_posts
    )
  rescue
    _ -> :ok
  end

  defp broadcast_migration_completed(stats) do
    PublishingPubSub.broadcast_db_migration_completed(stats)

    # Only auto-enable DB storage if migration completed without errors
    if Map.get(stats, :errors, 0) == 0 do
      Publishing.enable_db_storage!()
    else
      Logger.warning(
        "[MigrateToDB] Skipping auto-enable DB storage: #{stats.errors} errors during migration"
      )
    end
  rescue
    _ -> :ok
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Creates a new migration job.

  ## Examples

      MigrateToDatabaseWorker.create_job()

  """
  def create_job do
    new(%{"type" => "full_migration"})
  end

  @doc """
  Enqueues a migration job.

  ## Examples

      {:ok, job} = MigrateToDatabaseWorker.enqueue()

  """
  def enqueue do
    create_job()
    |> Oban.insert()
  end
end
