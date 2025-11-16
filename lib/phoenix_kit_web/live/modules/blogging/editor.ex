defmodule PhoenixKitWeb.Live.Modules.Blogging.Editor do
  @moduledoc """
  Markdown editor for blogging posts.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Blogging.Renderer
  alias PhoenixKit.Settings
  alias PhoenixKit.Storage
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.BlogHTML
  alias PhoenixKitWeb.Helpers.MediaSelectorHelper
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.Metadata
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  @impl true
  def mount(params, _session, socket) do
    blog_slug = params["blog"] || params["category"] || params["type"]
    locale = params["locale"] || socket.assigns[:current_locale] || "en"
    Gettext.put_locale(PhoenixKitWeb.Gettext, locale)
    Process.put(:phoenix_kit_current_locale, locale)

    socket =
      socket
      |> assign(:current_locale, locale)
      |> assign(:project_title, Settings.get_setting("project_title", "PhoenixKit"))
      |> assign(:page_title, "Blogging Editor")
      |> assign(:blog_slug, blog_slug)

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

  def handle_params(%{"new" => "true"} = params, _uri, socket) do
    blog_slug = socket.assigns.blog_slug
    blog_mode = Blogging.get_blog_mode(blog_slug)
    all_enabled_languages = Storage.enabled_language_codes()
    primary_language = hd(all_enabled_languages)

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> floor_datetime_to_minute()
    virtual_post = build_virtual_post(blog_slug, blog_mode, primary_language, now)

    socket =
      socket
      |> assign(:blog_mode, blog_mode)
      |> assign(:post, virtual_post)
      |> assign(:blog_name, Blogging.blog_name(blog_slug) || blog_slug)
      |> assign(:form, post_form(virtual_post))
      |> assign(:content, "")
      |> assign(:current_language, primary_language)
      |> assign(:available_languages, virtual_post.available_languages)
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> assign(
        :current_path,
        Routes.path("/admin/blogging/#{blog_slug}/edit?new=true",
          locale: socket.assigns.current_locale
        )
      )
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_post, true)
      |> assign(:public_url, nil)
      |> push_event("changes-status", %{has_changes: false})

    # Handle media selection from media selector
    socket =
      case MediaSelectorHelper.get_first_selected(params) do
        {:ok, file_id} ->
          socket
          |> assign(:form, update_form_with_media(socket.assigns.form, file_id))
          |> assign(:has_pending_changes, true)
          |> put_flash(:info, gettext("Featured image selected"))
          |> push_event("changes-status", %{has_changes: true})

        :none ->
          socket
      end

    {:noreply, socket}
  end

  def handle_params(%{"path" => path} = params, _uri, socket)
      when not is_map_key(params, "preview_token") do
    blog_slug = socket.assigns.blog_slug
    blog_mode = Blogging.get_blog_mode(blog_slug)

    case Blogging.read_post(blog_slug, path) do
      {:ok, post} ->
        all_enabled_languages = Storage.enabled_language_codes()
        switch_to_lang = Map.get(params, "switch_to")

        socket =
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

            socket
            |> assign(:blog_mode, blog_mode)
            |> assign(:post, virtual_post)
            |> assign(:blog_name, Blogging.blog_name(blog_slug) || blog_slug)
            |> assign(:form, post_form(virtual_post))
            |> assign(:content, "")
            |> assign(:current_language, switch_to_lang)
            |> assign(:available_languages, post.available_languages)
            |> assign(:all_enabled_languages, all_enabled_languages)
            |> assign(
              :current_path,
              Routes.path(
                "/admin/blogging/#{blog_slug}/edit?path=#{URI.encode_www_form(new_path)}",
                locale: socket.assigns.current_locale
              )
            )
            |> assign(:has_pending_changes, false)
            |> assign(:is_new_translation, true)
            |> assign(:original_post_path, path)
            |> assign(:public_url, nil)
            |> push_event("changes-status", %{has_changes: false})
          else
            socket
            |> assign(:blog_mode, blog_mode)
            |> assign(:post, %{post | blog: blog_slug})
            |> assign(:blog_name, Blogging.blog_name(blog_slug) || blog_slug)
            |> assign(:form, post_form(post))
            |> assign(:content, post.content)
            |> assign(:current_language, post.language)
            |> assign(:available_languages, post.available_languages)
            |> assign(:all_enabled_languages, all_enabled_languages)
            |> assign(
              :current_path,
              Routes.path("/admin/blogging/#{blog_slug}/edit?path=#{URI.encode_www_form(path)}",
                locale: socket.assigns.current_locale
              )
            )
            |> assign(:has_pending_changes, false)
            |> assign(:public_url, build_public_url(post, post.language))
            |> push_event("changes-status", %{has_changes: false})
          end

        # Handle media selection from media selector
        socket =
          case MediaSelectorHelper.get_first_selected(params) do
            {:ok, file_id} ->
              socket
              |> assign(:form, update_form_with_media(socket.assigns.form, file_id))
              |> assign(:has_pending_changes, true)
              |> put_flash(:info, gettext("Featured image selected"))
              |> push_event("changes-status", %{has_changes: true})

            :none ->
              socket
          end

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("Post not found"))
         |> push_navigate(
           to: Routes.path("/admin/blogging/#{blog_slug}", locale: socket.assigns.current_locale)
         )}
    end
  end

  # Catch-all for other param combinations (shouldn't normally be reached)
  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("update_meta", params, socket) do
    params =
      params
      |> Map.drop(["_target"])

    # No real-time validation - accept any input, validation happens on save
    new_form =
      socket.assigns.form
      |> Map.merge(params)
      |> normalize_form()

    has_changes = dirty?(socket.assigns.post, new_form, socket.assigns.content)

    # Update public_url if status changed
    updated_post = %{
      socket.assigns.post
      | metadata: Map.merge(socket.assigns.post.metadata, %{status: new_form["status"]})
    }

    language = editor_language(socket.assigns)
    public_url = build_public_url(updated_post, language)

    {:noreply,
     socket
     |> assign(:form, new_form)
     |> assign(:has_pending_changes, has_changes)
     |> assign(:public_url, public_url)
     |> clear_flash()
     |> push_event("changes-status", %{has_changes: has_changes})}
  end

  def handle_event("clear_featured_image", _params, socket) do
    # Clear the featured image from the form
    current_form = socket.assigns.form

    updated_params =
      Map.update(current_form.params, "metadata", %{}, fn metadata ->
        Map.delete(metadata, "featured_image_id")
      end)

    updated_form = %{current_form | params: updated_params}

    {:noreply,
     socket
     |> assign(:form, updated_form)
     |> assign(:has_pending_changes, true)
     |> put_flash(:info, gettext("Featured image cleared"))
     |> push_event("changes-status", %{has_changes: true})}
  end

  def handle_event("generate_slug_from_content", _params, socket) do
    # Only generate slug if in slug mode and slug is empty
    if socket.assigns.blog_mode == "slug" do
      current_slug = Map.get(socket.assigns.form, "slug", "")
      content = socket.assigns.content || ""

      new_slug =
        if current_slug == "" and String.trim(content) != "" do
          # Extract title from content and use it for slug
          title = Metadata.extract_title_from_content(content)
          Storage.generate_unique_slug(socket.assigns.blog_slug, title, nil)
        else
          current_slug
        end

      new_form =
        socket.assigns.form
        |> Map.put("slug", new_slug)
        |> normalize_form()

      has_changes = dirty?(socket.assigns.post, new_form, socket.assigns.content)

      {:noreply,
       socket
       |> assign(:form, new_form)
       |> assign(:has_pending_changes, has_changes)
       |> push_event("changes-status", %{has_changes: has_changes})
       |> push_event("update-slug", %{slug: new_slug})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("update_content", %{"content" => content}, socket) do
    # Auto-generate slug from content live for new unsaved posts only
    is_new_unsaved =
      Map.get(socket.assigns, :is_new_post, false) ||
        Map.get(socket.assigns, :is_new_translation, false)

    {new_form, slug_events} =
      if socket.assigns.blog_mode == "slug" && is_new_unsaved && String.trim(content) != "" do
        title = Metadata.extract_title_from_content(content)

        case Storage.generate_unique_slug(socket.assigns.blog_slug, title, nil) do
          {:ok, new_slug} ->
            current_slug = Map.get(socket.assigns.form, "slug", "")

            if new_slug != current_slug do
              {Map.put(socket.assigns.form, "slug", new_slug),
               [{"update-slug", %{slug: new_slug}}]}
            else
              {socket.assigns.form, []}
            end

          {:error, _} ->
            # If slug generation fails, keep current form
            {socket.assigns.form, []}
        end
      else
        {socket.assigns.form, []}
      end

    has_changes = dirty?(socket.assigns.post, new_form, content)

    socket =
      socket
      |> assign(:content, content)
      |> assign(:form, new_form)
      |> assign(:has_pending_changes, has_changes)
      |> push_event("changes-status", %{has_changes: has_changes})

    socket =
      Enum.reduce(slug_events, socket, fn {event, data}, acc ->
        push_event(acc, event, data)
      end)

    {:noreply, socket}
  end

  def handle_event("save", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
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

  def handle_event("noop", _params, socket), do: {:noreply, socket}

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
           "/admin/blogging/#{socket.assigns.blog_slug}/preview#{query_string}",
           locale: socket.assigns.current_locale
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
         Routes.path("/admin/blogging/#{socket.assigns.blog_slug}",
           locale: socket.assigns.current_locale
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
      {:noreply,
       push_patch(socket,
         to:
           Routes.path(
             "/admin/blogging/#{blog_slug}/edit?path=#{URI.encode(new_path)}",
             locale: socket.assigns.current_locale
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

      {:noreply,
       socket
       |> assign(:post, virtual_post)
       |> assign(:form, post_form(virtual_post))
       |> assign(:content, "")
       |> assign(:current_language, new_language)
       |> assign(:has_pending_changes, false)
       |> assign(:is_new_translation, true)
       |> assign(:original_post_path, post.path || post.slug)
       |> push_event("changes-status", %{has_changes: false})}
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

    case Blogging.create_post(socket.assigns.blog_slug, create_opts) do
      {:ok, new_post} ->
        case Blogging.update_post(socket.assigns.blog_slug, new_post, params, %{scope: scope}) do
          {:ok, updated_post} ->
            # Invalidate cache for newly created post
            invalidate_post_cache(socket.assigns.blog_slug, updated_post)

            {:noreply,
             socket
             |> assign(:post, updated_post)
             |> assign(:form, post_form(updated_post))
             |> assign(:content, updated_post.content)
             |> assign(:available_languages, updated_post.available_languages)
             |> assign(:has_pending_changes, false)
             |> assign(:is_new_post, false)
             |> assign(:blog_mode, socket.assigns.blog_mode)
             |> push_event("changes-status", %{has_changes: false})
             |> put_flash(:info, gettext("Post created and saved"))
             |> push_patch(
               to:
                 Routes.path(
                   "/admin/blogging/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(updated_post.path)}",
                   locale: socket.assigns.current_locale
                 )
             )}

          {:error, :invalid_format} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
               )
             )}

          {:error, :reserved_language_code} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "This slug is reserved because it's a language code (like 'en', 'es', 'fr'). Please choose a different slug to avoid routing conflicts."
               )
             )}

          {:error, :invalid_slug} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
               )
             )}

          {:error, :slug_already_exists} ->
            {:noreply, put_flash(socket, :error, gettext("A post with that slug already exists"))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to save post"))}
        end

      {:error, :invalid_slug} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
           )
         )}

      {:error, :slug_already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("A post with that slug already exists"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create post"))}
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

    case Blogging.add_language_to_post(
           socket.assigns.blog_slug,
           original_identifier,
           socket.assigns.current_language
         ) do
      {:ok, new_post} ->
        case Blogging.update_post(socket.assigns.blog_slug, new_post, params, %{scope: scope}) do
          {:ok, updated_post} ->
            # Invalidate cache for newly created translation
            invalidate_post_cache(socket.assigns.blog_slug, updated_post)

            {:noreply,
             socket
             |> assign(:post, updated_post)
             |> assign(:form, post_form(updated_post))
             |> assign(:content, updated_post.content)
             |> assign(:available_languages, updated_post.available_languages)
             |> assign(:has_pending_changes, false)
             |> assign(:is_new_translation, false)
             |> assign(:original_post_path, nil)
             |> push_event("changes-status", %{has_changes: false})
             |> put_flash(:info, gettext("Translation created and saved"))
             |> push_patch(
               to:
                 Routes.path(
                   "/admin/blogging/#{socket.assigns.blog_slug}/edit?path=#{URI.encode(updated_post.path)}",
                   locale: socket.assigns.current_locale
                 )
             )}

          {:error, :invalid_format} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
               )
             )}

          {:error, :reserved_language_code} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "This slug is reserved because it's a language code (like 'en', 'es', 'fr'). Please choose a different slug to avoid routing conflicts."
               )
             )}

          {:error, :invalid_slug} ->
            {:noreply,
             put_flash(
               socket,
               :error,
               gettext(
                 "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
               )
             )}

          {:error, :slug_already_exists} ->
            {:noreply, put_flash(socket, :error, gettext("A post with that slug already exists"))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to save translation"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create translation file"))}
    end
  end

  defp update_existing_post(socket, params) do
    scope = socket.assigns[:phoenix_kit_current_scope]

    case Blogging.update_post(socket.assigns.blog_slug, socket.assigns.post, params, %{
           scope: scope
         }) do
      {:ok, post} ->
        # Invalidate cache for this post
        invalidate_post_cache(socket.assigns.blog_slug, post)

        {:noreply,
         socket
         |> assign(:post, post)
         |> assign(:form, post_form(post))
         |> assign(:content, post.content)
         |> assign(:has_pending_changes, false)
         |> push_event("changes-status", %{has_changes: false})
         |> put_flash(:info, gettext("Post saved"))}

      {:error, :invalid_format} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
           )
         )}

      {:error, :reserved_language_code} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "This slug is reserved because it's a language code (like 'en', 'es', 'fr'). Please choose a different slug to avoid routing conflicts."
           )
         )}

      {:error, :invalid_slug} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext(
             "Invalid slug format. Please use only lowercase letters, numbers, and hyphens (e.g. my-post-title)"
           )
         )}

      {:error, :slug_already_exists} ->
        {:noreply, put_flash(socket, :error, gettext("A post with that slug already exists"))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save post"))}
    end
  end

  defp post_form(post) do
    base = %{
      "status" => post.metadata.status || "draft",
      "published_at" =>
        post.metadata.published_at ||
          DateTime.utc_now()
          |> floor_datetime_to_minute()
          |> DateTime.to_iso8601(),
      "featured_image_id" => post.metadata.featured_image_id || ""
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
        Map.put(base, "slug", String.trim(slug || ""))

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
      blog: blog_slug,
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
    |> assign(:form, form)
    |> assign(:content, data[:content] || "")
    |> assign(:current_language, language)
    |> assign(:available_languages, post.available_languages)
    |> assign(:all_enabled_languages, Storage.enabled_language_codes())
    |> assign(:has_pending_changes, true)
    |> assign(:is_new_post, data[:is_new_post] || false)
    |> assign(:public_url, build_public_url(post, language))
    |> assign(:blog_name, Blogging.blog_name(blog_slug) || blog_slug)
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

    Routes.path("/admin/blogging/#{blog_slug}/edit#{query}",
      locale: socket.assigns.current_locale
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
      blog: blog_slug,
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
      slug: nil
    }
  end

  defp build_virtual_post(blog_slug, _mode, primary_language, now) do
    date = DateTime.to_date(now)
    time = DateTime.to_time(now)

    time_folder =
      "#{String.pad_leading(to_string(time.hour), 2, "0")}:#{String.pad_leading(to_string(time.minute), 2, "0")}"

    %{
      blog: blog_slug,
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
      mode: :timestamp
    }
  end

  defp slug_base_dir(post, blog_slug) do
    cond do
      Map.get(post, :mode) == :slug and Map.get(post, :slug) ->
        Path.join([blog_slug || "blog", post.slug])

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
    blog_slug = post.blog || "blog"

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
end
