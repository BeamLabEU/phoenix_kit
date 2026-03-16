defmodule PhoenixKit.Modules.Publishing.Web.Editor do
  @moduledoc """
  Markdown editor for publishing posts.

  This LiveView handles post editing with support for:
  - Collaborative editing (presence tracking, lock management)
  - AI translation
  - Version management
  - Multi-language support
  - Autosave
  - Media selection

  The implementation is split into submodules:
  - Editor.Collaborative - Presence and lock management
  - Editor.Translation - AI translation workflow
  - Editor.Versions - Version switching and creation
  - Editor.Forms - Form building and normalization
  - Editor.Persistence - Save operations
  - Editor.Preview - Preview mode handling
  - Editor.Helpers - Shared utilities
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  # Suppress dialyzer warnings for pattern matches
  @dialyzer {:nowarn_function, handle_event: 3}

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Modules.AI
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Constants
  alias PhoenixKit.Modules.Publishing.DBStorage
  alias PhoenixKit.Modules.Publishing.ListingCache
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Shared
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Submodule aliases
  alias PhoenixKit.Modules.Publishing.Web.Editor.Collaborative
  alias PhoenixKit.Modules.Publishing.Web.Editor.Forms
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Modules.Publishing.Web.Editor.Persistence
  alias PhoenixKit.Modules.Publishing.Web.Editor.Translation
  alias PhoenixKit.Modules.Publishing.Web.Editor.Versions
  alias PhoenixKit.Utils.Date, as: UtilsDate

  # Import publishing-specific components
  import PhoenixKit.Modules.Publishing.Web.Components.LanguageSwitcher
  import PhoenixKit.Modules.Publishing.Web.Components.VersionSwitcher

  require Logger

  # ============================================================================
  # Template Helper Delegations
  # ============================================================================

  defdelegate datetime_local_value(value), to: Forms
  defdelegate featured_image_preview_url(value), to: Helpers
  defdelegate format_language_list(codes), to: Helpers

  defdelegate build_editor_languages(post, enabled_languages, current_language),
    to: Helpers

  # JS command for language switching. Skeleton visibility is controlled
  # server-side via @editor_loading assign — the switch_language handler sets
  # it to true (showing skeleton, hiding fields), and handle_params sets it
  # back to false when the new language data is ready.
  defp switch_lang_js(lang_code, current_lang) do
    if lang_code == current_lang do
      %JS{}
    else
      JS.push("switch_language", value: %{language: lang_code})
    end
  end

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    live_source =
      socket.id ||
        "publishing-editor-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, "Publishing Editor")
      |> assign(:group_slug, group_slug)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_mode, :single)
      |> assign(:media_selected_uuids, MapSet.new())
      |> assign(:is_autosaving, false)
      |> assign(:autosave_timer, nil)
      |> assign(:slug_manually_set, false)
      |> assign(:last_auto_slug, "")
      |> assign(:url_slug_manually_set, false)
      |> assign(:last_auto_url_slug, "")
      |> assign(:live_source, live_source)
      |> assign(:form_key, nil)
      |> assign(:lock_owner?, true)
      |> assign(:readonly?, false)
      |> assign(:lock_owner_user, nil)
      |> assign(:spectators, [])
      |> assign(:other_viewers, [])
      |> assign(:last_activity_at, System.monotonic_time(:second))
      |> assign(:lock_expiration_timer, nil)
      |> assign(:lock_warning_shown, false)
      |> assign(:form, %{})
      |> assign(:post, nil)
      |> assign(:content, "")
      |> assign(:group_mode, nil)
      |> assign(:current_language, nil)
      |> assign(:current_language_enabled, true)
      |> assign(:current_language_known, true)
      |> assign(:is_primary_language, true)
      |> assign(:post_primary_language_status, {:ok, :current})
      |> assign(:available_languages, [])
      |> assign(:all_enabled_languages, [])
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_post, false)
      |> assign(:is_new_translation, false)
      |> assign(:editor_loading, false)
      |> assign(:public_url, nil)
      |> assign(:current_version, nil)
      |> assign(:available_versions, [])
      |> assign(:version_statuses, %{})
      |> assign(:version_dates, %{})
      |> assign(:editing_published_version, false)
      |> assign(:viewing_older_version, false)
      |> assign(:show_new_version_modal, false)
      |> assign(:new_version_source, nil)
      |> assign(:show_ai_translation, false)
      |> assign(:ai_enabled, AI.enabled?())
      |> assign(:ai_endpoints, Translation.list_ai_endpoints())
      |> assign(:ai_selected_endpoint_uuid, Translation.get_default_ai_endpoint_uuid())
      |> assign(:ai_prompts, Translation.list_ai_prompts())
      |> assign(:ai_selected_prompt_uuid, Translation.get_default_ai_prompt_uuid())
      |> assign(:ai_default_prompt_exists, Translation.default_translation_prompt_exists?())
      |> assign(:ai_translation_status, nil)
      |> assign(:ai_translation_progress, nil)
      |> assign(:ai_translation_total, nil)
      |> assign(:ai_translation_languages, [])
      |> assign(:translation_locked?, false)
      |> assign(:show_translation_confirm, false)
      |> assign(:pending_translation_languages, [])
      |> assign(:translation_warnings, [])
      |> assign(:current_path, Routes.path("/admin/publishing/#{group_slug}/edit"))

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:group_slug] && socket.assigns[:post] && socket.assigns[:lock_owner?] do
      Collaborative.broadcast_editor_activity(socket, :left)
    end

    Collaborative.unsubscribe_from_old_post_topics(socket)
    Collaborative.cancel_lock_expiration_timer(socket)

    :ok
  end

  # ============================================================================
  # Handle Params
  # ============================================================================

  @impl true

  # Match both /admin/publishing/:group/new route AND legacy ?new=true
  def handle_params(params, _uri, %{assigns: %{live_action: :new}} = socket)
      when not is_map_key(params, "preview_token") do
    handle_new_post(socket)
  end

  def handle_params(%{"new" => "true"} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    handle_new_post(socket)
  end

  # UUID-based route: /admin/publishing/:group/:post_uuid/edit
  def handle_params(%{"post_uuid" => post_uuid} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    handle_uuid_post_params(socket, post_uuid, params)
  end

  def handle_params(%{"path" => path} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    handle_path_post_params(socket, path, params)
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp handle_uuid_post_params(socket, post_uuid, params) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)

    version = parse_version_param(params["v"])
    language = params["lang"]

    case Publishing.read_post_by_uuid(post_uuid, language, version) do
      {:ok, post} ->
        all_enabled_languages = Publishing.enabled_language_codes()

        old_form_key = socket.assigns[:form_key]
        old_post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

        {socket, form_key} =
          if language && language not in post.available_languages do
            handle_new_translation_params(
              socket,
              post,
              group_slug,
              group_mode,
              language,
              all_enabled_languages
            )
          else
            handle_existing_post_params(
              socket,
              post,
              group_slug,
              group_mode,
              nil,
              all_enabled_languages
            )
          end

        socket =
          socket
          |> Collaborative.setup_collaborative_editing(form_key,
            old_form_key: old_form_key,
            old_post_slug: old_post_slug
          )
          |> Translation.maybe_restore_translation_status()
          |> assign(:editor_loading, false)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:editor_loading, false)
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  defp handle_path_post_params(socket, path, params) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)

    case Publishing.read_post(group_slug, path) do
      {:ok, post} ->
        all_enabled_languages = Publishing.enabled_language_codes()
        requested_lang = Map.get(params, "lang")

        old_form_key = socket.assigns[:form_key]
        old_post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

        {socket, form_key} =
          if requested_lang && requested_lang not in post.available_languages do
            handle_new_translation_params(
              socket,
              post,
              group_slug,
              group_mode,
              requested_lang,
              all_enabled_languages
            )
          else
            handle_existing_post_params(
              socket,
              post,
              group_slug,
              group_mode,
              path,
              all_enabled_languages
            )
          end

        socket =
          socket
          |> Collaborative.setup_collaborative_editing(form_key,
            old_form_key: old_form_key,
            old_post_slug: old_post_slug
          )
          |> Translation.maybe_restore_translation_status()
          |> assign(:editor_loading, false)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:editor_loading, false)
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  defp handle_new_post(socket) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)
    all_enabled_languages = Publishing.enabled_language_codes()
    primary_language = Publishing.get_primary_language()

    now = UtilsDate.utc_now() |> DateTime.truncate(:second) |> Forms.floor_datetime_to_minute()
    virtual_post = Helpers.build_virtual_post(group_slug, group_mode, primary_language, now)

    form = Forms.post_form(virtual_post)
    form_key = PublishingPubSub.generate_form_key(group_slug, virtual_post, :new)

    old_form_key = socket.assigns[:form_key]
    old_post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

    socket =
      socket
      |> assign(:group_mode, group_mode)
      |> assign(:post, virtual_post)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> Forms.assign_form_with_tracking(form, slug_manually_set: false)
      |> assign(:content, "")
      |> assign(:available_languages, virtual_post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> Helpers.assign_current_language(primary_language)
      |> assign(:current_path, Helpers.build_new_post_url(group_slug))
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_post, true)
      |> assign(:public_url, nil)
      |> assign(:form_key, form_key)
      |> assign(:current_version, 1)
      |> assign(:available_versions, [])
      |> assign(:version_statuses, %{})
      |> assign(:version_dates, %{})
      |> assign(:editing_published_version, false)
      |> assign(:saved_status, "draft")
      |> push_event("changes-status", %{has_changes: false})

    socket =
      Collaborative.setup_collaborative_editing(socket, form_key,
        old_form_key: old_form_key,
        old_post_slug: old_post_slug
      )

    {:noreply, socket}
  end

  defp parse_version_param(nil), do: nil
  defp parse_version_param(v) when is_integer(v), do: v

  defp parse_version_param(v) when is_binary(v) do
    case Integer.parse(v) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_version_param(_), do: nil

  defp handle_new_translation_params(
         socket,
         post,
         group_slug,
         group_mode,
         switch_to_lang,
         all_enabled_languages
       ) do
    current_version = Map.get(post, :version, 1)

    virtual_post =
      post
      |> Map.put(:original_language, post.language)
      |> Map.put(:language, switch_to_lang)
      |> Map.put(:group, group_slug)
      |> Map.put(:content, "")
      |> Map.put(:metadata, Map.put(post.metadata, :title, ""))
      |> Map.put(:mode, post.mode)
      |> Map.put(:slug, post.slug)

    form = Forms.post_form_with_primary_status(group_slug, virtual_post, current_version)
    fk = PublishingPubSub.generate_form_key(group_slug, virtual_post, :edit)

    available_versions = Map.get(post, :available_versions, [])

    sock =
      socket
      |> assign(:group_mode, group_mode)
      |> assign(:post, virtual_post)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> Forms.assign_form_with_tracking(form, slug_manually_set: false)
      |> assign(:content, "")
      |> assign(:available_languages, post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> Helpers.assign_current_language(switch_to_lang)
      |> assign(
        :current_path,
        Helpers.build_edit_url(group_slug, post,
          lang: switch_to_lang,
          version: current_version
        )
      )
      |> assign(:current_version, current_version)
      |> assign(:available_versions, available_versions)
      |> assign(:version_statuses, Map.get(post, :version_statuses, %{}))
      |> assign(:version_dates, Map.get(post, :version_dates, %{}))
      |> assign(
        :viewing_older_version,
        Versions.viewing_older_version?(current_version, available_versions, switch_to_lang)
      )
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_translation, true)
      |> assign(:public_url, nil)
      |> assign(:form_key, fk)
      |> assign(:saved_status, form["status"])
      |> push_event("changes-status", %{has_changes: false})

    {sock, fk}
  end

  defp handle_existing_post_params(
         socket,
         post,
         group_slug,
         group_mode,
         _path,
         all_enabled_languages
       ) do
    version = Map.get(post, :version, 1)
    form = Forms.post_form_with_primary_status(group_slug, post, version)
    fk = PublishingPubSub.generate_form_key(group_slug, post, :edit)

    is_published = form["status"] == "published"

    # Seed auto-title from existing content for manual-set detection
    extracted_title = Metadata.extract_title_from_content(post.content || "")
    auto_title = if extracted_title == Constants.default_title(), do: "", else: extracted_title
    form_title = Map.get(form, "title", "")
    title_manually_set = form_title != "" and auto_title != "" and form_title != auto_title

    sock =
      socket
      |> assign(:group_mode, group_mode)
      |> assign(:post, %{post | group: group_slug})
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> Forms.assign_form_with_tracking(form,
        last_auto_title: auto_title,
        title_manually_set: title_manually_set
      )
      |> assign(:content, post.content)
      |> assign(:available_languages, post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> Helpers.assign_current_language(post.language)
      |> assign(
        :current_path,
        Helpers.build_edit_url(group_slug, post, version: version, lang: post.language)
      )
      |> assign(:has_pending_changes, false)
      |> assign(:public_url, Helpers.build_public_url(post, post.language))
      |> assign(:form_key, fk)
      |> assign(:current_version, Map.get(post, :version, 1))
      |> assign(:available_versions, Map.get(post, :available_versions, []))
      |> assign(:version_statuses, Map.get(post, :version_statuses, %{}))
      |> assign(:version_dates, Map.get(post, :version_dates, %{}))
      |> assign(:editing_published_version, is_published)
      |> assign(
        :viewing_older_version,
        Versions.viewing_older_version?(
          Map.get(post, :version, 1),
          Map.get(post, :available_versions, []),
          post.language
        )
      )
      |> assign(:is_new_translation, false)
      |> assign(:saved_status, Map.get(post.metadata, :status, "draft"))
      |> push_event("changes-status", %{has_changes: false})

    {sock, fk}
  end

  # ============================================================================
  # Handle Events - Form Updates
  # ============================================================================

  @impl true
  def handle_event("update_meta", params, socket) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
      {:noreply, socket}
    else
      params = params |> Map.drop(["_target"])
      params = Forms.preserve_auto_url_slug(params, socket)
      params = Forms.preserve_auto_title(params, socket)

      new_form =
        socket.assigns.form
        |> Map.merge(params)
        |> Forms.normalize_form()

      slug_manually_set =
        if Map.has_key?(params, "slug") do
          slug_value = Map.get(new_form, "slug", "")
          slug_value != "" && slug_value != socket.assigns.last_auto_slug
        else
          socket.assigns.slug_manually_set
        end

      url_slug_manually_set =
        if Map.has_key?(params, "url_slug") do
          url_slug_value = Map.get(new_form, "url_slug", "")
          url_slug_value != "" && url_slug_value != socket.assigns.last_auto_url_slug
        else
          socket.assigns.url_slug_manually_set
        end

      {new_form, title_manually_set} =
        Forms.detect_title_manual_set(params, new_form, socket)

      has_changes = Forms.dirty?(socket.assigns.post, new_form, socket.assigns.content)

      language = Helpers.editor_language(socket.assigns)
      new_status = new_form["status"]

      # Update both metadata.status and language_statuses for the current language
      # This ensures the language switcher reflects the user's selection immediately
      current_language_statuses = Map.get(socket.assigns.post, :language_statuses, %{})
      updated_language_statuses = Map.put(current_language_statuses, language, new_status)

      # Update post with current form values for accurate public URL
      form_slug = new_form["slug"]
      form_url_slug = new_form["url_slug"]

      updated_post =
        socket.assigns.post
        |> Map.put(:metadata, Map.merge(socket.assigns.post.metadata, %{status: new_status}))
        |> Map.put(:language_statuses, updated_language_statuses)
        |> then(fn p ->
          if form_slug && form_slug != "", do: Map.put(p, :slug, form_slug), else: p
        end)
        |> then(fn p ->
          if form_url_slug && form_url_slug != "",
            do: Map.put(p, :url_slug, form_url_slug),
            else: p
        end)

      public_url = Helpers.build_public_url(updated_post, language)

      socket =
        socket
        |> assign(:form, new_form)
        |> assign(:post, updated_post)
        |> assign(:slug_manually_set, slug_manually_set)
        |> assign(:url_slug_manually_set, url_slug_manually_set)
        |> assign(:title_manually_set, title_manually_set)
        |> assign(:has_pending_changes, has_changes)
        |> assign(:public_url, public_url)
        |> clear_flash()
        |> push_event("changes-status", %{has_changes: has_changes})

      socket = if has_changes, do: schedule_autosave(socket), else: socket

      Collaborative.broadcast_form_change(socket, :meta, new_form)

      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    end
  end

  def handle_event("update_content", %{"content" => content}, socket) do
    socket = maybe_reclaim_lock(socket)

    if socket.assigns.readonly? or socket.assigns.translation_locked? do
      {:noreply, socket}
    else
      {socket, new_form, slug_events} = Forms.maybe_update_slug_from_content(socket, content)

      # Auto-update title from H1 if not manually set
      socket = assign(socket, :form, new_form)
      {socket, new_form, title_events} = Forms.maybe_update_title_from_content(socket, content)

      has_changes = Forms.dirty?(socket.assigns.post, new_form, content)

      socket =
        socket
        |> assign(:content, content)
        |> assign(:form, new_form)
        |> assign(:has_pending_changes, has_changes)
        |> push_event("changes-status", %{has_changes: has_changes})

      socket = Forms.push_slug_events(socket, slug_events ++ title_events)
      socket = if has_changes, do: schedule_autosave(socket), else: socket

      Collaborative.broadcast_form_change(socket, :content, %{content: content, form: new_form})

      socket = Collaborative.touch_activity(socket)

      {:noreply, socket}
    end
  end

  def handle_event("generate_slug_from_content", _params, socket) do
    if socket.assigns.group_mode == "slug" do
      content = socket.assigns.content || ""

      {socket, new_form, slug_events} =
        Forms.maybe_update_slug_from_content(socket, content, force: true)

      has_changes = Forms.dirty?(socket.assigns.post, new_form, socket.assigns.content)

      {:noreply,
       socket
       |> assign(:form, new_form)
       |> assign(:has_pending_changes, has_changes)
       |> push_event("changes-status", %{has_changes: has_changes})
       |> Forms.push_slug_events(slug_events)}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Events - Save
  # ============================================================================

  def handle_event("save", _params, socket) when socket.assigns.readonly? == true do
    socket = maybe_reclaim_lock(socket)

    cond do
      socket.assigns.readonly? ->
        {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}

      socket.assigns.translation_locked? ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot save while translation is in progress"))}

      true ->
        Persistence.perform_save(socket)
    end
  end

  def handle_event("save", _params, socket)
      when socket.assigns.translation_locked? == true do
    {:noreply, put_flash(socket, :error, gettext("Cannot save while translation is in progress"))}
  end

  def handle_event("save", _params, socket) do
    Persistence.perform_save(socket)
  rescue
    e ->
      Logger.error("Editor save failed: #{Exception.message(e)}")
      {:noreply, put_flash(socket, :error, gettext("Something went wrong. Please try again."))}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("clear_translation", _params, socket) do
    group_slug = socket.assigns.group_slug
    post = socket.assigns.post
    language = socket.assigns.current_language
    post_uuid = post[:uuid]

    result =
      with db_post when not is_nil(db_post) <- DBStorage.get_post_by_uuid(post_uuid, [:group]),
           db_version when not is_nil(db_version) <- Shared.resolve_db_version(db_post, nil),
           content when not is_nil(content) <-
             DBStorage.get_content(db_version.uuid, language) do
        # Don't delete the last language
        remaining =
          DBStorage.list_contents(db_version.uuid)
          |> Enum.reject(&(&1.language == language))

        if remaining == [] do
          {:error, :last_language}
        else
          repo = PhoenixKit.RepoHelper.repo()

          case repo.delete(content) do
            {:ok, _} ->
              ListingCache.regenerate(group_slug)

              PublishingPubSub.broadcast_translation_deleted(
                group_slug,
                db_post.slug || db_post.uuid,
                language
              )

              :ok

            {:error, reason} ->
              {:error, reason}
          end
        end
      else
        nil -> {:error, :not_found}
      end

    case result do
      :ok ->
        primary_lang = post[:primary_language] || Publishing.get_primary_language()
        url = Helpers.build_edit_url(group_slug, post, lang: primary_lang)

        {:noreply,
         socket
         |> put_flash(:info, gettext("Translation cleared"))
         |> push_navigate(to: url)}

      {:error, :last_language} ->
        {:noreply,
         put_flash(socket, :error, gettext("Cannot remove the last language from a post"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to clear translation"))}
    end
  end

  # ============================================================================
  # Handle Events - Media
  # ============================================================================

  def handle_event("open_media_selector", _params, socket) do
    {:noreply, assign(socket, :show_media_selector, true)}
  end

  def handle_event("open_image_component_selector", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:inserting_image_component, true)}
  end

  def handle_event("insert_component", %{"component" => "video"}, socket) do
    {:noreply,
     push_event(socket, "phx:prompt-and-insert", %{
       component: "video",
       prompt: "Enter YouTube URL:",
       placeholder: "https://youtu.be/dQw4w9WgXcQ"
     })}
  end

  def handle_event("insert_component", %{"component" => "cta"}, socket) do
    template = """
    <CTA primary="true" action="/your-link">Button Text</CTA>
    """

    {:noreply, push_event(socket, "phx:insert-at-cursor", %{text: template})}
  end

  def handle_event("insert_video_component", %{"url" => url}, socket) do
    template = """

    <Video url="#{url}">
      Optional caption text
    </Video>

    """

    {:noreply, push_event(socket, "phx:insert-at-cursor", %{text: template})}
  end

  def handle_event("clear_featured_image", _params, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      updated_form = Map.put(socket.assigns.form, "featured_image_uuid", "")

      socket =
        socket
        |> assign(:form, updated_form)
        |> assign(:has_pending_changes, true)
        |> put_flash(:info, gettext("Featured image cleared"))
        |> push_event("changes-status", %{has_changes: true})
        |> schedule_autosave()

      {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Events - AI Translation
  # ============================================================================

  def handle_event("toggle_ai_translation", _params, socket) do
    {:noreply, assign(socket, :show_ai_translation, !socket.assigns.show_ai_translation)}
  end

  def handle_event("select_ai_endpoint", %{"endpoint_uuid" => endpoint_uuid}, socket) do
    endpoint_uuid = if endpoint_uuid == "", do: nil, else: endpoint_uuid

    {:noreply, assign(socket, :ai_selected_endpoint_uuid, endpoint_uuid)}
  end

  def handle_event("select_ai_prompt", %{"prompt_uuid" => prompt_uuid}, socket) do
    prompt_uuid = if prompt_uuid == "", do: nil, else: prompt_uuid

    {:noreply, assign(socket, :ai_selected_prompt_uuid, prompt_uuid)}
  end

  def handle_event("generate_default_translation_prompt", _params, socket) do
    case Translation.generate_default_translation_prompt() do
      {:ok, prompt} ->
        {:noreply,
         socket
         |> assign(:ai_prompts, Translation.list_ai_prompts())
         |> assign(:ai_selected_prompt_uuid, prompt.uuid)
         |> assign(:ai_default_prompt_exists, true)
         |> Phoenix.LiveView.put_flash(:info, gettext("Default translation prompt created"))}

      {:error, _changeset} ->
        {:noreply,
         Phoenix.LiveView.put_flash(
           socket,
           :error,
           gettext("Failed to create prompt. It may already exist.")
         )}
    end
  end

  def handle_event("translate_to_all_languages", _params, socket) do
    target_languages = Translation.get_all_target_languages(socket)
    empty_opts = {:warning, gettext("No other languages enabled to translate to")}
    Translation.enqueue_translation(socket, target_languages, empty_opts)
  end

  def handle_event("translate_missing_languages", _params, socket) do
    target_languages = Translation.get_target_languages_for_translation(socket)
    empty_opts = {:info, gettext("All languages already have translations")}
    Translation.enqueue_translation(socket, target_languages, empty_opts)
  end

  def handle_event("translate_to_this_language", _params, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      Translation.start_translation_to_current(socket)
    end
  end

  def handle_event("confirm_translation", _params, socket) do
    target_languages = socket.assigns.pending_translation_languages

    current_warnings = Translation.build_translation_warnings(socket, target_languages)

    if current_warnings != socket.assigns.translation_warnings do
      {:noreply, assign(socket, :translation_warnings, current_warnings)}
    else
      socket =
        socket
        |> assign(:show_translation_confirm, false)
        |> assign(:pending_translation_languages, [])
        |> assign(:translation_warnings, [])

      Translation.do_enqueue_translation(socket, target_languages)
    end
  end

  def handle_event("cancel_translation", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_translation_confirm, false)
     |> assign(:pending_translation_languages, [])
     |> assign(:translation_warnings, [])}
  end

  # ============================================================================
  # Handle Events - Version Management
  # ============================================================================

  def handle_event("toggle_version_access", %{"enabled" => enabled_str}, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      enabled = enabled_str == "true"
      post = socket.assigns.post
      group_slug = socket.assigns.group_slug

      updated_metadata = Map.put(post.metadata, :allow_version_access, enabled)
      updated_post = %{post | metadata: updated_metadata}

      scope = socket.assigns[:phoenix_kit_current_scope]
      params = %{"allow_version_access" => enabled}

      case Publishing.update_post(group_slug, updated_post, params, %{scope: scope}) do
        {:ok, saved_post} ->
          flash_msg =
            if enabled,
              do: gettext("Version access enabled - older versions are now publicly accessible"),
              else: gettext("Version access disabled - only live version is publicly accessible")

          {:noreply,
           socket
           |> assign(:post, saved_post)
           |> put_flash(:info, flash_msg)}

        {:error, _reason} ->
          {:noreply,
           put_flash(socket, :error, gettext("Failed to update version access setting"))}
      end
    end
  end

  def handle_event("switch_version", %{"version" => version_str}, socket) do
    version = String.to_integer(version_str)

    if version == socket.assigns.current_version do
      {:noreply, socket}
    else
      case Versions.read_version_post(socket, version) do
        {:ok, version_post} ->
          {socket, old_form_key, old_post_slug, new_form_key, actual_language} =
            Versions.apply_version_switch(
              socket,
              version,
              version_post,
              &Forms.post_form_with_primary_status/3
            )

          socket =
            socket
            |> Helpers.assign_current_language(actual_language)
            |> Collaborative.cleanup_and_setup_collaborative_editing(old_form_key, new_form_key,
              old_post_slug: old_post_slug
            )

          post = socket.assigns.post

          url =
            Helpers.build_edit_url(socket.assigns.group_slug, post,
              version: version,
              lang: actual_language
            )

          {:noreply, push_patch(socket, to: url, replace: true)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Version not found"))}
      end
    end
  end

  def handle_event("open_new_version_modal", _params, socket) do
    if socket.assigns[:readonly?] or socket.assigns[:is_new_post] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:show_new_version_modal, true)
       |> assign(:new_version_source, nil)}
    end
  end

  def handle_event("close_new_version_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_new_version_modal, false)
     |> assign(:new_version_source, nil)}
  end

  def handle_event("set_new_version_source", %{"source" => "blank"}, socket) do
    {:noreply, assign(socket, :new_version_source, nil)}
  end

  def handle_event("set_new_version_source", %{"source" => version_str}, socket) do
    case Integer.parse(version_str) do
      {version, _} -> {:noreply, assign(socket, :new_version_source, version)}
      :error -> {:noreply, socket}
    end
  end

  def handle_event("create_version_from_source", _params, socket) do
    case Versions.create_version_from_source(socket) do
      {:ok, socket} -> {:noreply, socket}
      {:error, socket} -> {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Events - Language Switching
  # ============================================================================

  def handle_event("switch_language", %{"language" => new_language}, socket) do
    if socket.assigns[:is_new_post] do
      {:noreply,
       put_flash(socket, :error, gettext("Please save the post first before switching languages"))}
    else
      do_switch_language(socket, new_language)
    end
  end

  def handle_event("update_primary_language", _params, socket) do
    group_slug = socket.assigns.group_slug
    post = socket.assigns.post

    if post do
      primary_language = Publishing.get_primary_language()
      language_name = Helpers.get_language_name(primary_language)

      case Publishing.update_post_primary_language(group_slug, post.uuid, primary_language) do
        :ok ->
          Persistence.regenerate_listing_cache(group_slug)

          updated_post = Map.put(post, :primary_language, primary_language)
          enabled_languages = socket.assigns[:all_enabled_languages] || []

          editor_languages =
            Helpers.build_editor_languages(
              updated_post,
              enabled_languages,
              socket.assigns.current_language
            )

          socket =
            socket
            |> assign(:post, updated_post)
            |> assign(:editor_languages, editor_languages)
            |> assign(:post_primary_language_status, {:ok, :current})
            |> put_flash(:info, gettext("Primary language updated: %{lang}", lang: language_name))

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to update primary language: %{reason}", reason: inspect(reason))
           )}
      end
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Events - Navigation
  # ============================================================================

  def handle_event("preview", _params, socket) do
    # Save first if there are pending changes (autosave is 500ms but user might click fast)
    socket =
      if socket.assigns.has_pending_changes do
        {:noreply, saved} = Persistence.perform_save(socket)
        saved
      else
        socket
      end

    group_slug = socket.assigns.group_slug
    post = socket.assigns.post
    post_uuid = post[:uuid]
    language = socket.assigns.current_language
    version = socket.assigns[:current_version]

    query_params = %{"lang" => language}
    query_params = if version, do: Map.put(query_params, "v", version), else: query_params
    query = URI.encode_query(query_params)

    {:noreply,
     push_navigate(socket,
       to: Routes.path("/admin/publishing/#{group_slug}/#{post_uuid}/preview?#{query}")
     )}
  end

  def handle_event("attempt_cancel", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    handle_event("cancel", %{}, socket)
  end

  def handle_event("attempt_cancel", _params, socket) do
    {:noreply, push_event(socket, "confirm-navigation", %{})}
  end

  def handle_event("cancel", _params, socket) do
    {:noreply,
     socket
     |> push_event("changes-status", %{has_changes: false})
     |> push_navigate(to: Routes.path("/admin/publishing/#{socket.assigns.group_slug}"))}
  end

  def handle_event("back_to_list", _params, socket) do
    handle_event("attempt_cancel", %{}, socket)
  end

  # ============================================================================
  # Handle Info - Autosave
  # ============================================================================

  @impl true
  def handle_info({:deferred_language_switch, group_slug, target_language}, socket) do
    old_form_key = socket.assigns[:form_key]

    if old_form_key && connected?(socket) do
      alias PhoenixKit.Modules.Publishing.PresenceHelpers
      PresenceHelpers.untrack_editing_session(old_form_key, socket)
      PresenceHelpers.unsubscribe_from_editing(old_form_key)
      PublishingPubSub.unsubscribe_from_editor_form(old_form_key)
    end

    post = socket.assigns.post

    url =
      Helpers.build_edit_url(group_slug, post,
        lang: target_language,
        version: socket.assigns[:current_version]
      )

    {:noreply, push_patch(socket, to: url)}
  end

  @impl true
  def handle_info(:autosave, socket) do
    if socket.assigns.has_pending_changes and not socket.assigns.translation_locked? do
      socket =
        socket
        |> assign(:is_autosaving, true)
        |> assign(:autosave_timer, nil)
        |> push_event("autosave-status", %{saving: true})

      {:noreply, updated_socket} = Persistence.perform_save(socket)

      {:noreply,
       updated_socket
       |> assign(:is_autosaving, false)
       |> push_event("autosave-status", %{saving: false})}
    else
      {:noreply, assign(socket, :autosave_timer, nil)}
    end
  rescue
    e ->
      Logger.error("[Publishing.Editor] Autosave failed: #{Exception.message(e)}")

      {:noreply,
       socket
       |> assign(:is_autosaving, false)
       |> assign(:autosave_timer, nil)
       |> push_event("autosave-status", %{saving: false})
       |> put_flash(:error, gettext("Autosave failed — click Save to retry"))}
  end

  # ============================================================================
  # Handle Info - Media
  # ============================================================================

  def handle_info({:media_selected, file_uuids}, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, assign(socket, :show_media_selector, false)}
    else
      handle_media_selected(socket, file_uuids)
    end
  end

  def handle_info({:media_selector_closed}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, false)
     |> assign(:inserting_image_component, false)}
  end

  def handle_info({:editor_content_changed, %{content: content}}, socket) do
    {socket, new_form, slug_events} = Forms.maybe_update_slug_from_content(socket, content)

    # Auto-update title from H1 if not manually set
    socket = assign(socket, :form, new_form)
    {socket, new_form, title_events} = Forms.maybe_update_title_from_content(socket, content)

    has_changes = Forms.dirty?(socket.assigns.post, new_form, content)

    socket =
      socket
      |> assign(:content, content)
      |> assign(:form, new_form)
      |> assign(:has_pending_changes, has_changes)
      |> push_event("changes-status", %{has_changes: has_changes})
      |> Forms.push_slug_events(slug_events ++ title_events)

    socket = if has_changes, do: schedule_autosave(socket), else: socket

    {:noreply, socket}
  end

  def handle_info({:editor_insert_component, %{type: :image}}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:inserting_image_component, true)}
  end

  def handle_info({:editor_insert_component, %{type: :video}}, socket) do
    {:noreply, push_event(socket, "prompt-and-insert", %{type: "video"})}
  end

  def handle_info({:editor_insert_component, _}, socket), do: {:noreply, socket}
  def handle_info({:editor_save_requested, _}, socket), do: {:noreply, socket}

  # ============================================================================
  # Handle Info - Collaborative Editing
  # ============================================================================

  def handle_info({:editor_saved, form_key, source}, socket) do
    cond do
      socket.assigns.form_key == nil ->
        {:noreply, socket}

      form_key != socket.assigns.form_key ->
        {:noreply, socket}

      source == socket.id ->
        {:noreply, socket}

      true ->
        socket = Persistence.reload_post(socket)
        {:noreply, socket}
    end
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    if socket.assigns[:form_key] do
      form_key = socket.assigns.form_key
      was_owner = socket.assigns[:lock_owner?]

      socket = Collaborative.assign_editing_role(socket, form_key)

      if !was_owner && socket.assigns[:lock_owner?] do
        socket = reload_post_on_lock_acquired(socket)
        Collaborative.broadcast_editor_activity(socket, :joined)

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_sync_request, form_key, requester_socket_id}, socket) do
    if socket.assigns[:form_key] == form_key && socket.assigns[:lock_owner?] do
      state = %{
        form: socket.assigns.form,
        content: socket.assigns.content
      }

      PublishingPubSub.broadcast_editor_sync_response(form_key, requester_socket_id, state)
    end

    {:noreply, socket}
  end

  def handle_info({:editor_sync_response, form_key, requester_socket_id, state}, socket) do
    if socket.assigns[:form_key] == form_key &&
         requester_socket_id == socket.id &&
         socket.assigns.readonly? do
      socket = Collaborative.apply_remote_form_state(socket, state)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:editor_form_change, form_key, payload, source}, socket) do
    cond do
      socket.assigns[:form_key] != form_key ->
        {:noreply, socket}

      source == socket.id ->
        {:noreply, socket}

      socket.assigns[:readonly?] != true ->
        {:noreply, socket}

      true ->
        socket = Collaborative.apply_remote_form_change(socket, payload)
        {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Info - Translation Events
  # ============================================================================

  def handle_info({:translation_started, group_slug, post_identifier, target_languages}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      current_lang = socket.assigns[:current_language]
      source_lang = source_language_for_translation(socket)
      should_lock = current_lang == source_lang or current_lang in target_languages

      {:noreply,
       socket
       |> assign(:ai_translation_status, :in_progress)
       |> assign(:ai_translation_progress, 0)
       |> assign(:ai_translation_total, length(target_languages))
       |> assign(:ai_translation_languages, target_languages)
       |> assign(:translation_locked?, should_lock)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:translation_progress, group_slug, post_identifier, completed, total, _last_language},
        socket
      ) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      socket =
        socket
        |> assign(:ai_translation_status, :in_progress)
        |> assign(:ai_translation_progress, completed)
        |> assign(:ai_translation_total, total)
        |> Persistence.refresh_available_languages()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_completed, group_slug, post_identifier, results}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      flash_msg =
        if results.failure_count > 0 do
          gettext("Translation completed with %{success} succeeded, %{failed} failed",
            success: results.success_count,
            failed: results.failure_count
          )
        else
          gettext("Translation completed successfully for %{count} languages",
            count: results.success_count
          )
        end

      flash_level = if results.failure_count > 0, do: :warning, else: :info

      current_language = socket.assigns[:current_language]
      succeeded_languages = results[:succeeded] || []

      socket =
        socket
        |> assign(:ai_translation_status, :completed)
        |> assign(:ai_translation_languages, [])
        |> assign(:translation_locked?, false)

      socket =
        if current_language in succeeded_languages do
          Persistence.reload_translated_content(socket, flash_msg, flash_level)
        else
          # Reload source language content too (worker reads from DB, no conflict)
          socket
          |> Persistence.refresh_available_languages()
          |> put_flash(flash_level, flash_msg)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_created, group_slug, post_identifier, language}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      case re_read_post(socket) do
        {:ok, updated_post} ->
          socket =
            socket
            |> assign(:available_languages, updated_post.available_languages)
            |> assign(
              :post,
              socket.assigns.post
              |> Map.put(:available_languages, updated_post.available_languages)
              |> Map.put(:language_statuses, updated_post.language_statuses)
            )

          {:noreply, socket}

        {:error, _} ->
          available = socket.assigns[:available_languages] || []

          if language in available do
            {:noreply, socket}
          else
            {:noreply, assign(socket, :available_languages, available ++ [language])}
          end
      end
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_deleted, group_slug, post_identifier, language}, socket) do
    if socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier) do
      available = socket.assigns[:available_languages] || []
      updated_available = List.delete(available, language)

      socket =
        socket
        |> assign(:available_languages, updated_available)
        |> assign(:post, Map.put(socket.assigns.post, :available_languages, updated_available))

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Handle Info - Version Events
  # ============================================================================

  def handle_info({:post_version_created, group_slug, post_identifier, version_info}, socket) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier)

    we_just_created = socket.assigns[:just_created_version] == true

    cond do
      !is_our_post ->
        {:noreply, socket}

      we_just_created ->
        # Clear the flag and don't show flash for our own action
        {:noreply, assign(socket, :just_created_version, nil)}

      true ->
        available_versions =
          version_info[:available_versions] || socket.assigns[:available_versions]

        socket =
          socket
          |> assign(:available_versions, available_versions)
          |> assign(:post, Map.put(socket.assigns.post, :available_versions, available_versions))
          |> put_flash(:info, gettext("A new version was created by another editor"))

        {:noreply, socket}
    end
  end

  def handle_info({:post_version_deleted, group_slug, post_identifier, deleted_version}, socket) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier)

    if is_our_post do
      {:noreply, Versions.handle_version_deleted(socket, deleted_version)}
    else
      {:noreply, socket}
    end
  end

  # Handle version published with source_id (user UUID)
  def handle_info(
        {:post_version_published, group_slug, post_identifier, published_version,
         source_user_uuid},
        socket
      ) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug && post_matches?(socket, post_identifier)

    # Ignore if same user published (works across all their tabs)
    our_user_uuid =
      get_in(socket.assigns, [:phoenix_kit_current_scope, Access.key(:user), Access.key(:uuid)])

    from_us = source_user_uuid != nil && source_user_uuid == our_user_uuid

    cond do
      !is_our_post ->
        {:noreply, socket}

      from_us ->
        {:noreply, socket}

      true ->
        socket =
          socket
          |> put_flash(
            :info,
            gettext("Version %{version} was published by another editor",
              version: published_version
            )
          )

        {:noreply, socket}
    end
  end

  # Handle version published without source_id (legacy format, treat as from another editor)
  def handle_info({:post_version_published, group_slug, post_slug, published_version}, socket) do
    handle_info({:post_version_published, group_slug, post_slug, published_version, nil}, socket)
  end

  # ============================================================================
  # Handle Info - Lock Expiration
  # ============================================================================

  def handle_info(:check_lock_expiration, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      socket = Collaborative.check_lock_expiration(socket)
      {:noreply, socket}
    end
  end

  # ============================================================================
  # Private Helpers
  # ============================================================================

  defp source_language_for_translation(socket) do
    Translation.source_language_for_translation(socket)
  end

  # Matches a broadcast identifier (slug or UUID) against the current post.
  # Broadcasts may send slug for slug-mode posts or UUID for timestamp-mode posts.
  defp post_matches?(socket, broadcast_id) do
    post = socket.assigns[:post]

    post != nil &&
      (post[:slug] == broadcast_id || post[:uuid] == broadcast_id)
  end

  defp reload_post_on_lock_acquired(socket) do
    case re_read_post(socket) do
      {:ok, post} ->
        form = Forms.post_form(post)
        extracted_title = Metadata.extract_title_from_content(post.content || "")

        auto_title =
          if extracted_title == Constants.default_title(), do: "", else: extracted_title

        socket
        |> assign(:post, %{post | group: socket.assigns.group_slug})
        |> Forms.assign_form_with_tracking(form,
          last_auto_title: auto_title,
          title_manually_set: false
        )
        |> assign(:content, post.content)
        |> assign(:has_pending_changes, false)
        |> push_event("changes-status", %{has_changes: false})
        |> push_event("set-content", %{content: post.content})
        |> Collaborative.maybe_start_lock_expiration_timer()

      {:error, _} ->
        # Still start the lock expiration timer even if re-read fails,
        # since this user is now the owner
        Collaborative.maybe_start_lock_expiration_timer(socket)
    end
  end

  defp maybe_reclaim_lock(socket) do
    if socket.assigns[:lock_released_by_timeout] do
      Collaborative.try_reclaim_lock(socket)
    else
      socket
    end
  end

  defp schedule_autosave(socket) do
    if socket.assigns.autosave_timer do
      Process.cancel_timer(socket.assigns.autosave_timer)
    end

    # Save quickly — DB writes are ~5ms, no reason to delay
    timer_ref = Process.send_after(self(), :autosave, 500)
    assign(socket, :autosave_timer, timer_ref)
  end

  defp re_read_post(socket) do
    case socket.assigns[:post] do
      nil -> {:error, :no_post}
      %{uuid: nil} -> {:error, :no_uuid}
      post -> Publishing.read_post_by_uuid(post.uuid)
    end
  end

  defp do_switch_language(socket, new_language) do
    # Cancel any pending autosave before switching language context
    if timer = socket.assigns[:autosave_timer] do
      Process.cancel_timer(timer)
    end

    socket = assign(socket, :autosave_timer, nil)
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug
    content_exists = new_language in post.available_languages

    if content_exists do
      switch_to_existing_language(socket, group_slug, new_language)
    else
      switch_to_new_translation(socket, post, group_slug, new_language)
    end
  end

  defp switch_to_existing_language(socket, group_slug, target_language) do
    # Set loading state first, then defer the actual patch so LiveView
    # sends the skeleton-visible diff before starting the patch round-trip.
    send(self(), {:deferred_language_switch, group_slug, target_language})

    {:noreply, assign(socket, :editor_loading, true)}
  end

  defp switch_to_new_translation(socket, post, group_slug, new_language) do
    current_version = socket.assigns.current_version || 1

    virtual_post =
      Helpers.build_virtual_translation(post, group_slug, new_language, socket)

    available_versions = socket.assigns.available_versions || []
    new_form_key = PublishingPubSub.generate_form_key(group_slug, virtual_post, :edit)
    old_form_key = socket.assigns[:form_key]
    old_post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

    form = Forms.post_form_with_primary_status(group_slug, virtual_post, current_version)

    socket =
      socket
      |> assign(:post, virtual_post)
      |> Forms.assign_form_with_tracking(form, slug_manually_set: false)
      |> assign(:content, "")
      |> Helpers.assign_current_language(new_language)
      |> assign(
        :viewing_older_version,
        Versions.viewing_older_version?(current_version, available_versions, new_language)
      )
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_translation, true)
      |> assign(:form_key, new_form_key)
      |> push_event("changes-status", %{has_changes: false})

    socket =
      Collaborative.cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key,
        old_post_slug: old_post_slug
      )

    url =
      Helpers.build_edit_url(group_slug, post, lang: new_language, version: current_version)

    {:noreply,
     socket
     |> assign(:editor_loading, true)
     |> push_patch(to: url, replace: true)}
  end

  defp handle_media_selected(socket, file_ids) do
    file_uuid = List.first(file_ids)
    inserting_image_component = Map.get(socket.assigns, :inserting_image_component, false)

    {socket, autosave?} =
      cond do
        file_uuid && inserting_image_component ->
          file_url = Helpers.get_file_url(file_uuid)

          js_code =
            "window.publishingEditorInsertMedia && window.publishingEditorInsertMedia(#{Jason.encode!(file_url)}, 'image')"

          {
            socket
            |> assign(:show_media_selector, false)
            |> assign(:inserting_image_component, false)
            |> put_flash(:info, gettext("Image component inserted"))
            |> push_event("exec-js", %{js: js_code}),
            false
          }

        file_uuid ->
          {
            socket
            |> assign(:form, Forms.update_form_with_media(socket.assigns.form, file_uuid))
            |> assign(:has_pending_changes, true)
            |> assign(:show_media_selector, false)
            |> put_flash(:info, gettext("Featured image selected"))
            |> push_event("changes-status", %{has_changes: true}),
            true
          }

        true ->
          {socket |> assign(:show_media_selector, false), false}
      end

    socket = if autosave?, do: schedule_autosave(socket), else: socket

    {:noreply, socket}
  end
end
