defmodule PhoenixKitWeb.Live.Modules.Blogging.Editor do
  @moduledoc """
  Markdown editor for blogging posts.
  """
  use PhoenixKitWeb, :live_view
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage
  alias PhoenixKit.Settings
  alias PhoenixKit.Utils.Routes

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
  def handle_params(%{"new" => "true"}, _uri, socket) do
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
        Routes.path("/admin/blogging/#{blog_slug}/edit", locale: socket.assigns.current_locale)
      )
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_post, true)
      |> assign(:public_url, nil)
      |> push_event("changes-status", %{has_changes: false})

    {:noreply, socket}
  end

  def handle_params(%{"path" => path} = params, _uri, socket) do
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
              |> Map.put(:blog, blog_slug || "blog")
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
              Routes.path("/admin/blogging/#{blog_slug}/edit",
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
            |> assign(:post, %{post | blog: blog_slug || "blog"})
            |> assign(:blog_name, Blogging.blog_name(blog_slug) || blog_slug)
            |> assign(:form, post_form(post))
            |> assign(:content, post.content)
            |> assign(:current_language, post.language)
            |> assign(:available_languages, post.available_languages)
            |> assign(:all_enabled_languages, all_enabled_languages)
            |> assign(
              :current_path,
              Routes.path("/admin/blogging/#{blog_slug}/edit",
                locale: socket.assigns.current_locale
              )
            )
            |> assign(:has_pending_changes, false)
            |> assign(:public_url, build_public_url(post, socket.assigns.current_locale))
            |> push_event("changes-status", %{has_changes: false})
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

  @impl true
  def handle_event("update_meta", params, socket) do
    params =
      params
      |> Map.drop(["_target"])
      |> maybe_autofill_slug(socket)

    with :ok <- validate_slug(socket.assigns.blog_mode, params, socket) do
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

      public_url = build_public_url(updated_post, socket.assigns.current_locale)

      {:noreply,
       socket
       |> assign(:form, new_form)
       |> assign(:has_pending_changes, has_changes)
       |> assign(:public_url, public_url)
       |> push_event("changes-status", %{has_changes: has_changes})}
    else
      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("update_content", %{"content" => content}, socket) do
    has_changes = dirty?(socket.assigns.post, socket.assigns.form, content)

    socket =
      socket
      |> assign(:content, content)
      |> assign(:has_pending_changes, has_changes)

    {:noreply, push_event(socket, "changes-status", %{has_changes: has_changes})}
  end

  def handle_event("save", _params, %{assigns: %{has_pending_changes: false}} = socket) do
    {:noreply, socket}
  end

  def handle_event("save", _params, socket) do
    params =
      socket.assigns.form
      |> Map.take(["title", "status", "published_at", "slug"])
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
    {:noreply,
     push_navigate(socket,
       to:
         Routes.path(
           "/admin/blogging/#{socket.assigns.blog_slug}/preview?path=#{URI.encode(socket.assigns.post.path)}",
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
    create_opts =
      if socket.assigns.blog_mode == "slug" do
        %{
          title: Map.get(params, "title"),
          slug: Map.get(params, "slug")
        }
      else
        %{}
      end

    case Blogging.create_post(socket.assigns.blog_slug, create_opts) do
      {:ok, new_post} ->
        case Blogging.update_post(socket.assigns.blog_slug, new_post, params) do
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

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to save post"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create post"))}
    end
  end

  defp create_new_translation(socket, params) do
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
        case Blogging.update_post(socket.assigns.blog_slug, new_post, params) do
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

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Failed to save translation"))}
        end

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to create translation file"))}
    end
  end

  defp update_existing_post(socket, params) do
    case Blogging.update_post(socket.assigns.blog_slug, socket.assigns.post, params) do
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

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Failed to save post"))}
    end
  end

  defp post_form(post) do
    base = %{
      "title" => post.metadata.title || "",
      "status" => post.metadata.status || "draft",
      "published_at" =>
        post.metadata.published_at ||
          DateTime.utc_now()
          |> floor_datetime_to_minute()
          |> DateTime.to_iso8601()
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
    base =
      %{
        "title" => Map.get(form, "title", "") || "",
        "status" => Map.get(form, "status", "draft") || "draft",
        "published_at" => normalize_published_at(Map.get(form, "published_at"))
      }

    case Map.fetch(form, "slug") do
      {:ok, slug} ->
        Map.put(base, "slug", String.trim(slug || ""))

      :error ->
        base
    end
  end

  defp normalize_form(_),
    do: %{"title" => "", "status" => "draft", "published_at" => "", "slug" => ""}

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

  defp build_virtual_post(blog_slug, "slug", primary_language, now) do
    default_blog_slug = blog_slug || "blog"

    %{
      blog: default_blog_slug,
      date: nil,
      time: nil,
      path: nil,
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        slug: ""
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

    default_blog_slug = blog_slug || "blog"

    %{
      blog: default_blog_slug,
      date: date,
      time: time,
      path:
        Path.join([
          default_blog_slug,
          Date.to_iso8601(date),
          time_folder,
          "#{primary_language}.phk"
        ]),
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now)
      },
      content: "",
      language: primary_language,
      available_languages: [],
      mode: :timestamp
    }
  end

  defp maybe_autofill_slug(params, %{assigns: %{blog_mode: "slug"} = assigns}) do
    trimmed_params =
      case Map.fetch(params, "slug") do
        {:ok, slug} when is_binary(slug) -> Map.put(params, "slug", String.trim(slug))
        {:ok, _} -> Map.put(params, "slug", "")
        :error -> params
      end

    slug_value = Map.get(trimmed_params, "slug")
    current_slug = assigns.form |> Map.get("slug", "")

    cond do
      is_binary(slug_value) and slug_value != "" ->
        trimmed_params

      slug_value == "" ->
        Map.put(trimmed_params, "slug", "")

      current_slug not in [nil, ""] ->
        Map.put(trimmed_params, "slug", current_slug)

      true ->
        title =
          Map.get(trimmed_params, "title") ||
            Map.get(assigns.form, "title") ||
            ""

        title = String.trim(to_string(title))

        if title == "" do
          Map.put(trimmed_params, "slug", "")
        else
          generated = Storage.generate_unique_slug(assigns.blog_slug, title, nil)
          Map.put(trimmed_params, "slug", generated)
        end
    end
  end

  defp maybe_autofill_slug(params, _socket) do
    Map.delete(params, "slug")
  end

  defp validate_slug("slug", params, socket) do
    slug =
      Map.get(params, "slug") ||
        Map.get(socket.assigns.form, "slug") ||
        ""

    cond do
      slug == "" ->
        :ok

      Storage.valid_slug?(slug) ->
        :ok

      true ->
        {:error, gettext("Slug must contain only lowercase letters, numbers, and hyphens")}
    end
  end

  defp validate_slug(_mode, _params, _socket), do: :ok

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
      blog_slug = post.blog || "blog"

      case Map.get(post, :mode) do
        :slug ->
          # Slug mode: /language/blog/blog-slug/post-slug
          if post.slug do
            "/#{language}/blog/#{blog_slug}/#{post.slug}"
          else
            nil
          end

        :timestamp ->
          # Timestamp mode: /language/blog/blog-slug/YYYY-MM-DD/HH:MM
          if post.metadata.published_at do
            case DateTime.from_iso8601(post.metadata.published_at) do
              {:ok, datetime, _} ->
                date = DateTime.to_date(datetime) |> Date.to_iso8601()
                time = format_time_for_url(datetime)
                "/#{language}/blog/#{blog_slug}/#{date}/#{time}"

              _ ->
                nil
            end
          else
            nil
          end

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp format_time_for_url(%DateTime{} = datetime) do
    datetime
    |> DateTime.to_time()
    |> Time.truncate(:second)
    |> then(fn time ->
      "#{String.pad_leading(to_string(time.hour), 2, "0")}:#{String.pad_leading(to_string(time.minute), 2, "0")}"
    end)
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
    PhoenixKit.Blogging.Renderer.invalidate_cache(blog_slug, identifier, post.language)
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

  defp extract_identifier_from_path(_), do: "unknown"
end
