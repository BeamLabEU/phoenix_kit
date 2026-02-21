defmodule PhoenixKit.Modules.Publishing.PubSub do
  @moduledoc """
  PubSub integration for real-time publishing updates.

  Provides broadcasting and subscription for post changes,
  enabling live updates across all connected admin clients.

  ## Features

  - Post lifecycle events (create, update, delete, status change)
  - Collaborative editing with real-time form state sync
  - Owner/spectator model for concurrent editing
  """

  alias PhoenixKit.PubSub.Manager

  @topic_prefix "publishing"
  @topic_editor_forms "publishing:editor_forms"
  @topic_groups "publishing:groups"

  # ============================================================================
  # Group-Level Updates (group creation/deletion)
  # ============================================================================

  @doc """
  Returns the topic for global group updates (create, delete).
  """
  def groups_topic, do: @topic_groups

  @doc """
  Subscribes the current process to group updates (creation/deletion).
  """
  def subscribe_to_groups do
    Manager.subscribe(groups_topic())
  end

  @doc """
  Unsubscribes the current process from group updates.
  """
  def unsubscribe_from_groups do
    Manager.unsubscribe(groups_topic())
  end

  @doc """
  Broadcasts a group created event.
  """
  def broadcast_group_created(group) do
    Manager.broadcast(groups_topic(), {:group_created, group})
  end

  @doc """
  Broadcasts a group deleted event.
  """
  def broadcast_group_deleted(group_slug) do
    Manager.broadcast(groups_topic(), {:group_deleted, group_slug})
  end

  @doc """
  Broadcasts a group updated event.
  """
  def broadcast_group_updated(group) do
    Manager.broadcast(groups_topic(), {:group_updated, group})
  end

  # Backward compatibility aliases
  @doc false
  @deprecated "Use groups_topic/0 instead"
  def blogs_topic, do: groups_topic()

  @doc false
  @deprecated "Use subscribe_to_groups/0 instead"
  def subscribe_to_blogs, do: subscribe_to_groups()

  @doc false
  @deprecated "Use unsubscribe_from_groups/0 instead"
  def unsubscribe_from_blogs, do: unsubscribe_from_groups()

  @doc false
  @deprecated "Use broadcast_group_created/1 instead"
  def broadcast_blog_created(group), do: broadcast_group_created(group)

  @doc false
  @deprecated "Use broadcast_group_deleted/1 instead"
  def broadcast_blog_deleted(group_slug), do: broadcast_group_deleted(group_slug)

  @doc false
  @deprecated "Use broadcast_group_updated/1 instead"
  def broadcast_blog_updated(group), do: broadcast_group_updated(group)

  # ============================================================================
  # Post List Updates (simple refresh)
  # ============================================================================

  @doc """
  Returns the topic for a specific group's posts.
  """
  def posts_topic(group_slug) do
    "#{@topic_prefix}:#{group_slug}:posts"
  end

  @doc """
  Subscribes the current process to post updates for a group.
  """
  def subscribe_to_posts(group_slug) do
    Manager.subscribe(posts_topic(group_slug))
  end

  @doc """
  Unsubscribes the current process from post updates for a group.
  """
  def unsubscribe_from_posts(group_slug) do
    Manager.unsubscribe(posts_topic(group_slug))
  end

  @doc """
  Broadcasts a post created event.
  """
  def broadcast_post_created(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:post_created, post})
  end

  @doc """
  Broadcasts a post updated event.
  """
  def broadcast_post_updated(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:post_updated, post})
  end

  @doc """
  Broadcasts a post deleted event.
  """
  def broadcast_post_deleted(group_slug, post_path) do
    Manager.broadcast(posts_topic(group_slug), {:post_deleted, post_path})
  end

  @doc """
  Broadcasts a post status changed event.
  """
  def broadcast_post_status_changed(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:post_status_changed, post})
  end

  @doc """
  Broadcasts that a new version was created for a post.
  """
  def broadcast_version_created(group_slug, post) do
    Manager.broadcast(posts_topic(group_slug), {:version_created, post})
  end

  @doc """
  Broadcasts that the live version changed for a post.
  """
  def broadcast_version_live_changed(group_slug, post_slug, version) do
    Manager.broadcast(posts_topic(group_slug), {:version_live_changed, post_slug, version})
  end

  @doc """
  Broadcasts that a version was deleted from a post.
  """
  def broadcast_version_deleted(group_slug, post_slug, version) do
    Manager.broadcast(posts_topic(group_slug), {:version_deleted, post_slug, version})
  end

  # ============================================================================
  # Post-Level Updates (version and translation changes)
  # ============================================================================

  @doc """
  Returns the topic for a specific post's version updates.
  This allows editors to receive notifications when versions are created/deleted.
  """
  def post_versions_topic(group_slug, post_slug) do
    "#{@topic_prefix}:#{group_slug}:post:#{post_slug}:versions"
  end

  @doc """
  Subscribes to version updates for a specific post.
  """
  def subscribe_to_post_versions(group_slug, post_slug) do
    Manager.subscribe(post_versions_topic(group_slug, post_slug))
  end

  @doc """
  Unsubscribes from version updates for a specific post.
  """
  def unsubscribe_from_post_versions(group_slug, post_slug) do
    Manager.unsubscribe(post_versions_topic(group_slug, post_slug))
  end

  @doc """
  Broadcasts that a new version was created for a post (to post-level topic).
  """
  def broadcast_post_version_created(group_slug, post_slug, version_info) do
    Manager.broadcast(
      post_versions_topic(group_slug, post_slug),
      {:post_version_created, group_slug, post_slug, version_info}
    )
  end

  @doc """
  Broadcasts that a version was deleted from a post (to post-level topic).
  """
  def broadcast_post_version_deleted(group_slug, post_slug, version) do
    Manager.broadcast(
      post_versions_topic(group_slug, post_slug),
      {:post_version_deleted, group_slug, post_slug, version}
    )
  end

  @doc """
  Broadcasts that the live/published version changed (to post-level topic).
  Includes source_id so receivers can ignore their own broadcasts.
  """
  def broadcast_post_version_published(group_slug, post_slug, version, source_id \\ nil) do
    Manager.broadcast(
      post_versions_topic(group_slug, post_slug),
      {:post_version_published, group_slug, post_slug, version, source_id}
    )
  end

  @doc """
  Returns the topic for a specific post's translation updates.
  This allows all editors of different language versions to receive updates
  when new translations are added.
  """
  def post_translations_topic(group_slug, post_slug) do
    "#{@topic_prefix}:#{group_slug}:post:#{post_slug}:translations"
  end

  @doc """
  Subscribes to translation updates for a specific post.
  """
  def subscribe_to_post_translations(group_slug, post_slug) do
    Manager.subscribe(post_translations_topic(group_slug, post_slug))
  end

  @doc """
  Unsubscribes from translation updates for a specific post.
  """
  def unsubscribe_from_post_translations(group_slug, post_slug) do
    Manager.unsubscribe(post_translations_topic(group_slug, post_slug))
  end

  @doc """
  Broadcasts that a new translation was created for a post.
  """
  def broadcast_translation_created(group_slug, post_slug, language) do
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_created, group_slug, post_slug, language}
    )
  end

  @doc """
  Broadcasts that a translation was deleted from a post.
  """
  def broadcast_translation_deleted(group_slug, post_slug, language) do
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_deleted, group_slug, post_slug, language}
    )
  end

  # ============================================================================
  # Editor Save Sync (last-save-wins model)
  # ============================================================================

  @doc """
  Broadcasts that a post was saved, so other editors can reload from disk.

  The `source` is the socket.id of the saver, so they don't reload their own save.
  """
  def broadcast_editor_saved(form_key, source) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_saved, form_key, source}
    )
  end

  # ============================================================================
  # Collaborative Editor (real-time form sync)
  # ============================================================================

  @doc """
  Returns the topic for a specific editor form.

  The form_key uniquely identifies a post being edited:
  - For existing posts: "group_slug:post_path" or "group_slug:slug"
  - For new posts: "group_slug:new:language"
  """
  def editor_form_topic(form_key) do
    "#{@topic_editor_forms}:#{form_key}"
  end

  @doc """
  Returns the presence topic for tracking editors of a post.
  """
  def editor_presence_topic(form_key) do
    "publishing:presence:editor:#{form_key}"
  end

  @doc """
  Subscribes to collaborative events for a specific editor form.
  """
  def subscribe_to_editor_form(form_key) do
    Manager.subscribe(editor_form_topic(form_key))
  end

  @doc """
  Unsubscribes from collaborative events for a specific editor form.
  """
  def unsubscribe_from_editor_form(form_key) do
    Manager.unsubscribe(editor_form_topic(form_key))
  end

  @doc """
  Broadcasts a form state change to all subscribers.

  Options:
  - `:source` - The source identifier to prevent self-echoing
  """
  def broadcast_editor_form_change(form_key, payload, opts \\ []) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_form_change, form_key, payload, Keyword.get(opts, :source)}
    )
  end

  @doc """
  Broadcasts a sync request for new joiners to get current state.
  """
  def broadcast_editor_sync_request(form_key, requester_socket_id) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_sync_request, form_key, requester_socket_id}
    )
  end

  @doc """
  Broadcasts a sync response with current form state.
  """
  def broadcast_editor_sync_response(form_key, requester_socket_id, state) do
    Manager.broadcast(
      editor_form_topic(form_key),
      {:editor_sync_response, form_key, requester_socket_id, state}
    )
  end

  # ============================================================================
  # Cache Updates (for live admin UI updates)
  # ============================================================================

  @doc """
  Returns the topic for cache updates for a specific group.
  """
  def cache_topic(group_slug) do
    "#{@topic_prefix}:#{group_slug}:cache"
  end

  @doc """
  Subscribes the current process to cache updates for a group.
  """
  def subscribe_to_cache(group_slug) do
    Manager.subscribe(cache_topic(group_slug))
  end

  @doc """
  Unsubscribes the current process from cache updates for a group.
  """
  def unsubscribe_from_cache(group_slug) do
    Manager.unsubscribe(cache_topic(group_slug))
  end

  @doc """
  Broadcasts that the cache state has changed (file regenerated, memory loaded, etc).
  """
  def broadcast_cache_changed(group_slug) do
    Manager.broadcast(cache_topic(group_slug), {:cache_changed, group_slug})
  end

  @doc """
  Broadcasts detailed cache operation info.
  """
  def broadcast_cache_operation(group_slug, operation, metadata \\ %{}) do
    Manager.broadcast(
      cache_topic(group_slug),
      {:cache_operation, group_slug, operation, metadata}
    )
  end

  # ============================================================================
  # AI Translation Progress
  # ============================================================================

  @doc """
  Broadcasts that AI translation has started.
  Sent to both posts_topic (for group listing) and post_translations_topic (for editor).
  """
  def broadcast_translation_started(group_slug, post_slug, target_languages) do
    payload = {:translation_started, group_slug, post_slug, target_languages}

    # Broadcast to group listing
    Manager.broadcast(
      posts_topic(group_slug),
      {:translation_started, post_slug, length(target_languages)}
    )

    # Broadcast to editor (more detailed info)
    Manager.broadcast(post_translations_topic(group_slug, post_slug), payload)
  end

  @doc """
  Broadcasts AI translation progress (after each language completes).
  Sent to both posts_topic (for group listing) and post_translations_topic (for editor).
  """
  def broadcast_translation_progress(group_slug, post_slug, completed, total, last_language) do
    # Broadcast to group listing
    Manager.broadcast(
      posts_topic(group_slug),
      {:translation_progress, post_slug, completed, total}
    )

    # Broadcast to editor (more detailed info)
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_progress, group_slug, post_slug, completed, total, last_language}
    )
  end

  @doc """
  Broadcasts that AI translation has completed (success or partial failure).
  Sent to both posts_topic (for group listing) and post_translations_topic (for editor).
  """
  def broadcast_translation_completed(group_slug, post_slug, results) do
    # Broadcast to group listing
    Manager.broadcast(
      posts_topic(group_slug),
      {:translation_completed, post_slug, results}
    )

    # Broadcast to editor
    Manager.broadcast(
      post_translations_topic(group_slug, post_slug),
      {:translation_completed, group_slug, post_slug, results}
    )
  end

  # ============================================================================
  # Editor Presence for Group Listing
  # ============================================================================

  @doc """
  Returns the global topic for editor activity across a group.
  Used by group listing to show who's editing what.
  """
  def group_editors_topic(group_slug) do
    "#{@topic_prefix}:#{group_slug}:editors"
  end

  @doc """
  Subscribes to editor activity for a group (used by group listing).
  """
  def subscribe_to_group_editors(group_slug) do
    Manager.subscribe(group_editors_topic(group_slug))
  end

  @doc """
  Unsubscribes from editor activity for a group.
  """
  def unsubscribe_from_group_editors(group_slug) do
    Manager.unsubscribe(group_editors_topic(group_slug))
  end

  @doc """
  Broadcasts that a user started editing a post.
  """
  def broadcast_editor_joined(group_slug, post_slug, user_info) do
    Manager.broadcast(
      group_editors_topic(group_slug),
      {:editor_joined, post_slug, user_info}
    )
  end

  @doc """
  Broadcasts that a user stopped editing a post.
  """
  def broadcast_editor_left(group_slug, post_slug, user_info) do
    Manager.broadcast(
      group_editors_topic(group_slug),
      {:editor_left, post_slug, user_info}
    )
  end

  # Deprecated shims for backward compatibility
  @doc false
  @deprecated "Use group_editors_topic/1 instead"
  def blog_editors_topic(group_slug), do: group_editors_topic(group_slug)

  @doc false
  @deprecated "Use subscribe_to_group_editors/1 instead"
  def subscribe_to_blog_editors(group_slug), do: subscribe_to_group_editors(group_slug)

  @doc false
  @deprecated "Use unsubscribe_from_group_editors/1 instead"
  def unsubscribe_from_blog_editors(group_slug), do: unsubscribe_from_group_editors(group_slug)

  # ============================================================================
  # Bulk Operations Progress
  # ============================================================================

  @doc """
  Returns the topic for bulk operation progress.
  """
  def bulk_operation_topic(group_slug) do
    "#{@topic_prefix}:#{group_slug}:bulk_operations"
  end

  @doc """
  Subscribes to bulk operation progress for a group.
  """
  def subscribe_to_bulk_operations(group_slug) do
    Manager.subscribe(bulk_operation_topic(group_slug))
  end

  @doc """
  Broadcasts bulk operation progress.
  """
  def broadcast_bulk_operation_progress(
        group_slug,
        operation_id,
        operation_type,
        completed,
        total
      ) do
    Manager.broadcast(
      bulk_operation_topic(group_slug),
      {:bulk_operation_progress, operation_id, operation_type, completed, total}
    )
  end

  @doc """
  Broadcasts bulk operation completion.
  """
  def broadcast_bulk_operation_completed(group_slug, operation_id, operation_type, results) do
    Manager.broadcast(
      bulk_operation_topic(group_slug),
      {:bulk_operation_completed, operation_id, operation_type, results}
    )
  end

  # ============================================================================
  # Form Key Helpers
  # ============================================================================

  @doc """
  Generates a form key for a post being edited.

  The form key includes the language to allow concurrent editing of different
  translations of the same post.

  ## Examples

      generate_form_key("blog", %{path: "blog/my-post/v1/en.phk"})
      # => "blog:blog/my-post/v1/en.phk"

      generate_form_key("blog", %{slug: "my-post", language: "en"})
      # => "blog:my-post:en"

      generate_form_key("blog", %{slug: "my-post", language: "en"}, :new)
      # => "blog:new:en"
  """
  def generate_form_key(group_slug, post, mode \\ :edit)

  # UUID-based form key (preferred for DB posts)
  def generate_form_key(group_slug, %{uuid: uuid, language: lang}, :edit)
      when is_binary(uuid) and is_binary(lang) do
    "#{group_slug}:#{uuid}:#{lang}"
  end

  # Path already includes language (e.g., "blog/my-post/v1/en.phk")
  def generate_form_key(group_slug, %{path: path}, :edit) when is_binary(path) do
    "#{group_slug}:#{path}"
  end

  # Slug mode - include language for per-language locking
  def generate_form_key(group_slug, %{slug: slug, language: lang}, :edit)
      when is_binary(slug) and is_binary(lang) do
    "#{group_slug}:#{slug}:#{lang}"
  end

  # Fallback for slug without language (shouldn't happen in practice)
  def generate_form_key(group_slug, %{slug: slug}, :edit) when is_binary(slug) do
    "#{group_slug}:#{slug}"
  end

  def generate_form_key(group_slug, %{language: lang}, :new) do
    "#{group_slug}:new:#{lang}"
  end

  def generate_form_key(group_slug, _post, :new) do
    "#{group_slug}:new"
  end

  def generate_form_key(group_slug, _, _) do
    "#{group_slug}:unknown"
  end

  # ============================================================================
  # DB Import Progress (synchronous DBImporter + async MigrateToDatabaseWorker)
  # ============================================================================

  @doc """
  Broadcasts that a DB import has started for a specific group.
  """
  def broadcast_db_import_started(group_slug, source \\ :sync) do
    Manager.broadcast(groups_topic(), {:db_import_started, group_slug, source})
    Manager.broadcast(posts_topic(group_slug), {:db_import_started, group_slug, source})
  end

  @doc """
  Broadcasts that a DB import has completed for a specific group.
  Includes stats so listeners can show counts.
  """
  def broadcast_db_import_completed(group_slug, stats, source \\ :sync) do
    Manager.broadcast(groups_topic(), {:db_import_completed, group_slug, stats, source})
    Manager.broadcast(posts_topic(group_slug), {:db_import_completed, group_slug, stats, source})
  end

  @doc """
  Broadcasts DB migration progress (from the async MigrateToDatabaseWorker).
  """
  def broadcast_db_migration_started(total_groups) do
    Manager.broadcast(groups_topic(), {:db_migration_started, total_groups})
  end

  @doc """
  Broadcasts per-group progress during async DB migration.
  """
  def broadcast_db_migration_group_progress(group_slug, posts_migrated, total_posts) do
    Manager.broadcast(
      groups_topic(),
      {:db_migration_group_progress, group_slug, posts_migrated, total_posts}
    )

    Manager.broadcast(
      posts_topic(group_slug),
      {:db_migration_group_progress, group_slug, posts_migrated, total_posts}
    )
  end

  @doc """
  Broadcasts that async DB migration has completed for all groups.
  """
  def broadcast_db_migration_completed(stats) do
    Manager.broadcast(groups_topic(), {:db_migration_completed, stats})
  end

  # ============================================================================
  # Primary Language Migration Progress
  # ============================================================================

  @doc """
  Broadcasts that primary language migration has started.
  """
  def broadcast_primary_language_migration_started(group_slug, total_count) do
    Manager.broadcast(
      posts_topic(group_slug),
      {:primary_language_migration_started, group_slug, total_count}
    )
  end

  @doc """
  Broadcasts primary language migration progress.
  """
  def broadcast_primary_language_migration_progress(group_slug, current, total) do
    Manager.broadcast(
      posts_topic(group_slug),
      {:primary_language_migration_progress, group_slug, current, total}
    )
  end

  @doc """
  Broadcasts that primary language migration has completed.
  """
  def broadcast_primary_language_migration_completed(
        group_slug,
        success_count,
        error_count,
        primary_language
      ) do
    Manager.broadcast(
      posts_topic(group_slug),
      {:primary_language_migration_completed, group_slug, success_count, error_count,
       primary_language}
    )
  end

  # ============================================================================
  # Legacy Structure Migration Progress
  # ============================================================================

  @doc """
  Broadcasts that legacy structure migration has started.
  """
  def broadcast_legacy_structure_migration_started(group_slug, total_count) do
    Manager.broadcast(
      posts_topic(group_slug),
      {:legacy_structure_migration_started, group_slug, total_count}
    )
  end

  @doc """
  Broadcasts legacy structure migration progress.
  """
  def broadcast_legacy_structure_migration_progress(group_slug, current, total) do
    Manager.broadcast(
      posts_topic(group_slug),
      {:legacy_structure_migration_progress, group_slug, current, total}
    )
  end

  @doc """
  Broadcasts that legacy structure migration has completed.
  """
  def broadcast_legacy_structure_migration_completed(group_slug, success_count, error_count) do
    Manager.broadcast(
      posts_topic(group_slug),
      {:legacy_structure_migration_completed, group_slug, success_count, error_count}
    )
  end
end
