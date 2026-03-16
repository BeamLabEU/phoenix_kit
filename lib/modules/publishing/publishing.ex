defmodule PhoenixKit.Modules.Publishing do
  @moduledoc """
  Publishing module for managing content groups and their posts.

  Database-backed CMS for creating timestamped or slug-based posts
  with multi-language support and versioning.

  This module acts as a facade, delegating to focused submodules:

  - `Publishing.Groups` — Group CRUD
  - `Publishing.Posts` — Post CRUD, reading, and listing
  - `Publishing.Versions` — Version create, publish, delete
  - `Publishing.TranslationManager` — Language/translation management
  - `Publishing.StaleFixer` — Stale value detection and repair
  """

  use PhoenixKit.Module

  require Logger

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.LanguageHelpers
  alias PhoenixKit.Modules.Publishing.SlugHelpers
  # ============================================================================
  # Language Utility Delegates
  # ============================================================================

  defdelegate get_language_info(language_code), to: LanguageHelpers
  defdelegate enabled_language_codes(), to: LanguageHelpers
  defdelegate get_primary_language(), to: LanguageHelpers
  defdelegate language_enabled?(language_code, enabled_languages), to: LanguageHelpers
  defdelegate get_display_code(language_code, enabled_languages), to: LanguageHelpers

  defdelegate order_languages_for_display(available_languages, enabled_languages),
    to: LanguageHelpers

  defdelegate order_languages_for_display(available_languages, enabled_languages, primary),
    to: LanguageHelpers

  # ============================================================================
  # Slug Utility Delegates
  # ============================================================================

  defdelegate validate_slug(slug), to: SlugHelpers
  defdelegate slug_exists?(group_slug, post_slug), to: SlugHelpers
  defdelegate generate_unique_slug(group_slug, title), to: SlugHelpers
  defdelegate generate_unique_slug(group_slug, title, preferred_slug), to: SlugHelpers
  defdelegate generate_unique_slug(group_slug, title, preferred_slug, opts), to: SlugHelpers
  defdelegate validate_url_slug(group_slug, url_slug, language, exclude), to: SlugHelpers
  defdelegate clear_url_slug_from_post(group_slug, post_slug, url_slug), to: DBStorage

  # ============================================================================
  # Cache Delegates
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.ListingCache

  defdelegate regenerate_cache(group_slug), to: ListingCache, as: :regenerate
  defdelegate invalidate_cache(group_slug), to: ListingCache, as: :invalidate
  defdelegate cache_exists?(group_slug), to: ListingCache, as: :exists?
  defdelegate find_cached_post(group_slug, post_slug), to: ListingCache, as: :find_post

  defdelegate find_cached_post_by_path(group_slug, date, time),
    to: ListingCache,
    as: :find_post_by_path

  # ============================================================================
  # Group Delegates
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.Groups

  defdelegate list_groups(), to: Groups
  defdelegate get_group(slug), to: Groups
  defdelegate add_group(name, opts \\ []), to: Groups
  defdelegate remove_group(slug), to: Groups
  defdelegate remove_group(slug, opts), to: Groups
  defdelegate update_group(slug, params), to: Groups
  defdelegate trash_group(slug), to: Groups
  defdelegate group_name(slug), to: Groups
  defdelegate get_group_mode(group_slug), to: Groups
  defdelegate preset_types(), to: Groups
  defdelegate valid_types(), to: Groups
  defdelegate restore_group(slug), to: Groups
  defdelegate list_trashed_groups(), to: Groups

  # ============================================================================
  # Post Delegates
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.Posts

  defdelegate list_posts(group_slug, preferred_language \\ nil), to: Posts
  defdelegate create_post(group_slug, opts \\ %{}), to: Posts
  defdelegate read_post(group_slug, identifier, language \\ nil, version \\ nil), to: Posts
  defdelegate read_post_by_uuid(post_uuid, language \\ nil, version \\ nil), to: Posts
  defdelegate update_post(group_slug, post, params, opts \\ %{}), to: Posts
  defdelegate change_post_status(group_slug, post_uuid, new_status, opts \\ []), to: Posts
  defdelegate trash_post(group_slug, post_uuid), to: Posts
  defdelegate restore_post(group_slug, post_uuid), to: Posts
  defdelegate count_posts_on_date(group_slug, date), to: Posts
  defdelegate list_times_on_date(group_slug, date), to: Posts
  defdelegate find_by_url_slug(group_slug, language, url_slug), to: Posts
  defdelegate find_by_previous_url_slug(group_slug, language, url_slug), to: Posts
  defdelegate extract_slug_version_and_language(group_slug, identifier), to: Posts

  @doc "Always returns false — auto-versioning is disabled."
  def should_create_new_version?(_post, _params, _editing_language), do: false

  @doc "Returns true when the given post is a DB-backed post (has a UUID)."
  @spec db_post?(map()) :: boolean()
  defdelegate db_post?(post), to: Posts

  # ============================================================================
  # Version Delegates
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.Versions

  defdelegate list_versions(group_slug, post_slug), to: Versions
  defdelegate get_published_version(group_slug, post_slug), to: Versions
  defdelegate get_version_status(group_slug, post_slug, version_number, language), to: Versions
  defdelegate get_version_metadata(group_slug, post_slug, version_number, language), to: Versions

  defdelegate create_new_version(group_slug, source_post, params \\ %{}, opts \\ %{}),
    to: Versions

  defdelegate publish_version(group_slug, post_uuid, version, opts \\ []), to: Versions

  defdelegate create_version_from(
                group_slug,
                post_uuid,
                source_version,
                params \\ %{},
                opts \\ %{}
              ),
              to: Versions

  defdelegate delete_version(group_slug, post_uuid, version), to: Versions
  defdelegate broadcast_version_created(group_slug, broadcast_id, new_version), to: Versions

  # ============================================================================
  # Translation Delegates
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.TranslationManager

  defdelegate get_post_primary_language(group_slug, post_slug, version \\ nil),
    to: TranslationManager

  defdelegate check_primary_language_status(group_slug, post_slug), to: TranslationManager

  defdelegate update_post_primary_language(group_slug, post_uuid, new_primary_language),
    to: TranslationManager

  defdelegate update_posts_primary_language(group_slug), to: TranslationManager
  defdelegate count_posts_needing_language_update(group_slug), to: TranslationManager

  defdelegate add_language_to_post(group_slug, post_uuid, language_code, version \\ nil),
    to: TranslationManager

  defdelegate add_language_to_db(group_slug, post_uuid, language_code, version_number),
    to: TranslationManager

  defdelegate delete_language(group_slug, post_uuid, language_code, version \\ nil),
    to: TranslationManager

  defdelegate set_translation_status(group_slug, post_identifier, version, language, status),
    to: TranslationManager

  defdelegate translate_post_to_all_languages(group_slug, post_uuid, opts \\ []),
    to: TranslationManager

  # ============================================================================
  # Stale Value Correction Delegates
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.StaleFixer

  defdelegate fix_stale_group(group), to: StaleFixer
  defdelegate fix_stale_post(post), to: StaleFixer
  defdelegate fix_stale_version(version), to: StaleFixer
  defdelegate fix_stale_content(content), to: StaleFixer
  defdelegate fix_all_stale_values(), to: StaleFixer
  defdelegate reconcile_post_status(post), to: StaleFixer

  # ============================================================================
  # Module Behaviour Callbacks
  # ============================================================================

  @publishing_enabled_key "publishing_enabled"

  @impl PhoenixKit.Module
  @spec enabled?() :: boolean()
  def enabled? do
    settings_call(:get_boolean_setting, [@publishing_enabled_key, false])
  end

  @impl PhoenixKit.Module
  @spec enable_system() :: {:ok, any()} | {:error, any()}
  def enable_system do
    settings_call(:update_boolean_setting, [@publishing_enabled_key, true])
  end

  @impl PhoenixKit.Module
  @spec disable_system() :: {:ok, any()} | {:error, any()}
  def disable_system do
    settings_call(:update_boolean_setting, [@publishing_enabled_key, false])
  end

  @impl PhoenixKit.Module
  def module_key, do: "publishing"

  @impl PhoenixKit.Module
  def module_name, do: "Publishing"

  @impl PhoenixKit.Module
  def get_config do
    %{
      enabled: enabled?(),
      groups_count: length(list_groups())
    }
  end

  @impl PhoenixKit.Module
  def permission_metadata do
    %{
      key: "publishing",
      label: "Publishing",
      icon: "hero-document-duplicate",
      description: "Database-backed CMS pages and multi-language content"
    }
  end

  @impl PhoenixKit.Module
  def admin_tabs do
    [
      Tab.new!(
        id: :admin_publishing,
        label: "Publishing",
        icon: "hero-document-text",
        path: "publishing",
        priority: 600,
        level: :admin,
        permission: "publishing",
        match: :prefix,
        group: :admin_modules,
        subtab_display: :when_active,
        highlight_with_subtabs: false,
        dynamic_children: &__MODULE__.publishing_children/1
      )
    ]
  end

  @doc "Dynamic children function for Publishing sidebar tabs."
  def publishing_children(_scope) do
    groups = load_publishing_groups_for_tabs()

    groups
    |> Enum.with_index()
    |> Enum.map(fn {group, idx} ->
      slug = group["slug"] || ""
      name = group["name"] || slug
      hash = :erlang.phash2(slug) |> Integer.to_string(16) |> String.downcase()
      sanitized = slug |> String.replace(~r/[^a-zA-Z0-9_]/, "_") |> String.slice(0, 50)

      %Tab{
        id: :"admin_publishing_#{sanitized}_#{hash}",
        label: name,
        icon: "hero-document-text",
        path: "publishing/#{slug}",
        priority: 601 + idx,
        level: :admin,
        permission: "publishing",
        match: :prefix,
        parent: :admin_publishing
      }
    end)
  rescue
    e ->
      Logger.warning("[Publishing] dashboard_tabs failed: #{inspect(e)}")
      []
  end

  defp load_publishing_groups_for_tabs do
    alias PhoenixKit.Settings

    publishing_enabled = Settings.get_boolean_setting("publishing_enabled", false)

    if publishing_enabled do
      alias PhoenixKit.Modules.Publishing.DBStorage

      DBStorage.list_groups()
      |> Enum.map(fn g -> %{"name" => g.name, "slug" => g.slug} end)
    else
      []
    end
  rescue
    e ->
      Logger.warning("[Publishing] load_publishing_groups_for_tabs failed: #{inspect(e)}")
      []
  end

  @impl PhoenixKit.Module
  def settings_tabs do
    [
      Tab.new!(
        id: :admin_settings_publishing,
        label: "Publishing",
        icon: "hero-document-text",
        path: "publishing",
        priority: 921,
        level: :admin,
        parent: :admin_settings,
        permission: "publishing"
      )
    ]
  end

  @impl PhoenixKit.Module
  def children, do: [PhoenixKit.Modules.Publishing.Presence]

  @impl PhoenixKit.Module
  def route_module, do: PhoenixKitWeb.Routes.PublishingRoutes

  # ============================================================================
  # Shared Helpers (used across submodules)
  # ============================================================================

  alias PhoenixKit.Modules.Publishing.Shared

  @slug_regex ~r/^[a-z0-9]+(?:-[a-z0-9]+)*$/

  @doc false
  def slugify(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
  end

  @doc """
  Returns true when the slug matches the allowed lowercase letters, numbers, and hyphen pattern,
  and is not a reserved language code.

  Group slugs cannot be language codes (like 'en', 'es', 'fr') to prevent routing ambiguity.
  """
  @spec valid_slug?(String.t()) :: boolean()
  def valid_slug?(slug) when is_binary(slug) do
    slug != "" and Regex.match?(@slug_regex, slug) and not reserved_language_code?(slug)
  end

  def valid_slug?(_), do: false

  defp reserved_language_code?(slug) do
    language_codes =
      try do
        Languages.get_language_codes()
      rescue
        e ->
          Logger.debug(
            "[Publishing] reserved_language_code? check failed, assuming no reserved codes: #{inspect(e)}"
          )

          []
      end

    slug in language_codes
  end

  @doc false
  defdelegate fetch_option(opts, key), to: Shared

  @doc false
  defdelegate audit_metadata(scope, action), to: Shared

  # ============================================================================
  # Settings Helpers (private)
  # ============================================================================

  defp settings_module do
    case PhoenixKit.Config.get(:publishing_settings_module) do
      :not_found -> PhoenixKit.Settings
      {:ok, module} -> module
    end
  end

  defp settings_call(fun, args) do
    module = settings_module()

    case fun do
      :get_json_setting_cached ->
        if function_exported?(module, :get_json_setting_cached, length(args)) do
          apply(module, :get_json_setting_cached, args)
        else
          apply(module, :get_json_setting, args)
        end

      _ ->
        apply(module, fun, args)
    end
  end
end
