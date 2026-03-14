defmodule PhoenixKit.Modules.Publishing.FacadeTest do
  @moduledoc """
  Tests that all public functions are properly delegated through the facade.
  Verifies every function in Publishing.* submodules is accessible via Publishing.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing

  # ============================================================================
  # Group Delegations
  # ============================================================================

  describe "group delegations" do
    test "all group functions are exported from facade" do
      assert function_exported?(Publishing, :list_groups, 0)
      assert function_exported?(Publishing, :get_group, 1)
      assert function_exported?(Publishing, :add_group, 1)
      assert function_exported?(Publishing, :add_group, 2)
      assert function_exported?(Publishing, :remove_group, 1)
      assert function_exported?(Publishing, :remove_group, 2)
      assert function_exported?(Publishing, :update_group, 2)
      assert function_exported?(Publishing, :trash_group, 1)
      assert function_exported?(Publishing, :group_name, 1)
      assert function_exported?(Publishing, :get_group_mode, 1)
      assert function_exported?(Publishing, :preset_types, 0)
      assert function_exported?(Publishing, :valid_types, 0)
    end
  end

  # ============================================================================
  # Version Delegations
  # ============================================================================

  describe "version delegations" do
    test "all version functions are exported from facade" do
      assert function_exported?(Publishing, :list_versions, 2)
      assert function_exported?(Publishing, :get_published_version, 2)
      assert function_exported?(Publishing, :get_version_status, 4)
      assert function_exported?(Publishing, :get_version_metadata, 4)
      assert function_exported?(Publishing, :create_new_version, 2)
      assert function_exported?(Publishing, :create_new_version, 3)
      assert function_exported?(Publishing, :create_new_version, 4)
      assert function_exported?(Publishing, :publish_version, 3)
      assert function_exported?(Publishing, :publish_version, 4)
      assert function_exported?(Publishing, :create_version_from, 3)
      assert function_exported?(Publishing, :create_version_from, 4)
      assert function_exported?(Publishing, :create_version_from, 5)
      assert function_exported?(Publishing, :delete_version, 3)
      assert function_exported?(Publishing, :broadcast_version_created, 3)
    end
  end

  # ============================================================================
  # Translation Delegations
  # ============================================================================

  describe "translation delegations" do
    test "all translation functions are exported from facade" do
      assert function_exported?(Publishing, :get_post_primary_language, 2)
      assert function_exported?(Publishing, :get_post_primary_language, 3)
      assert function_exported?(Publishing, :check_primary_language_status, 2)
      assert function_exported?(Publishing, :update_post_primary_language, 3)
      assert function_exported?(Publishing, :posts_need_primary_language_migration?, 1)
      assert function_exported?(Publishing, :get_primary_language_migration_status, 1)
      assert function_exported?(Publishing, :migrate_posts_to_current_primary_language, 1)
      assert function_exported?(Publishing, :add_language_to_post, 3)
      assert function_exported?(Publishing, :add_language_to_post, 4)
      assert function_exported?(Publishing, :add_language_to_db, 4)
      assert function_exported?(Publishing, :delete_language, 3)
      assert function_exported?(Publishing, :delete_language, 4)
      assert function_exported?(Publishing, :set_translation_status, 5)
      assert function_exported?(Publishing, :translate_post_to_all_languages, 2)
      assert function_exported?(Publishing, :translate_post_to_all_languages, 3)
    end
  end

  # ============================================================================
  # Stale Fixer Delegations
  # ============================================================================

  describe "stale fixer delegations" do
    test "all stale fixer functions are exported from facade" do
      assert function_exported?(Publishing, :fix_stale_group, 1)
      assert function_exported?(Publishing, :fix_stale_post, 1)
      assert function_exported?(Publishing, :fix_stale_version, 1)
      assert function_exported?(Publishing, :fix_stale_content, 1)
      assert function_exported?(Publishing, :fix_all_stale_values, 0)
      assert function_exported?(Publishing, :reconcile_post_status, 1)
    end
  end

  # ============================================================================
  # Cache Delegations
  # ============================================================================

  describe "cache delegations" do
    test "all cache functions are exported from facade" do
      assert function_exported?(Publishing, :regenerate_cache, 1)
      assert function_exported?(Publishing, :invalidate_cache, 1)
      assert function_exported?(Publishing, :cache_exists?, 1)
      assert function_exported?(Publishing, :find_cached_post, 2)
      assert function_exported?(Publishing, :find_cached_post_by_path, 3)
      assert function_exported?(Publishing, :posts_needing_primary_language_migration, 1)
      assert function_exported?(Publishing, :count_primary_language_status, 1)
    end
  end

  # ============================================================================
  # Language Helper Delegations
  # ============================================================================

  describe "language helper delegations" do
    test "all language helper functions are exported from facade" do
      assert function_exported?(Publishing, :get_language_info, 1)
      assert function_exported?(Publishing, :enabled_language_codes, 0)
      assert function_exported?(Publishing, :get_primary_language, 0)
      assert function_exported?(Publishing, :language_enabled?, 2)
      assert function_exported?(Publishing, :get_display_code, 2)
      assert function_exported?(Publishing, :order_languages_for_display, 2)
      assert function_exported?(Publishing, :order_languages_for_display, 3)
    end
  end

  # ============================================================================
  # Slug Helper Delegations
  # ============================================================================

  describe "slug helper delegations" do
    test "all slug helper functions are exported from facade" do
      assert function_exported?(Publishing, :validate_slug, 1)
      assert function_exported?(Publishing, :slug_exists?, 2)
      assert function_exported?(Publishing, :generate_unique_slug, 2)
      assert function_exported?(Publishing, :generate_unique_slug, 3)
      assert function_exported?(Publishing, :generate_unique_slug, 4)
      assert function_exported?(Publishing, :validate_url_slug, 4)
    end
  end

  # ============================================================================
  # Shared Helpers on Facade
  # ============================================================================

  describe "shared helpers on facade" do
    test "slugify is accessible" do
      assert Publishing.slugify("Hello World") == "hello-world"
    end

    test "valid_slug? is accessible" do
      assert Publishing.valid_slug?("hello-world")
      refute Publishing.valid_slug?("")
    end

    test "fetch_option is accessible" do
      assert Publishing.fetch_option(%{key: "val"}, :key) == "val"
    end

    test "audit_metadata is accessible" do
      assert Publishing.audit_metadata(nil, :create) == %{}
    end

    test "db_post? is accessible" do
      assert Publishing.db_post?(%{uuid: "test"})
      refute Publishing.db_post?(%{})
    end

    test "should_create_new_version? always returns false" do
      refute Publishing.should_create_new_version?(%{}, %{}, "en")
    end

    test "module behaviour functions" do
      assert Publishing.module_key() == "publishing"
      assert Publishing.module_name() == "Publishing"
    end
  end
end
