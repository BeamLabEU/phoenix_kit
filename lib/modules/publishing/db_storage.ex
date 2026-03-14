defmodule PhoenixKit.Modules.Publishing.DBStorage do
  @moduledoc """
  Database storage layer for the Publishing module.

  Provides CRUD operations for publishing groups, posts, versions, and contents
  via PostgreSQL with Ecto.
  """

  import Ecto.Query

  alias PhoenixKit.Modules.Publishing.DBStorage.Mapper
  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  require Logger

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # ===========================================================================
  # Groups
  # ===========================================================================

  @doc "Creates a publishing group."
  def create_group(attrs) do
    %PublishingGroup{}
    |> PublishingGroup.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a publishing group."
  def update_group(%PublishingGroup{} = group, attrs) do
    group
    |> PublishingGroup.changeset(attrs)
    |> repo().update()
  end

  @doc "Gets a group by slug."
  def get_group_by_slug(slug) do
    repo().get_by(PublishingGroup, slug: slug)
  end

  @doc "Gets a group by UUID."
  def get_group(uuid) do
    repo().get(PublishingGroup, uuid)
  end

  @doc "Lists all groups ordered by position."
  def list_groups do
    PublishingGroup
    |> order_by([g], asc: g.position, asc: g.name)
    |> repo().all()
  end

  @doc "Upserts a group by slug."
  def upsert_group(attrs) do
    slug = Map.get(attrs, :slug) || Map.get(attrs, "slug")

    case get_group_by_slug(slug) do
      nil -> create_group(attrs)
      group -> update_group(group, attrs)
    end
  end

  @doc "Deletes a group and all its posts (cascade)."
  def delete_group(%PublishingGroup{} = group) do
    repo().delete(group)
  end

  # ===========================================================================
  # Posts
  # ===========================================================================

  @doc "Creates a post within a group."
  def create_post(attrs) do
    %PublishingPost{}
    |> PublishingPost.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a post."
  def update_post(%PublishingPost{} = post, attrs) do
    post
    |> PublishingPost.changeset(attrs)
    |> repo().update()
  end

  @doc "Gets a post by group slug and post slug."
  def get_post(group_slug, post_slug) do
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug and p.slug == ^post_slug,
      preload: [group: g]
    )
    |> repo().one()
  end

  @doc """
  Gets a timestamp-mode post by date and time.

  Truncates seconds from the input time since URLs use HH:MM format only,
  and new posts are stored with seconds zeroed. For older posts with non-zero
  seconds, falls back to hour:minute matching.
  """
  def get_post_by_datetime(group_slug, %Date{} = date, %Time{} = time) do
    # Normalize to zero seconds (URLs only carry HH:MM)
    normalized_time = %Time{hour: time.hour, minute: time.minute, second: 0, microsecond: {0, 0}}

    # Try exact match first (fast, uses index, works for all properly-stored posts)
    result =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug and p.post_date == ^date and p.post_time == ^normalized_time,
        preload: [group: g]
      )
      |> repo().one()

    if result do
      result
    else
      # Fallback for older posts stored with non-zero seconds
      hour = time.hour
      minute = time.minute

      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where:
          g.slug == ^group_slug and p.post_date == ^date and
            fragment(
              "EXTRACT(HOUR FROM ?)::integer = ? AND EXTRACT(MINUTE FROM ?)::integer = ?",
              p.post_time,
              ^hour,
              p.post_time,
              ^minute
            ),
        order_by: [asc: p.post_time],
        limit: 1,
        preload: [group: g]
      )
      |> repo().one()
    end
  end

  @doc "Gets a post by UUID with preloads."
  def get_post_by_uuid(uuid, preloads \\ []) do
    PublishingPost
    |> repo().get(uuid)
    |> maybe_preload(preloads)
  end

  @doc "Lists posts in a group, optionally filtered by status."
  def list_posts(group_slug, status \\ nil) do
    query =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug,
        preload: [group: g]
      )

    query =
      if status do
        where(query, [p], p.status == ^status)
      else
        query
      end

    query
    |> order_by_mode()
    |> repo().all()
  end

  @doc "Counts posts in a group."
  def count_posts(group_slug) do
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug,
      select: count(p.uuid)
    )
    |> repo().one() || 0
  end

  @doc "Lists posts in timestamp mode (ordered by date/time desc)."
  def list_posts_timestamp_mode(group_slug, status \\ nil) do
    query =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug,
        order_by: [desc: p.post_date, desc: p.post_time],
        preload: [group: g]
      )

    if status do
      where(query, [p], p.status == ^status)
    else
      query
    end
    |> repo().all()
  end

  @doc "Lists posts in slug mode (ordered by slug asc)."
  def list_posts_slug_mode(group_slug, status \\ nil) do
    query =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug,
        order_by: [asc: p.slug],
        preload: [group: g]
      )

    if status do
      where(query, [p], p.status == ^status)
    else
      query
    end
    |> repo().all()
  end

  @doc "Finds a post by date and time (timestamp mode, matches hour:minute only)."
  def find_post_by_date_time(group_slug, date, time) do
    # Delegate to get_post_by_datetime which handles normalization and fallback
    get_post_by_datetime(group_slug, date, time)
  end

  @doc "Soft-deletes a post by setting status to 'archived'."
  def soft_delete_post(%PublishingPost{} = post) do
    update_post(post, %{status: "archived"})
  end

  @doc "Hard-deletes a post and all its versions/contents (cascade)."
  def delete_post(%PublishingPost{} = post) do
    repo().delete(post)
  end

  @doc """
  Counts posts by primary language status for a group.

  Returns `%{current: n, needs_migration: n, needs_backfill: n}` where:
  - `current` — primary_language matches the global setting
  - `needs_migration` — primary_language is set but differs from global
  - `needs_backfill` — primary_language is nil
  """
  def count_primary_language_status(group_slug, global_primary) do
    posts = list_posts(group_slug)
    count_primary_language_status_from_posts(posts, global_primary)
  end

  @doc """
  Counts primary language status from an already-loaded list of posts.
  Avoids re-querying when posts are already available.

  Posts can be DB structs or maps (with `:primary_language` key).
  """
  def count_primary_language_status_from_posts(posts, global_primary) do
    Enum.reduce(posts, %{current: 0, needs_migration: 0, needs_backfill: 0}, fn post, acc ->
      primary_lang = Map.get(post, :primary_language)

      cond do
        is_nil(primary_lang) ->
          %{acc | needs_backfill: acc.needs_backfill + 1}

        primary_lang == global_primary ->
          %{acc | current: acc.current + 1}

        true ->
          %{acc | needs_migration: acc.needs_migration + 1}
      end
    end)
  end

  @doc """
  Updates all posts in a group to use the given primary language.

  Returns `{:ok, count}` with the number of updated posts.
  """
  def update_primary_language(group_slug, primary_language) do
    group = get_group_by_slug(group_slug)

    if group do
      {count, _} =
        from(p in PublishingPost,
          where:
            p.group_uuid == ^group.uuid and
              (is_nil(p.primary_language) or p.primary_language != ^primary_language)
        )
        |> repo().update_all(
          set: [primary_language: primary_language, updated_at: DateTime.utc_now()]
        )

      {:ok, count}
    else
      {:ok, 0}
    end
  end

  @doc "Counts posts needing primary language update in a group."
  def count_posts_needing_language_update(group_slug, primary_language) do
    group = get_group_by_slug(group_slug)

    if group do
      from(p in PublishingPost,
        where:
          p.group_uuid == ^group.uuid and
            (is_nil(p.primary_language) or p.primary_language != ^primary_language),
        select: count(p.uuid)
      )
      |> repo().one() || 0
    else
      0
    end
  end

  # ===========================================================================
  # Versions
  # ===========================================================================

  @doc "Creates a new version for a post."
  def create_version(attrs) do
    %PublishingVersion{}
    |> PublishingVersion.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates a version."
  def update_version(%PublishingVersion{} = version, attrs) do
    version
    |> PublishingVersion.changeset(attrs)
    |> repo().update()
  end

  @doc "Gets the latest version for a post."
  def get_latest_version(post_uuid) do
    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid,
      order_by: [desc: v.version_number],
      limit: 1
    )
    |> repo().one()
  end

  @doc "Gets a specific version by post and version number."
  def get_version(post_uuid, version_number) do
    repo().get_by(PublishingVersion,
      post_uuid: post_uuid,
      version_number: version_number
    )
  end

  @doc "Lists all versions for a post, ordered by version number."
  def list_versions(post_uuid) do
    from(v in PublishingVersion,
      where: v.post_uuid == ^post_uuid,
      order_by: [asc: v.version_number]
    )
    |> repo().all()
  end

  @doc """
  Gets the next version number for a post.

  Uses SELECT ... FOR UPDATE to lock the row and prevent concurrent reads
  from getting the same number.
  """
  def next_version_number(post_uuid) do
    result =
      from(v in PublishingVersion,
        where: v.post_uuid == ^post_uuid,
        select: max(v.version_number),
        lock: "FOR UPDATE"
      )
      |> repo().one()

    (result || 0) + 1
  end

  @doc """
  Creates a new version by cloning content from a source version.

  Creates a new version row and copies all content rows from the source.
  Wrapped in a transaction for atomicity.

  Returns `{:ok, %PublishingVersion{}}` or `{:error, reason}`.
  """
  def create_version_from(post_uuid, source_version_number, opts \\ %{}) do
    repo().transaction(fn ->
      source_version = get_version(post_uuid, source_version_number)
      unless source_version, do: repo().rollback(:source_not_found)

      new_version = do_create_cloned_version(post_uuid, source_version, opts)
      copy_contents_to_version(source_version.uuid, new_version.uuid)
      new_version
    end)
  end

  defp do_create_cloned_version(post_uuid, source_version, opts) do
    new_number = next_version_number(post_uuid)

    case create_version(%{
           post_uuid: post_uuid,
           version_number: new_number,
           status: "draft",
           created_by_uuid: opts[:created_by_uuid],
           data: %{"created_from" => source_version.version_number}
         }) do
      {:ok, new_version} -> new_version
      {:error, reason} -> repo().rollback(reason)
    end
  end

  defp copy_contents_to_version(source_version_uuid, target_version_uuid) do
    for content <- list_contents(source_version_uuid) do
      case create_content(%{
             version_uuid: target_version_uuid,
             language: content.language,
             title: content.title,
             content: content.content,
             status: "draft",
             url_slug: content.url_slug,
             data: content.data
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> repo().rollback(reason)
      end
    end
  end

  # ===========================================================================
  # Contents
  # ===========================================================================

  @doc "Creates content for a version/language."
  def create_content(attrs) do
    %PublishingContent{}
    |> PublishingContent.changeset(attrs)
    |> repo().insert()
  end

  @doc "Updates content."
  def update_content(%PublishingContent{} = content, attrs) do
    content
    |> PublishingContent.changeset(attrs)
    |> repo().update()
  end

  @doc "Bulk-updates the status of all content rows for a version."
  def update_content_status(version_uuid, new_status) do
    from(c in PublishingContent, where: c.version_uuid == ^version_uuid)
    |> repo().update_all(set: [status: new_status, updated_at: DateTime.utc_now()])
  end

  @doc "Bulk-updates the status of all content rows for a version, excluding a specific language."
  def update_content_status_except(version_uuid, exclude_language, new_status) do
    from(c in PublishingContent,
      where: c.version_uuid == ^version_uuid and c.language != ^exclude_language
    )
    |> repo().update_all(set: [status: new_status, updated_at: DateTime.utc_now()])
  end

  @doc "Gets content for a specific version and language."
  def get_content(version_uuid, language) do
    repo().get_by(PublishingContent,
      version_uuid: version_uuid,
      language: language
    )
  end

  @doc "Lists all content rows for a version."
  def list_contents(version_uuid) do
    from(c in PublishingContent,
      where: c.version_uuid == ^version_uuid,
      order_by: [asc: c.language]
    )
    |> repo().all()
  end

  @doc "Lists available languages for a version."
  def list_languages(version_uuid) do
    from(c in PublishingContent,
      where: c.version_uuid == ^version_uuid,
      select: c.language,
      order_by: [asc: c.language]
    )
    |> repo().all()
  end

  @doc "Finds content by URL slug across all versions in a group."
  def find_by_url_slug(group_slug, language, url_slug) do
    # Try matching by content url_slug first
    result =
      from(c in PublishingContent,
        join: v in assoc(c, :version),
        join: p in assoc(v, :post),
        join: g in assoc(p, :group),
        where: g.slug == ^group_slug and c.language == ^language and c.url_slug == ^url_slug,
        preload: [version: {v, post: {p, group: g}}]
      )
      |> repo().one()

    # Fallback: if no custom url_slug match, try matching by post.slug
    # (content rows with NULL/empty url_slug use the post slug as their public URL)
    result ||
      from(c in PublishingContent,
        join: v in assoc(c, :version),
        join: p in assoc(v, :post),
        join: g in assoc(p, :group),
        where:
          g.slug == ^group_slug and c.language == ^language and p.slug == ^url_slug and
            (is_nil(c.url_slug) or c.url_slug == ""),
        preload: [version: {v, post: {p, group: g}}]
      )
      |> repo().one()
  end

  @doc "Finds content by a previous URL slug (stored in data.previous_url_slugs JSONB array)."
  def find_by_previous_url_slug(group_slug, language, url_slug) do
    from(c in PublishingContent,
      join: v in assoc(c, :version),
      join: p in assoc(v, :post),
      join: g in assoc(p, :group),
      where:
        g.slug == ^group_slug and
          c.language == ^language and
          fragment("? @> ?", c.data, ^%{"previous_url_slugs" => [url_slug]}),
      preload: [version: {v, post: {p, group: g}}]
    )
    |> repo().one()
  end

  @doc "Clears a specific url_slug from all content rows of a post. Returns cleared language codes."
  def clear_url_slug_from_post(group_slug, post_slug, url_slug_to_clear) do
    case get_post(group_slug, post_slug) do
      nil ->
        []

      db_post ->
        # Find all content rows across all versions with this url_slug
        contents =
          from(c in PublishingContent,
            join: v in assoc(c, :version),
            where: v.post_uuid == ^db_post.uuid and c.url_slug == ^url_slug_to_clear,
            select: {c, c.language}
          )
          |> repo().all()

        Enum.each(contents, fn {content, _lang} ->
          update_content(content, %{url_slug: nil})
        end)

        Enum.map(contents, fn {_content, lang} -> lang end) |> Enum.uniq()
    end
  end

  @doc "Upserts content by version_id + language using ON CONFLICT."
  def upsert_content(attrs) do
    changeset = PublishingContent.changeset(%PublishingContent{}, attrs)

    repo().insert(changeset,
      on_conflict: {:replace, [:title, :content, :status, :url_slug, :data, :updated_at]},
      conflict_target: [:version_uuid, :language],
      returning: true
    )
  end

  # ===========================================================================
  # Compound Operations
  # ===========================================================================

  @doc """
  Reads a full post with its latest version and content for a specific language.

  Returns a post map or nil if not found.
  """
  def read_post(group_slug, post_slug, language \\ nil, version_number \\ nil) do
    with post when not is_nil(post) <- get_post(group_slug, post_slug),
         version when not is_nil(version) <- resolve_version(post, version_number),
         contents <- list_contents(version.uuid),
         content when not is_nil(content) <- resolve_content(contents, language, post) do
      all_versions = list_versions(post.uuid)

      {:ok, Mapper.to_post_map(post, version, content, contents, all_versions)}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Reads a timestamp-mode post by date and time instead of slug.
  """
  def read_post_by_datetime(group_slug, date, time, language \\ nil, version_number \\ nil) do
    with post when not is_nil(post) <- get_post_by_datetime(group_slug, date, time),
         version when not is_nil(version) <- resolve_version(post, version_number),
         contents <- list_contents(version.uuid),
         content when not is_nil(content) <- resolve_content(contents, language, post) do
      all_versions = list_versions(post.uuid)

      {:ok, Mapper.to_post_map(post, version, content, contents, all_versions)}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Lists all posts in a group with their latest version metadata.

  Returns a list of post maps suitable for listing pages.
  """
  def list_posts_with_metadata(group_slug) do
    posts = list_posts(group_slug)
    post_uuids = Enum.map(posts, & &1.uuid)

    # Batch-load ALL versions for all posts in one query
    all_versions_by_post = batch_load_versions(post_uuids)

    # Find latest version per post and collect all version UUIDs we need contents for
    latest_by_post =
      Map.new(all_versions_by_post, fn {post_uuid, versions} ->
        {post_uuid, List.last(versions)}
      end)

    # Also find published versions that differ from latest (for status overlay)
    published_by_post =
      Map.new(all_versions_by_post, fn {post_uuid, versions} ->
        {post_uuid, Enum.find(versions, fn v -> v.status == "published" end)}
      end)

    # Collect all version UUIDs we need contents for (latest + published if different)
    version_uuids_needed =
      Enum.flat_map(posts, fn post ->
        latest = latest_by_post[post.uuid]
        published = published_by_post[post.uuid]

        [latest, published]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.uuid)
        |> Enum.map(& &1.uuid)
      end)

    # Batch-load ALL contents for all needed versions in one query
    all_contents_by_version = batch_load_contents(version_uuids_needed)

    Enum.map(posts, fn post ->
      all_versions = Map.get(all_versions_by_post, post.uuid, [])
      version = latest_by_post[post.uuid]

      if version do
        contents = Map.get(all_contents_by_version, version.uuid, [])
        published_version = published_by_post[post.uuid]

        published_statuses =
          build_published_statuses(published_version, version, all_contents_by_version)

        primary_content = resolve_content(contents, nil, post)

        if primary_content do
          Mapper.to_post_map(post, version, primary_content, contents, all_versions,
            published_language_statuses: published_statuses
          )
        else
          Mapper.to_listing_map(post, version, contents, all_versions,
            published_language_statuses: published_statuses
          )
        end
      else
        Mapper.to_listing_map(post, nil, [], [])
      end
    end)
  end

  @doc """
  Lists all posts in a group in listing format (excerpt only, no full content).

  Always uses `Mapper.to_listing_map/4` which strips content bodies and includes
  only excerpts. Designed for caching in `:persistent_term` where data is copied
  to the reading process heap — keeping entries small matters.
  """
  def list_posts_for_listing(group_slug) do
    posts = list_posts(group_slug)
    post_uuids = Enum.map(posts, & &1.uuid)

    all_versions_by_post = batch_load_versions(post_uuids)

    latest_by_post =
      Map.new(all_versions_by_post, fn {post_uuid, versions} ->
        {post_uuid, List.last(versions)}
      end)

    published_by_post =
      Map.new(all_versions_by_post, fn {post_uuid, versions} ->
        {post_uuid, Enum.find(versions, fn v -> v.status == "published" end)}
      end)

    version_uuids_needed =
      Enum.flat_map(posts, fn post ->
        latest = latest_by_post[post.uuid]
        published = published_by_post[post.uuid]

        [latest, published]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq_by(& &1.uuid)
        |> Enum.map(& &1.uuid)
      end)

    all_contents_by_version = batch_load_contents(version_uuids_needed)

    Enum.map(posts, fn post ->
      all_versions = Map.get(all_versions_by_post, post.uuid, [])
      version = latest_by_post[post.uuid]

      if version do
        contents = Map.get(all_contents_by_version, version.uuid, [])
        published_version = published_by_post[post.uuid]

        published_statuses =
          build_published_statuses(published_version, version, all_contents_by_version)

        Mapper.to_listing_map(post, version, contents, all_versions,
          published_language_statuses: published_statuses
        )
      else
        Mapper.to_listing_map(post, nil, [], [])
      end
    end)
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp resolve_version(post, nil), do: get_latest_version(post.uuid)
  defp resolve_version(post, version_number), do: get_version(post.uuid, version_number)

  defp build_published_statuses(published_version, latest_version, all_contents_by_version) do
    if published_version && published_version.uuid != latest_version.uuid do
      Map.get(all_contents_by_version, published_version.uuid, [])
      |> Map.new(fn c -> {c.language, c.status} end)
    else
      %{}
    end
  end

  defp resolve_content(contents, nil, post) do
    # No language specified — use primary language, then any available
    Enum.find(contents, fn c -> c.language == post.primary_language end) ||
      List.first(contents)
  end

  defp resolve_content(contents, language, post) do
    # Try exact language match first, fall back to primary language, then any available.
    # This handles cases where the DB has partial content (e.g., only 3 of 39 languages
    # were imported) but the editor requests the primary language.
    Enum.find(contents, fn c -> c.language == language end) ||
      Enum.find(contents, fn c -> c.language == post.primary_language end) ||
      List.first(contents)
  end

  defp order_by_mode(query) do
    # Default ordering: published_at desc, then inserted_at desc
    order_by(query, [p], desc: p.published_at, desc: p.inserted_at)
  end

  # Batch-loads all versions for a list of post UUIDs in a single query.
  # Returns %{post_uuid => [versions sorted by version_number asc]}
  defp batch_load_versions([]), do: %{}

  defp batch_load_versions(post_uuids) do
    from(v in PublishingVersion,
      where: v.post_uuid in ^post_uuids,
      order_by: [asc: v.version_number]
    )
    |> repo().all()
    |> Enum.group_by(& &1.post_uuid)
  end

  # Batch-loads all contents for a list of version UUIDs in a single query.
  # Returns %{version_uuid => [contents sorted by language]}
  defp batch_load_contents([]), do: %{}

  defp batch_load_contents(version_uuids) do
    from(c in PublishingContent,
      where: c.version_uuid in ^version_uuids,
      order_by: [asc: c.language]
    )
    |> repo().all()
    |> Enum.group_by(& &1.version_uuid)
  end

  defp maybe_preload(nil, _preloads), do: nil
  defp maybe_preload(record, []), do: record
  defp maybe_preload(record, preloads), do: repo().preload(record, preloads)
end
