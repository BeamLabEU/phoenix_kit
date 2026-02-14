defmodule PhoenixKit.Modules.Publishing.Web.Editor.Helpers do
  @moduledoc """
  Shared helper functions for the publishing editor.

  Contains utilities for URL building, language handling,
  virtual post creation, and other common operations.
  """

  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Storage
  alias PhoenixKit.Modules.Publishing.Web.Editor.Translation
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Modules.Storage.URLSigner

  # ============================================================================
  # Language Helpers
  # ============================================================================

  @doc """
  Assigns current language with enabled/known status.
  """
  def assign_current_language(socket, language_code) do
    enabled_languages = socket.assigns[:all_enabled_languages] || []
    lang_info = Publishing.get_language_info(language_code)
    post_primary = socket.assigns[:post] && socket.assigns.post[:primary_language]
    primary_language = post_primary || Storage.get_primary_language()
    is_primary = language_code == primary_language

    # Check if the post needs primary language migration
    primary_lang_status =
      case {socket.assigns[:blog_slug], socket.assigns[:post]} do
        {blog_slug, post} when is_binary(blog_slug) and is_map(post) ->
          post_dir = get_post_directory(post)

          if post_dir do
            Publishing.check_primary_language_status(blog_slug, post_dir)
          else
            {:ok, :current}
          end

        _ ->
          {:ok, :current}
      end

    # Get language names for display
    current_language_name = if lang_info, do: lang_info[:name], else: String.upcase(language_code)
    primary_language_name = get_language_name(primary_language)
    global_primary = Storage.get_primary_language()
    global_primary_language_name = get_language_name(global_primary)

    socket
    |> Phoenix.Component.assign(:current_language, language_code)
    |> Phoenix.Component.assign(:current_language_name, current_language_name)
    |> Phoenix.Component.assign(:primary_language_name, primary_language_name)
    |> Phoenix.Component.assign(:global_primary_language_name, global_primary_language_name)
    |> Phoenix.Component.assign(
      :current_language_enabled,
      Storage.language_enabled?(language_code, enabled_languages)
    )
    |> Phoenix.Component.assign(:current_language_known, lang_info != nil)
    |> Phoenix.Component.assign(:is_primary_language, is_primary)
    |> Phoenix.Component.assign(:post_primary_language_status, primary_lang_status)
    |> Translation.maybe_clear_completed_translation_status()
  end

  @doc """
  Gets the language name for a language code.
  """
  def get_language_name(language_code) do
    case Publishing.get_language_info(language_code) do
      %{name: name} -> name
      _ -> String.upcase(language_code)
    end
  end

  @doc """
  Formats a list of language codes for display.
  """
  def format_language_list(language_codes) when is_list(language_codes) do
    count = length(language_codes)

    cond do
      count == 0 ->
        ""

      count <= 3 ->
        Enum.map_join(language_codes, ", ", &get_language_name/1)

      true ->
        "#{count} languages"
    end
  end

  def format_language_list(_), do: ""

  @doc """
  Gets the editor language from assigns.
  """
  def editor_language(assigns) do
    assigns[:current_language] ||
      assigns |> Map.get(:post, %{}) |> Map.get(:language) ||
      hd(Storage.enabled_language_codes())
  end

  @doc """
  Builds language data for the publishing_language_switcher component.
  """
  def build_editor_languages(post, _blog_slug, enabled_languages, current_language) do
    post_primary = post[:primary_language] || Storage.get_primary_language()

    all_languages =
      Storage.order_languages_for_display(
        post.available_languages || [],
        enabled_languages,
        post_primary
      )

    language_statuses = Map.get(post, :language_statuses) || %{}

    Enum.map(all_languages, fn lang_code ->
      lang_info = Publishing.get_language_info(lang_code)
      file_exists = lang_code in (post.available_languages || [])
      is_current = lang_code == current_language
      is_enabled = Storage.language_enabled?(lang_code, enabled_languages)
      is_known = lang_info != nil
      is_primary = lang_code == post_primary

      status = Map.get(language_statuses, lang_code)
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
        known: is_known,
        is_primary: is_primary
      }
    end)
  end

  # ============================================================================
  # URL Helpers
  # ============================================================================

  @doc """
  Builds the public URL for a post.
  """
  def build_public_url(post, language) do
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
      PublishingHTML.build_post_url(blog_slug, post, language)
    else
      nil
    end
  end

  defp build_timestamp_mode_url(blog_slug, post, language) do
    if post.metadata.published_at do
      case DateTime.from_iso8601(post.metadata.published_at) do
        {:ok, _datetime, _} -> PublishingHTML.build_post_url(blog_slug, post, language)
        _ -> nil
      end
    else
      nil
    end
  end

  @doc """
  Gets the URL for a file from storage.
  """
  def get_file_url(file_id) do
    URLSigner.signed_url(file_id, "original")
  end

  # ============================================================================
  # Virtual Post Building
  # ============================================================================

  @doc """
  Builds a virtual post for new post creation.
  """
  def build_virtual_post(blog_slug, "slug", primary_language, now) do
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

  def build_virtual_post(blog_slug, _mode, primary_language, now) do
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

  @doc """
  Builds a virtual translation for a new language.
  """
  def build_virtual_translation(post, blog_slug, new_language, new_path, socket) do
    post
    |> Map.put(:path, new_path)
    |> Map.put(:language, new_language)
    |> Map.put(:blog, blog_slug || "blog")
    |> Map.put(:content, "")
    |> Map.put(:metadata, Map.put(post.metadata, :title, ""))
    |> Map.put(:mode, post.mode)
    |> Map.put(:slug, post.slug || Map.get(socket.assigns.form, "slug"))
  end

  # ============================================================================
  # Post Directory Helpers
  # ============================================================================

  @doc """
  Gets post directory path for primary language status check.
  """
  def get_post_directory(%{mode: :timestamp, date: date, time: time})
      when not is_nil(date) and not is_nil(time) do
    date_str = Date.to_iso8601(date)
    time_str = format_time_for_path(time)
    Path.join(date_str, time_str)
  end

  def get_post_directory(%{slug: slug}) when is_binary(slug) and slug != "", do: slug
  def get_post_directory(_), do: nil

  defp format_time_for_path(%Time{} = time) do
    time
    |> Time.to_string()
    |> String.slice(0, 5)
    |> String.replace(":", ":")
  end

  defp format_time_for_path(time) when is_binary(time), do: String.slice(time, 0, 5)
  defp format_time_for_path(_), do: nil

  @doc """
  Gets the base directory for a slug-mode post.
  """
  def slug_base_dir(post, blog_slug) do
    cond do
      # For versioned posts, use the path to preserve version directory
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

  # ============================================================================
  # Featured Image Helpers
  # ============================================================================

  @doc """
  Gets the preview URL for a featured image.
  """
  def featured_image_preview_url(value) do
    case sanitize_featured_image_id(value) do
      nil ->
        nil

      file_id ->
        PublishingHTML.featured_image_url(%{metadata: %{featured_image_id: file_id}}, "medium")
    end
  end

  @doc """
  Sanitizes a featured image ID value.
  """
  def sanitize_featured_image_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def sanitize_featured_image_id(_), do: nil
end
