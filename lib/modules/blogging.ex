defmodule PhoenixKit.Modules.Blogging do
  @moduledoc """
  DEPRECATED: This module has been renamed to `PhoenixKit.Modules.Publishing`.

  All functions in this module delegate to `PhoenixKit.Modules.Publishing`.
  Please update your code to use the new module name directly.

  This module will be removed in a future major version.
  """

  @deprecated "Use PhoenixKit.Modules.Publishing instead"

  # Core functions - delegate to new names
  defdelegate enabled?(), to: PhoenixKit.Modules.Publishing
  defdelegate enable_system(), to: PhoenixKit.Modules.Publishing
  defdelegate disable_system(), to: PhoenixKit.Modules.Publishing
  defdelegate list_blogs(), to: PhoenixKit.Modules.Publishing, as: :list_groups
  defdelegate blog_name(slug), to: PhoenixKit.Modules.Publishing, as: :group_name
  defdelegate get_blog_mode(slug), to: PhoenixKit.Modules.Publishing, as: :get_group_mode
  defdelegate add_blog(name, opts \\ []), to: PhoenixKit.Modules.Publishing, as: :add_group
  defdelegate remove_blog(slug), to: PhoenixKit.Modules.Publishing, as: :remove_group
  defdelegate update_blog(slug, params), to: PhoenixKit.Modules.Publishing, as: :update_group
  defdelegate trash_blog(slug), to: PhoenixKit.Modules.Publishing, as: :trash_group
  defdelegate slugify(text), to: PhoenixKit.Modules.Publishing
  defdelegate valid_slug?(slug), to: PhoenixKit.Modules.Publishing
  defdelegate preset_types(), to: PhoenixKit.Modules.Publishing

  # Post functions
  defdelegate list_posts(blog_slug, locale), to: PhoenixKit.Modules.Publishing
  defdelegate read_post(blog_slug, path), to: PhoenixKit.Modules.Publishing
  defdelegate read_post(blog_slug, slug, language), to: PhoenixKit.Modules.Publishing
  defdelegate read_post(blog_slug, slug, language, version), to: PhoenixKit.Modules.Publishing
  defdelegate create_post(blog_slug, params), to: PhoenixKit.Modules.Publishing
  defdelegate update_post(blog_slug, post, params), to: PhoenixKit.Modules.Publishing
  defdelegate update_post(blog_slug, post, params, opts), to: PhoenixKit.Modules.Publishing

  defdelegate add_language_to_post(blog_slug, path, new_language),
    to: PhoenixKit.Modules.Publishing

  defdelegate add_language_to_post(blog_slug, path, new_language, opts),
    to: PhoenixKit.Modules.Publishing

  # Version functions (delegated from Storage)
  defdelegate list_versions(blog_slug, post_slug), to: PhoenixKit.Modules.Publishing
  defdelegate get_latest_version(blog_slug, post_slug), to: PhoenixKit.Modules.Publishing

  defdelegate get_latest_published_version(blog_slug, post_slug),
    to: PhoenixKit.Modules.Publishing

  defdelegate get_live_version(blog_slug, post_slug),
    to: PhoenixKit.Modules.Publishing,
    as: :get_published_version

  defdelegate get_version_status(blog_slug, post_slug, version, language),
    to: PhoenixKit.Modules.Publishing

  defdelegate detect_post_structure(post_path), to: PhoenixKit.Modules.Publishing
  defdelegate content_changed?(post, params), to: PhoenixKit.Modules.Publishing
  defdelegate status_change_only?(post, params), to: PhoenixKit.Modules.Publishing

  defdelegate should_create_new_version?(post, params, editing_language),
    to: PhoenixKit.Modules.Publishing

  # Slug utilities (delegated from Storage)
  defdelegate validate_slug(slug), to: PhoenixKit.Modules.Publishing
  defdelegate slug_exists?(blog_slug, post_slug), to: PhoenixKit.Modules.Publishing
  defdelegate generate_unique_slug(blog_slug, title), to: PhoenixKit.Modules.Publishing

  defdelegate generate_unique_slug(blog_slug, title, preferred_slug),
    to: PhoenixKit.Modules.Publishing

  defdelegate generate_unique_slug(blog_slug, title, preferred_slug, opts),
    to: PhoenixKit.Modules.Publishing

  # Language utilities (delegated from Storage)
  defdelegate enabled_language_codes(), to: PhoenixKit.Modules.Publishing
  defdelegate get_primary_language(), to: PhoenixKit.Modules.Publishing

  @doc false
  @deprecated "Use get_primary_language/0 instead"
  def get_master_language, do: get_primary_language()

  defdelegate get_language_info(language_code), to: PhoenixKit.Modules.Publishing

  defdelegate language_enabled?(language_code, enabled_languages),
    to: PhoenixKit.Modules.Publishing

  defdelegate get_display_code(language_code, enabled_languages),
    to: PhoenixKit.Modules.Publishing

  defdelegate order_languages_for_display(available_languages, enabled_languages),
    to: PhoenixKit.Modules.Publishing

  # Version metadata (delegated from Storage)
  defdelegate get_version_metadata(blog_slug, post_slug, version, language),
    to: PhoenixKit.Modules.Publishing

  # Storage migration functions - delegate to new names
  defdelegate legacy_blog?(blog_slug), to: PhoenixKit.Modules.Publishing, as: :legacy_group?
  defdelegate has_legacy_blogs?(), to: PhoenixKit.Modules.Publishing, as: :has_legacy_groups?
end
