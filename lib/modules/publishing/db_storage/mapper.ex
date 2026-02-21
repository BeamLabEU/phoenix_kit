defmodule PhoenixKit.Modules.Publishing.DBStorage.Mapper do
  @moduledoc """
  Transitional mapper: converts DB records to the legacy map format
  expected by Publishing's web layer (LiveViews, templates, controllers).

  This exists so the web layer doesn't need changes during the transition.
  Once the DB migration is complete and verified, the web layer can be
  updated to use DB records directly and this mapper can be removed.

  ## Legacy Map Shape

  The filesystem `Storage` module returns maps with these keys:
  - `:group` - group slug
  - `:slug` - post directory slug
  - `:url_slug` - per-language URL slug
  - `:date` - Date struct (timestamp mode)
  - `:time` - Time struct (timestamp mode)
  - `:path` - relative path
  - `:full_path` - absolute path
  - `:mode` - :timestamp or :slug atom
  - `:language` - current language code
  - `:available_languages` - list of language codes
  - `:language_statuses` - %{language => status}
  - `:version` - current version number
  - `:available_versions` - list of version numbers
  - `:version_statuses` - %{version_number => status}
  - `:version_dates` - %{version_number => date_string}
  - `:content` - markdown/PHK body
  - `:metadata` - map with :title, :description, :status, :slug, etc.
  - `:primary_language` - primary language code
  """

  alias PhoenixKit.Modules.Publishing.PublishingContent
  alias PhoenixKit.Modules.Publishing.PublishingPost
  alias PhoenixKit.Modules.Publishing.PublishingVersion

  @doc """
  Converts a full post read (post + version + content + all contents + all versions)
  into the legacy map format expected by the web layer.
  """
  def to_legacy_map(
        %PublishingPost{} = post,
        %PublishingVersion{} = version,
        %PublishingContent{} = content,
        all_contents,
        all_versions
      ) do
    available_languages = Enum.map(all_contents, & &1.language) |> Enum.sort()

    language_statuses =
      Map.new(all_contents, fn c -> {c.language, c.status} end)

    available_versions = Enum.map(all_versions, & &1.version_number) |> Enum.sort()

    version_statuses =
      Map.new(all_versions, fn v -> {v.version_number, v.status} end)

    version_dates =
      Map.new(all_versions, fn v ->
        {v.version_number, format_datetime(v.inserted_at)}
      end)

    version_languages =
      Map.new(all_versions, fn v ->
        {v.version_number, available_languages}
      end)

    group_slug = get_group_slug(post)

    %{
      uuid: post.uuid,
      group: group_slug,
      slug: post.slug,
      url_slug: presence(content.url_slug) || post.slug,
      date: post.post_date,
      time: post.post_time,
      path: build_path(post, version.version_number, content.language),
      full_path: nil,
      mode: String.to_existing_atom(post.mode),
      language: content.language,
      available_languages: available_languages,
      language_statuses: language_statuses,
      language_slugs: build_language_slugs(all_contents, post.slug),
      language_previous_slugs: build_language_previous_slugs(all_contents),
      version: version.version_number,
      available_versions: available_versions,
      version_statuses: version_statuses,
      version_dates: version_dates,
      version_languages: version_languages,
      is_legacy_structure: false,
      content: content.content,
      metadata: build_metadata(post, version, content),
      primary_language: post.primary_language
    }
  end

  @doc """
  Converts a post to a listing-format map (no content body, just metadata).
  Used for listing pages where full content isn't needed.
  """
  def to_listing_map(%PublishingPost{} = post, version, all_contents, all_versions) do
    available_languages = Enum.map(all_contents, & &1.language) |> Enum.sort()

    language_statuses =
      Map.new(all_contents, fn c -> {c.language, c.status} end)

    available_versions = Enum.map(all_versions, & &1.version_number) |> Enum.sort()

    version_statuses =
      Map.new(all_versions, fn v -> {v.version_number, v.status} end)

    version_dates =
      Map.new(all_versions, fn v ->
        {v.version_number, format_datetime(v.inserted_at)}
      end)

    primary_content =
      Enum.find(all_contents, fn c -> c.language == post.primary_language end) ||
        List.first(all_contents)

    group_slug = get_group_slug(post)
    current_version = if version, do: version.version_number, else: 1

    %{
      uuid: post.uuid,
      group: group_slug,
      slug: post.slug,
      url_slug: presence(primary_content && primary_content.url_slug) || post.slug,
      date: post.post_date,
      time: post.post_time,
      path: build_path(post, current_version, primary_content && primary_content.language),
      full_path: nil,
      mode: String.to_existing_atom(post.mode),
      language: post.primary_language,
      available_languages: available_languages,
      language_statuses: language_statuses,
      language_slugs: build_language_slugs(all_contents, post.slug),
      language_previous_slugs: build_language_previous_slugs(all_contents),
      version: current_version,
      available_versions: available_versions,
      version_statuses: version_statuses,
      version_dates: version_dates,
      version_languages: %{},
      is_legacy_structure: false,
      content: primary_content && extract_excerpt(primary_content),
      metadata: build_listing_metadata(post, primary_content),
      primary_language: post.primary_language,
      # Per-language data for listing pages (so language switching shows correct titles)
      language_titles: Map.new(all_contents, fn c -> {c.language, c.title} end),
      language_excerpts: Map.new(all_contents, fn c -> {c.language, extract_excerpt(c)} end)
    }
  end

  # ===========================================================================
  # Private Helpers
  # ===========================================================================

  defp get_group_slug(%PublishingPost{group: %{slug: slug}}), do: slug
  defp get_group_slug(%PublishingPost{} = _post), do: nil

  defp build_path(
         %PublishingPost{mode: "timestamp", post_date: date, post_time: time},
         version_number,
         language
       )
       when not is_nil(date) do
    date_str = Date.to_iso8601(date)
    time_str = if time, do: time |> Time.to_string() |> String.slice(0, 5), else: "00:00"
    version = version_number || 1
    lang = language || "en"
    "#{date_str}/#{time_str}/v#{version}/#{lang}.phk"
  end

  defp build_path(post, version_number, language) do
    slug = post.slug
    version = version_number || 1
    lang = language || post.primary_language || "en"
    "#{slug}/v#{version}/#{lang}.phk"
  end

  defp build_metadata(post, version, content) do
    %{
      title: content.title,
      description: PublishingContent.get_description(content),
      status: content.status,
      slug: post.slug,
      version: version.version_number,
      allow_version_access: PublishingPost.allow_version_access?(post),
      url_slug: content.url_slug,
      previous_url_slugs: PublishingContent.get_previous_url_slugs(content),
      published_at: format_datetime(post.published_at),
      featured_image_id: PublishingContent.get_featured_image_id(content),
      primary_language: post.primary_language
    }
  end

  defp build_listing_metadata(post, nil) do
    %{
      title: nil,
      description: nil,
      status: post.status,
      slug: post.slug,
      published_at: format_datetime(post.published_at),
      featured_image_id: nil,
      primary_language: post.primary_language
    }
  end

  defp build_listing_metadata(post, content) do
    %{
      title: content.title,
      description: PublishingContent.get_description(content),
      status: content.status,
      slug: post.slug,
      published_at: format_datetime(post.published_at),
      featured_image_id: PublishingContent.get_featured_image_id(content),
      primary_language: post.primary_language
    }
  end

  defp build_language_slugs(all_contents, default_slug) do
    Map.new(all_contents, fn c ->
      {c.language, presence(c.url_slug) || default_slug}
    end)
  end

  defp build_language_previous_slugs(all_contents) do
    Map.new(all_contents, fn c ->
      {c.language, PublishingContent.get_previous_url_slugs(c)}
    end)
  end

  defp extract_excerpt(%PublishingContent{} = content) do
    # Use custom excerpt from data, or description, or first paragraph
    case PublishingContent.get_excerpt(content) do
      excerpt when is_binary(excerpt) and excerpt != "" ->
        excerpt

      _ ->
        case PublishingContent.get_description(content) do
          desc when is_binary(desc) and desc != "" ->
            desc

          _ ->
            extract_first_paragraph(content.content)
        end
    end
  end

  defp extract_first_paragraph(nil), do: nil

  defp extract_first_paragraph(content) when is_binary(content) do
    content
    |> String.split(~r/\n\n+/)
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> List.first()
    |> case do
      nil -> ""
      text -> text |> String.trim() |> String.slice(0, 300)
    end
  end

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: to_string(other)

  # Returns nil for nil and empty string, otherwise the value
  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value
end
