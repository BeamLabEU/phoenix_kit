defmodule PhoenixKit.Modules.Publishing.DBStorage do
  @moduledoc """
  Database storage adapter for the Publishing module.

  Provides CRUD operations for publishing groups, posts, versions, and contents.
  Works alongside the existing filesystem `Storage` module during the transition.

  ## Usage

  This module is used by the dual-write layer (Phase 3) and becomes the primary
  storage when `publishing_storage` is set to `:db`.
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

  @doc "Gets a timestamp-mode post by date and time."
  def get_post_by_datetime(group_slug, %Date{} = date, %Time{} = time) do
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug and p.post_date == ^date and p.post_time == ^time,
      preload: [group: g]
    )
    |> repo().one()
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

  @doc "Finds a post by date and time (timestamp mode)."
  def find_post_by_date_time(group_slug, date, time) do
    from(p in PublishingPost,
      join: g in assoc(p, :group),
      where: g.slug == ^group_slug and p.post_date == ^date and p.post_time == ^time,
      preload: [group: g]
    )
    |> repo().one()
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

    Enum.reduce(posts, %{current: 0, needs_migration: 0, needs_backfill: 0}, fn post, acc ->
      cond do
        is_nil(post.primary_language) ->
          %{acc | needs_backfill: acc.needs_backfill + 1}

        post.primary_language == global_primary ->
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
  def migrate_primary_language(group_slug, primary_language) do
    posts =
      from(p in PublishingPost,
        join: g in assoc(p, :group),
        where:
          g.slug == ^group_slug and
            (is_nil(p.primary_language) or p.primary_language != ^primary_language)
      )
      |> repo().all()

    count =
      Enum.count(posts, fn post ->
        case update_post(post, %{primary_language: primary_language}) do
          {:ok, _} -> true
          {:error, _} -> false
        end
      end)

    {:ok, count}
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

  @doc "Gets the next version number for a post."
  def next_version_number(post_uuid) do
    result =
      from(v in PublishingVersion,
        where: v.post_uuid == ^post_uuid,
        select: max(v.version_number)
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

  @doc "Upserts content by version_id + language."
  def upsert_content(attrs) do
    version_uuid = Map.get(attrs, :version_uuid) || Map.get(attrs, "version_uuid")
    language = Map.get(attrs, :language) || Map.get(attrs, "language")

    case get_content(version_uuid, language) do
      nil -> create_content(attrs)
      content -> update_content(content, attrs)
    end
  end

  # ===========================================================================
  # Compound Operations
  # ===========================================================================

  @doc """
  Reads a full post with its latest version and content for a specific language.

  Returns a map suitable for the legacy mapper or nil if not found.
  """
  def read_post(group_slug, post_slug, language \\ nil, version_number \\ nil) do
    with post when not is_nil(post) <- get_post(group_slug, post_slug),
         version when not is_nil(version) <- resolve_version(post, version_number),
         contents <- list_contents(version.uuid),
         content when not is_nil(content) <- resolve_content(contents, language, post) do
      all_versions = list_versions(post.uuid)

      {:ok, Mapper.to_legacy_map(post, version, content, contents, all_versions)}
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

      {:ok, Mapper.to_legacy_map(post, version, content, contents, all_versions)}
    else
      nil -> {:error, :not_found}
    end
  end

  @doc """
  Lists all posts in a group with their latest version metadata.

  Returns a list of legacy-format maps suitable for listing pages.
  """
  def list_posts_with_metadata(group_slug) do
    posts = list_posts(group_slug)

    Enum.map(posts, fn post ->
      version = get_latest_version(post.uuid)

      if version do
        contents = list_contents(version.uuid)
        all_versions = list_versions(post.uuid)
        primary_content = resolve_content(contents, nil, post)

        if primary_content do
          Mapper.to_legacy_map(post, version, primary_content, contents, all_versions)
        else
          Mapper.to_listing_map(post, version, contents, all_versions)
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

    Enum.map(posts, fn post ->
      version = get_latest_version(post.uuid)

      if version do
        contents = list_contents(version.uuid)
        all_versions = list_versions(post.uuid)
        Mapper.to_listing_map(post, version, contents, all_versions)
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

  defp maybe_preload(nil, _preloads), do: nil
  defp maybe_preload(record, []), do: record
  defp maybe_preload(record, preloads), do: repo().preload(record, preloads)
end
