defmodule PhoenixKitWeb.Live.Modules.Blogging.PubSub do
  @moduledoc """
  PubSub integration for real-time blogging updates.

  Provides broadcasting and subscription for blog post changes,
  enabling live updates across all connected admin clients.

  ## Features

  - Post lifecycle events (create, update, delete, status change)
  - Collaborative editing with real-time form state sync
  - Owner/spectator model for concurrent editing
  """

  alias PhoenixKit.PubSub.Manager

  @topic_prefix "blogging"
  @topic_editor_forms "blogging:editor_forms"
  @topic_blogs "blogging:blogs"

  # ============================================================================
  # Blog-Level Updates (blog creation/deletion)
  # ============================================================================

  @doc """
  Returns the topic for global blog updates (create, delete).
  """
  def blogs_topic, do: @topic_blogs

  @doc """
  Subscribes the current process to blog updates (creation/deletion).
  """
  def subscribe_to_blogs do
    Manager.subscribe(blogs_topic())
  end

  @doc """
  Unsubscribes the current process from blog updates.
  """
  def unsubscribe_from_blogs do
    Manager.unsubscribe(blogs_topic())
  end

  @doc """
  Broadcasts a blog created event.
  """
  def broadcast_blog_created(blog) do
    Manager.broadcast(blogs_topic(), {:blog_created, blog})
  end

  @doc """
  Broadcasts a blog deleted event.
  """
  def broadcast_blog_deleted(blog_slug) do
    Manager.broadcast(blogs_topic(), {:blog_deleted, blog_slug})
  end

  @doc """
  Broadcasts a blog updated event.
  """
  def broadcast_blog_updated(blog) do
    Manager.broadcast(blogs_topic(), {:blog_updated, blog})
  end

  # ============================================================================
  # Post List Updates (simple refresh)
  # ============================================================================

  @doc """
  Returns the topic for a specific blog's posts.
  """
  def posts_topic(blog_slug) do
    "#{@topic_prefix}:#{blog_slug}:posts"
  end

  @doc """
  Subscribes the current process to post updates for a blog.
  """
  def subscribe_to_posts(blog_slug) do
    Manager.subscribe(posts_topic(blog_slug))
  end

  @doc """
  Unsubscribes the current process from post updates for a blog.
  """
  def unsubscribe_from_posts(blog_slug) do
    Manager.unsubscribe(posts_topic(blog_slug))
  end

  @doc """
  Broadcasts a post created event.
  """
  def broadcast_post_created(blog_slug, post) do
    Manager.broadcast(posts_topic(blog_slug), {:post_created, post})
  end

  @doc """
  Broadcasts a post updated event.
  """
  def broadcast_post_updated(blog_slug, post) do
    Manager.broadcast(posts_topic(blog_slug), {:post_updated, post})
  end

  @doc """
  Broadcasts a post deleted event.
  """
  def broadcast_post_deleted(blog_slug, post_path) do
    Manager.broadcast(posts_topic(blog_slug), {:post_deleted, post_path})
  end

  @doc """
  Broadcasts a post status changed event.
  """
  def broadcast_post_status_changed(blog_slug, post) do
    Manager.broadcast(posts_topic(blog_slug), {:post_status_changed, post})
  end

  # ============================================================================
  # Post-Level Updates (translation changes)
  # ============================================================================

  @doc """
  Returns the topic for a specific post's translation updates.
  This allows all editors of different language versions to receive updates
  when new translations are added.
  """
  def post_translations_topic(blog_slug, post_slug) do
    "#{@topic_prefix}:#{blog_slug}:post:#{post_slug}:translations"
  end

  @doc """
  Subscribes to translation updates for a specific post.
  """
  def subscribe_to_post_translations(blog_slug, post_slug) do
    Manager.subscribe(post_translations_topic(blog_slug, post_slug))
  end

  @doc """
  Unsubscribes from translation updates for a specific post.
  """
  def unsubscribe_from_post_translations(blog_slug, post_slug) do
    Manager.unsubscribe(post_translations_topic(blog_slug, post_slug))
  end

  @doc """
  Broadcasts that a new translation was created for a post.
  """
  def broadcast_translation_created(blog_slug, post_slug, language) do
    Manager.broadcast(
      post_translations_topic(blog_slug, post_slug),
      {:translation_created, blog_slug, post_slug, language}
    )
  end

  @doc """
  Broadcasts that a translation was deleted from a post.
  """
  def broadcast_translation_deleted(blog_slug, post_slug, language) do
    Manager.broadcast(
      post_translations_topic(blog_slug, post_slug),
      {:translation_deleted, blog_slug, post_slug, language}
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
  - For existing posts: "blog_slug:post_path" or "blog_slug:slug"
  - For new posts: "blog_slug:new:language"
  """
  def editor_form_topic(form_key) do
    "#{@topic_editor_forms}:#{form_key}"
  end

  @doc """
  Returns the presence topic for tracking editors of a post.
  """
  def editor_presence_topic(form_key) do
    "blogging:presence:editor:#{form_key}"
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
  # Form Key Helpers
  # ============================================================================

  @doc """
  Generates a form key for a post being edited.

  ## Examples

      generate_form_key("blog", %{path: "blog/my-post/en.phk"})
      # => "blog:blog/my-post/en.phk"

      generate_form_key("blog", %{slug: "my-post", language: "en"}, :new)
      # => "blog:new:en"
  """
  def generate_form_key(blog_slug, post, mode \\ :edit)

  def generate_form_key(blog_slug, %{path: path}, :edit) when is_binary(path) do
    "#{blog_slug}:#{path}"
  end

  def generate_form_key(blog_slug, %{slug: slug}, :edit) when is_binary(slug) do
    "#{blog_slug}:#{slug}"
  end

  def generate_form_key(blog_slug, %{language: lang}, :new) do
    "#{blog_slug}:new:#{lang}"
  end

  def generate_form_key(blog_slug, _post, :new) do
    "#{blog_slug}:new"
  end

  def generate_form_key(blog_slug, _, _) do
    "#{blog_slug}:unknown"
  end
end
