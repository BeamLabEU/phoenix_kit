defmodule PhoenixKit.Modules.Publishing.Web.Editor do
  @moduledoc """
  Markdown editor for publishing posts.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  # Suppress dialyzer warnings for pattern matches in create_new_post/create_new_translation
  # where dialyzer incorrectly infers that {:ok, _} patterns can never match.
  # The Publishing context functions do return {:ok, _} on success.
  @dialyzer {:nowarn_function, create_new_post: 2}
  @dialyzer {:nowarn_function, create_new_translation: 2}
  @dialyzer {:nowarn_function, handle_post_update_error: 2}
  @dialyzer {:nowarn_function, handle_post_update_result: 4}
  @dialyzer {:nowarn_function, handle_event: 3}

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Metadata
  alias PhoenixKit.Modules.Publishing.PresenceHelpers
  alias PhoenixKit.Modules.Publishing.PubSub, as: PublishingPubSub
  alias PhoenixKit.Modules.Publishing.Renderer
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.BlogHTML

  require Logger

  @impl true
  def mount(params, _session, socket) do
    # Attach locale hook for automatic locale handling

    blog_slug = params["blog"] || params["category"] || params["type"]

    # Generate a unique source ID for this socket to prevent self-echoing
    live_source =
      socket.id ||
        "blog-editor-" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

    socket =
      socket
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Publishing Editor")
      |> assign(:blog_slug, blog_slug)
      |> assign(:blog_name, Publishing.group_name(blog_slug) || blog_slug)
      |> assign(:show_media_selector, false)
      |> assign(:media_selection_mode, :single)
      |> assign(:media_selected_ids, MapSet.new())
      |> assign(:is_autosaving, false)
      |> assign(:autosave_timer, nil)
      |> assign(:slug_manually_set, false)
      |> assign(:last_auto_slug, "")
      # Collaborative editing assigns
      |> assign(:live_source, live_source)
      |> assign(:form_key, nil)
      |> assign(:lock_owner?, true)
      |> assign(:readonly?, false)
      |> assign(:lock_owner_user, nil)
      |> assign(:spectators, [])
      |> assign(:other_viewers, [])
      # Default editor form/content assigns (will be overridden by handle_params)
      |> assign(:form, %{})
      |> assign(:post, nil)
      |> assign(:content, "")
      |> assign(:blog_mode, nil)
      |> assign(:current_language, nil)
      |> assign(:current_language_enabled, true)
      |> assign(:current_language_known, true)
      |> assign(:is_master_language, true)
      |> assign(:available_languages, [])
      |> assign(:all_enabled_languages, [])
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_post, false)
      |> assign(:is_new_translation, false)
      |> assign(:public_url, nil)
      # Version-related assigns
      |> assign(:current_version, nil)
      |> assign(:available_versions, [])
      |> assign(:version_statuses, %{})
      |> assign(:version_dates, %{})
      |> assign(:editing_published_version, false)
      |> assign(:viewing_older_version, false)
      # New Version modal assigns
      |> assign(:show_new_version_modal, false)
      |> assign(:new_version_source, nil)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{blog_slug}/edit",
          locale: socket.assigns.current_locale_base
        )
      )

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"preview_token" => token} = params, uri, socket) do
    endpoint = socket.endpoint || PhoenixKitWeb.Endpoint

    case Phoenix.Token.verify(endpoint, "blog-preview", token, max_age: 300) do
      {:ok, data} ->
        socket =
          socket
          |> apply_preview_payload(data)
          |> assign(:preview_token, token)
          |> assign(:current_path, preview_editor_path(socket, data, token, params))
          |> push_event("changes-status", %{has_changes: true})

        {:noreply, socket}

      {:error, _reason} ->
        handle_params(Map.delete(params, "preview_token"), uri, socket)
    end
  end

  def handle_params(%{"new" => "true"}, _uri, socket) do
    blog_slug = socket.assigns.blog_slug
    blog_mode = Publishing.get_group_mode(blog_slug)
    all_enabled_languages = Storage.enabled_language_codes()
    primary_language = hd(all_enabled_languages)

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> floor_datetime_to_minute()
    virtual_post = build_virtual_post(blog_slug, blog_mode, primary_language, now)

    form = post_form(virtual_post)

    # Generate form key for new post (for collaborative editing)
    form_key = PublishingPubSub.generate_form_key(blog_slug, virtual_post, :new)

    socket =
      socket
      |> assign(:blog_mode, blog_mode)
      |> assign(:post, virtual_post)
      |> assign(:blog_name, Publishing.group_name(blog_slug) || blog_slug)
      |> assign_form_with_tracking(form, slug_manually_set: false)
      |> assign(:content, "")
      |> assign(:available_languages, virtual_post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> assign_current_language(primary_language)
      |> assign(
        :current_path,
        Routes.path("/admin/publishing/#{blog_slug}/edit?new=true",
          locale: socket.assigns.current_locale_base
        )
      )
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_post, true)
      |> assign(:public_url, nil)
      |> assign(:form_key, form_key)
      # New posts start at version 1
      |> assign(:current_version, 1)
      |> assign(:available_versions, [])
      |> assign(:version_statuses, %{})
      |> assign(:version_dates, %{})
      |> assign(:editing_published_version, false)
      |> push_event("changes-status", %{has_changes: false})

    # Set up collaborative editing for new posts
    socket = setup_collaborative_editing(socket, form_key)

    {:noreply, socket}
  end

  def handle_params(%{"path" => path} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    blog_slug = socket.assigns.blog_slug
    blog_mode = Publishing.get_group_mode(blog_slug)

    case Publishing.read_post(blog_slug, path) do
      {:ok, post} ->
        all_enabled_languages = Storage.enabled_language_codes()
        switch_to_lang = Map.get(params, "switch_to")

        {socket, form_key} =
          if switch_to_lang && switch_to_lang not in post.available_languages do
            new_path =
              path
              |> Path.dirname()
              |> Path.join("#{switch_to_lang}.phk")

            virtual_post =
              post
              |> Map.put(:path, new_path)
              |> Map.put(:language, switch_to_lang)
              |> Map.put(:blog, blog_slug)
              |> Map.put(:content, "")
              |> Map.put(:metadata, Map.put(post.metadata, :title, ""))
              |> Map.put(:mode, post.mode)
              |> Map.put(:slug, post.slug)

            form = post_form(virtual_post)
            fk = PublishingPubSub.generate_form_key(blog_slug, virtual_post, :edit)

            # Recalculate viewing_older_version for the new translation language
            # Translations (non-master languages) should not be locked
            current_version = Map.get(post, :version, 1)
            available_versions = Map.get(post, :available_versions, [])

            sock =
              socket
              |> assign(:blog_mode, blog_mode)
              |> assign(:post, virtual_post)
              |> assign(:blog_name, Publishing.group_name(blog_slug) || blog_slug)
              |> assign_form_with_tracking(form, slug_manually_set: false)
              |> assign(:content, "")
              |> assign(:available_languages, post.available_languages)
              |> assign(:all_enabled_languages, all_enabled_languages)
              |> assign_current_language(switch_to_lang)
              |> assign(
                :current_path,
                Routes.path(
                  "/admin/publishing/#{blog_slug}/edit?path=#{URI.encode_www_form(new_path)}",
                  locale: socket.assigns.current_locale_base
                )
              )
              |> assign(:current_version, current_version)
              |> assign(:available_versions, available_versions)
              |> assign(:version_statuses, Map.get(post, :version_statuses, %{}))
              |> assign(:version_dates, Map.get(post, :version_dates, %{}))
              |> assign(
                :viewing_older_version,
                viewing_older_version?(current_version, available_versions, switch_to_lang)
              )
              |> assign(:has_pending_changes, false)
              |> assign(:is_new_translation, true)
              |> assign(:original_post_path, path)
              |> assign(:public_url, nil)
              |> assign(:form_key, fk)
              |> push_event("changes-status", %{has_changes: false})

            {sock, fk}
          else
            form = post_form(post)
            fk = PublishingPubSub.generate_form_key(blog_slug, post, :edit)

            # Check if we're editing a published version
            is_published = Map.get(post.metadata, :status) == "published"

            sock =
              socket
              |> assign(:blog_mode, blog_mode)
              |> assign(:post, %{post | group: blog_slug})
              |> assign(:blog_name, Publishing.group_name(blog_slug) || blog_slug)
              |> assign_form_with_tracking(form)
              |> assign(:content, post.content)
              |> assign(:available_languages, post.available_languages)
              |> assign(:all_enabled_languages, all_enabled_languages)
              |> assign_current_language(post.language)
              |> assign(
                :current_path,
                Routes.path(
                  "/admin/publishing/#{blog_slug}/edit?path=#{URI.encode_www_form(path)}",
                  locale: socket.assigns.current_locale_base
                )
              )
              |> assign(:has_pending_changes, false)
              |> assign(:public_url, build_public_url(post, post.language))
              |> assign(:form_key, fk)
              # Version-related assigns
              |> assign(:current_version, Map.get(post, :version, 1))
              |> assign(:available_versions, Map.get(post, :available_versions, []))
              |> assign(:version_statuses, Map.get(post, :version_statuses, %{}))
              |> assign(:version_dates, Map.get(post, :version_dates, %{}))
              |> assign(:editing_published_version, is_published)
              |> assign(
                :viewing_older_version,
                viewing_older_version?(
                  Map.get(post, :version, 1),
                  Map.get(post, :available_versions, []),
                  post.language
                )
              )
              |> push_event("changes-status", %{has_changes: false})

            {sock, fk}
          end

        # Set up collaborative editing
        socket = setup_collaborative_editing(socket, form_key)

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(
           to:
             Routes.path("/admin/publishing/#{blog_slug}",
               locale: socket.assigns.current_locale_base
             )
         )}
    end
  end

  # Catch-all for other param combinations (shouldn't normally be reached)
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_meta", params, socket) do
    # Spectators cannot edit
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      params =
        params
        |> Map.drop(["_target"])

      # No real-time validation - accept any input, validation happens on save
      new_form =
        socket.assigns.form
        |> Map.merge(params)
        |> normalize_form()

      slug_manually_set =
        if Map.has_key?(params, "slug") do
          slug_value = Map.get(new_form, "slug", "")
          slug_value != "" && slug_value != socket.assigns.last_auto_slug
        else
          socket.assigns.slug_manually_set
        end

      has_changes = dirty?(socket.assigns.post, new_form, socket.assigns.content)

      # Update public_url if status changed
      updated_post = %{
        socket.assigns.post
        | metadata: Map.merge(socket.assigns.post.metadata, %{status: new_form["status"]})
      }

      language = editor_language(socket.assigns)
      public_url = build_public_url(updated_post, language)

      socket =
        socket
        |> assign(:form, new_form)
        |> assign(:slug_manually_set, slug_manually_set)
        |> assign(:has_pending_changes, has_changes)
        |> assign(:public_url, public_url)
        |> clear_flash()
        |> push_event("changes-status", %{has_changes: has_changes})

      # Trigger debounced autosave if changes detected
      socket =
        if has_changes do
          schedule_autosave(socket)
        else
          socket
        end

      {:noreply, socket}
    end
  end

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
    # Spectators cannot edit
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      # Clear the featured image from the form (form is a simple map, not a struct)
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

  def handle_event("generate_slug_from_content", _params, socket) do
    # Only generate slug if in slug mode and slug is empty
    if socket.assigns.blog_mode == "slug" do
      content = socket.assigns.content || ""

      {socket, new_form, slug_events} =
        maybe_update_slug_from_content(socket, content, force: true)

      has_changes = dirty?(socket.assigns.post, new_form, socket.assigns.content)

      {:noreply,
       socket
       |> assign(:form, new_form)
       |> assign(:has_pending_changes, has_changes)
       |> push_event("changes-status", %{has_changes: has_changes})
       |> push_slug_events(slug_events)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_content", %{"content" => content}, socket) do
    # Spectators cannot edit
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      {socket, new_form, slug_events} = maybe_update_slug_from_content(socket, content)

      has_changes = dirty?(socket.assigns.post, new_form, content)

      socket =
        socket
        |> assign(:content, content)
        |> assign(:form, new_form)
        |> assign(:has_pending_changes, has_changes)
        |> push_event("changes-status", %{has_changes: has_changes})

      socket =
        push_slug_events(socket, slug_events)

      # Trigger debounced autosave if changes detected
      socket =
        if has_changes do
          schedule_autosave(socket)
        else
          socket
        end

      {:noreply, socket}
    end
  end

  def handle_event("save", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, %{assigns: %{readonly?: true}} = socket) do
    {:noreply, put_flash(socket, :error, gettext("Cannot save - you are spectating"))}
  end

  def handle_event("save", _params, socket) do
    perform_save(socket)
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_version_access", %{"enabled" => enabled_str}, socket) do
    # Spectators cannot edit
    if socket.assigns[:readonly?] do
      {:noreply, socket}
    else
      enabled = enabled_str == "true"
      post = socket.assigns.post
      blog_slug = socket.assigns.blog_slug

      # Update the metadata with the new setting
      updated_metadata = Map.put(post.metadata, :allow_version_access, enabled)
      updated_post = %{post | metadata: updated_metadata}

      # Save the change to disk
      scope = socket.assigns[:phoenix_kit_current_scope]
      params = %{"allow_version_access" => enabled}

      case Publishing.update_post(blog_slug, updated_post, params, %{scope: scope}) do
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

  def handle_event("preview", _params, socket) do
    preview_payload = build_preview_payload(socket)
    endpoint = socket.endpoint || PhoenixKitWeb.Endpoint
    token = Phoenix.Token.sign(endpoint, "blog-preview", preview_payload, max_age: 300)

    query_params =
      %{"preview_token" => token}
      |> maybe_put_preview_path(preview_payload.path)
      |> maybe_put_preview_new_flag(preview_payload)

    query_string =
      case URI.encode_query(query_params) do
        "" -> ""
        encoded -> "?" <> encoded
      end

    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/publishing/#{socket.assigns.blog_slug}/preview#{query_string}",
           locale: socket.assigns.current_locale_base
         )
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
     |> push_navigate(
       to:
         Routes.path("/admin/publishing/#{socket.assigns.blog_slug}",
           locale: socket.assigns.current_locale_base
         )
     )}
  end

  def handle_event("back_to_list", _params, socket) do
    handle_event("attempt_cancel", %{}, socket)
  end

  def handle_event("switch_language", %{"language" => new_language}, socket) do
    post = socket.assigns.post
    blog_slug = socket.assigns.blog_slug

    base_dir = slug_base_dir(post, blog_slug)
    new_path = Path.join(base_dir, "#{new_language}.phk")

    file_exists = new_language in post.available_languages

    if file_exists do
      # Clean up old presence before switching to existing language file
      old_form_key = socket.assigns[:form_key]

      if old_form_key && connected?(socket) do
        PresenceHelpers.untrack_editing_session(old_form_key, socket)
        PresenceHelpers.unsubscribe_from_editing(old_form_key)
        PublishingPubSub.unsubscribe_from_editor_form(old_form_key)
      end

      {:noreply,
       push_patch(socket,
         to:
           Routes.path(
             "/admin/publishing/#{blog_slug}/edit?path=#{URI.encode(new_path)}",
             locale: socket.assigns.current_locale_base
           )
       )}
    else
      virtual_post =
        post
        |> Map.put(:path, new_path)
        |> Map.put(:language, new_language)
        |> Map.put(:blog, blog_slug || "blog")
        |> Map.put(:content, "")
        |> Map.put(:metadata, Map.put(post.metadata, :title, ""))
        |> Map.put(:mode, post.mode)
        |> Map.put(:slug, post.slug || Map.get(socket.assigns.form, "slug"))

      # Recalculate viewing_older_version for the new language
      # Translations (non-master languages) should not be locked
      current_version = socket.assigns.current_version || 1
      available_versions = socket.assigns.available_versions || []

      # Generate new form_key for the new language
      new_form_key = PublishingPubSub.generate_form_key(blog_slug, virtual_post, :edit)

      # Save old form_key BEFORE assigning new one (for presence cleanup)
      old_form_key = socket.assigns[:form_key]

      socket =
        socket
        |> assign(:post, virtual_post)
        |> assign_form_with_tracking(post_form(virtual_post), slug_manually_set: false)
        |> assign(:content, "")
        |> assign_current_language(new_language)
        |> assign(
          :viewing_older_version,
          viewing_older_version?(current_version, available_versions, new_language)
        )
        |> assign(:has_pending_changes, false)
        |> assign(:is_new_translation, true)
        |> assign(:original_post_path, post.path || post.slug)
        |> assign(:form_key, new_form_key)
        |> push_event("changes-status", %{has_changes: false})

      # Clean up old presence and set up new (pass old_form_key explicitly)
      socket = cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key)

      # Update the URL to reflect the new language using switch_to parameter
      # (since the new translation file doesn't exist yet)
      original_path = socket.assigns[:original_post_path] || post.path || post.slug

      {:noreply,
       push_patch(socket,
         to:
           Routes.path(
             "/admin/publishing/#{blog_slug}/edit?path=#{URI.encode(original_path)}&switch_to=#{new_language}",
             locale: socket.assigns.current_locale_base
           ),
         replace: true
       )}
    end
  end

  def handle_event("switch_version", %{"version" => version_str}, socket) do
    version = String.to_integer(version_str)
    current_version = socket.assigns.current_version

    if version == current_version do
      {:noreply, socket}
    else
      blog_slug = socket.assigns.blog_slug
      post = socket.assigns.post
      language = socket.assigns.current_language
      blog_mode = socket.assigns.blog_mode
      master_language = Storage.get_master_language()

      # Read the specified version based on blog mode
      # Try current language first, then fall back to master language
      read_result =
        case blog_mode do
          "slug" ->
            case Publishing.read_post(blog_slug, post.slug, language, version) do
              {:ok, _} = result ->
                result

              {:error, _} when language != master_language ->
                # Fall back to master language
                Publishing.read_post(blog_slug, post.slug, master_language, version)

              error ->
                error
            end

          _ ->
            # For timestamp mode, build the versioned path
            case read_timestamp_version(blog_slug, post, language, version) do
              {:ok, _} = result ->
                result

              {:error, _} when language != master_language ->
                # Fall back to master language
                read_timestamp_version(blog_slug, post, master_language, version)

              error ->
                error
            end
        end

      case read_result do
        {:ok, version_post} ->
          form = post_form(version_post)
          is_published = Map.get(version_post.metadata, :status) == "published"
          actual_language = version_post.language

          # Generate new form_key for the new version
          new_form_key = PublishingPubSub.generate_form_key(blog_slug, version_post, :edit)

          # Save old form_key BEFORE assigning new one (for presence cleanup)
          old_form_key = socket.assigns[:form_key]

          socket =
            socket
            |> assign(:post, %{version_post | group: blog_slug})
            |> assign_form_with_tracking(form)
            |> assign(:content, version_post.content)
            |> assign(:current_version, version)
            |> assign(:available_versions, version_post.available_versions)
            |> assign(:version_statuses, version_post.version_statuses)
            |> assign(:version_dates, Map.get(version_post, :version_dates, %{}))
            |> assign(:available_languages, version_post.available_languages)
            |> assign(:editing_published_version, is_published)
            |> assign(
              :viewing_older_version,
              viewing_older_version?(version, version_post.available_versions, actual_language)
            )
            |> assign(:has_pending_changes, false)
            |> assign(:public_url, build_public_url(version_post, actual_language))
            |> assign_current_language(actual_language)
            |> assign(:form_key, new_form_key)
            |> push_event("changes-status", %{has_changes: false})
            |> push_event("set-content", %{content: version_post.content})

          # Clean up old presence and set up new (pass old_form_key explicitly)
          socket = cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key)

          # Update URL to reflect the new version's path
          {:noreply,
           push_patch(socket,
             to:
               Routes.path(
                 "/admin/publishing/#{blog_slug}/edit?path=#{URI.encode(version_post.path)}",
                 locale: socket.assigns.current_locale_base
               ),
             replace: true
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Version not found"))}
      end
    end
  end

  # ============================================================================
  # New Version Modal Handlers
  # ============================================================================

  def handle_event("open_new_version_modal", _params, socket) do
    # Only allow opening if we're not a spectator and post exists
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
    blog_slug = socket.assigns.blog_slug
    post = socket.assigns.post
    source_version = socket.assigns.new_version_source
    scope = socket.assigns[:phoenix_kit_current_scope]

    # For timestamp mode, construct the date/time path identifier
    # For slug mode, use the slug directly
    post_identifier =
      case post.mode do
        :timestamp ->
          date_str = Date.to_iso8601(post.date)
          time_str = format_time_folder(post.time)
          "#{date_str}/#{time_str}"

        _ ->
          post.slug
      end

    case Publishing.create_version_from(blog_slug, post_identifier, source_version, %{}, scope: scope) do
      {:ok, new_version_post} ->
        # Navigate to the new version
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

        {:noreply,
         socket
         |> assign(:show_new_version_modal, false)
         |> assign(:new_version_source, nil)
         |> put_flash(:info, flash_msg)
         |> push_navigate(
           to:
             Routes.path(
               "/admin/publishing/#{blog_slug}/edit?path=#{URI.encode(new_path)}",
               locale: socket.assigns.current_locale_base
             )
         )}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:show_new_version_modal, false)
         |> put_flash(
           :error,
           gettext("Failed to create new version: %{reason}", reason: inspect(reason))
         )}
    end
  end

  def handle_event("migrate_to_versioned", _params, socket) do
    post = socket.assigns.post

    if post && post.is_legacy_structure do
      language = socket.assigns.current_language

      case Storage.migrate_post_to_versioned(post, language) do
        {:ok, migrated_post} ->
          # Refresh the form with the migrated post
          form = post_form(migrated_post)

          socket =
            socket
            |> assign(:post, %{migrated_post | group: socket.assigns.blog_slug})
            |> assign_form_with_tracking(form)
            |> assign(:content, migrated_post.content)
            |> assign(:current_version, migrated_post.version)
            |> assign(:available_versions, migrated_post.available_versions)
            |> assign(:version_statuses, migrated_post.version_statuses)
            |> assign(:version_dates, Map.get(migrated_post, :version_dates, %{}))
            |> assign(
              :viewing_older_version,
              viewing_older_version?(
                migrated_post.version,
                migrated_post.available_versions,
                language
              )
            )
            |> assign(:has_pending_changes, false)
            |> push_event("changes-status", %{has_changes: false})
            |> put_flash(:info, gettext("Post migrated to versioned structure (v1)"))
            |> push_patch(
              to:
                Routes.path(
                  "/admin/publishing/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(migrated_post.path)}",
                  locale: socket.assigns.current_locale_base
                )
            )

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Failed to migrate post: %{reason}", reason: inspect(reason))
           )}
      end
    else
      {:noreply, socket}
    end
  end

  # Helper to read a specific version for timestamp-mode posts
  defp read_timestamp_version(blog_slug, post, language, version) do
    # Build the versioned path for timestamp mode
    date_str = Date.to_iso8601(post.date)
    time_str = format_time_folder(post.time)
    versioned_path = Path.join([blog_slug, date_str, time_str, "v#{version}", "#{language}.phk"])

    Storage.read_post(blog_slug, versioned_path)
  end

  defp format_time_folder(%Time{} = time) do
    {hour, minute, _second} = Time.to_erl(time)

    "#{String.pad_leading(to_string(hour), 2, "0")}:#{String.pad_leading(to_string(minute), 2, "0")}"
  end

  @impl true
  def handle_info(:autosave, socket) do
    # Only autosave if there are pending changes
    if socket.assigns.has_pending_changes do
      socket =
        socket
        |> assign(:is_autosaving, true)
        |> assign(:autosave_timer, nil)
        |> push_event("autosave-status", %{saving: true})

      # Perform the save
      {:noreply, updated_socket} = perform_save(socket)

      {:noreply,
       updated_socket
       |> assign(:is_autosaving, false)
       |> push_event("autosave-status", %{saving: false})}
    else
      {:noreply, assign(socket, :autosave_timer, nil)}
    end
  end

  def handle_info({:media_selected, file_ids}, socket) do
    # Spectators cannot edit
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

  # Handle content changes from MarkdownEditor component
  def handle_info({:editor_content_changed, %{content: content}}, socket) do
    {socket, new_form, slug_events} = maybe_update_slug_from_content(socket, content)

    has_changes = dirty?(socket.assigns.post, new_form, content)

    socket =
      socket
      |> assign(:content, content)
      |> assign(:form, new_form)
      |> assign(:has_pending_changes, has_changes)
      |> push_event("changes-status", %{has_changes: has_changes})
      |> push_slug_events(slug_events)

    socket =
      if has_changes do
        schedule_autosave(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  # Handle image insert from MarkdownEditor toolbar
  def handle_info({:editor_insert_component, %{type: :image}}, socket) do
    {:noreply,
     socket
     |> assign(:show_media_selector, true)
     |> assign(:inserting_image_component, true)}
  end

  # Handle video insert from MarkdownEditor toolbar
  def handle_info({:editor_insert_component, %{type: :video}}, socket) do
    {:noreply, push_event(socket, "prompt-and-insert", %{type: "video"})}
  end

  # Catch-all for other MarkdownEditor events
  def handle_info({:editor_insert_component, _}, socket), do: {:noreply, socket}
  def handle_info({:editor_save_requested, _}, socket), do: {:noreply, socket}

  # Handle save broadcasts from other users/tabs (last-save-wins sync)
  def handle_info({:editor_saved, form_key, source}, socket) do
    Logger.debug(
      "EDITOR_SAVED received: form_key=#{inspect(form_key)}, source=#{inspect(source)}, " <>
        "my_form_key=#{inspect(socket.assigns[:form_key])}, my_socket_id=#{inspect(socket.id)}"
    )

    cond do
      # Ignore if no form_key set
      socket.assigns.form_key == nil ->
        Logger.debug("EDITOR_SAVED ignored: no form_key")
        {:noreply, socket}

      # Ignore if different form
      form_key != socket.assigns.form_key ->
        Logger.debug("EDITOR_SAVED ignored: different form_key")
        {:noreply, socket}

      # Ignore our own save broadcast
      source == socket.id ->
        Logger.debug("EDITOR_SAVED ignored: own broadcast")
        {:noreply, socket}

      # Another tab/user saved - reload from disk to get their changes
      true ->
        Logger.debug("EDITOR_SAVED: reloading from disk!")
        socket = reload_post_from_disk(socket)
        {:noreply, socket}
    end
  end

  # Handle presence changes (users joining/leaving)
  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket) do
    if socket.assigns[:form_key] do
      form_key = socket.assigns.form_key
      was_owner = socket.assigns[:lock_owner?]

      # Re-evaluate our role
      socket = assign_editing_role(socket, form_key)

      # If we were promoted from spectator to owner, we can now edit
      if !was_owner && socket.assigns[:lock_owner?] do
        # Reload the post from disk to get fresh state
        socket =
          case Publishing.read_post(socket.assigns.blog_slug, socket.assigns.post.path) do
            {:ok, post} ->
              form = post_form(post)

              socket
              |> assign(:post, %{post | group: socket.assigns.blog_slug})
              |> assign_form_with_tracking(form)
              |> assign(:content, post.content)
              |> assign(:has_pending_changes, false)
              |> push_event("changes-status", %{has_changes: false})

            {:error, _} ->
              socket
          end

        {:noreply, socket}
      else
        {:noreply, socket}
      end
    else
      {:noreply, socket}
    end
  end

  # Handle sync requests from new spectators
  def handle_info({:editor_sync_request, form_key, requester_socket_id}, socket) do
    if socket.assigns[:form_key] == form_key && socket.assigns[:lock_owner?] do
      # Send current state to the requester
      state = %{
        form: socket.assigns.form,
        content: socket.assigns.content
      }

      PublishingPubSub.broadcast_editor_sync_response(form_key, requester_socket_id, state)
    end

    {:noreply, socket}
  end

  # Handle sync responses (when we're a new spectator)
  def handle_info({:editor_sync_response, form_key, requester_socket_id, state}, socket) do
    if socket.assigns[:form_key] == form_key &&
         requester_socket_id == socket.id &&
         socket.assigns.readonly? do
      socket = apply_remote_form_state(socket, state)
      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  # Handle translation created events (update language selector in real-time)
  def handle_info({:translation_created, blog_slug, post_slug, language}, socket) do
    # Only update if this is the same post
    if socket.assigns[:blog_slug] == blog_slug &&
         socket.assigns[:post] &&
         socket.assigns.post[:slug] == post_slug do
      # Refresh available languages by re-reading the post's languages from disk
      case Publishing.read_post(blog_slug, socket.assigns.post.path) do
        {:ok, updated_post} ->
          socket =
            socket
            |> assign(:available_languages, updated_post.available_languages)
            |> assign(
              :post,
              Map.put(socket.assigns.post, :available_languages, updated_post.available_languages)
            )

          {:noreply, socket}

        {:error, _} ->
          # If we can't read (e.g., file deleted), just add the language to available list
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

  # Handle translation deleted events
  def handle_info({:translation_deleted, blog_slug, post_slug, language}, socket) do
    if socket.assigns[:blog_slug] == blog_slug &&
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

  # Helper for handle_info({:media_selected, ...})
  defp handle_media_selected(socket, file_ids) do
    # Handle the selected file IDs from the media selector modal
    file_id = List.first(file_ids)
    inserting_image_component = Map.get(socket.assigns, :inserting_image_component, false)

    {socket, autosave?} =
      cond do
        file_id && inserting_image_component ->
          # Insert image with standard markdown syntax at cursor via JavaScript
          file_url = get_file_url(file_id)

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
            |> assign(:form, update_form_with_media(socket.assigns.form, file_id))
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

  # Get a URL for a file from storage (for standard markdown image syntax)
  defp get_file_url(file_id) do
    URLSigner.signed_url(file_id, "original")
  end

  defp schedule_autosave(socket) do
    # Cancel existing timer if any
    if socket.assigns.autosave_timer do
      Process.cancel_timer(socket.assigns.autosave_timer)
    end

    # Schedule new autosave
    timer_ref = Process.send_after(self(), :autosave, 2000)
    assign(socket, :autosave_timer, timer_ref)
  end

  defp perform_save(socket) do
    params =
      socket.assigns.form
      |> Map.take(["status", "published_at", "slug", "featured_image_id"])
      |> Map.put("content", socket.assigns.content)

    params =
      case {socket.assigns.blog_mode, Map.get(params, "slug")} do
        {"slug", slug} when is_binary(slug) and slug != "" ->
          params

        {"slug", _} ->
          Map.delete(params, "slug")

        _ ->
          Map.delete(params, "slug")
      end

    is_new_post = Map.get(socket.assigns, :is_new_post, false)
    is_new_translation = Map.get(socket.assigns, :is_new_translation, false)

    cond do
      is_new_post ->
        create_new_post(socket, params)

      is_new_translation ->
        create_new_translation(socket, params)

      true ->
        update_existing_post(socket, params)
    end
  end

  defp create_new_post(socket, params) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    create_opts =
      if socket.assigns.blog_mode == "slug" do
        %{
          title: Map.get(params, "title"),
          slug: Map.get(params, "slug")
        }
      else
        %{}
      end
      |> Map.put(:scope, scope)

    case Publishing.create_post(socket.assigns.blog_slug, create_opts) do
      {:ok, new_post} ->
        # Note: Publishing.create_post and update_post handle broadcasts internally
        case Publishing.update_post(socket.assigns.blog_slug, new_post, params, %{scope: scope}) do
          {:ok, _updated_post} = result ->
            handle_post_update_result(socket, result, gettext("Post created and saved"), %{
              is_new_post: false
            })

          error ->
            handle_post_update_result(socket, error, gettext("Post created and saved"), %{
              is_new_post: false
            })
        end

      {:error, error} ->
        handle_post_creation_error(socket, error, gettext("Failed to create post"))
    end
  end

  defp create_new_translation(socket, params) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    original_identifier =
      case socket.assigns.blog_mode do
        "slug" ->
          socket.assigns.post.slug ||
            Map.get(socket.assigns, :original_post_path, socket.assigns.post.path)

        _ ->
          Map.get(socket.assigns, :original_post_path, socket.assigns.post.path)
      end

    # Pass the current version to ensure translation is created in the right version
    current_version = socket.assigns[:current_version]

    case Publishing.add_language_to_post(
           socket.assigns.blog_slug,
           original_identifier,
           socket.assigns.current_language,
           current_version
         ) do
      {:ok, new_post} ->
        # Note: Publishing.add_language_to_post and update_post handle broadcasts internally
        case Publishing.update_post(socket.assigns.blog_slug, new_post, params, %{scope: scope}) do
          {:ok, _updated_post} = result ->
            handle_post_update_result(socket, result, gettext("Translation created and saved"), %{
              is_new_translation: false,
              original_post_path: nil
            })

          error ->
            handle_post_update_result(socket, error, gettext("Translation created and saved"), %{
              is_new_translation: false,
              original_post_path: nil
            })
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create translation file"))}
    end
  end

  defp update_existing_post(socket, params) do
    scope = socket.assigns[:phoenix_kit_current_scope]
    post = socket.assigns.post
    language = socket.assigns.current_language
    old_path = post.path

    # Check if we need to create a new version (editing published content)
    # This applies to both slug-mode and timestamp-mode blogs
    # Only create versions for posts that have been migrated to versioned structure
    should_create_version =
      not Map.get(post, :is_legacy_structure, false) and
        Storage.should_create_new_version?(post, params, language)

    if should_create_version do
      # Create new version instead of updating in place
      create_new_version_from_edit(socket, params, scope)
    else
      update_post_in_place(socket, params, scope, old_path)
    end
  end

  defp create_new_version_from_edit(socket, params, scope) do
    blog_slug = socket.assigns.blog_slug
    post = socket.assigns.post

    case Publishing.create_new_version(blog_slug, post, params, %{scope: scope}) do
      {:ok, new_version_post} ->
        # Invalidate cache for the post
        invalidate_post_cache(blog_slug, new_version_post)

        # Note: Publishing.create_new_version handles broadcasts internally

        form = post_form(new_version_post)

        socket =
          socket
          |> assign(:post, new_version_post)
          |> assign_form_with_tracking(form)
          |> assign(:content, new_version_post.content)
          |> assign(:current_version, new_version_post.version)
          |> assign(:available_versions, new_version_post.available_versions)
          |> assign(:version_statuses, new_version_post.version_statuses)
          |> assign(:version_dates, Map.get(new_version_post, :version_dates, %{}))
          |> assign(:editing_published_version, false)
          |> assign(:has_pending_changes, false)
          |> push_event("changes-status", %{has_changes: false})
          |> put_flash(
            :info,
            gettext("Created new version %{version} (draft)", version: new_version_post.version)
          )
          |> push_patch(
            to:
              Routes.path(
                "/admin/publishing/#{blog_slug}/edit?path=#{URI.encode(new_version_post.path)}",
                locale: socket.assigns.current_locale_base
              )
          )

        {:noreply, socket}

      {:error, reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Failed to create new version: %{reason}", reason: inspect(reason))
         )}
    end
  end

  defp update_post_in_place(socket, params, scope, old_path) do
    blog_slug = socket.assigns.blog_slug
    post = socket.assigns.post
    current_version = socket.assigns[:current_version]
    current_status = Map.get(post.metadata, :status)
    new_status = Map.get(params, "status")

    # Check if this is a status change TO published for a versioned post
    # If so, we need to use publish_version which archives other versions
    # IMPORTANT: Only trigger for master language - translation status changes
    # should not archive other versions
    is_master_language = socket.assigns[:is_master_language] == true

    is_publishing =
      is_master_language and
        new_status == "published" and
        current_status != "published" and
        current_version != nil and
        not Map.get(post, :is_legacy_structure, false)

    # First update the post content/metadata
    # Pass is_master_language so storage can set status_manual when translator changes status
    case Publishing.update_post(blog_slug, post, params, %{
           scope: scope,
           is_master_language: is_master_language
         }) do
      {:ok, updated_post} ->
        # If publishing, call publish_version to archive other versions
        if is_publishing do
          # For timestamp mode, construct the date/time path identifier
          # For slug mode, use the slug directly
          post_identifier =
            case post.mode do
              :timestamp ->
                date_str = Date.to_iso8601(post.date)
                time_str = format_time_folder(post.time)
                "#{date_str}/#{time_str}"

              _ ->
                post.slug
            end

          case Publishing.publish_version(blog_slug, post_identifier, current_version) do
            :ok ->
              handle_post_save_success(socket, updated_post, old_path)

            {:error, reason} ->
              {:noreply,
               put_flash(
                 socket,
                 :warning,
                 gettext("Post saved but failed to archive other versions: %{reason}",
                   reason: inspect(reason)
                 )
               )}
          end
        else
          handle_post_save_success(socket, updated_post, old_path)
        end

      {:error, error} ->
        handle_post_in_place_error(socket, error)
    end
  end

  defp handle_post_save_success(socket, post, old_path) do
    blog_slug = socket.assigns.blog_slug

    # Invalidate cache for this post
    invalidate_post_cache(blog_slug, post)

    # Broadcast save to other tabs/users so they can reload (for editor sync)
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

    # Re-read post from disk to get fresh cross-version statuses
    current_version = socket.assigns[:current_version]
    current_language = socket.assigns[:current_language]

    refreshed_post =
      case Publishing.read_post(blog_slug, post.path, current_language, current_version) do
        {:ok, fresh_post} -> fresh_post
        {:error, _} -> post
      end

    form = post_form(refreshed_post)

    # Check if post is now published (for versioning message updates)
    is_published = Map.get(refreshed_post.metadata, :status) == "published"

    socket =
      socket
      |> assign(:post, refreshed_post)
      |> assign_form_with_tracking(form)
      |> assign(:content, refreshed_post.content)
      |> assign(:has_pending_changes, false)
      |> assign(:editing_published_version, is_published)
      |> assign(:language_statuses, refreshed_post.language_statuses)
      |> assign(:version_statuses, refreshed_post.version_statuses)
      |> assign(:version_dates, Map.get(refreshed_post, :version_dates, %{}))
      |> push_event("changes-status", %{has_changes: false})
      |> maybe_update_current_path(old_path, refreshed_post.path)

    {:noreply, if(flash_message, do: put_flash(socket, :info, flash_message), else: socket)}
  end

  defp handle_post_in_place_error(socket, :invalid_format) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_in_place_error(socket, :reserved_language_code) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "This slug is reserved because it's a language code (like 'en', 'es', 'fr'). Please choose a different slug to avoid routing conflicts."
       )
     )}
  end

  defp handle_post_in_place_error(socket, :invalid_slug) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_in_place_error(socket, :slug_already_exists) do
    {:noreply, put_flash(socket, :error, gettext("A post with that slug already exists"))}
  end

  defp handle_post_in_place_error(socket, _reason) do
    {:noreply, put_flash(socket, :error, gettext("Failed to save post"))}
  end

  # Helper function to handle post update results and reduce cyclomatic complexity
  defp handle_post_update_result(socket, update_result, success_message, extra_assigns) do
    case update_result do
      {:ok, updated_post} ->
        # Invalidate cache for the post
        invalidate_post_cache(socket.assigns.blog_slug, updated_post)

        # Broadcast save to other tabs/users so they can reload
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

        form = post_form(updated_post)

        socket =
          socket
          |> assign(:post, updated_post)
          |> assign_form_with_tracking(form)
          |> assign(:content, updated_post.content)
          |> assign(:available_languages, updated_post.available_languages)
          |> assign(:has_pending_changes, false)
          |> assign(extra_assigns)
          |> push_event("changes-status", %{has_changes: false})
          |> push_patch(
            to:
              Routes.path(
                "/admin/publishing/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(updated_post.path)}",
                locale: socket.assigns.current_locale_base
              )
          )

        {:noreply, if(flash_message, do: put_flash(socket, :info, flash_message), else: socket)}

      {:error, error} ->
        handle_post_update_error(socket, error)
    end
  end

  # Helper function to handle post update errors
  defp handle_post_update_error(socket, :invalid_format) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_update_error(socket, :reserved_language_code) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "This slug is reserved because it's a language code (like 'en', 'es', 'fr'). Please choose a different slug to avoid routing conflicts."
       )
     )}
  end

  defp handle_post_update_error(socket, :invalid_slug) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_update_error(socket, :slug_already_exists) do
    {:noreply, put_flash(socket, :error, gettext("A post with that slug already exists"))}
  end

  defp handle_post_update_error(socket, _reason) do
    {:noreply, put_flash(socket, :error, gettext("Failed to save post"))}
  end

  # Helper function to assign current language with enabled/known status
  # This tracks whether the current language is enabled in the Languages module
  # and whether it's a recognized language code (vs unknown files like "test.phk")
  defp assign_current_language(socket, language_code) do
    enabled_languages = socket.assigns[:all_enabled_languages] || []
    lang_info = Publishing.get_language_info(language_code)
    master_language = Storage.get_master_language()

    socket
    |> assign(:current_language, language_code)
    |> assign(
      :current_language_enabled,
      Storage.language_enabled?(language_code, enabled_languages)
    )
    |> assign(:current_language_known, lang_info != nil)
    |> assign(:is_master_language, language_code == master_language)
  end

  # Helper function to handle post creation errors
  defp handle_post_creation_error(socket, :invalid_slug, _fallback_message) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext(
         "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
       )
     )}
  end

  defp handle_post_creation_error(socket, :slug_already_exists, _fallback_message) do
    {:noreply, put_flash(socket, :error, gettext("A post with that slug already exists"))}
  end

  defp handle_post_creation_error(socket, _reason, fallback_message) do
    {:noreply, put_flash(socket, :error, fallback_message)}
  end

  defp post_form(post) do
    base = %{
      "status" => post.metadata.status || "draft",
      "published_at" =>
        post.metadata.published_at ||
          DateTime.utc_now()
          |> floor_datetime_to_minute()
          |> DateTime.to_iso8601(),
      "featured_image_id" => Map.get(post.metadata, :featured_image_id, "")
    }

    form =
      cond do
        Map.get(post, :mode) == :slug ->
          Map.put(base, "slug", post.slug || Map.get(post.metadata, :slug) || "")

        Map.get(post, "mode") == :slug ->
          Map.put(
            base,
            "slug",
            post["slug"] || Map.get(post, :slug) || Map.get(post.metadata, :slug) || ""
          )

        true ->
          base
      end

    normalize_form(form)
  end

  defp floor_datetime_to_minute(%DateTime{} = datetime) do
    %DateTime{datetime | second: 0, microsecond: {0, 0}}
  end

  defp dirty?(post, form, content) do
    normalized_form = normalize_form(form)
    normalized_form != post_form(post) || content != post.content
  end

  defp normalize_form(form) when is_map(form) do
    featured_image_id =
      form
      |> Map.get("featured_image_id", "")
      |> to_string()
      |> String.trim()

    base =
      %{
        "status" => Map.get(form, "status", "draft") || "draft",
        "published_at" => normalize_published_at(Map.get(form, "published_at")),
        "featured_image_id" => featured_image_id
      }

    case Map.fetch(form, "slug") do
      {:ok, slug} ->
        # Normalize slug: trim and downcase to match validation requirements
        normalized_slug = slug |> to_string() |> String.trim() |> String.downcase()
        Map.put(base, "slug", normalized_slug)

      :error ->
        base
    end
  end

  defp normalize_form(_),
    do: %{
      "status" => "draft",
      "published_at" => "",
      "slug" => "",
      "featured_image_id" => ""
    }

  defp datetime_local_value(nil), do: ""

  defp datetime_local_value(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        dt
        |> floor_datetime_to_minute()
        |> DateTime.to_naive()
        |> NaiveDateTime.to_iso8601()

      _ ->
        value
    end
  end

  defp normalize_published_at(nil), do: ""

  defp normalize_published_at(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        ""

      String.length(trimmed) == 16 and String.contains?(trimmed, "T") ->
        trimmed <> ":00Z"

      true ->
        case DateTime.from_iso8601(trimmed) do
          {:ok, dt, _} ->
            dt
            |> floor_datetime_to_minute()
            |> DateTime.to_iso8601()

          _ ->
            trimmed
        end
    end
  end

  defp normalize_published_at(_), do: ""

  defp featured_image_preview_url(value) do
    case sanitize_featured_image_id(value) do
      nil ->
        nil

      file_id ->
        BlogHTML.featured_image_url(%{metadata: %{featured_image_id: file_id}}, "medium")
    end
  end

  defp sanitize_featured_image_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp sanitize_featured_image_id(_), do: nil

  @doc """
  Builds language data for the blog_language_switcher component in the editor.
  Returns a list of language maps with status, exists flag, enabled flag, and code.

  The `enabled` field indicates if the language is currently active in the Languages module.
  The `known` field indicates if the language code is recognized (vs unknown files like "test.phk").

  Uses preloaded `language_statuses` from the post when available to avoid re-reading files.
  """
  def build_editor_languages(post, _blog_slug, enabled_languages, current_language) do
    # Use shared ordering function for consistent display across all views
    all_languages =
      Storage.order_languages_for_display(post.available_languages || [], enabled_languages)

    # Get preloaded language statuses (falls back to empty map for backwards compatibility)
    language_statuses = Map.get(post, :language_statuses) || %{}

    Enum.map(all_languages, fn lang_code ->
      lang_info = Publishing.get_language_info(lang_code)
      file_exists = lang_code in (post.available_languages || [])
      is_current = lang_code == current_language
      is_enabled = Storage.language_enabled?(lang_code, enabled_languages)
      is_known = lang_info != nil

      # Use preloaded status instead of re-reading file
      status = Map.get(language_statuses, lang_code)

      # Get display code (base or full dialect depending on enabled languages)
      display_code = Storage.get_display_code(lang_code, enabled_languages)

      %{
        code: lang_code,
        display_code: display_code,
        name: if(lang_info, do: lang_info.name, else: lang_code),
        flag: if(lang_info, do: lang_info.flag, else: ""),
        status: status,
        exists: file_exists,
        is_current: is_current,
        enabled: is_enabled,
        known: is_known
      }
    end)
  end

  defp build_preview_payload(socket) do
    form = socket.assigns.form || %{}
    post = socket.assigns.post

    metadata = %{
      status: map_get_with_fallback(form, "status", metadata_value(post, :status), "draft"),
      published_at:
        map_get_with_fallback(
          form,
          "published_at",
          metadata_value(post, :published_at),
          ""
        ),
      slug: preview_slug(form, post)
    }

    %{
      blog_slug: socket.assigns.blog_slug,
      path: post.path,
      mode: Map.get(post, :mode) || Map.get(post, "mode") || infer_mode(socket),
      language: socket.assigns.current_language,
      available_languages: post.available_languages || [],
      metadata: metadata,
      content: socket.assigns.content || "",
      is_new_post:
        Map.get(socket.assigns, :is_new_post, false) ||
          is_nil(post.path)
    }
  end

  defp maybe_put_preview_path(params, path) when is_binary(path) and path != "" do
    Map.put(params, "path", path)
  end

  defp maybe_put_preview_path(params, _), do: params

  defp maybe_put_preview_new_flag(params, %{is_new_post: true}) do
    Map.put(params, "new", "true")
  end

  defp maybe_put_preview_new_flag(params, _), do: params

  defp map_get_with_fallback(map, key, fallback, default) do
    case Map.get(map, key) do
      nil -> fallback || default
      value -> value
    end
  end

  defp preview_slug(form, post) do
    form_slug =
      form
      |> Map.get("slug")
      |> case do
        nil -> nil
        slug -> String.trim(to_string(slug))
      end

    cond do
      form_slug && form_slug != "" ->
        form_slug

      Map.get(post, :slug) && post.slug != "" ->
        post.slug

      Map.get(post, "slug") && post["slug"] != "" ->
        post["slug"]

      metadata_value(post, :slug) ->
        metadata_value(post, :slug)

      metadata_value(post, "slug") ->
        metadata_value(post, "slug")

      true ->
        ""
    end
  end

  defp metadata_value(post, key) do
    metadata = Map.get(post, :metadata) || %{}

    cond do
      is_atom(key) ->
        Map.get(metadata, key) || Map.get(metadata, Atom.to_string(key))

      is_binary(key) ->
        Map.get(metadata, key) ||
          try do
            Map.get(metadata, String.to_existing_atom(key))
          rescue
            ArgumentError -> nil
          end

      true ->
        nil
    end
  end

  defp apply_preview_payload(socket, data) do
    blog_slug = data[:blog_slug] || socket.assigns.blog_slug
    mode = data[:mode] || :timestamp
    language = data[:language] || socket.assigns.current_language || "en"
    metadata = normalize_preview_metadata(data[:metadata] || %{}, mode)

    post = build_preview_post(data, blog_slug, mode, language, metadata)
    form = build_preview_form(metadata, mode)

    apply_preview_assigns(socket, post, form, blog_slug, mode, data)
  end

  defp build_preview_post(data, blog_slug, mode, language, metadata) do
    {date, time} = derive_datetime_fields(mode, metadata[:published_at])
    path = data[:path] || derive_preview_path(blog_slug, metadata[:slug], language, mode)
    full_path = if path, do: Storage.absolute_path(path), else: nil
    available_languages = data[:available_languages] || []

    available_languages =
      [language | available_languages] |> Enum.reject(&is_nil/1) |> Enum.uniq()

    %{
      group: blog_slug,
      slug: metadata[:slug],
      date: date,
      time: time,
      path: path,
      full_path: full_path,
      metadata: metadata,
      content: data[:content] || "",
      language: language,
      available_languages: available_languages,
      mode: mode
    }
  end

  defp build_preview_form(metadata, mode) do
    %{
      "title" => metadata[:title] || "",
      "status" => metadata[:status] || "draft",
      "published_at" => metadata[:published_at] || ""
    }
    |> maybe_put_form_slug(metadata[:slug], mode)
    |> normalize_form()
  end

  defp apply_preview_assigns(socket, post, form, blog_slug, mode, data) do
    language = post.language

    socket
    |> assign(:blog_mode, mode_to_string(mode))
    |> assign(:blog_slug, blog_slug)
    |> assign(:post, post)
    |> assign_form_with_tracking(form, slug_manually_set: false)
    |> assign(:content, data[:content] || "")
    |> assign(:available_languages, post.available_languages)
    |> assign(:all_enabled_languages, Storage.enabled_language_codes())
    |> assign_current_language(language)
    |> assign(:has_pending_changes, true)
    |> assign(:is_new_post, data[:is_new_post] || false)
    |> assign(:public_url, build_public_url(post, language))
    |> assign(:blog_name, Publishing.group_name(blog_slug) || blog_slug)
  end

  defp normalize_preview_metadata(metadata, mode) do
    metadata_map =
      Enum.reduce(metadata, %{}, fn
        {key, value}, acc when key in [:status, :published_at, :slug] ->
          Map.put(acc, key, value)

        {"status", value}, acc ->
          Map.put(acc, :status, value)

        {"published_at", value}, acc ->
          Map.put(acc, :published_at, value)

        {"slug", value}, acc ->
          Map.put(acc, :slug, value)

        _, acc ->
          acc
      end)

    defaults =
      case mode do
        :slug -> %{status: "draft", published_at: "", slug: ""}
        _ -> %{status: "draft", published_at: "", slug: nil}
      end

    Map.merge(defaults, metadata_map)
  end

  defp derive_datetime_fields(:timestamp, published_at) do
    with value when is_binary(value) and value != "" <- published_at,
         {:ok, dt, _offset} <- DateTime.from_iso8601(value) do
      floored = floor_datetime_to_minute(dt)

      {DateTime.to_date(floored), DateTime.to_time(floored)}
    else
      _ -> {nil, nil}
    end
  end

  defp derive_datetime_fields(_, _), do: {nil, nil}

  defp derive_preview_path(_blog_slug, _slug, _language, :timestamp), do: nil

  defp derive_preview_path(blog_slug, slug, language, :slug)
       when is_binary(slug) and slug != "" do
    Path.join([blog_slug, slug, "#{language}.phk"])
  end

  defp derive_preview_path(_, _, _, _), do: nil

  defp maybe_put_form_slug(form, slug, :slug) do
    Map.put(form, "slug", slug || "")
  end

  defp maybe_put_form_slug(form, _slug, _mode), do: form

  defp mode_to_string(:slug), do: "slug"
  defp mode_to_string(_), do: "timestamp"

  defp preview_editor_path(socket, data, token, params) do
    blog_slug = data[:blog_slug] || socket.assigns.blog_slug

    query_params =
      %{}
      |> maybe_put_preview_path(Map.get(params, "path") || data[:path])
      |> maybe_put_preview_new_flag(%{is_new_post: data[:is_new_post] || false})
      |> Map.put("preview_token", token)

    query =
      case URI.encode_query(query_params) do
        "" -> ""
        encoded -> "?" <> encoded
      end

    Routes.path("/admin/publishing/#{blog_slug}/edit#{query}",
      locale: socket.assigns.current_locale_base
    )
  end

  defp infer_mode(socket) do
    case socket.assigns[:blog_mode] do
      "slug" -> :slug
      :slug -> :slug
      _ -> :timestamp
    end
  end

  defp build_virtual_post(blog_slug, "slug", primary_language, now) do
    %{
      group: blog_slug,
      date: nil,
      time: nil,
      path: nil,
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        slug: "",
        featured_image_id: nil
      },
      content: "",
      language: primary_language,
      available_languages: [],
      mode: :slug,
      slug: nil,
      is_legacy_structure: false
    }
  end

  defp build_virtual_post(blog_slug, _mode, primary_language, now) do
    date = DateTime.to_date(now)
    time = DateTime.to_time(now)

    time_folder =
      "#{String.pad_leading(to_string(time.hour), 2, "0")}:#{String.pad_leading(to_string(time.minute), 2, "0")}"

    %{
      group: blog_slug,
      date: date,
      time: time,
      path:
        Path.join([
          blog_slug,
          Date.to_iso8601(date),
          time_folder,
          "#{primary_language}.phk"
        ]),
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        featured_image_id: nil
      },
      content: "",
      language: primary_language,
      available_languages: [],
      mode: :timestamp,
      is_legacy_structure: false
    }
  end

  defp slug_base_dir(post, blog_slug) do
    cond do
      # For versioned posts, use the path to preserve version directory
      # e.g., "blog/post-slug/v1/en.phk" -> "blog/post-slug/v1"
      post.path && not Map.get(post, :is_legacy_structure, false) ->
        Path.dirname(post.path)

      # For legacy slug mode posts without versioning
      Map.get(post, :mode) == :slug and Map.get(post, :slug) ->
        Path.join([blog_slug || "blog", post.slug])

      # Fallback to path dirname if available
      post.path ->
        Path.dirname(post.path)

      true ->
        Path.join([blog_slug || "blog", post.slug || ""])
    end
  end

  defp build_public_url(post, language) do
    # Only show public URL for published posts
    if Map.get(post.metadata, :status) == "published" do
      build_url_for_mode(post, language)
    else
      nil
    end
  end

  defp build_url_for_mode(post, language) do
    blog_slug = post.group || "blog"

    case Map.get(post, :mode) do
      :slug -> build_slug_mode_url(blog_slug, post, language)
      :timestamp -> build_timestamp_mode_url(blog_slug, post, language)
      _ -> nil
    end
  end

  defp build_slug_mode_url(blog_slug, post, language) do
    if post.slug do
      BlogHTML.build_post_url(blog_slug, post, language)
    else
      nil
    end
  end

  defp build_timestamp_mode_url(blog_slug, post, language) do
    if post.metadata.published_at do
      case DateTime.from_iso8601(post.metadata.published_at) do
        {:ok, _datetime, _} -> BlogHTML.build_post_url(blog_slug, post, language)
        _ -> nil
      end
    else
      nil
    end
  end

  defp editor_language(assigns) do
    assigns[:current_language] ||
      assigns |> Map.get(:post, %{}) |> Map.get(:language) ||
      hd(Storage.enabled_language_codes())
  end

  defp invalidate_post_cache(blog_slug, post) do
    # Determine identifier based on post mode
    identifier =
      case Map.get(post, :mode) do
        :slug -> post.slug
        :timestamp -> extract_identifier_from_path(post.path)
        _ -> post.slug || extract_identifier_from_path(post.path)
      end

    # Call the Renderer module's cache invalidation
    # Note: The Renderer uses content-hash keys, so this mainly logs the invalidation request
    # The actual cache will be automatically invalidated when content hash changes
    Renderer.invalidate_cache(blog_slug, identifier, post.language)
  end

  defp extract_identifier_from_path(path) when is_binary(path) do
    # For timestamp mode: "blog/2025-01-15/09:30/en.phk" -> "2025-01-15/09:30"
    # For slug mode: "blog/getting-started/en.phk" -> "getting-started"
    path
    |> String.split("/")
    # Remove language.phk
    |> Enum.drop(-1)
    # Remove blog name
    |> Enum.drop(1)
    |> Enum.join("/")
  end

  defp update_form_with_media(form, file_id) do
    # Update the form with the selected file_id
    # The form is a simple map with string keys
    Map.put(form, "featured_image_id", file_id)
  end

  defp assign_form_with_tracking(socket, form, opts \\ []) do
    slug = Map.get(form, "slug", "")

    slug_manually_set =
      case Keyword.fetch(opts, :slug_manually_set) do
        {:ok, value} -> value
        :error -> Map.get(socket.assigns, :slug_manually_set, false)
      end

    last_auto_slug =
      case Keyword.fetch(opts, :last_auto_slug) do
        {:ok, value} -> value
        :error -> slug
      end

    socket
    |> assign(:form, form)
    |> assign(:last_auto_slug, last_auto_slug)
    |> assign(:slug_manually_set, slug_manually_set)
  end

  defp maybe_update_slug_from_content(socket, content, opts \\ []) do
    force? = Keyword.get(opts, :force, false)
    content = content || ""

    cond do
      socket.assigns.blog_mode != "slug" ->
        no_slug_update(socket)

      not force? && Map.get(socket.assigns, :slug_manually_set, false) ->
        no_slug_update(socket)

      String.trim(content) == "" ->
        no_slug_update(socket)

      true ->
        update_slug_from_content(socket, content)
    end
  end

  defp no_slug_update(socket), do: {socket, socket.assigns.form, []}

  defp update_slug_from_content(socket, content) do
    title = Metadata.extract_title_from_content(content)
    current_slug = socket.assigns.post.slug || Map.get(socket.assigns.form, "slug", "")

    case Storage.generate_unique_slug(socket.assigns.blog_slug, title, nil,
           current_slug: current_slug
         ) do
      {:ok, ""} ->
        no_slug_update(socket)

      {:ok, new_slug} ->
        apply_new_slug(socket, new_slug)

      {:error, _reason} ->
        no_slug_update(socket)
    end
  end

  defp apply_new_slug(socket, new_slug) do
    current_slug = Map.get(socket.assigns.form, "slug", "")

    if new_slug != current_slug do
      form =
        socket.assigns.form
        |> Map.put("slug", new_slug)
        |> normalize_form()

      socket =
        socket
        |> assign(:last_auto_slug, new_slug)
        |> assign(:slug_manually_set, false)

      {socket, form, [{"update-slug", %{slug: new_slug}}]}
    else
      socket =
        socket
        |> assign(:last_auto_slug, new_slug)
        |> assign(:slug_manually_set, false)

      {socket, socket.assigns.form, []}
    end
  end

  defp push_slug_events(socket, events) do
    Enum.reduce(events, socket, fn {event, data}, acc ->
      push_event(acc, event, data)
    end)
  end

  defp maybe_update_current_path(socket, old_path, new_path)
       when new_path in [nil, ""] or new_path == old_path,
       do: socket

  defp maybe_update_current_path(socket, _old_path, new_path) do
    encoded = URI.encode(new_path)

    path =
      Routes.path(
        "/admin/publishing/#{socket.assigns.blog_slug}/edit?path=#{encoded}",
        locale: socket.assigns.current_locale_base
      )

    socket
    |> assign(:current_path, path)
    |> push_patch(to: path)
  end

  # ============================================================================
  # Collaborative Editing
  # ============================================================================

  # Used when we know the old form_key (e.g., when switching languages/versions)
  defp cleanup_and_setup_collaborative_editing(socket, old_form_key, new_form_key) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    if connected?(socket) && new_form_key && current_user do
      try do
        # Clean up old presence tracking
        if old_form_key && old_form_key != new_form_key do
          PresenceHelpers.untrack_editing_session(old_form_key, socket)
          PresenceHelpers.unsubscribe_from_editing(old_form_key)
          PublishingPubSub.unsubscribe_from_editor_form(old_form_key)
        end

        # Track this user in Presence
        case PresenceHelpers.track_editing_session(new_form_key, socket, current_user) do
          {:ok, _ref} -> :ok
          {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
        end

        # Subscribe to presence changes and form events
        PresenceHelpers.subscribe_to_editing(new_form_key)
        PublishingPubSub.subscribe_to_editor_form(new_form_key)

        # Determine our role (owner or spectator)
        socket = assign_editing_role(socket, new_form_key)

        # Load spectator state if we're not the owner
        if socket.assigns.readonly? do
          load_spectator_state(socket, new_form_key)
        else
          socket
        end
      rescue
        ArgumentError ->
          socket
          |> assign(:lock_owner?, true)
          |> assign(:readonly?, false)
          |> assign(:lock_owner_user, nil)
          |> assign(:spectators, [])
          |> assign(:other_viewers, [])
      end
    else
      socket
      |> assign(:lock_owner?, true)
      |> assign(:readonly?, false)
      |> assign(:lock_owner_user, nil)
      |> assign(:spectators, [])
      |> assign(:other_viewers, [])
    end
  end

  # Used for initial setup (reads old_form_key from socket.assigns)
  defp setup_collaborative_editing(socket, form_key) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    if connected?(socket) && form_key && current_user do
      do_setup_collaborative_editing(socket, form_key, current_user)
    else
      assign_default_editing_state(socket)
    end
  end

  defp do_setup_collaborative_editing(socket, form_key, current_user) do
    old_form_key = socket.assigns[:form_key]

    try do
      cleanup_old_presence(old_form_key, form_key, socket)
      track_and_subscribe(form_key, socket, current_user)
      subscribe_to_post_translations(socket)

      socket
      |> assign_editing_role(form_key)
      |> maybe_load_spectator_state(form_key)
    rescue
      ArgumentError ->
        Logger.warning(
          "Publishing Presence not available - collaborative editing disabled. " <>
            "Ensure PhoenixKit.Supervisor starts before your Endpoint in application.ex"
        )

        assign_default_editing_state(socket)
    end
  end

  defp cleanup_old_presence(old_form_key, form_key, socket) do
    if old_form_key && old_form_key != form_key do
      PresenceHelpers.untrack_editing_session(old_form_key, socket)
      PresenceHelpers.unsubscribe_from_editing(old_form_key)
      PublishingPubSub.unsubscribe_from_editor_form(old_form_key)
    end
  end

  defp track_and_subscribe(form_key, socket, current_user) do
    case PresenceHelpers.track_editing_session(form_key, socket, current_user) do
      {:ok, _ref} -> :ok
      {:error, {:already_tracked, _pid, _topic, _key}} -> :ok
    end

    PresenceHelpers.subscribe_to_editing(form_key)
    PublishingPubSub.subscribe_to_editor_form(form_key)
  end

  defp subscribe_to_post_translations(socket) do
    case socket.assigns[:post] && socket.assigns.post[:slug] do
      post_slug when is_binary(post_slug) ->
        PublishingPubSub.subscribe_to_post_translations(socket.assigns.blog_slug, post_slug)

      _ ->
        :ok
    end
  end

  defp maybe_load_spectator_state(socket, form_key) do
    if socket.assigns.readonly?, do: load_spectator_state(socket, form_key), else: socket
  end

  defp assign_default_editing_state(socket) do
    socket
    |> assign(:lock_owner?, true)
    |> assign(:readonly?, false)
    |> assign(:lock_owner_user, nil)
    |> assign(:spectators, [])
    |> assign(:other_viewers, [])
  end

  defp assign_editing_role(socket, form_key) do
    current_user = socket.assigns[:phoenix_kit_current_user]

    case PresenceHelpers.get_editing_role(form_key, socket.id, current_user.id) do
      {:owner, _presences} ->
        # I'm the owner - I can edit
        socket
        |> assign(:lock_owner?, true)
        |> assign(:readonly?, false)
        |> populate_presence_info(form_key)

      {:spectator, _owner_meta, _presences} ->
        # Different user is the owner - I'm read-only
        socket
        |> assign(:lock_owner?, false)
        |> assign(:readonly?, true)
        |> populate_presence_info(form_key)
    end
  end

  defp populate_presence_info(socket, form_key) do
    presences = PresenceHelpers.get_sorted_presences(form_key)

    my_user_id =
      socket.assigns[:phoenix_kit_current_user] && socket.assigns.phoenix_kit_current_user.id

    {lock_owner_user, spectators, other_viewers} =
      case presences do
        [] ->
          {nil, [], []}

        [{_owner_socket_id, owner_meta} | spectator_list] ->
          spectators =
            Enum.map(spectator_list, fn {_socket_id, meta} ->
              %{
                user: meta.user,
                user_id: meta.user_id,
                user_email: meta.user_email
              }
            end)

          # Other viewers = all presences from OTHER users (not just other sockets)
          # This prevents showing your own stale sockets during page refresh
          other_viewers =
            presences
            |> Enum.reject(fn {_socket_id, meta} -> meta.user_id == my_user_id end)
            |> Enum.map(fn {_socket_id, meta} ->
              %{
                user: meta.user,
                user_id: meta.user_id,
                user_email: meta.user_email
              }
            end)
            |> Enum.uniq_by(& &1.user_id)

          {owner_meta.user, spectators, other_viewers}
      end

    socket
    |> assign(:lock_owner_user, lock_owner_user)
    |> assign(:spectators, spectators)
    |> assign(:other_viewers, other_viewers)
  end

  defp load_spectator_state(socket, form_key) do
    # Owner might have unsaved changes - sync from their Presence metadata
    case PresenceHelpers.get_lock_owner(form_key) do
      %{form_state: form_state} when not is_nil(form_state) ->
        apply_remote_form_state(socket, form_state)

      _ ->
        # No form state to sync
        socket
    end
  end

  defp apply_remote_form_state(socket, form_state) do
    form = Map.get(form_state, :form) || Map.get(form_state, "form") || socket.assigns.form

    content =
      Map.get(form_state, :content) || Map.get(form_state, "content") || socket.assigns.content

    socket
    |> assign(:form, form)
    |> assign(:content, content)
    |> assign(:has_pending_changes, true)
  end

  # Reload post from disk when another tab/user saves (last-save-wins)
  defp reload_post_from_disk(socket) do
    blog_slug = socket.assigns.blog_slug
    post_path = socket.assigns.post.path

    case Publishing.read_post(blog_slug, post_path) do
      {:ok, updated_post} ->
        form = post_form(updated_post)

        socket
        |> assign(:post, %{updated_post | group: blog_slug})
        |> assign_form_with_tracking(form)
        |> assign(:content, updated_post.content)
        |> assign(:available_languages, updated_post.available_languages)
        |> assign(:has_pending_changes, false)
        |> push_event("changes-status", %{has_changes: false})
        |> push_event("set-content", %{content: updated_post.content})
        |> put_flash(:info, gettext("Post updated by another user"))

      {:error, _reason} ->
        # File might have been deleted or moved
        socket
        |> put_flash(
          :warning,
          gettext("Could not reload post - it may have been moved or deleted")
        )
    end
  end

  # With variant versioning, all versions are editable since they're independent attempts.
  # This function always returns false - no version locking.
  defp viewing_older_version?(_current_version, _available_versions, _current_language), do: false
end
