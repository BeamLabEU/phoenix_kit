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
  alias PhoenixKit.Utils.Routes

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

    # Check if this post's primary language matches the global setting
    global_primary = Storage.get_primary_language()

    primary_lang_status =
      cond do
        post_primary == nil -> {:needs_update, :backfill}
        post_primary != global_primary -> {:needs_update, :migration}
        true -> {:ok, :current}
      end

    # Get language names for display
    current_language_name = if lang_info, do: lang_info.name, else: String.upcase(language_code)
    primary_language_name = get_language_name(primary_language)
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
  def build_editor_languages(post, _group_slug, enabled_languages, current_language) do
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
        is_primary: is_primary,
        uuid: post[:uuid]
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
    group_slug = post.group || "group"

    case Map.get(post, :mode) do
      :slug -> build_slug_mode_url(group_slug, post, language)
      :timestamp -> build_timestamp_mode_url(group_slug, post, language)
      _ -> nil
    end
  end

  defp build_slug_mode_url(group_slug, post, language) do
    if post.slug do
      PublishingHTML.build_post_url(group_slug, post, language)
    else
      nil
    end
  end

  defp build_timestamp_mode_url(group_slug, post, language) do
    if post.metadata.published_at do
      case DateTime.from_iso8601(post.metadata.published_at) do
        {:ok, _datetime, _} -> PublishingHTML.build_post_url(group_slug, post, language)
        _ -> nil
      end
    else
      nil
    end
  end

  @doc """
  Gets the URL for a file from storage.
  """
  def get_file_url(file_uuid) do
    URLSigner.signed_url(file_uuid, "original")
  end

  # ============================================================================
  # Virtual Post Building
  # ============================================================================

  @doc """
  Builds a virtual post for new post creation.
  """
  def build_virtual_post(group_slug, "slug", primary_language, now) do
    %{
      group: group_slug,
      date: nil,
      time: nil,
      path: nil,
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        slug: "",
        featured_image_uuid: nil
      },
      content: "",
      language: primary_language,
      available_languages: [],
      mode: :slug,
      slug: nil,
      is_legacy_structure: false
    }
  end

  def build_virtual_post(group_slug, _mode, primary_language, now) do
    date = DateTime.to_date(now)
    time = DateTime.to_time(now)

    time_folder =
      "#{String.pad_leading(to_string(time.hour), 2, "0")}:#{String.pad_leading(to_string(time.minute), 2, "0")}"

    %{
      group: group_slug,
      date: date,
      time: time,
      path:
        Path.join([
          group_slug,
          Date.to_iso8601(date),
          time_folder,
          "#{primary_language}.phk"
        ]),
      full_path: nil,
      metadata: %{
        title: "",
        status: "draft",
        published_at: DateTime.to_iso8601(now),
        featured_image_uuid: nil
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
  def build_virtual_translation(post, group_slug, new_language, new_path, socket) do
    post
    |> Map.put(:path, new_path)
    |> Map.put(:language, new_language)
    |> Map.put(:group, group_slug || "group")
    |> Map.put(:content, "")
    |> Map.put(:metadata, Map.put(post.metadata, :title, ""))
    |> Map.put(:mode, post.mode)
    |> Map.put(:slug, post.slug || Map.get(socket.assigns.form, "slug"))
  end

  # ============================================================================
  # Featured Image Helpers
  # ============================================================================

  @doc """
  Gets the preview URL for a featured image.
  """
  def featured_image_preview_url(value) do
    case sanitize_featured_image_uuid(value) do
      nil ->
        nil

      file_uuid ->
        PublishingHTML.featured_image_url(
          %{metadata: %{featured_image_uuid: file_uuid}},
          "medium"
        )
    end
  end

  @doc """
  Sanitizes a featured image ID value.
  """
  def sanitize_featured_image_uuid(value) when is_binary(value) do
    value
    |> String.trim()
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  def sanitize_featured_image_uuid(_), do: nil

  # ============================================================================
  # URL Construction Helpers
  # ============================================================================

  @doc """
  Builds the URL for a post overview page.

  Uses UUID-based URL when available, falls back to legacy path URL.
  """
  def build_post_url(group_slug, post, _opts \\ []) do
    case post[:uuid] do
      nil ->
        # Fallback to legacy editor URL
        path = post[:path] || "#{post[:slug]}/v1/#{post[:language] || "en"}.phk"
        Routes.path("/admin/publishing/#{group_slug}/edit?path=#{URI.encode(path)}")

      uuid ->
        Routes.path("/admin/publishing/#{group_slug}/#{uuid}")
    end
  end

  @doc """
  Builds the URL for the post editor.

  Uses UUID-based URL when available, falls back to legacy path URL.
  Options: `:version`, `:lang`
  """
  def build_edit_url(group_slug, post, opts \\ []) do
    case post[:uuid] do
      nil ->
        # Fallback to legacy path URL
        path = post[:path] || "#{post[:slug]}/v1/#{post[:language] || "en"}.phk"

        base = "/admin/publishing/#{group_slug}/edit?path=#{URI.encode(path)}"

        base =
          if opts[:lang],
            do: "#{base}&lang=#{opts[:lang]}",
            else: base

        Routes.path(base)

      uuid ->
        base = "/admin/publishing/#{group_slug}/#{uuid}/edit"
        params = build_query_params(opts)

        if params == "" do
          Routes.path(base)
        else
          Routes.path("#{base}?#{params}")
        end
    end
  end

  @doc """
  Builds the URL for the post preview.
  """
  def build_preview_url(group_slug, post, _opts \\ []) do
    case post[:uuid] do
      nil ->
        Routes.path("/admin/publishing/#{group_slug}/preview")

      uuid ->
        Routes.path("/admin/publishing/#{group_slug}/#{uuid}/preview")
    end
  end

  @doc """
  Builds the URL for creating a new post.
  """
  def build_new_post_url(group_slug) do
    Routes.path("/admin/publishing/#{group_slug}/new")
  end

  defp build_query_params(opts) do
    params =
      []
      |> maybe_add_param("v", opts[:version])
      |> maybe_add_param("lang", opts[:lang])

    URI.encode_query(params)
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, key, value), do: [{key, value} | params]
end
