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

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

  # Submodule aliases
  alias PhoenixKit.Modules.Publishing.Web.Editor.Collaborative
  alias PhoenixKit.Modules.Publishing.Web.Editor.Forms
  alias PhoenixKit.Modules.Publishing.Web.Editor.Helpers
  alias PhoenixKit.Modules.Publishing.Web.Editor.Persistence
  alias PhoenixKit.Modules.Publishing.Web.Editor.Preview
  alias PhoenixKit.Modules.Publishing.Web.Editor.Translation
  alias PhoenixKit.Modules.Publishing.Web.Editor.Versions

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

  defdelegate build_editor_languages(post, group_slug, enabled_languages, current_language),
    to: Helpers

  # ============================================================================
  # Mount
  # ============================================================================

  @impl true
  def mount(params, _session, socket) do
    group_slug = params["group"] || params["category"] || params["type"]

    live_source =
      socket.id ||
        "blog-editor-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    socket =
      socket
      |> assign(:project_title, Settings.get_project_title())
      |> assign(:page_title, "Publishing Editor")
      |> assign(:group_slug, group_slug)
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_mode, :single)
      |> assign(:media_selected_ids, MapSet.new())
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
      |> assign(:ai_enabled, Translation.ai_translation_available?())
      |> assign(:ai_endpoints, Translation.list_ai_endpoints())
      |> assign(:ai_selected_endpoint_id, Translation.get_default_ai_endpoint_id())
      |> assign(:ai_translation_status, nil)
      |> assign(:ai_translation_progress, nil)
      |> assign(:ai_translation_total, nil)
      |> assign(:ai_translation_languages, [])
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
  def handle_params(%{"preview_token" => token} = params, uri, socket) do
    endpoint = socket.endpoint || PhoenixKitWeb.Endpoint

    case Phoenix.Token.verify(endpoint, "blog-preview", token, max_age: 300) do
      {:ok, data} ->
        old_form_key = socket.assigns[:form_key]
        old_post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

        socket =
          socket
          |> Preview.apply_preview_payload(data)
          |> assign(:preview_token, token)
          |> assign(:current_path, Preview.preview_editor_path(socket, data, token, params))

        form_key =
          PublishingPubSub.generate_form_key(
            socket.assigns.group_slug,
            socket.assigns.post,
            if(socket.assigns.is_new_post, do: :new, else: :edit)
          )

        socket = assign(socket, :form_key, form_key)

        socket =
          Collaborative.setup_collaborative_editing(socket, form_key,
            old_form_key: old_form_key,
            old_post_slug: old_post_slug
          )

        socket =
          push_event(socket, "changes-status", %{
            has_changes: socket.assigns.has_pending_changes
          })

        {:noreply, socket}

      {:error, _reason} ->
        handle_params(Map.delete(params, "preview_token"), uri, socket)
    end
  end

  # Match both /admin/publishing/:group/new route AND legacy ?new=true
  def handle_params(params, _uri, %{assigns: %{live_action: :new}} = socket)
      when not is_map_key(params, "preview_token") do
    case ensure_db_mode(socket) do
      {:ok, socket} -> handle_new_post(socket)
      {:redirect, socket} -> {:noreply, socket}
    end
  end

  def handle_params(%{"new" => "true"} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    case ensure_db_mode(socket) do
      {:ok, socket} -> handle_new_post(socket)
      {:redirect, socket} -> {:noreply, socket}
    end
  end

  # UUID-based route: /admin/publishing/:group/:post_uuid/edit
  def handle_params(%{"post_uuid" => post_uuid} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    case ensure_db_mode(socket) do
      {:redirect, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        handle_uuid_post_params(socket, post_uuid, params)
    end
  end

  def handle_params(%{"path" => path} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    case ensure_db_mode(socket) do
      {:redirect, socket} ->
        {:noreply, socket}

      {:ok, socket} ->
        handle_path_post_params(socket, path, params)
    end
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  # Ensures the editor is in DB mode. Fresh installs (no FS posts) auto-flip to DB.
  # Existing FS posts require migration before editing is allowed.
  defp ensure_db_mode(socket) do
    cond do
      Publishing.db_storage?() ->
        {:ok, socket}

      Publishing.db_storage_direct?() ->
        # Cache was stale — DB says "db" mode, refresh cache and proceed
        {:ok, socket}

      not Publishing.has_any_fs_posts?() ->
        # Fresh install — no FS posts, auto-enable DB mode
        Publishing.enable_db_storage!()
        {:ok, socket}

      true ->
        group_slug = socket.assigns.group_slug

        {:redirect,
         socket
         |> put_flash(
           :error,
           gettext(
             "Posts must be migrated to the database before editing. Import your posts from the Publishing admin."
           )
         )
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  defp handle_uuid_post_params(socket, post_uuid, params) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)

    version = parse_version_param(params["v"])
    language = params["lang"]

    case Publishing.read_post_by_uuid(post_uuid, language, version) do
      {:ok, post} ->
        all_enabled_languages = Storage.enabled_language_codes()

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
              post.path,
              all_enabled_languages
            )
          else
            handle_existing_post_params(
              socket,
              post,
              group_slug,
              group_mode,
              post.path,
              all_enabled_languages
            )
          end

        socket =
          Collaborative.setup_collaborative_editing(socket, form_key,
            old_form_key: old_form_key,
            old_post_slug: old_post_slug
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  defp handle_path_post_params(socket, path, params) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)

    case Publishing.read_post(group_slug, path) do
      {:ok, post} ->
        all_enabled_languages = Storage.enabled_language_codes()
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
              path,
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
          Collaborative.setup_collaborative_editing(socket, form_key,
            old_form_key: old_form_key,
            old_post_slug: old_post_slug
          )

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(to: Routes.path("/admin/publishing/#{group_slug}"))}
    end
  end

  defp handle_new_post(socket) do
    group_slug = socket.assigns.group_slug
    group_mode = Publishing.get_group_mode(group_slug)
    all_enabled_languages = Storage.enabled_language_codes()
    primary_language = Storage.get_primary_language()

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> Forms.floor_datetime_to_minute()
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
         _path,
         all_enabled_languages
       ) do
    # DB-only: no FS path needed
    new_path = nil
    original_id = post.slug

    current_version = Map.get(post, :version, 1)

    virtual_post =
      post
      |> Map.put(:original_language, post.language)
      |> Map.put(:path, new_path)
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
      |> assign(:original_post_path, original_id)
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

    sock =
      socket
      |> assign(:group_mode, group_mode)
      |> assign(:post, %{post | group: group_slug})
      |> assign(:group_name, Publishing.group_name(group_slug) || group_slug)
      |> Forms.assign_form_with_tracking(form)
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
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      params = params |> Map.drop(["_target"])
      params = Forms.preserve_auto_url_slug(params, socket)

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

      has_changes = Forms.dirty?(socket.assigns.post, new_form, socket.assigns.content)

      language = Helpers.editor_language(socket.assigns)
      new_status = new_form["status"]

      # Update both metadata.status and language_statuses for the current language
      # This ensures the language switcher reflects the user's selection immediately
      current_language_statuses = Map.get(socket.assigns.post, :language_statuses, %{})
      updated_language_statuses = Map.put(current_language_statuses, language, new_status)

      updated_post =
        socket.assigns.post
        |> Map.put(:metadata, Map.merge(socket.assigns.post.metadata, %{status: new_status}))
        |> Map.put(:language_statuses, updated_language_statuses)

      public_url = Helpers.build_public_url(updated_post, language)

      socket =
        socket
        |> assign(:form, new_form)
        |> assign(:post, updated_post)
        |> assign(:slug_manually_set, slug_manually_set)
        |> assign(:url_slug_manually_set, url_slug_manually_set)
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
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      {socket, new_form, slug_events} = Forms.maybe_update_slug_from_content(socket, content)

      has_changes = Forms.dirty?(socket.assigns.post, new_form, content)

      socket =
        socket
        |> assign(:content, content)
        |> assign(:form, new_form)
        |> assign(:has_pending_changes, has_changes)
        |> push_event("changes-status", %{has_changes: has_changes})

      socket = Forms.push_slug_events(socket, slug_events)
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

  def handle_event("save", _params, socket) when socket.assigns.has_pending_changes == false do
    is_new = socket.assigns[:is_new_post] || socket.assigns[:is_new_translation]

    if is_new do
      Persistence.perform_save(socket)
    else
      {:noreply, socket}
    end
  end

  def handle_event("save", _params, %{assigns: %{readonly?: true}} = socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}
  end

  def handle_event("save", _params, socket) do
    Persistence.perform_save(socket)
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

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
      updated_form = Map.put(socket.assigns.form, "featured_image_id", "")

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

  def handle_event("select_ai_endpoint", %{"endpoint_id" => endpoint_id}, socket) do
    # endpoint_id can be UUID or integer - AI module handles both
    endpoint_id = if endpoint_id == "", do: nil, else: endpoint_id

    {:noreply, assign(socket, :ai_selected_endpoint_id, endpoint_id)}
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
          {socket, old_form_key, old_post_slug, new_form_key, actual_language, _new_path} =
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
      primary_language = Storage.get_primary_language()
      language_name = Helpers.get_language_name(primary_language)

      case Publishing.update_post_primary_language(group_slug, post.slug, primary_language) do
        :ok ->
          Persistence.regenerate_listing_cache(group_slug)

          updated_post = Map.put(post, :primary_language, primary_language)
          enabled_languages = socket.assigns[:all_enabled_languages] || []

          editor_languages =
            Helpers.build_editor_languages(
              updated_post,
              group_slug,
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
    preview_payload = Preview.build_preview_payload(socket)
    endpoint = socket.endpoint || PhoenixKitWeb.Endpoint
    token = Phoenix.Token.sign(endpoint, "blog-preview", preview_payload, max_age: 300)

    query_params = Preview.build_preview_query_params(preview_payload, token)

    query_string =
      case URI.encode_query(query_params) do
        "" -> ""
        encoded -> "?" <> encoded
      end

    {:noreply,
     push_navigate(socket,
       to: Routes.path("/admin/publishing/#{socket.assigns.group_slug}/preview#{query_string}")
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
  def handle_info(:autosave, socket) do
    if socket.assigns.has_pending_changes do
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
  end

  # ============================================================================
  # Handle Info - Media
  # ============================================================================

  def handle_info({:media_selected, file_ids}, socket) do
    if socket.assigns[:readonly?] do
      {:noreply, assign(socket, :show_media_selector, false)}
    else
      handle_media_selected(socket, file_ids)
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

    has_changes = Forms.dirty?(socket.assigns.post, new_form, content)

    socket =
      socket
      |> assign(:content, content)
      |> assign(:form, new_form)
      |> assign(:has_pending_changes, has_changes)
      |> push_event("changes-status", %{has_changes: has_changes})
      |> Forms.push_slug_events(slug_events)

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
        socket =
          case re_read_post(socket) do
            {:ok, post} ->
              form = Forms.post_form(post)

              socket
              |> assign(:post, %{post | group: socket.assigns.group_slug})
              |> Forms.assign_form_with_tracking(form)
              |> assign(:content, post.content)
              |> assign(:has_pending_changes, false)
              |> push_event("changes-status", %{has_changes: false})
              |> Collaborative.maybe_start_lock_expiration_timer()

            {:error, _} ->
              socket
          end

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

  def handle_info({:translation_started, group_slug, post_slug, target_languages}, socket) do
    if socket.assigns[:group_slug] == group_slug &&
         socket.assigns[:post] &&
         socket.assigns.post[:slug] == post_slug do
      {:noreply,
       socket
       |> assign(:ai_translation_status, :in_progress)
       |> assign(:ai_translation_progress, 0)
       |> assign(:ai_translation_total, length(target_languages))
       |> assign(:ai_translation_languages, target_languages)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:translation_progress, group_slug, post_slug, completed, total, _last_language},
        socket
      ) do
    if socket.assigns[:group_slug] == group_slug &&
         socket.assigns[:post] &&
         socket.assigns.post[:slug] == post_slug do
      socket =
        socket
        |> assign(:ai_translation_progress, completed)
        |> assign(:ai_translation_total, total)
        |> Persistence.refresh_available_languages()

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_completed, group_slug, post_slug, results}, socket) do
    if socket.assigns[:group_slug] == group_slug &&
         socket.assigns[:post] &&
         socket.assigns.post[:slug] == post_slug do
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

      socket =
        if current_language in succeeded_languages do
          Persistence.reload_translated_content(socket, flash_msg, flash_level)
        else
          socket
          |> Persistence.refresh_available_languages()
          |> put_flash(flash_level, flash_msg)
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:translation_created, group_slug, post_slug, language}, socket) do
    if socket.assigns[:group_slug] == group_slug &&
         socket.assigns[:post] &&
         socket.assigns.post[:slug] == post_slug do
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

  def handle_info({:translation_deleted, group_slug, post_slug, language}, socket) do
    if socket.assigns[:group_slug] == group_slug &&
         socket.assigns[:post] &&
         socket.assigns.post[:slug] == post_slug do
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

  def handle_info({:post_version_created, group_slug, post_slug, version_info}, socket) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug &&
        socket.assigns[:post] &&
        socket.assigns.post[:slug] == post_slug

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

  def handle_info({:post_version_deleted, group_slug, post_slug, deleted_version}, socket) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug &&
        socket.assigns[:post] &&
        socket.assigns.post[:slug] == post_slug

    if is_our_post do
      {:noreply, Versions.handle_version_deleted(socket, group_slug, post_slug, deleted_version)}
    else
      {:noreply, socket}
    end
  end

  # Handle version published with source_id (user ID)
  def handle_info(
        {:post_version_published, group_slug, post_slug, published_version, source_user_id},
        socket
      ) do
    is_our_post =
      socket.assigns[:group_slug] == group_slug &&
        socket.assigns[:post] &&
        socket.assigns.post[:slug] == post_slug

    # Ignore if same user published (works across all their tabs)
    our_user_id =
      get_in(socket.assigns, [:phoenix_kit_current_scope, Access.key(:user), Access.key(:id)])

    from_us = source_user_id != nil && source_user_id == our_user_id

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

  defp schedule_autosave(socket) do
    if socket.assigns.autosave_timer do
      Process.cancel_timer(socket.assigns.autosave_timer)
    end

    timer_ref = Process.send_after(self(), :autosave, 2000)
    assign(socket, :autosave_timer, timer_ref)
  end

  defp re_read_post(socket) do
    post = socket.assigns.post
    Publishing.read_post_by_uuid(post.uuid)
  end

  defp do_switch_language(socket, new_language) do
    post = socket.assigns.post
    group_slug = socket.assigns.group_slug
    file_exists = new_language in post.available_languages

    if file_exists do
      switch_to_existing_language(socket, group_slug, new_language)
    else
      switch_to_new_translation(socket, post, group_slug, new_language)
    end
  end

  defp switch_to_existing_language(socket, group_slug, target_language) do
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

  defp switch_to_new_translation(socket, post, group_slug, new_language) do
    current_version = socket.assigns.current_version || 1

    # DB-only: no FS path needed
    new_path = nil

    virtual_post =
      Helpers.build_virtual_translation(post, group_slug, new_language, new_path, socket)

    available_versions = socket.assigns.available_versions || []
    new_form_key = PublishingPubSub.generate_form_key(group_slug, virtual_post, :edit)
    old_form_key = socket.assigns[:form_key]
    old_post_slug = socket.assigns[:post] && socket.assigns.post[:slug]

    form = Forms.post_form_with_primary_status(group_slug, virtual_post, current_version)

    original_id = post.slug

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
      |> assign(:original_post_path, original_id)
      |> assign(:form_key, new_form_key)
      |> push_event("changes-status", %{has_changes: false})

    socket =
      Collaborative.cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key,
        old_post_slug: old_post_slug
      )

    url =
      Helpers.build_edit_url(group_slug, post, lang: new_language, version: current_version)

    {:noreply, push_patch(socket, to: url, replace: true)}
  end

  defp handle_media_selected(socket, file_ids) do
    file_id = List.first(file_ids)
    inserting_image_component = Map.get(socket.assigns, :inserting_image_component, false)

    {socket, autosave?} =
      cond do
        file_id && inserting_image_component ->
          file_url = Helpers.get_file_url(file_id)

          js_code =
            "window.publishingEditorInsertMedia && window.publishingEditorInsertMedia('#{file_url}', 'image')"

          {
            socket
            |> assign(:show_media_selector, false)
            |> assign(:inserting_image_component, false)
            |> put_flash(:info, gettext("Image component inserted"))
            |> push_event("exec-js", %{js: js_code}),
            false
          }

        file_id ->
          {
            socket
            |> assign(:form, Forms.update_form_with_media(socket.assigns.form, file_id))
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
