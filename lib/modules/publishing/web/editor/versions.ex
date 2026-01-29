defmodule PhoenixKit.Modules.Publishing.Web.Editor.Versions do
  @moduledoc """
  Version management functionality for the publishing editor.

  Handles version switching, creation, migration, and
  version-related UI state management.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Utils.Routes

  # ============================================================================
  # Version Reading
  # ============================================================================

  @doc """
  Reads a specific version of a post.
  """
  def read_version_post(socket, version) do
    blog_slug = socket.assigns.blog_slug
    post = socket.assigns.post
    language = socket.assigns.current_language
    # Use the post's stored primary language for fallback, not global
    primary_language = post[:primary_language] || Storage.get_primary_language()

    read_fn =
      if socket.assigns.blog_mode == "slug" do
        fn lang -> Publishing.read_post(blog_slug, post.slug, lang, version) end
      else
        fn lang -> read_timestamp_version(blog_slug, post, lang, version) end
      end

    # Try current language first, fall back to primary if different
    case read_fn.(language) do
      {:ok, _} = result -> result
      {:error, _} when language != primary_language -> read_fn.(primary_language)
      error -> error
    end
  end

  defp read_timestamp_version(blog_slug, post, language, version) do
    # Extract timestamp identifier from current post path
    timestamp_id = extract_timestamp_identifier(post.path)
    versioned_path = Path.join([blog_slug, timestamp_id, "v#{version}", "#{language}.phk"])

    Storage.read_post(blog_slug, versioned_path)
  end

  # ============================================================================
  # Version Switching
  # ============================================================================

  @doc """
  Applies a version switch to the socket.
  """
  def apply_version_switch(socket, version, version_post, form_builder_fn) do
    blog_slug = socket.assigns.blog_slug
    form = form_builder_fn.(blog_slug, version_post, version)
    is_published = form["status"] == "published"
    actual_language = version_post.language
    new_form_key = PublishingPubSub.generate_form_key(blog_slug, version_post, :edit)

    # Save old form_key and post slug BEFORE assigning new one (for presence cleanup)
    old_form_key = socket.assigns[:form_key]
    old_post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

    socket =
      socket
      |> Phoenix.Component.assign(:post, %{version_post | group: blog_slug})
      |> Phoenix.Component.assign(:form, form)
      |> Phoenix.Component.assign(:content, version_post.content)
      |> Phoenix.Component.assign(:current_version, version)
      |> Phoenix.Component.assign(:available_versions, version_post.available_versions)
      |> Phoenix.Component.assign(:version_statuses, version_post.version_statuses)
      |> Phoenix.Component.assign(:version_dates, Map.get(version_post, :version_dates, %{}))
      |> Phoenix.Component.assign(:available_languages, version_post.available_languages)
      |> Phoenix.Component.assign(:editing_published_version, is_published)
      |> Phoenix.Component.assign(:viewing_older_version, false)
      |> Phoenix.Component.assign(:has_pending_changes, false)
      |> Phoenix.Component.assign(:form_key, new_form_key)
      |> Phoenix.Component.assign(:saved_status, form["status"])
      |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
      |> Phoenix.LiveView.push_event("set-content", %{content: version_post.content})

    # Return socket with cleanup info for the caller to handle collaborative editing
    {socket, old_form_key, old_post_slug, new_form_key, actual_language, version_post.path}
  end

  # ============================================================================
  # Version Creation
  # ============================================================================

  @doc """
  Creates a new version from a source version.
  Returns {:ok, socket} or {:error, socket} for use in handle_event.
  """
  def create_version_from_source(socket) do
    blog_slug = socket.assigns.blog_slug
    post = socket.assigns.post
    source_version = socket.assigns.new_version_source
    scope = socket.assigns[:phoenix_kit_current_scope]

    post_identifier =
      case post.mode do
        :timestamp ->
          extract_timestamp_identifier(post.path)

        _ ->
          post.slug
      end

    # Set just_created_version BEFORE calling create_version_from to prevent race condition
    # where the PubSub broadcast is received before this assign happens
    socket = Phoenix.Component.assign(socket, :just_created_version, true)

    case Publishing.create_version_from(blog_slug, post_identifier, source_version, %{},
           scope: scope
         ) do
      {:ok, new_version_post} ->
        new_path = new_version_post.path

        flash_msg =
          if source_version do
            gettext("Created new version %{version} from v%{source}",
              version: new_version_post.version,
              source: source_version
            )
          else
            gettext("Created new blank version %{version}", version: new_version_post.version)
          end

        socket =
          socket
          |> Phoenix.Component.assign(:show_new_version_modal, false)
          |> Phoenix.Component.assign(:new_version_source, nil)
          |> Phoenix.LiveView.put_flash(:info, flash_msg)
          |> Phoenix.LiveView.push_navigate(
            to: Routes.path("/admin/publishing/#{blog_slug}/edit?path=#{URI.encode(new_path)}")
          )

        {:ok, socket}

      {:error, reason} ->
        socket =
          socket
          |> Phoenix.Component.assign(:show_new_version_modal, false)
          |> Phoenix.LiveView.put_flash(
            :error,
            gettext("Failed to create new version: %{reason}", reason: inspect(reason))
          )

        {:error, socket}
    end
  end

  # ============================================================================
  # Version Migration
  # ============================================================================

  @doc """
  Migrates a legacy post to versioned structure.
  """
  def migrate_to_versioned(socket) do
    post = socket.assigns.post

    if post && post.is_legacy_structure do
      language = socket.assigns.current_language

      case Storage.migrate_post_to_versioned(post, language) do
        {:ok, migrated_post} ->
          socket =
            socket
            |> Phoenix.Component.assign(:post, %{migrated_post | group: socket.assigns.blog_slug})
            |> Phoenix.Component.assign(:content, migrated_post.content)
            |> Phoenix.Component.assign(:current_version, migrated_post.version)
            |> Phoenix.Component.assign(:available_versions, migrated_post.available_versions)
            |> Phoenix.Component.assign(:version_statuses, migrated_post.version_statuses)
            |> Phoenix.Component.assign(
              :version_dates,
              Map.get(migrated_post, :version_dates, %{})
            )
            |> Phoenix.Component.assign(:viewing_older_version, false)
            |> Phoenix.Component.assign(:has_pending_changes, false)
            |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
            |> Phoenix.LiveView.put_flash(
              :info,
              gettext("Post migrated to versioned structure (v1)")
            )

          {:ok, socket, migrated_post}

        {:error, reason} ->
          socket =
            Phoenix.LiveView.put_flash(
              socket,
              :error,
              gettext("Failed to migrate post: %{reason}", reason: inspect(reason))
            )

          {:error, socket}
      end
    else
      {:noop, socket}
    end
  end

  # ============================================================================
  # Version Deletion Handling
  # ============================================================================

  @doc """
  Handles when a version is deleted by another editor.
  """
  def handle_version_deleted(socket, blog_slug, post_slug, deleted_version) do
    available_versions = socket.assigns[:available_versions] || []
    updated_versions = Enum.reject(available_versions, &(&1 == deleted_version))
    current_version = socket.assigns[:current_version]

    if current_version == deleted_version do
      switch_to_surviving_version(socket, blog_slug, post_slug, updated_versions)
    else
      # We weren't viewing the deleted version, just update the list
      socket
      |> Phoenix.Component.assign(:available_versions, updated_versions)
      |> Phoenix.Component.assign(
        :post,
        Map.put(socket.assigns.post, :available_versions, updated_versions)
      )
    end
  end

  defp switch_to_surviving_version(
         socket,
         blog_slug,
         post_slug,
         [surviving_version | _] = versions
       ) do
    current_language = editor_language(socket.assigns)

    case Publishing.read_post(blog_slug, post_slug, current_language, surviving_version) do
      {:ok, fresh_post} ->
        apply_surviving_version(socket, blog_slug, fresh_post, versions, surviving_version)

      {:error, _} ->
        socket
        |> Phoenix.Component.assign(:readonly?, true)
        |> Phoenix.LiveView.put_flash(
          :error,
          gettext("The version you were editing was deleted and no other versions are available.")
        )
    end
  end

  defp switch_to_surviving_version(socket, _blog_slug, _post_slug, []) do
    # No versions left - this post is effectively deleted
    socket
    |> Phoenix.Component.assign(:readonly?, true)
    |> Phoenix.Component.assign(:current_version, nil)
    |> Phoenix.Component.assign(:available_versions, [])
    |> Phoenix.Component.assign(
      :post,
      %{socket.assigns.post | path: nil, current_version: nil}
    )
    |> Phoenix.Component.assign(:has_pending_changes, false)
    |> Phoenix.LiveView.put_flash(
      :error,
      gettext("All versions of this post have been deleted. Please navigate away.")
    )
  end

  defp apply_surviving_version(
         socket,
         blog_slug,
         fresh_post,
         updated_versions,
         surviving_version
       ) do
    socket
    |> Phoenix.Component.assign(:post, %{fresh_post | group: blog_slug})
    |> Phoenix.Component.assign(:available_versions, updated_versions)
    |> Phoenix.Component.assign(:current_version, surviving_version)
    |> Phoenix.Component.assign(:content, fresh_post.content)
    |> Phoenix.Component.assign(:has_pending_changes, false)
    |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
    |> Phoenix.LiveView.put_flash(
      :warning,
      gettext("The version you were editing was deleted. Switched to version %{version}.",
        version: surviving_version
      )
    )
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  @doc """
  Extract timestamp identifier (YYYY-MM-DD/HH:MM) from a post path.
  """
  def extract_timestamp_identifier(path) when is_binary(path) do
    parts = String.split(path, "/", trim: true)

    case parts do
      # Versioned: [blog, date, time, version, file]
      [_blog, date, time, _version, _file] ->
        "#{date}/#{time}"

      # Legacy: [blog, date, time, file]
      [_blog, date, time, _file] ->
        "#{date}/#{time}"

      _ ->
        nil
    end
  end

  def extract_timestamp_identifier(_), do: nil

  @doc """
  With variant versioning, all versions are editable since they're independent attempts.
  This function always returns false - no version locking.
  """
  def viewing_older_version?(_current_version, _available_versions, _current_language), do: false

  defp editor_language(assigns) do
    assigns[:current_language] ||
      assigns |> Map.get(:post, %{}) |> Map.get(:language) ||
      hd(Storage.enabled_language_codes())
  end
end
