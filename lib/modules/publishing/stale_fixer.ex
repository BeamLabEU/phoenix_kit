defmodule PhoenixKit.Modules.Publishing.StaleFixer do
  @moduledoc """
  Fixes stale or invalid values on publishing records.

  Validates and corrects fields like mode, type, status, language, and
  timestamps across groups, posts, versions, and content. Also reconciles
  status consistency between posts, versions, and content rows.
  """

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.PublishingGroup
  alias PhoenixKit.Modules.Publishing.PublishingPost

  @valid_types ["blog", "faq", "legal", "custom"]
  @valid_group_modes ["timestamp", "slug"]
  @valid_post_statuses ["draft", "published", "archived", "scheduled"]
  @valid_version_statuses ["draft", "published", "archived"]
  @default_group_mode "timestamp"
  @default_group_type "blog"

  @type_item_names %{
    "blog" => {"post", "posts"},
    "faq" => {"question", "questions"},
    "legal" => {"document", "documents"}
  }
  @default_item_singular "item"
  @default_item_plural "items"

  @doc """
  Fixes stale or invalid values on a publishing group record.

  Checks and corrects:
  - `mode` — must be "timestamp" or "slug" (defaults to "timestamp")
  - `data.type` — must be in valid_types (defaults to "custom")
  - `data.item_singular` — must be a non-empty string (defaults based on type)
  - `data.item_plural` — must be a non-empty string (defaults based on type)

  Can be called explicitly or runs lazily when groups are loaded in the admin.
  Returns the group unchanged if no fixes are needed.
  """
  @spec fix_stale_group(PublishingGroup.t()) :: PublishingGroup.t()
  def fix_stale_group(%PublishingGroup{} = group) do
    attrs = build_group_fixes(group)
    apply_stale_fix(group, attrs, &DBStorage.update_group/2)
  end

  defp build_group_fixes(group) do
    data = group.data || %{}
    type = Map.get(data, "type", @default_group_type)
    fixed_type = if type in @valid_types, do: type, else: "custom"
    fixed_mode = if group.mode in @valid_group_modes, do: group.mode, else: @default_group_mode

    {default_singular, default_plural} = default_item_names(fixed_type)
    item_singular = Map.get(data, "item_singular")
    item_plural = Map.get(data, "item_plural")

    fixed_singular = valid_string_or_default(item_singular, default_singular)
    fixed_plural = valid_string_or_default(item_plural, default_plural)

    data_changes =
      data
      |> maybe_update("type", type, fixed_type)
      |> maybe_update("item_singular", item_singular, fixed_singular)
      |> maybe_update("item_plural", item_plural, fixed_plural)

    attrs = if data_changes != data, do: %{data: data_changes}, else: %{}
    if fixed_mode != group.mode, do: Map.put(attrs, :mode, fixed_mode), else: attrs
  end

  defp valid_string_or_default(val, default) do
    if is_binary(val) and val != "", do: val, else: default
  end

  @doc """
  Fixes stale or invalid values on a publishing post record.

  Checks and corrects:
  - `primary_language` — must be a recognized language code. Resolution order:
    1. Tries to resolve a dialect (e.g., "en" → "en-US")
    2. Falls back to the first available language on the post
    3. Falls back to the system primary language
  - `status` — must be a valid post status (defaults to "draft")
  - `mode` — must be "timestamp" or "slug" (defaults to "timestamp")
  - `post_date`/`post_time` — must be present for timestamp mode posts

  Only fixes languages not in the master predefined list — languages that were
  added, used, then removed from enabled are left untouched.
  """
  @spec fix_stale_post(PublishingPost.t()) :: PublishingPost.t()
  def fix_stale_post(%PublishingPost{} = post) do
    attrs = build_post_fixes(post)
    apply_stale_fix(post, attrs, &DBStorage.update_post/2)
  end

  defp build_post_fixes(post) do
    %{}
    |> maybe_fix_post_language(post)
    |> maybe_fix_post_status(post)
    |> maybe_fix_post_mode(post)
    |> maybe_fix_post_timestamp(post)
  end

  defp maybe_fix_post_language(attrs, post) do
    case fix_stale_language(post) do
      nil -> attrs
      fixed_lang -> Map.put(attrs, :primary_language, fixed_lang)
    end
  end

  defp maybe_fix_post_status(attrs, post) do
    if post.status in @valid_post_statuses, do: attrs, else: Map.put(attrs, :status, "draft")
  end

  defp maybe_fix_post_mode(attrs, post) do
    fixed_mode = if post.mode in @valid_group_modes, do: post.mode, else: @default_group_mode
    if fixed_mode != post.mode, do: Map.put(attrs, :mode, fixed_mode), else: attrs
  end

  defp maybe_fix_post_timestamp(attrs, post) do
    if (attrs[:mode] || post.mode) == "timestamp" do
      now = DateTime.utc_now()

      attrs
      |> then(fn a ->
        if is_nil(post.post_date), do: Map.put(a, :post_date, DateTime.to_date(now)), else: a
      end)
      |> then(fn a ->
        if is_nil(post.post_time),
          do: Map.put(a, :post_time, Time.new!(now.hour, now.minute, 0)),
          else: a
      end)
    else
      attrs
    end
  end

  # Returns the fixed language or nil if no fix needed.
  defp fix_stale_language(post) do
    lang = post.primary_language

    if lang && Languages.get_predefined_language(lang) do
      nil
    else
      fixed = resolve_stale_language(lang, post)
      if fixed != lang, do: fixed, else: nil
    end
  end

  defp resolve_stale_language(lang, post) do
    dialect = if lang, do: Languages.DialectMapper.base_to_dialect(lang), else: nil

    if dialect && Languages.get_predefined_language(dialect) do
      dialect
    else
      available = post_available_languages(post)

      if available != [] do
        Enum.find(available, hd(available), fn code ->
          Languages.get_predefined_language(code) != nil
        end)
      else
        LanguageHelpers.get_primary_language()
      end
    end
  end

  defp post_available_languages(post) do
    case DBStorage.list_versions(post.uuid) do
      [] -> []
      versions -> DBStorage.list_languages(hd(versions).uuid)
    end
  end

  defp apply_stale_fix(record, attrs, _update_fn) when attrs == %{}, do: record

  defp apply_stale_fix(record, attrs, update_fn) do
    identifier = Map.get(record, :uuid) || Map.get(record, :slug) || "unknown"

    Logger.info(
      "[Publishing] Fixing stale values for #{record.__struct__} #{identifier}: #{inspect(attrs)}"
    )

    case update_fn.(record, attrs) do
      {:ok, updated} ->
        updated

      {:error, reason} ->
        Logger.warning(
          "[Publishing] Failed to fix stale values for #{identifier}: #{inspect(reason)}"
        )

        record
    end
  end

  defp maybe_update(data, key, old_val, new_val) do
    if old_val != new_val, do: Map.put(data, key, new_val), else: data
  end

  @doc """
  Fixes stale values across all groups, posts, versions, and content.
  Also reconciles status consistency between posts, versions, and content.
  Callable via internal API or IEx.
  """
  @spec fix_all_stale_values() :: :ok
  def fix_all_stale_values do
    groups = DBStorage.list_groups()
    Enum.each(groups, &fix_stale_group/1)

    for group <- groups do
      posts = DBStorage.list_posts(group.slug)
      Enum.each(posts, &fix_stale_post/1)

      # Fix versions, content, and status consistency for each post
      for post <- posts do
        versions = DBStorage.list_versions(post.uuid)

        for version <- versions do
          fix_stale_version(version)

          contents = DBStorage.list_contents(version.uuid)
          Enum.each(contents, &fix_stale_content/1)
        end

        # Reconcile status consistency after individual fixes
        reconcile_post_status(post)
      end
    end

    :ok
  end

  @doc false
  def fix_stale_version(version) do
    if version.status not in @valid_version_statuses do
      Logger.info(
        "[Publishing] Fixing stale version #{version.uuid}: status #{inspect(version.status)} → \"draft\""
      )

      DBStorage.update_version(version, %{status: "draft"})
    end
  end

  @doc false
  def fix_stale_content(content) do
    attrs =
      %{}
      |> maybe_fix_content_status(content)
      |> maybe_fix_content_language(content)

    if attrs != %{} do
      Logger.info(
        "[Publishing] Fixing stale content #{content.uuid} (#{content.language}): #{inspect(attrs)}"
      )

      DBStorage.update_content(content, attrs)
    end
  end

  defp maybe_fix_content_status(attrs, content) do
    if content.status in @valid_version_statuses,
      do: attrs,
      else: Map.put(attrs, :status, "draft")
  end

  defp maybe_fix_content_language(attrs, content) do
    if is_binary(content.language) and content.language != "" do
      attrs
    else
      Map.put(attrs, :language, LanguageHelpers.get_primary_language())
    end
  end

  # Reconciles status consistency between a post, its versions, and content.
  #
  # Rules enforced:
  # 1. Post "published" requires at least one "published" version → else demote to "draft"
  # 2. Version "published" requires its post to be "published" → else archive the version
  # 3. Content "published" requires its version to be "published" → else demote to "draft"
  # 4. Non-published versions cannot have "published" content → demote content to "draft"
  #
  # Note: individual translations CAN be "draft" while the version is "published" —
  # this is the normal state for untranslated languages. We only fix content that
  # claims to be "published" when it shouldn't be.
  @doc false
  def reconcile_post_status(%PublishingPost{} = post) do
    # Re-read to get current state after individual fixes
    post = DBStorage.get_post_by_uuid(post.uuid) || post
    versions = DBStorage.list_versions(post.uuid)

    published_versions = Enum.filter(versions, &(&1.status == "published"))

    cond do
      # Post says published but no version backs it up
      post.status == "published" and published_versions == [] ->
        Logger.info(
          "[Publishing] Reconcile: post #{post.uuid} is published but has no published versions, demoting to draft"
        )

        DBStorage.update_post(post, %{status: "draft"})

      # Post is not published but a version claims to be — archive the version
      post.status in ["draft", "archived"] and published_versions != [] ->
        Logger.info(
          "[Publishing] Reconcile: post #{post.uuid} is #{inspect(post.status)} but has #{length(published_versions)} published versions, archiving"
        )

        for v <- published_versions do
          DBStorage.update_version(v, %{status: "archived"})
          demote_published_content(v.uuid)
        end

      true ->
        :ok
    end

    # For ALL non-published versions, no content should be "published"
    non_published_versions = Enum.reject(versions, &(&1.status == "published"))

    for v <- non_published_versions do
      demote_published_content(v.uuid)
    end
  end

  # Demotes any "published" content rows to "draft" within a version.
  # Leaves "draft" and "archived" content untouched.
  defp demote_published_content(version_uuid) do
    contents = DBStorage.list_contents(version_uuid)
    published = Enum.filter(contents, &(&1.status == "published"))

    if published != [] do
      Logger.info(
        "[Publishing] Demoting #{length(published)} published content row(s) to \"draft\" in version #{version_uuid}"
      )

      for content <- published do
        DBStorage.update_content(content, %{status: "draft"})
      end
    end
  end

  # Returns the default item names for a given type.
  defp default_item_names(type) do
    Map.get(@type_item_names, type, {@default_item_singular, @default_item_plural})
  end
end
