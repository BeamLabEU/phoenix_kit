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
    all_enabled_languages = Storage.enabled_language_codes()
    primary_language = hd(all_enabled_languages)

    now = DateTime.utc_now() |> DateTime.truncate(:second) |> floor_datetime_to_minute()
    date = DateTime.to_date(now)
    time = DateTime.to_time(now)

    time_folder =
      "#{String.pad_leading(to_string(time.hour), 2, "0")}:#{String.pad_leading(to_string(time.minute), 2, "0")}"

    virtual_path =
      Path.join([blog_slug || "blog", Date.to_iso8601(date), time_folder, "#{primary_language}.phk"])

    default_blog_slug = blog_slug || "blog"

    virtual_post = %{
      blog: default_blog_slug,
      date: date,
      time: time,
      path: virtual_path,
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now)
      },
      content: "",
      language: primary_language,
      available_languages: []
    }

    socket =
      socket
      |> assign(:post, virtual_post)
      |> assign(:blog_name, Blogging.blog_name(blog_slug) || blog_slug)
      |> assign(:form, post_form(virtual_post))
      |> assign(:content, "")
      |> assign(:current_language, primary_language)
      |> assign(:available_languages, [])
      |> assign(:all_enabled_languages, all_enabled_languages)
      |> assign(
        :current_path,
        Routes.path("/admin/blogging/#{blog_slug}/edit", locale: socket.assigns.current_locale)
      )
      |> assign(:has_pending_changes, false)
      |> assign(:is_new_post, true)
      |> push_event("changes-status", %{has_changes: false})

    {:noreply, socket}
  end

  def handle_params(%{"path" => path} = params, _uri, socket) do
    blog_slug = socket.assigns.blog_slug

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

            socket
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
            |> push_event("changes-status", %{has_changes: false})
          else
            socket
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

  def handle_event("update_meta", params, socket) do
    params = Map.drop(params, ["_target"])

    new_form =
      socket.assigns.form
      |> Map.merge(params)
      |> normalize_form()

    has_changes = dirty?(socket.assigns.post, new_form, socket.assigns.content)

    {:noreply,
     socket
     |> assign(:form, new_form)
     |> assign(:has_pending_changes, has_changes)
     |> push_event("changes-status", %{has_changes: has_changes})}
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
      |> Map.take(["title", "status", "published_at"])
      |> Map.put("content", socket.assigns.content)

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

    new_path =
      post.path
      |> Path.dirname()
      |> Path.join("#{new_language}.phk")

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

      {:noreply,
       socket
       |> assign(:post, virtual_post)
       |> assign(:form, post_form(virtual_post))
       |> assign(:content, "")
       |> assign(:current_language, new_language)
       |> assign(:has_pending_changes, false)
       |> assign(:is_new_translation, true)
       |> assign(:original_post_path, post.path)
       |> push_event("changes-status", %{has_changes: false})}
    end
  end

  defp create_new_post(socket, params) do
    case Blogging.create_post(socket.assigns.blog_slug) do
      {:ok, new_post} ->
        case Blogging.update_post(socket.assigns.blog_slug, new_post, params) do
          {:ok, updated_post} ->
            {:noreply,
             socket
             |> assign(:post, updated_post)
             |> assign(:form, post_form(updated_post))
             |> assign(:content, updated_post.content)
             |> assign(:available_languages, updated_post.available_languages)
             |> assign(:has_pending_changes, false)
             |> assign(:is_new_post, false)
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
    original_path = Map.get(socket.assigns, :original_post_path, socket.assigns.post.path)

    case Blogging.add_language_to_post(
           socket.assigns.blog_slug,
           original_path,
           socket.assigns.current_language
         ) do
      {:ok, new_post} ->
        case Blogging.update_post(socket.assigns.blog_slug, new_post, params) do
          {:ok, updated_post} ->
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
    %{
      "title" => post.metadata.title || "",
      "status" => post.metadata.status || "draft",
      "published_at" =>
        post.metadata.published_at ||
          DateTime.utc_now()
          |> floor_datetime_to_minute()
          |> DateTime.to_iso8601()
    }
    |> normalize_form()
  end

  defp floor_datetime_to_minute(%DateTime{} = datetime) do
    %DateTime{datetime | second: 0, microsecond: {0, 0}}
  end

  defp dirty?(post, form, content) do
    normalized_form = normalize_form(form)
    normalized_form != post_form(post) || content != post.content
  end

  defp normalize_form(form) when is_map(form) do
    %{
      "title" => Map.get(form, "title", "") || "",
      "status" => Map.get(form, "status", "draft") || "draft",
      "published_at" => normalize_published_at(Map.get(form, "published_at"))
    }
  end

  defp normalize_form(_), do: %{"title" => "", "status" => "draft", "published_at" => ""}

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
end
