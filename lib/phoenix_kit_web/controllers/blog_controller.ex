defmodule PhoenixKitWeb.BlogController do
  @moduledoc """
  Public blog post display controller.

  Handles public-facing routes for viewing published blog posts with multi-language support.

  URL patterns:
    /:language/:blog_slug/:post_slug - Slug mode post
    /:language/:blog_slug/:date/:time - Timestamp mode post
    /:language/:blog_slug - Blog listing
  """

  use PhoenixKitWeb, :controller
  require Logger

  alias PhoenixKit.Blogging.Renderer
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKitWeb.BlogHTML
  alias PhoenixKitWeb.Live.Modules.Blogging
  alias PhoenixKitWeb.Live.Modules.Blogging.Metadata
  alias PhoenixKitWeb.Live.Modules.Blogging.Storage

  @doc """
  Displays a blog post, blog listing, or all blogs overview.

  Path parsing determines which action to take:
  - [] -> Invalid request (no blog specified)
  - [blog_slug] -> Blog listing
  - [blog_slug, post_slug] -> Slug mode post
  - [blog_slug, date, time] -> Timestamp mode post
  """
  def show(conn, %{"language" => language_param} = params) do
    # Detect if 'language' param is actually a language code or a blog slug
    # This allows the same route to work for both single and multi-language setups
    {language, adjusted_params} = detect_language_or_blog(language_param, params)

    conn = assign(conn, :current_language, language)

    if Blogging.enabled?() and public_enabled?() do
      case build_segments(adjusted_params) do
        [] ->
          handle_not_found(conn, :invalid_path)

        segments ->
          case parse_path(segments) do
            {:listing, blog_slug} ->
              render_blog_listing(conn, blog_slug, language, conn.params)

            {:slug_post, blog_slug, post_slug} ->
              render_post(conn, blog_slug, {:slug, post_slug}, language)

            {:timestamp_post, blog_slug, date, time} ->
              render_post(conn, blog_slug, {:timestamp, date, time}, language)

            {:error, reason} ->
              handle_not_found(conn, reason)
          end
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # Fallback for routes without language parameter (shouldn't happen with new routing)
  def show(conn, params) do
    language = get_default_language()
    conn = assign(conn, :current_language, language)

    if Blogging.enabled?() and public_enabled?() do
      case build_segments(params) do
        [] ->
          handle_not_found(conn, :invalid_path)

        segments ->
          case parse_path(segments) do
            {:listing, blog_slug} ->
              render_blog_listing(conn, blog_slug, language, conn.params)

            {:slug_post, blog_slug, post_slug} ->
              render_post(conn, blog_slug, {:slug, post_slug}, language)

            {:timestamp_post, blog_slug, date, time} ->
              render_post(conn, blog_slug, {:timestamp, date, time}, language)

            {:error, reason} ->
              handle_not_found(conn, reason)
          end
      end
    else
      handle_not_found(conn, :module_disabled)
    end
  end

  # ============================================================================
  # Language Detection
  # ============================================================================

  # Detects whether the 'language' parameter is actually a language code or a blog slug.
  #
  # This allows the same route pattern (/:language/:blog/*path) to work for both:
  # - Multi-language: /en/my-blog/my-post (language=en, blog=my-blog)
  # - Single-language: /my-blog/my-post (language=my-blog, needs adjustment)
  #
  # Returns {detected_language, adjusted_params}
  defp detect_language_or_blog(language_param, params) do
    # Check if this looks like a valid language code
    if valid_language?(language_param) do
      # It's a real language code - use as-is
      {language_param, params}
    else
      # It's actually a blog slug - shift parameters
      # language_param becomes the blog, and what was 'blog' becomes part of path
      default_language = get_default_language()

      adjusted_params =
        case params do
          # Pattern: %{"language" => blog_slug, "blog" => first_path_segment, "path" => rest}
          %{"blog" => first_segment, "path" => rest} when is_list(rest) ->
            %{"blog" => language_param, "path" => [first_segment | rest]}

          # Pattern: %{"language" => blog_slug, "blog" => first_path_segment}
          %{"blog" => first_segment} ->
            %{"blog" => language_param, "path" => [first_segment]}

          # Pattern: %{"language" => blog_slug} (just listing)
          _ ->
            %{"blog" => language_param}
        end

      {default_language, adjusted_params}
    end
  end

  defp valid_language?(code) when is_binary(code) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Check if it's an enabled language code (full dialect like en-US)
    # OR if it's a valid base code (like en) that maps to an enabled dialect
    cond do
      Languages.language_enabled?(code) ->
        true

      # Check if it's a base code that maps to an enabled dialect
      String.length(code) == 2 and not String.contains?(code, "-") ->
        dialect = DialectMapper.base_to_dialect(code)
        Languages.language_enabled?(dialect)

      true ->
        false
    end
  rescue
    _ -> false
  end

  defp valid_language?(_), do: false

  # ============================================================================
  # Path Parsing
  # ============================================================================

  defp build_segments(%{"blog" => blog} = params) when is_binary(blog) do
    case Map.get(params, "path") do
      nil -> [blog]
      path when is_list(path) -> [blog | path]
      path when is_binary(path) -> [blog, path]
      _ -> [blog]
    end
  end

  defp build_segments(_), do: []

  defp parse_path([]), do: {:error, :invalid_path}
  defp parse_path([blog_slug]), do: {:listing, blog_slug}

  defp parse_path([blog_slug, segment1, segment2]) do
    # Check if this is timestamp mode: segment1 matches date, segment2 matches time
    if date?(segment1) and time?(segment2) do
      {:timestamp_post, blog_slug, segment1, segment2}
    else
      # Invalid format
      {:error, :invalid_path}
    end
  end

  defp parse_path([blog_slug, post_slug]) do
    {:slug_post, blog_slug, post_slug}
  end

  defp parse_path(_), do: {:error, :invalid_path}

  # Date validation: YYYY-MM-DD
  defp date?(str) when is_binary(str) do
    String.match?(str, ~r/^\d{4}-(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])$/)
  end

  defp date?(_), do: false

  # Time validation: HH:MM (24-hour)
  defp time?(str) when is_binary(str) do
    String.match?(str, ~r/^([01]\d|2[0-3]):[0-5]\d$/)
  end

  defp time?(_), do: false

  # ============================================================================
  # Rendering Functions
  # ============================================================================

  defp render_blog_listing(conn, blog_slug, language, params) do
    case fetch_blog(blog_slug) do
      {:ok, blog} ->
        page = get_page_param(params)
        per_page = get_per_page_setting()

        # List published posts
        all_posts =
          Blogging.list_posts(blog_slug, language)
          |> filter_published()

        total_count = length(all_posts)
        posts = paginate(all_posts, page, per_page)

        breadcrumbs = [
          %{label: blog["name"], url: nil}
        ]

        conn
        |> assign(:page_title, blog["name"])
        |> assign(:blog, blog)
        |> assign(:posts, posts)
        |> assign(:current_language, language)
        |> assign(:page, page)
        |> assign(:per_page, per_page)
        |> assign(:total_count, total_count)
        |> assign(:total_pages, ceil(total_count / per_page))
        |> assign(:breadcrumbs, breadcrumbs)
        |> render(:index)

      {:error, reason} ->
        handle_not_found(conn, reason)
    end
  end

  defp render_post(conn, blog_slug, identifier, language) do
    case fetch_post(blog_slug, identifier, language) do
      {:ok, post} ->
        # Check if published
        if post.metadata.status == "published" do
          # Render markdown
          html_content = render_markdown(post.content)

          # Build translation links
          translations = build_translation_links(blog_slug, post, language)

          # Build breadcrumbs
          breadcrumbs = build_breadcrumbs(blog_slug, post, language)

          conn
          |> assign(:page_title, post.metadata.title)
          |> assign(:blog_slug, blog_slug)
          |> assign(:post, post)
          |> assign(:html_content, html_content)
          |> assign(:current_language, language)
          |> assign(:translations, translations)
          |> assign(:breadcrumbs, breadcrumbs)
          |> render(:show)
        else
          log_404(conn, blog_slug, identifier, language, :unpublished)
          handle_not_found(conn, :unpublished)
        end

      {:error, reason} ->
        log_404(conn, blog_slug, identifier, language, reason)
        handle_not_found(conn, reason)
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  defp fetch_blog(blog_slug) do
    blog_slug = blog_slug |> to_string() |> String.trim()

    case Enum.find(Blogging.list_blogs(), fn blog ->
           case blog["slug"] do
             slug when is_binary(slug) ->
               String.downcase(slug) == String.downcase(blog_slug)

             _ ->
               false
           end
         end) do
      nil -> {:error, :blog_not_found}
      blog -> {:ok, blog}
    end
  end

  defp fetch_post(blog_slug, {:slug, post_slug}, language) do
    case Blogging.read_post(blog_slug, post_slug, language) do
      {:ok, post} -> {:ok, post}
      _ -> {:error, :post_not_found}
    end
  end

  defp fetch_post(blog_slug, {:timestamp, date, time}, language) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Resolve base code to dialect if needed (e.g., "en" -> "en-US")
    resolved_language = resolve_language_for_file(language)

    # Build path for timestamp mode: blog/date/time/language.phk
    path = "#{blog_slug}/#{date}/#{time}/#{resolved_language}.phk"

    case Blogging.read_post(blog_slug, path) do
      {:ok, post} -> {:ok, post}
      _ -> {:error, :post_not_found}
    end
  end

  # Resolve a language code to the appropriate file language
  # Handles both base codes (en) and full dialect codes (en-US)
  defp resolve_language_for_file(language) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    if String.length(language) == 2 and not String.contains?(language, "-") do
      # It's a base code - convert to default dialect
      DialectMapper.base_to_dialect(language)
    else
      # Already a full dialect code
      language
    end
  end

  defp render_markdown(content) do
    Renderer.render_markdown(content)
  end

  defp build_translation_links(blog_slug, post, current_language) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Get enabled languages
    enabled_languages =
      try do
        Languages.enabled_locale_codes()
      rescue
        _ -> ["en"]
      end

    # Extract base code from current language for comparison
    current_base = DialectMapper.extract_base(current_language)

    # Filter available languages to only show enabled ones
    languages =
      post.available_languages
      |> normalize_languages(current_language)
      |> Enum.filter(fn lang ->
        language_enabled?(lang, enabled_languages) and translation_published?(post, lang)
      end)

    Enum.map(languages, fn lang ->
      base_code = DialectMapper.extract_base(lang)

      %{
        code: base_code,
        name: get_language_name(lang),
        url: BlogHTML.build_post_url(blog_slug, post, base_code),
        current: base_code == current_base
      }
    end)
  end

  defp normalize_languages([], current_language), do: [current_language]
  defp normalize_languages(languages, _current_language) when is_list(languages), do: languages

  defp language_enabled?(language, enabled_languages), do: language in enabled_languages

  defp translation_published?(post, language) when language == post.language do
    Map.get(post.metadata, :status) == "published"
  end

  defp translation_published?(post, language) do
    case fetch_translation_metadata(post, language) do
      {:ok, metadata} -> Map.get(metadata, :status) == "published"
      _ -> false
    end
  end

  defp fetch_translation_metadata(post, language) do
    post.full_path
    |> Path.dirname()
    |> Path.join(Storage.language_filename(language))
    |> read_metadata()
  end

  defp read_metadata(path) do
    with true <- File.exists?(path),
         {:ok, contents} <- File.read(path),
         {:ok, metadata, _content} <- Metadata.parse_with_content(contents) do
      {:ok, metadata}
    else
      _ -> :error
    end
  end

  defp build_breadcrumbs(blog_slug, post, language) do
    {:ok, blog} = fetch_blog(blog_slug)

    [
      %{label: blog["name"], url: BlogHTML.blog_listing_path(language, blog_slug)},
      %{label: post.metadata.title, url: nil}
    ]
  end

  defp get_language_name(code) do
    case Languages.get_language(code) do
      %{"name" => name} -> name
      _ -> String.upcase(code)
    end
  end

  defp get_default_language do
    case Languages.get_default_language() do
      %{"code" => code} -> code
      _ -> "en"
    end
  end

  defp filter_published(posts) do
    Enum.filter(posts, fn post ->
      post.metadata.status == "published"
    end)
  end

  defp default_blog_listing(language) do
    case Blogging.list_blogs() do
      [%{"slug" => slug} | _] -> BlogHTML.blog_listing_path(language, slug)
      _ -> nil
    end
  end

  defp paginate(posts, page, per_page) do
    posts
    |> Enum.drop((page - 1) * per_page)
    |> Enum.take(per_page)
  end

  defp get_page_param(params) do
    case Map.get(params, "page", "1") do
      page when is_binary(page) ->
        case Integer.parse(page) do
          {num, _} when num > 0 -> num
          _ -> 1
        end

      page when is_integer(page) and page > 0 ->
        page

      _ ->
        1
    end
  end

  defp get_per_page_setting do
    case Settings.get_setting("blogging_posts_per_page") do
      nil ->
        20

      value when is_binary(value) ->
        case Integer.parse(value) do
          {num, _} when num > 0 -> num
          _ -> 20
        end

      value when is_integer(value) and value > 0 ->
        value

      _ ->
        20
    end
  end

  defp public_enabled? do
    Settings.get_boolean_setting("blogging_public_enabled", true)
  end

  defp log_404(conn, blog_slug, identifier, language, reason) do
    Logger.info("Blog 404",
      blog_slug: blog_slug,
      identifier: inspect(identifier),
      reason: reason,
      language: language,
      user_agent: get_req_header(conn, "user-agent") |> List.first(),
      path: conn.request_path
    )
  end

  defp handle_not_found(conn, reason) do
    # Try to fall back to nearest valid parent in the breadcrumb chain
    case attempt_breadcrumb_fallback(conn, reason) do
      {:ok, redirect_path} ->
        conn
        |> put_flash(
          :info,
          gettext("The page you requested was not found. Showing closest match.")
        )
        |> redirect(to: redirect_path)

      :no_fallback ->
        conn
        |> put_status(:not_found)
        |> put_view(html: PhoenixKitWeb.ErrorHTML)
        |> render(:"404")
    end
  end

  defp attempt_breadcrumb_fallback(conn, reason) do
    language = conn.assigns[:current_language] || "en"
    path = conn.params["path"] || []

    handle_fallback_case(reason, path, language)
  end

  defp handle_fallback_case(reason, [blog_slug, _post_identifier], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_to_blog_or_overview(blog_slug, language)
  end

  defp handle_fallback_case(reason, [blog_slug, _date, _time], language)
       when reason in [:post_not_found, :unpublished] do
    fallback_to_blog_or_overview(blog_slug, language)
  end

  defp handle_fallback_case(:blog_not_found, [_blog_slug], language) do
    fallback_to_default_blog(language)
  end

  defp handle_fallback_case(:blog_not_found, [], language) do
    fallback_to_default_blog(language)
  end

  defp handle_fallback_case(:post_not_found, [blog_slug, post_slug], language) do
    fallback_to_default_language(blog_slug, post_slug, language)
  end

  defp handle_fallback_case(_reason, _path, _language), do: :no_fallback

  defp fallback_to_default_blog(language) do
    case default_blog_listing(language) do
      nil -> :no_fallback
      path -> {:ok, path}
    end
  end

  defp fallback_to_blog_or_overview(blog_slug, language) do
    if blog_exists?(blog_slug) do
      {:ok, BlogHTML.blog_listing_path(language, blog_slug)}
    else
      case default_blog_listing(language) do
        nil -> :no_fallback
        path -> {:ok, path}
      end
    end
  end

  defp fallback_to_default_language(blog_slug, post_slug, language) do
    default_lang = get_default_language()

    if language != default_lang and blog_exists?(blog_slug) do
      # Try the post in default language
      case Blogging.read_post(blog_slug, post_slug, default_lang) do
        {:ok, post} when post.metadata.status == "published" ->
          {:ok, BlogHTML.build_post_url(blog_slug, post, default_lang)}

        _ ->
          # Post doesn't exist in default language either, go to blog listing
          {:ok, BlogHTML.blog_listing_path(default_lang, blog_slug)}
      end
    else
      :no_fallback
    end
  end

  defp blog_exists?(blog_slug) do
    case fetch_blog(blog_slug) do
      {:ok, _} -> true
      _ -> false
    end
  end
end
