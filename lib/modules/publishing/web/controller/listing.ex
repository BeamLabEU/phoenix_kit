defmodule PhoenixKit.Modules.Publishing.Web.Controller.Listing do
  @moduledoc """
  Blog listing functionality for the publishing controller.

  Handles rendering blog post listings with:
  - Language filtering and fallback
  - Pagination
  - Translation link building for listings
  """

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Publishing
  alias PhoenixKit.Modules.Publishing.Web.Controller.Language
  alias PhoenixKit.Modules.Publishing.Web.Controller.PostFetching
  alias PhoenixKit.Modules.Publishing.Web.Controller.Translations
  alias PhoenixKit.Modules.Publishing.Web.HTML, as: PublishingHTML
  alias PhoenixKit.Settings

  # ============================================================================
  # Blog Listing Rendering
  # ============================================================================

  @doc """
  Renders a blog listing page.
  """
  def render_blog_listing(conn, blog_slug, language, params) do
    case fetch_blog(blog_slug) do
      {:ok, blog} ->
        # Only preserve pagination params for redirects
        pagination_params = Map.take(params, ["page"])

        # Check if we need to redirect to canonical URL
        canonical_language = Language.get_canonical_url_language(language)

        if canonical_language != language do
          # Redirect to canonical URL
          canonical_url =
            PublishingHTML.blog_listing_path(canonical_language, blog_slug, pagination_params)

          {:redirect, canonical_url}
        else
          page = get_page_param(params)
          per_page = get_per_page_setting()

          # Try cache first, fall back to filesystem scan
          all_posts_unfiltered = PostFetching.fetch_posts_with_cache(blog_slug)
          published_posts = filter_published(all_posts_unfiltered)

          # Resolve posts for the requested language, with fallback handling
          listing_context = %{
            blog: blog,
            blog_slug: blog_slug,
            language: language,
            canonical_language: canonical_language,
            published_posts: published_posts,
            all_posts_unfiltered: all_posts_unfiltered,
            page: page,
            per_page: per_page,
            pagination_params: pagination_params
          }

          resolve_listing_posts_for_language(conn, listing_context)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ============================================================================
  # Language Resolution for Listings
  # ============================================================================

  @doc """
  Resolves posts for the requested language, handling exact match vs fallback.
  """
  def resolve_listing_posts_for_language(conn, ctx) do
    exact_language_posts = filter_by_exact_language_strict(ctx.published_posts, ctx.language)

    case resolve_language_posts(
           exact_language_posts,
           ctx.published_posts,
           ctx.blog_slug,
           ctx.language
         ) do
      {:exact, posts} ->
        render_blog_index(conn, ctx, posts)

      {:fallback, fallback_language} ->
        fallback_url =
          PublishingHTML.blog_listing_path(
            fallback_language,
            ctx.blog_slug,
            ctx.pagination_params
          )

        {:redirect, fallback_url}

      :not_found ->
        {:error, :no_content_for_language}
    end
  end

  # Returns {:exact, posts}, {:fallback, language}, or :not_found
  defp resolve_language_posts(exact_posts, _published_posts, _blog_slug, _language)
       when exact_posts != [] do
    {:exact, exact_posts}
  end

  defp resolve_language_posts([], published_posts, blog_slug, language) do
    fallback_posts = filter_by_exact_language(published_posts, blog_slug, language)

    if fallback_posts != [] do
      {:fallback, get_fallback_language(language, fallback_posts)}
    else
      :not_found
    end
  end

  # ============================================================================
  # Blog Index Rendering
  # ============================================================================

  @doc """
  Renders the blog index page with resolved posts.
  """
  def render_blog_index(_conn, ctx, all_posts) do
    total_count = length(all_posts)
    posts = paginate(all_posts, ctx.page, ctx.per_page)
    breadcrumbs = [%{label: ctx.blog["name"], url: nil}]

    translations =
      Translations.build_listing_translations(
        ctx.blog_slug,
        ctx.canonical_language,
        ctx.all_posts_unfiltered
      )

    {:ok,
     %{
       page_title: ctx.blog["name"],
       blog: ctx.blog,
       posts: posts,
       current_language: ctx.canonical_language,
       translations: translations,
       page: ctx.page,
       per_page: ctx.per_page,
       total_count: total_count,
       total_pages: ceil(total_count / ctx.per_page),
       breadcrumbs: breadcrumbs
     }}
  end

  # ============================================================================
  # Filtering Functions
  # ============================================================================

  @doc """
  Filters posts to only include published ones.
  """
  def filter_published(posts) do
    Enum.filter(posts, fn post ->
      post.metadata.status == "published"
    end)
  end

  @doc """
  Filter posts to only include those that have a matching language file.
  Handles both exact matches and base code matches (e.g., "en" matches "en-US").
  Uses preloaded language_statuses to avoid redundant file reads.
  """
  def filter_by_exact_language(posts, _blog_slug, language) do
    Enum.filter(posts, fn post ->
      # Find the matching language file (exact or base code match)
      matching_language = find_matching_language(language, post.available_languages)

      # Use preloaded status from language_statuses map
      matching_language != nil and
        Map.get(post.language_statuses, matching_language) == "published"
    end)
  end

  @doc """
  Strict version - only matches exact language, no fallback to base code.
  """
  def filter_by_exact_language_strict(posts, language) do
    Enum.filter(posts, fn post ->
      language in post.available_languages and
        Map.get(post.language_statuses, language) == "published"
    end)
  end

  @doc """
  Find a matching language in available languages.
  Handles exact matches and base code matching.
  """
  def find_matching_language(language, available_languages) do
    cond do
      # Direct match
      language in available_languages ->
        language

      # Base code - find a dialect that matches
      Language.base_code?(language) ->
        Language.find_dialect_for_base_in_files(language, available_languages)

      # Full dialect not found - try base code match
      true ->
        base = DialectMapper.extract_base(language)
        Language.find_dialect_for_base_in_files(base, available_languages)
    end
  end

  @doc """
  Get the actual language that the fallback matched.
  Used to redirect to the correct URL when requested language has no content.
  """
  def get_fallback_language(requested_language, posts) do
    # Look at the first post to find what language actually matched
    case posts do
      [first_post | _] ->
        find_matching_language(requested_language, first_post.available_languages) ||
          requested_language

      [] ->
        requested_language
    end
  end

  # ============================================================================
  # Pagination
  # ============================================================================

  @doc """
  Paginates a list of posts.
  """
  def paginate(posts, page, per_page) do
    posts
    |> Enum.drop((page - 1) * per_page)
    |> Enum.take(per_page)
  end

  @doc """
  Gets the page number from params.
  """
  def get_page_param(params) do
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

  @doc """
  Gets the posts per page setting.
  """
  def get_per_page_setting do
    # Check new key first, fallback to legacy
    value =
      case Settings.get_setting_cached("publishing_posts_per_page") do
        nil -> Settings.get_setting_cached("blogging_posts_per_page")
        v -> v
      end

    case value do
      nil ->
        20

      v when is_binary(v) ->
        case Integer.parse(v) do
          {num, _} when num > 0 -> num
          _ -> 20
        end

      v when is_integer(v) and v > 0 ->
        v

      _ ->
        20
    end
  end

  # ============================================================================
  # Helper Functions
  # ============================================================================

  @doc """
  Fetches blog configuration by slug.
  """
  def fetch_blog(blog_slug) do
    blog_slug = blog_slug |> to_string() |> String.trim()

    case Enum.find(Publishing.list_groups(), fn blog ->
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

  @doc """
  Gets the default blog listing path for a language.
  """
  def default_blog_listing(language) do
    case Publishing.list_groups() do
      [%{"slug" => slug} | _] -> PublishingHTML.blog_listing_path(language, slug)
      _ -> nil
    end
  end
end
