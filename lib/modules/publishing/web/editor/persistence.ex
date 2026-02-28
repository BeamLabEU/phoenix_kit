defmodule PhoenixKit.Modules.Publishing.Web.Editor.Persistence do
  @moduledoc """
  Post persistence operations for the publishing editor.

  Handles create, update, and save operations for posts,
  including version creation and translation saving.
  """

  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.Editor.Forms
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers

  require Logger

  # ============================================================================
  # Save Orchestration
  # ============================================================================

  @doc """
  Performs save operation with validation and routing.
  Returns {:noreply, socket}.
  """
  def perform_save(socket) do
    params =
      socket.assigns.form
      |> Map.take(["status", "published_at", "slug", "featured_image_uuid", "url_slug", "title"])
      |> Map.put("content", socket.assigns.content)

    params =
      case {socket.assigns.group_mode, Map.get(params, "slug")} do
        {"slug", slug} when is_binary(slug) and slug != "" ->
          params

        {"slug", _} ->
          Map.delete(params, "slug")

        _ ->
          Map.delete(params, "slug")
      end

    # Validate url_slug before saving (for translations)
    # For directory slug conflicts, we auto-clear and show a notice instead of blocking
    case validate_url_slug_for_save(socket, params) do
      {:ok, validated_params} ->
        do_perform_save(socket, validated_params)

      {:ok, validated_params, notice} ->
        socket = Phoenix.LiveView.put_flash(socket, :info, notice)
        do_perform_save(socket, validated_params)

      {:error, reason} ->
        error_message = url_slug_error_message(reason)
        {:noreply, Phoenix.LiveView.put_flash(socket, :error, error_message)}
    end
  end

  defp validate_url_slug_for_save(socket, params) do
    url_slug = Map.get(params, "url_slug", "")

    if url_slug != "" do
      group_slug = socket.assigns.group_slug
      language = editor_language(socket.assigns)
      post_slug = socket.assigns.post.slug || socket.assigns.post[:uuid]

      case Storage.validate_url_slug(group_slug, url_slug, language, post_slug) do
        {:ok, _} ->
          {:ok, params}

        {:error, :conflicts_with_directory_slug} ->
          # Auto-clear the url_slug from ALL translations of this post
          cleared_params = Map.put(params, "url_slug", "")
          cleared_languages = DBStorage.clear_url_slug_from_post(group_slug, post_slug, url_slug)

          notice =
            if length(cleared_languages) > 1 do
              gettext(
                "Custom URL slug '%{slug}' was cleared from %{count} translations because it conflicts with another post's directory name",
                slug: url_slug,
                count: length(cleared_languages)
              )
            else
              gettext(
                "Custom URL slug '%{slug}' for %{language} was cleared because it conflicts with another post's directory name",
                slug: url_slug,
                language: language
              )
            end

          {:ok, cleared_params, notice}

        {:error, :slug_already_exists} ->
          # Auto-clear the url_slug from ALL translations of this post
          cleared_params = Map.put(params, "url_slug", "")
          cleared_languages = DBStorage.clear_url_slug_from_post(group_slug, post_slug, url_slug)

          notice =
            if length(cleared_languages) > 1 do
              gettext(
                "Custom URL slug '%{slug}' was cleared from %{count} translations because it's already in use by another post",
                slug: url_slug,
                count: length(cleared_languages)
              )
            else
              gettext(
                "Custom URL slug '%{slug}' for %{language} was cleared because it's already in use by another post",
                slug: url_slug,
                language: language
              )
            end

          {:ok, cleared_params, notice}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, params}
    end
  end

  defp url_slug_error_message(:invalid_format),
    do: gettext("URL slug must be lowercase letters, numbers, and hyphens only")

  defp url_slug_error_message(:reserved_language_code),
    do: gettext("URL slug cannot be a language code")

  defp url_slug_error_message(:reserved_route_word),
    do: gettext("URL slug cannot be a reserved word (admin, api, assets, etc.)")

  defp do_perform_save(socket, params) do
    is_new_post = Map.get(socket.assigns, :is_new_post, false)
    is_new_translation = Map.get(socket.assigns, :is_new_translation, false)

    # Check if translation file was created in background
    {socket, is_new_translation} =
      if is_new_translation do
        check_background_translation_creation(socket)
      else
        {socket, false}
      end

    cond do
      is_new_post ->
        create_new_post(socket, params)

      is_new_translation ->
        create_new_translation(socket, params)

      true ->
        update_existing_post(socket, params)
    end
  end

  defp check_background_translation_creation(socket) do
    target_language = socket.assigns.current_language

    # Check if content was created in DB for this language.
    # Verify the returned post's language matches — resolve_content falls back
    # to the primary language when the requested language doesn't exist yet,
    # which would trick us into thinking the translation was already created.
    case re_read_post(socket, target_language, socket.assigns.post[:version]) do
      {:ok, real_post}
      when real_post.language == target_language and
             real_post.content != nil and real_post.content != "" ->
        socket =
          socket
          |> Phoenix.Component.assign(:post, real_post)
          |> Phoenix.Component.assign(:is_new_translation, false)

        {socket, false}

      _ ->
        {socket, true}
    end
  end

  # ============================================================================
  # Create Operations
  # ============================================================================

  defp create_new_post(socket, params) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    create_opts =
      if socket.assigns.group_mode == "slug" do
        %{
          title: Map.get(params, "title"),
          slug: Map.get(params, "slug")
        }
      else
        %{}
      end
      |> Map.put(:scope, scope)

    case Publishing.create_post(socket.assigns.group_slug, create_opts) do
      {:ok, new_post} ->
        uuid = new_post[:uuid]

        result =
          case Publishing.update_post(socket.assigns.group_slug, new_post, params, %{scope: scope}) do
            {:ok, updated_post} ->
              # Preserve UUID from create_post (update_post returns FS post without it)
              {:ok, if(uuid, do: Map.put(updated_post, :uuid, uuid), else: updated_post)}

            error ->
              error
          end

        handle_post_update_result(socket, result, gettext("Post created and saved"), %{
          is_new_post: false
        })

      {:error, error} ->
        handle_post_creation_error(socket, error, gettext("Failed to create post"))
    end
  end

  defp create_new_translation(socket, params) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    original_identifier = socket.assigns.post.slug || socket.assigns.post[:uuid]

    current_version = socket.assigns[:current_version]

    case Publishing.add_language_to_post(
           socket.assigns.group_slug,
           original_identifier,
           socket.assigns.current_language,
           current_version
         ) do
      {:ok, new_post} ->
        case Publishing.update_post(socket.assigns.group_slug, new_post, params, %{
               scope: scope,
               is_primary_language: false
             }) do
          {:ok, _updated_post} = result ->
            handle_post_update_result(
              socket,
              result,
              gettext("Translation created and saved"),
              %{
                is_new_translation: false,
                original_post_path: nil
              }
            )

          error ->
            handle_post_update_result(
              socket,
              error,
              gettext("Translation created and saved"),
              %{
                is_new_translation: false,
                original_post_path: nil
              }
            )
        end

      {:error, _reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Failed to create translation file")
         )}
    end
  end

  # ============================================================================
  # Update Operations
  # ============================================================================

  defp update_existing_post(socket, params) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    post = socket.assigns.post
    language = socket.assigns.current_language
    old_path = post.path

    # Check if we need to create a new version
    should_create_version =
      not Map.get(post, :is_legacy_structure, false) and
        Storage.should_create_new_version?(post, params, language)

    if should_create_version do
      create_new_version_from_edit(socket, params, scope)
    else
      update_post_in_place(socket, params, scope, old_path)
    end
  end

  defp create_new_version_from_edit(socket, params, scope) do
    group_slug = socket.assigns.group_slug
    post = socket.assigns.post

    case Publishing.create_new_version(group_slug, post, params, %{scope: scope}) do
      {:ok, new_version_post} ->
        invalidate_post_cache(group_slug, new_version_post)

        socket =
          socket
          |> Phoenix.Component.assign(:post, new_version_post)
          |> Phoenix.Component.assign(:content, new_version_post.content)
          |> Phoenix.Component.assign(:current_version, new_version_post.version)
          |> Phoenix.Component.assign(:available_versions, new_version_post.available_versions)
          |> Phoenix.Component.assign(:version_statuses, new_version_post.version_statuses)
          |> Phoenix.Component.assign(
            :version_dates,
            Map.get(new_version_post, :version_dates, %{})
          )
          |> Phoenix.Component.assign(:editing_published_version, false)
          |> Phoenix.Component.assign(:has_pending_changes, false)
          |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
          |> Phoenix.LiveView.put_flash(
            :info,
            gettext("Created new version %{version} (draft)",
              version: new_version_post.version
            )
          )
          |> Phoenix.LiveView.push_patch(
            to:
              Helpers.build_edit_url(group_slug, new_version_post,
                version: new_version_post.version
              )
          )

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Failed to create new version: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp update_post_in_place(socket, params, scope, old_path) do
    group_slug = socket.assigns.group_slug
    # Ensure the post's language matches the current editing language,
    # not the stale language from when the post was initially loaded
    post = %{socket.assigns.post | language: socket.assigns.current_language}
    current_version = socket.assigns[:current_version]
    # Use saved_status (on-disk status) not post.metadata.status (form-updated status)
    saved_status = socket.assigns[:saved_status] || Map.get(post.metadata, :status, "draft")
    is_primary_language = socket.assigns[:is_primary_language] == true

    # For translations: if primary is not published, force status to match primary
    params = enforce_translation_status(params, socket, is_primary_language)
    new_status = Map.get(params, "status")

    # Check if this is a status change TO published for a versioned post
    is_publishing =
      should_publish_version?(
        is_primary_language,
        new_status,
        saved_status,
        current_version,
        post
      )

    case Publishing.update_post(group_slug, post, params, %{
           scope: scope,
           is_primary_language: is_primary_language
         }) do
      {:ok, updated_post} ->
        handle_successful_update(
          socket,
          updated_post,
          old_path,
          is_publishing,
          post,
          current_version
        )

      {:error, error} ->
        handle_post_in_place_error(socket, error)
    end
  end

  defp enforce_translation_status(params, _socket, true = _is_primary), do: params

  defp enforce_translation_status(params, socket, false = _is_primary) do
    primary_status = socket.assigns.form["status"]

    if primary_status == "published" do
      params
    else
      Map.put(params, "status", primary_status)
    end
  end

  defp should_publish_version?(is_primary, new_status, current_status, current_version, post) do
    is_primary and
      new_status == "published" and
      current_status != "published" and
      current_version != nil and
      not Map.get(post, :is_legacy_structure, false)
  end

  # ============================================================================
  # Success/Error Handlers
  # ============================================================================

  defp handle_successful_update(
         socket,
         updated_post,
         old_path,
         false = _is_publishing,
         _post,
         _version
       ) do
    handle_post_save_success(socket, updated_post, old_path)
  end

  defp handle_successful_update(
         socket,
         updated_post,
         old_path,
         true = _is_publishing,
         post,
         current_version
       ) do
    group_slug = socket.assigns.group_slug

    post_identifier = post.slug || post[:uuid]

    # Use user UUID so all tabs for the same user recognize their own publishes
    user_uuid =
      get_in(socket.assigns, [:phoenix_kit_current_scope, Access.key(:user), Access.key(:uuid)])

    case Publishing.publish_version(group_slug, post_identifier, current_version,
           source_id: user_uuid
         ) do
      :ok ->
        handle_post_save_success(socket, updated_post, old_path)

      {:error, reason} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :warning,
           gettext("Post saved but failed to archive other versions: %{reason}",
             reason: inspect(reason)
           )
         )}
    end
  end

  defp handle_post_save_success(socket, post, old_path) do
    group_slug = socket.assigns.group_slug

    invalidate_post_cache(group_slug, post)

    # Broadcast save to other tabs/users
    if socket.assigns[:form_key] do
      Logger.debug(
        "BROADCASTING editor_saved from update_existing_post: " <>
          "form_key=#{inspect(socket.assigns.form_key)}, source=#{inspect(socket.id)}"
      )

      PublishingPubSub.broadcast_editor_saved(socket.assigns.form_key, socket.id)
    end

    flash_message =
      if socket.assigns.is_autosaving,
        do: nil,
        else: gettext("Post saved")

    # Re-read post to get fresh cross-version statuses
    current_version = socket.assigns[:current_version]
    current_language = socket.assigns[:current_language]

    refreshed_post =
      case re_read_post(socket, current_language, current_version) do
        {:ok, fresh_post} ->
          fresh_post

        {:error, reason} ->
          Logger.warning(
            "Failed to re-read post after save: #{inspect(reason)}, post: #{post[:slug] || post[:path]}"
          )

          current_language_statuses = Map.get(post, :language_statuses, %{})
          new_status = Map.get(post.metadata, :status, "draft")
          updated_statuses = Map.put(current_language_statuses, current_language, new_status)
          Map.put(post, :language_statuses, updated_statuses)
      end

    form = Forms.post_form_with_primary_status(group_slug, refreshed_post, current_version)

    is_published = form["status"] == "published"

    # Update saved_status to reflect the newly saved status
    new_saved_status = form["status"]

    socket =
      socket
      |> Phoenix.Component.assign(:post, refreshed_post)
      |> Forms.assign_form_with_tracking(form)
      |> Phoenix.Component.assign(:content, refreshed_post.content)
      |> Phoenix.Component.assign(:has_pending_changes, false)
      |> Phoenix.Component.assign(:editing_published_version, is_published)
      |> Phoenix.Component.assign(:saved_status, new_saved_status)
      |> Phoenix.Component.assign(:language_statuses, refreshed_post.language_statuses)
      |> Phoenix.Component.assign(:version_statuses, refreshed_post.version_statuses)
      |> Phoenix.Component.assign(:version_dates, Map.get(refreshed_post, :version_dates, %{}))
      |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
      |> maybe_update_current_path(old_path, refreshed_post.path)

    {:noreply,
     if(flash_message, do: Phoenix.LiveView.put_flash(socket, :info, flash_message), else: socket)}
  end

  defp handle_post_in_place_error(socket, :invalid_format) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_in_place_error(socket, :reserved_language_code) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       gettext(
         "This slug is reserved because it's a language code (like 'en', 'es', 'fr'). Please choose a different slug to avoid routing conflicts."
       )
     )}
  end

  defp handle_post_in_place_error(socket, :invalid_slug) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_in_place_error(socket, :slug_already_exists) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       gettext("A post with that slug already exists")
     )}
  end

  defp handle_post_in_place_error(socket, _reason) do
    {:noreply, Phoenix.LiveView.put_flash(socket, :error, gettext("Failed to save post"))}
  end

  defp handle_post_update_result(socket, update_result, success_message, extra_assigns) do
    case update_result do
      {:ok, updated_post} ->
        invalidate_post_cache(socket.assigns.group_slug, updated_post)

        if socket.assigns[:form_key] do
          Logger.debug(
            "BROADCASTING editor_saved: " <>
              "form_key=#{inspect(socket.assigns.form_key)}, source=#{inspect(socket.id)}"
          )

          PublishingPubSub.broadcast_editor_saved(socket.assigns.form_key, socket.id)
        end

        flash_message =
          if socket.assigns.is_autosaving,
            do: nil,
            else: success_message

        alias PhoenixKit.Modules.Publishing.Web.Editor.Forms
        form = Forms.post_form(updated_post)

        socket =
          socket
          |> Phoenix.Component.assign(:post, updated_post)
          |> Forms.assign_form_with_tracking(form)
          |> Phoenix.Component.assign(:content, updated_post.content)
          |> Phoenix.Component.assign(:available_languages, updated_post.available_languages)
          |> Phoenix.Component.assign(:has_pending_changes, false)
          |> Phoenix.Component.assign(extra_assigns)
          |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
          |> Phoenix.LiveView.push_patch(
            to:
              Helpers.build_edit_url(socket.assigns.group_slug, updated_post,
                lang: updated_post.language,
                version: updated_post[:version]
              )
          )

        {:noreply,
         if(flash_message,
           do: Phoenix.LiveView.put_flash(socket, :info, flash_message),
           else: socket
         )}

      {:error, error} ->
        handle_post_update_error(socket, error)
    end
  end

  defp handle_post_update_error(socket, :invalid_format) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
     )}
  end

  defp handle_post_update_error(socket, :reserved_language_code) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       "This slug is reserved because it's a language code (like 'en', 'es', 'fr'). Please choose a different slug to avoid routing conflicts."
     )}
  end

  defp handle_post_update_error(socket, :invalid_slug) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
     )}
  end

  defp handle_post_update_error(socket, :slug_already_exists) do
    {:noreply, Phoenix.LiveView.put_flash(socket, :error, "A post with that slug already exists")}
  end

  defp handle_post_update_error(socket, :title_required) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       gettext("Title is required. Add a heading to your content or enter a title manually.")
     )}
  end

  defp handle_post_update_error(socket, _reason) do
    {:noreply, Phoenix.LiveView.put_flash(socket, :error, "Failed to save post")}
  end

  defp handle_post_creation_error(socket, :invalid_slug, _fallback_message) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_creation_error(socket, :slug_already_exists, _fallback_message) do
    {:noreply,
     Phoenix.LiveView.put_flash(
       socket,
       :error,
       gettext("A post with that slug already exists")
     )}
  end

  defp handle_post_creation_error(socket, _reason, fallback_message) do
    {:noreply, Phoenix.LiveView.put_flash(socket, :error, fallback_message)}
  end

  # ============================================================================
  # Helpers
  # ============================================================================

  defp re_read_post(socket, language \\ nil, version \\ nil) do
    post = socket.assigns.post
    Publishing.read_post_by_uuid(post.uuid, language, version)
  end

  defp invalidate_post_cache(group_slug, post) do
    identifier = post.slug

    Renderer.invalidate_cache(group_slug, identifier, post.language)
  end

  defp maybe_update_current_path(socket, old_path, new_path)
       when new_path in [nil, ""] or new_path == old_path,
       do: socket

  defp maybe_update_current_path(socket, _old_path, _new_path) do
    post = socket.assigns.post

    path =
      Helpers.build_edit_url(socket.assigns.group_slug, post,
        lang: post[:language],
        version: post[:version]
      )

    socket
    |> Phoenix.Component.assign(:current_path, path)
    |> Phoenix.LiveView.push_patch(to: path)
  end

  defp editor_language(assigns) do
    assigns[:current_language] ||
      assigns |> Map.get(:post, %{}) |> Map.get(:language) ||
      hd(Storage.enabled_language_codes())
  end

  # ============================================================================
  # Reload Operations
  # ============================================================================

  @doc """
  Reload content after AI translation completes for the current language.
  """
  def reload_translated_content(socket, flash_msg, flash_level) do
    group_slug = socket.assigns.group_slug

    case re_read_post(socket) do
      {:ok, updated_post} ->
        current_version = socket.assigns[:current_version]
        form = Forms.post_form_with_primary_status(group_slug, updated_post, current_version)

        socket
        |> Phoenix.Component.assign(:post, %{updated_post | group: group_slug})
        |> Forms.assign_form_with_tracking(form)
        |> Phoenix.Component.assign(:content, updated_post.content)
        |> Phoenix.Component.assign(:available_languages, updated_post.available_languages)
        |> Phoenix.Component.assign(:has_pending_changes, false)
        |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
        |> Phoenix.LiveView.push_event("set-content", %{content: updated_post.content})
        |> Phoenix.LiveView.put_flash(flash_level, flash_msg)

      {:error, _reason} ->
        Phoenix.LiveView.put_flash(socket, flash_level, flash_msg)
    end
  end

  @doc """
  Refresh available_languages and language_statuses (for language switcher updates).
  """
  def refresh_available_languages(socket) do
    case re_read_post(socket) do
      {:ok, updated_post} ->
        socket
        |> Phoenix.Component.assign(:available_languages, updated_post.available_languages)
        |> Phoenix.Component.assign(
          :post,
          socket.assigns.post
          |> Map.put(:available_languages, updated_post.available_languages)
          |> Map.put(:language_statuses, updated_post.language_statuses)
        )

      {:error, _reason} ->
        socket
    end
  end

  @doc """
  Reload post when another tab/user saves (last-save-wins).
  """
  def reload_post(socket) do
    group_slug = socket.assigns.group_slug
    current_version = socket.assigns[:current_version]

    case re_read_post(socket) do
      {:ok, updated_post} ->
        form = Forms.post_form_with_primary_status(group_slug, updated_post, current_version)

        socket
        |> Phoenix.Component.assign(:post, %{updated_post | group: group_slug})
        |> Forms.assign_form_with_tracking(form)
        |> Phoenix.Component.assign(:content, updated_post.content)
        |> Phoenix.Component.assign(:available_languages, updated_post.available_languages)
        |> Phoenix.Component.assign(:has_pending_changes, false)
        |> Phoenix.LiveView.push_event("changes-status", %{has_changes: false})
        |> Phoenix.LiveView.push_event("set-content", %{content: updated_post.content})
        |> Phoenix.LiveView.put_flash(:info, gettext("Post updated by another user"))

      {:error, _reason} ->
        socket
        |> Phoenix.LiveView.put_flash(
          :warning,
          gettext("Could not reload post - it may have been moved or deleted")
        )
    end
  end

  @doc """
  Regenerates the listing cache for a group.
  """
  def regenerate_listing_cache(group_slug) do
    ListingCache.regenerate(group_slug)
  end
end
