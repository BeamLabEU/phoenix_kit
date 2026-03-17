defmodule PhoenixKit.Modules.Publishing.Posts do
  @moduledoc """
  Post CRUD operations for the Publishing module.

  Handles creating, reading, updating, and trashing posts,
  as well as slug/version/language extraction and timestamp management.
  """

  require Logger

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants

  @timestamp_modes Constants.timestamp_modes()
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  alias PhoenixKit.Modules.Publishing.StaleFixer
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Suppress dialyzer false positives for pattern matches
  @dialyzer {:nowarn_function, create_post: 2}

  @max_timestamp_attempts 60

  @doc """
  Returns true when the given post is a DB-backed post (has a UUID).
  """
  @spec db_post?(map()) :: boolean()
  def db_post?(post), do: not is_nil(post[:uuid])

  @doc "Counts posts on a specific date for a group."
  def count_posts_on_date(group_slug, date) do
    group_slug
    |> list_times_on_date(date)
    |> length()
  end

  @doc "Lists time values for posts on a specific date."
  def list_times_on_date(group_slug, date) do
    date = if is_binary(date), do: Date.from_iso8601!(date), else: date

    group_slug
    |> DBStorage.list_posts_timestamp_mode("published", date: date)
    |> Enum.map(&(Time.to_string(&1.post_time) |> String.slice(0, 5)))
    |> Enum.uniq()
    |> Enum.sort()
  rescue
    e ->
      Logger.warning(
        "[Publishing] list_times_on_date failed for #{group_slug}/#{date}: #{inspect(e)}"
      )

      []
  end

  @doc """
  Finds a post by URL slug from the database.
  """
  @spec find_by_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_url_slug(group_slug, language, url_slug) do
    case DBStorage.find_by_url_slug(group_slug, language, url_slug) do
      nil -> {:error, :not_found}
      content -> {:ok, db_content_to_post_map(content)}
    end
  end

  @doc """
  Finds a post by a previous URL slug (for 301 redirects).
  """
  @spec find_by_previous_url_slug(String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, :not_found | :cache_miss}
  def find_by_previous_url_slug(group_slug, language, url_slug) do
    case DBStorage.find_by_previous_url_slug(group_slug, language, url_slug) do
      nil -> {:error, :not_found}
      content -> {:ok, db_content_to_post_map(content)}
    end
  end

  @doc """
  Lists posts for a given publishing group slug.

  Queries the database directly via DBStorage.
  The optional second argument is accepted for API compatibility but unused.
  """
  @spec list_posts(String.t(), String.t() | nil) :: [map()]
  def list_posts(group_slug, _preferred_language \\ nil) do
    DBStorage.list_posts_with_metadata(group_slug)
  end

  @doc "Lists posts filtered by status (e.g. 'trashed', 'published')."
  @spec list_posts_by_status(String.t(), String.t()) :: [map()]
  def list_posts_by_status(group_slug, status) do
    DBStorage.list_posts_with_metadata(group_slug, status)
  end

  @doc "Lists raw DB post records for a group, optionally filtered by status."
  @spec list_raw_posts(String.t(), String.t() | nil) :: [struct()]
  def list_raw_posts(group_slug, status \\ nil) do
    if status,
      do: DBStorage.list_posts(group_slug, status),
      else: DBStorage.list_posts(group_slug)
  end

  @doc "Counts primary language migration status from a list of posts."
  @spec count_primary_language_status(list(), String.t()) :: map() | nil
  def count_primary_language_status([], _primary), do: nil

  def count_primary_language_status(posts, primary_language) do
    DBStorage.count_primary_language_status_from_posts(posts, primary_language)
  end

  @doc """
  Creates a new post for the given publishing group using the current timestamp.
  """
  @spec create_post(String.t(), map() | keyword()) :: {:ok, map()} | {:error, any()}
  def create_post(group_slug, opts \\ %{}) do
    create_post_in_db(group_slug, opts)
  end

  @doc """
  Reads a post by its database UUID.

  Resolves the UUID to a group slug and post slug, then delegates to `read_post/4`.
  Invalid version/language params gracefully fall back to latest/primary.
  """
  def read_post_by_uuid(post_uuid, language \\ nil, version \\ nil) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        {:error, :not_found}

      db_post ->
        db_post = StaleFixer.fix_stale_post(db_post)
        group_slug = db_post.group.slug
        resolved_language = resolve_language_to_dialect(language)
        version_number = if version, do: normalize_version_number(version), else: nil

        if db_post.post_date && db_post.post_time do
          DBStorage.read_post_by_datetime(
            group_slug,
            db_post.post_date,
            db_post.post_time,
            resolved_language,
            version_number
          )
        else
          DBStorage.read_post(group_slug, db_post.slug, resolved_language, version_number)
        end
    end
  rescue
    e in [Ecto.QueryError, DBConnection.ConnectionError] ->
      Logger.warning("[Publishing] read_post_by_uuid failed for #{post_uuid}: #{inspect(e)}")
      {:error, :not_found}
  end

  @doc """
  Reads an existing post.

  For slug-mode groups, accepts an optional version parameter.
  If version is nil, reads the latest version.

  Reads from the database.
  """
  @spec read_post(String.t(), String.t(), String.t() | nil, integer() | nil) ::
          {:ok, map()} | {:error, any()}
  def read_post(group_slug, identifier, language \\ nil, version \\ nil) do
    read_post_from_db(group_slug, identifier, language, version)
  end

  @doc """
  Updates a post in the database.
  """
  @spec update_post(String.t(), map(), map(), map() | keyword()) ::
          {:ok, map()} | {:error, any()}
  def update_post(group_slug, post, params, opts \\ %{}) do
    # Normalize opts to map (callers may pass keyword list or map)
    opts_map = if Keyword.keyword?(opts), do: Map.new(opts), else: opts

    audit_meta =
      opts_map
      |> Shared.fetch_option(:scope)
      |> Shared.audit_metadata(:update)
      |> Map.put(:is_primary_language, Map.get(opts_map, :is_primary_language, true))

    result = update_post_in_db(group_slug, post, params, audit_meta)

    with {:ok, updated_post} <- result do
      ListingCache.regenerate(group_slug)

      unless Map.get(opts_map, :skip_broadcast, false) do
        PublishingPubSub.broadcast_post_updated(group_slug, updated_post)
      end
    end

    result
  end

  @doc """
  Changes a post's status by UUID.

  Reads the post, resolves primary language, updates status via `update_post`,
  invalidates render cache, and broadcasts the change.

  Returns `{:ok, updated_post}` or `{:error, reason}`.
  """
  @spec change_post_status(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def change_post_status(group_slug, post_uuid, new_status, opts \\ []) do
    case read_post_by_uuid(post_uuid) do
      {:ok, post} ->
        primary_language = post[:primary_language] || LanguageHelpers.get_primary_language()
        is_primary_language = post.language == primary_language

        case update_post(group_slug, post, %{"status" => new_status},
               scope: opts[:scope],
               is_primary_language: is_primary_language,
               skip_broadcast: true
             ) do
          {:ok, updated_post} ->
            identifier = updated_post[:uuid] || updated_post.slug
            Publishing.Renderer.invalidate_cache(group_slug, identifier, updated_post.language)
            PublishingPubSub.broadcast_post_status_changed(group_slug, updated_post)
            {:ok, updated_post}

          {:error, _} = err ->
            err
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Restores a trashed post by UUID, setting its status back to "draft".

  Reconciles version/content statuses and regenerates the group cache.
  Returns {:ok, post_uuid} on success or {:error, reason} on failure.
  """
  @spec restore_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def restore_post(group_slug, post_uuid) do
    case DBStorage.get_post_by_uuid(post_uuid) do
      nil ->
        {:error, :not_found}

      db_post ->
        case DBStorage.update_post(db_post, %{status: "draft"}) do
          {:ok, _} ->
            StaleFixer.reconcile_post_status(db_post)
            ListingCache.regenerate(group_slug)
            broadcast_id = db_post.slug || db_post.uuid
            PublishingPubSub.broadcast_post_updated(group_slug, %{slug: broadcast_id})
            {:ok, post_uuid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Soft-deletes a post by UUID.

  Returns {:ok, post_uuid} on success or {:error, reason} on failure.
  """
  @spec trash_post(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def trash_post(group_slug, post_uuid) do
    case DBStorage.get_post_by_uuid(post_uuid, [:group]) do
      nil ->
        {:error, :not_found}

      db_post ->
        case DBStorage.trash_post(db_post) do
          {:ok, _} ->
            broadcast_id = db_post.slug || db_post.uuid
            ListingCache.regenerate(group_slug)
            PublishingPubSub.broadcast_post_deleted(group_slug, broadcast_id)
            {:ok, post_uuid}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # Extract slug, version, and language from a path identifier
  # Handles paths like:
  #   - "post-slug" → {"post-slug", nil, nil}
  #   - "post-slug/en" → {"post-slug", nil, "en"}
  #   - "post-slug/v1/en" → {"post-slug", 1, "en"}
  #   - "group/post-slug/v2/am" → {"post-slug", 2, "am"}
  def extract_slug_version_and_language(_group_slug, nil), do: {"", nil, nil}

  def extract_slug_version_and_language(group_slug, identifier) do
    parts =
      identifier
      |> to_string()
      |> String.trim()
      |> String.trim_leading("/")
      |> String.split("/", trim: true)
      |> drop_group_prefix(group_slug)

    case parts do
      [] ->
        {"", nil, nil}

      [slug] ->
        {slug, nil, nil}

      [slug | rest] ->
        # Extract version if present (v1, v2, v3, etc.)
        {version, rest_after_version} = Shared.extract_version_from_parts(rest)

        # Extract language from remaining parts
        language =
          rest_after_version
          |> List.first()
          |> case do
            nil -> nil
            <<>> -> nil
            lang_code -> lang_code
          end

        {slug, version, language}
    end
  end

  @doc false
  def read_back_post(group_slug, identifier, db_post, language, version_number) do
    Shared.read_back_post(group_slug, identifier, db_post, language, version_number)
  end

  # ===========================================================================
  # Private helpers
  # ===========================================================================

  # Converts a DBStorage content record (with preloaded version/post/group) to a post map
  defp db_content_to_post_map(content) do
    version = content.version
    post = version.post

    %{
      slug: post.slug,
      url_slug: content.url_slug,
      language: content.language,
      metadata: %{
        title: content.title,
        status: content.status,
        description: (content.data || %{})["description"]
      }
    }
  end

  defp create_post_in_db(group_slug, opts) do
    case DBStorage.get_group_by_slug(group_slug) do
      nil ->
        {:error, :group_not_found}

      group ->
        do_create_post_in_db(group_slug, group, opts)
    end
  end

  defp do_create_post_in_db(group_slug, group, opts) do
    scope = Shared.fetch_option(opts, :scope)
    mode = Publishing.get_group_mode(group_slug)
    primary_language = LanguageHelpers.get_primary_language()
    now = UtilsDate.utc_now()

    # Resolve user UUID for audit
    created_by_uuid = Shared.resolve_scope_user_uuids(scope)

    # Generate slug for slug-mode groups
    slug_result =
      case mode do
        "slug" ->
          title = Shared.fetch_option(opts, :title)
          preferred_slug = Shared.fetch_option(opts, :slug)
          SlugHelpers.generate_unique_slug(group_slug, title || "", preferred_slug)

        _ ->
          {:ok, nil}
      end

    with {:ok, post_slug} <- slug_result do
      # Build post attributes
      post_attrs = %{
        group_uuid: group.uuid,
        slug: post_slug,
        status: "draft",
        mode: mode,
        primary_language: primary_language,
        published_at: nil,
        created_by_uuid: created_by_uuid,
        updated_by_uuid: created_by_uuid
      }

      # Add initial date/time for timestamp mode (truncate seconds since URLs use HH:MM only)
      # The actual available timestamp is resolved inside the transaction to avoid races.
      post_attrs =
        if mode == "timestamp" do
          date = DateTime.to_date(now)
          time = %Time{hour: now.hour, minute: now.minute, second: 0, microsecond: {0, 0}}

          Map.merge(post_attrs, %{
            post_date: date,
            post_time: time
          })
        else
          post_attrs
        end

      repo = PhoenixKit.RepoHelper.repo()

      tx_result =
        repo.transaction(fn ->
          # Find available timestamp INSIDE the transaction to prevent race conditions
          final_attrs =
            if mode == "timestamp" do
              {date, time} =
                find_available_timestamp(group_slug, post_attrs.post_date, post_attrs.post_time)

              %{post_attrs | post_date: date, post_time: time}
            else
              post_attrs
            end

          with {:ok, db_post} <- DBStorage.create_post(final_attrs),
               {:ok, db_version} <-
                 DBStorage.create_version(%{
                   post_uuid: db_post.uuid,
                   version_number: 1,
                   status: "draft",
                   created_by_uuid: created_by_uuid
                 }),
               {:ok, _content} <-
                 DBStorage.create_content(%{
                   version_uuid: db_version.uuid,
                   language: primary_language,
                   title: Shared.fetch_option(opts, :title) || "",
                   content: Shared.fetch_option(opts, :content) || "",
                   status: "draft",
                   url_slug: post_slug
                 }) do
            db_post
          else
            {:error, reason} -> repo.rollback(reason)
          end
        end)

      with {:ok, db_post} <- tx_result do
        # Read back via mapper to get a proper post map with UUID
        read_result =
          if mode == "timestamp" do
            DBStorage.read_post_by_datetime(
              group_slug,
              db_post.post_date,
              db_post.post_time,
              primary_language,
              1
            )
          else
            DBStorage.read_post(group_slug, db_post.slug, primary_language, 1)
          end

        case read_result do
          {:ok, post} ->
            ListingCache.regenerate(group_slug)
            PublishingPubSub.broadcast_post_created(group_slug, post)
            {:ok, post}

          {:error, _} = err ->
            err
        end
      end
    end
  end

  defp read_post_from_db(group_slug, identifier, language, version) do
    # If identifier is a UUID, resolve via UUID lookup (handles both modes)
    if Shared.uuid_format?(identifier) do
      read_post_by_uuid(identifier, language, version)
    else
      case Publishing.get_group_mode(group_slug) do
        "timestamp" ->
          read_post_from_db_timestamp(group_slug, identifier, language, version)

        _ ->
          read_post_from_db_slug(group_slug, identifier, language, version)
      end
    end
  end

  defp read_post_from_db_timestamp(group_slug, identifier, language, version) do
    case Shared.parse_timestamp_path(identifier) do
      {:ok, date, time, inferred_version, inferred_language} ->
        final_language = resolve_language_to_dialect(language || inferred_language)
        final_version = version || inferred_version
        version_number = normalize_version_number(final_version)

        DBStorage.read_post_by_datetime(
          group_slug,
          date,
          time,
          final_language,
          version_number
        )

      _ ->
        # Fallback: try as slug-based lookup
        read_post_from_db_slug(group_slug, identifier, language, version)
    end
  end

  defp read_post_from_db_slug(group_slug, identifier, language, version) do
    {post_slug, inferred_version, inferred_language} =
      extract_slug_version_and_language(group_slug, identifier)

    final_language = resolve_language_to_dialect(language || inferred_language)
    final_version = version || inferred_version
    version_number = normalize_version_number(final_version)

    DBStorage.read_post(group_slug, post_slug, final_language, version_number)
  end

  defp normalize_version_number(nil), do: nil

  defp normalize_version_number(v) when is_integer(v) and v > 0, do: v
  defp normalize_version_number(v) when is_integer(v), do: nil

  defp normalize_version_number(v) do
    case Integer.parse("#{v}") do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  # Resolves base language codes (de, en) to stored BCP-47 dialect codes (de-DE, en-US).
  # Content rows store full dialect codes, but URL paths use base codes.
  defp resolve_language_to_dialect(nil), do: nil

  defp resolve_language_to_dialect(language) do
    base = DialectMapper.extract_base(language)

    if base == language do
      DialectMapper.base_to_dialect(language)
    else
      language
    end
  end

  # Finds the next available minute for a timestamp-mode post.
  # If the given date/time is already taken, bumps forward by one minute at a time.
  # Limited to 60 attempts to prevent unbounded recursion.
  defp find_available_timestamp(group_slug, date, time, attempts \\ 0)

  defp find_available_timestamp(_group_slug, date, time, @max_timestamp_attempts) do
    {date, time}
  end

  defp find_available_timestamp(group_slug, date, time, attempts) do
    case DBStorage.get_post_by_datetime(group_slug, date, time) do
      nil ->
        {date, time}

      _existing ->
        # Bump by one minute
        total_seconds = time.hour * 3600 + time.minute * 60 + 60

        if total_seconds >= 86_400 do
          # Rolled past midnight — advance to next day at 00:00
          next_date = Date.add(date, 1)
          find_available_timestamp(group_slug, next_date, ~T[00:00:00], attempts + 1)
        else
          next_hour = div(total_seconds, 3600)
          next_minute = div(rem(total_seconds, 3600), 60)
          next_time = %Time{hour: next_hour, minute: next_minute, second: 0, microsecond: {0, 0}}
          find_available_timestamp(group_slug, date, next_time, attempts + 1)
        end
    end
  end

  # Updates a post in the database.
  # Writes directly to the database and returns the updated post map.
  defp update_post_in_db(group_slug, post, params, audit_meta) do
    db_post = find_db_post_for_update(group_slug, post)

    if db_post do
      if post[:mode] in @timestamp_modes || db_post.mode == "timestamp" do
        # Timestamp-mode posts don't have slugs — skip slug validation
        do_update_post_in_db(db_post, post, params, group_slug, nil, audit_meta)
      else
        # Handle slug changes
        desired_slug = Map.get(params, "slug", post.slug)

        case maybe_update_db_slug(db_post, desired_slug, group_slug) do
          {:ok, final_slug} ->
            do_update_post_in_db(db_post, post, params, group_slug, final_slug, audit_meta)

          {:error, _reason} = error ->
            error
        end
      end
    else
      {:error, :not_found}
    end
  rescue
    e ->
      Logger.warning("[Publishing] update_post_in_db failed: #{inspect(e)}")
      {:error, :db_update_failed}
  end

  # Find the DB post record for update, using UUID, date/time, or slug as available
  defp find_db_post_for_update(group_slug, post) do
    cond do
      # If we have a UUID, use it directly (most reliable)
      post[:uuid] ->
        DBStorage.get_post_by_uuid(post[:uuid], [:group])

      # Timestamp-mode: use date/time
      post[:mode] in @timestamp_modes && post[:date] && post[:time] ->
        DBStorage.get_post_by_datetime(group_slug, post[:date], post[:time])

      # Slug-mode: use slug
      post[:slug] ->
        DBStorage.get_post(group_slug, post[:slug])

      true ->
        nil
    end
  end

  defp maybe_update_db_slug(db_post, desired_slug, _group_slug)
       when desired_slug == db_post.slug do
    {:ok, db_post.slug}
  end

  defp maybe_update_db_slug(db_post, desired_slug, group_slug) do
    with {:ok, valid_slug} <- SlugHelpers.validate_slug(desired_slug),
         false <- SlugHelpers.slug_exists?(group_slug, valid_slug),
         {:ok, _} <- DBStorage.update_post(db_post, %{slug: valid_slug}) do
      {:ok, valid_slug}
    else
      true ->
        {:error, :slug_already_exists}

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.warning("[Publishing] slug update changeset error: #{inspect(changeset.errors)}")

        if Keyword.has_key?(changeset.errors, :slug),
          do: {:error, :slug_already_exists},
          else: {:error, :db_update_failed}

      {:error, reason} ->
        Logger.warning("[Publishing] slug update failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp do_update_post_in_db(db_post, post, params, group_slug, final_slug, audit_meta) do
    version_number = post[:version] || 1
    version = DBStorage.get_version(db_post.uuid, version_number)

    if version do
      language = post[:language] || db_post.primary_language
      post_metadata = post[:metadata] || %{}
      new_status = Map.get(params, "status", post_metadata[:status] || "draft")
      content = Map.get(params, "content", post[:content] || "")
      new_title = resolve_post_title(params, post, content)

      with :ok <- validate_title_for_publish(db_post, language, new_status, new_title),
           old_db_status = db_post.status,
           :ok <- update_post_level_fields(db_post, new_status, params, audit_meta),
           :ok <-
             upsert_post_content(version, language, new_title, content, new_status, params, post) do
        maybe_propagate_status(version, language, db_post, new_status, old_db_status)
        read_updated_post(db_post, group_slug, final_slug, language, version_number)
      end
    else
      {:error, :not_found}
    end
  end

  @default_title Constants.default_title()

  defp validate_title_for_publish(db_post, language, "published", title)
       when title in ["", @default_title] do
    if language == db_post.primary_language,
      do: {:error, :title_required},
      else: :ok
  end

  defp validate_title_for_publish(_db_post, _language, _status, _title), do: :ok

  defp read_updated_post(db_post, group_slug, final_slug, language, version_number) do
    if db_post.mode == "timestamp" do
      DBStorage.read_post_by_datetime(
        group_slug,
        db_post.post_date,
        db_post.post_time,
        language,
        version_number
      )
    else
      DBStorage.read_post(group_slug, final_slug, language, version_number)
    end
  end

  defp resolve_post_title(params, post, _content) do
    post_metadata = post[:metadata] || %{}

    Map.get(params, "title") ||
      post_metadata[:title] ||
      Constants.default_title()
  end

  defp update_post_level_fields(db_post, new_status, params, audit_meta) do
    update_attrs =
      %{
        status: new_status,
        published_at: parse_published_at(params, db_post)
      }
      |> maybe_put(:updated_by_uuid, audit_meta[:updated_by_uuid])
      |> maybe_put(:updated_by_email, audit_meta[:updated_by_email])

    case DBStorage.update_post(db_post, update_attrs) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp upsert_post_content(version, language, new_title, content, new_status, params, post) do
    existing_content = DBStorage.get_content(version.uuid, language)
    existing_url_slug = if existing_content, do: existing_content.url_slug
    existing_data = if existing_content, do: existing_content.data || %{}, else: %{}

    resolved_url_slug =
      case Map.fetch(params, "url_slug") do
        {:ok, val} -> val
        :error -> existing_url_slug
      end

    case DBStorage.upsert_content(%{
           version_uuid: version.uuid,
           language: language,
           title: new_title,
           content: content,
           status: new_status,
           url_slug: resolved_url_slug,
           data: build_content_data(params, post, existing_data)
         }) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_propagate_status(version, language, db_post, new_status, old_db_status) do
    is_primary = language == db_post.primary_language

    if is_primary and new_status != old_db_status do
      propagate_db_status_to_translations(version.uuid, language, new_status)
    end
  end

  defp propagate_db_status_to_translations(version_uuid, primary_language, new_status) do
    DBStorage.update_content_status_except(version_uuid, primary_language, new_status)
  end

  defp parse_published_at(params, db_post) do
    case Map.get(params, "published_at") do
      nil ->
        db_post.published_at

      "" ->
        db_post.published_at

      dt_string when is_binary(dt_string) ->
        case DateTime.from_iso8601(dt_string) do
          {:ok, dt, _} -> dt
          _ -> db_post.published_at
        end

      dt ->
        dt
    end
  end

  defp build_content_data(params, post, existing_data) do
    # Start from existing data to preserve previous_url_slugs, excerpt, seo_title, etc.
    data = existing_data

    data =
      case Map.get(params, "featured_image_uuid") do
        nil -> data
        id -> Map.put(data, "featured_image_uuid", id)
      end

    post_metadata = post[:metadata] || %{}

    case Map.get(params, "description", post_metadata[:description]) do
      nil -> data
      desc -> Map.put(data, "description", desc)
    end
  end

  # Only drop group prefix if there are more elements after it
  # This prevents dropping the post slug when it matches the group slug
  defp drop_group_prefix([group_slug | rest], group_slug) when rest != [], do: rest
  defp drop_group_prefix(list, _), do: list
end
