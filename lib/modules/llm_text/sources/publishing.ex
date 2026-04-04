defmodule PhoenixKit.Modules.LLMText.Sources.Publishing do
  @moduledoc """
  LLM text source for PhoenixKit Publishing module.

  Generates:
  - Index entries (one per published post) for llms.txt
  - Individual `.txt` files per published post at `{group_slug}/{post_slug}.txt`

  Only active when the Publishing module is loaded and enabled.
  """

  @behaviour PhoenixKit.Modules.LLMText.Sources.Source

  @compile {:no_warn_undefined,
            [
              {PhoenixKit.Modules.Publishing, :enabled?, 0},
              {PhoenixKit.Modules.Publishing, :list_groups, 0},
              {PhoenixKit.Modules.Publishing, :list_posts, 2}
            ]}

  require Logger

  alias PhoenixKit.Utils.Routes

  @publishing_mod PhoenixKit.Modules.Publishing

  @impl true
  def source_name, do: :publishing

  @impl true
  def enabled? do
    Code.ensure_loaded?(@publishing_mod) and
      function_exported?(@publishing_mod, :enabled?, 0) and
      @publishing_mod.enabled?()
  rescue
    _ -> false
  end

  @impl true
  def collect_index_entries do
    if enabled?() do
      language = get_default_language()
      groups = @publishing_mod.list_groups()

      Enum.flat_map(groups, fn group ->
        group_slug = group["slug"]
        group_name = group["name"]

        group_slug
        |> @publishing_mod.list_posts(language)
        |> Enum.filter(&published?/1)
        |> Enum.map(fn post ->
          %{
            title: get_title(post),
            url: build_post_url(post, group_slug),
            description: extract_description(post),
            group: group_name
          }
        end)
      end)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "LLMText PublishingSource failed to collect index entries: #{inspect(error)}"
      )

      []
  end

  @impl true
  def collect_page_files do
    if enabled?() do
      language = get_default_language()
      groups = @publishing_mod.list_groups()

      Enum.flat_map(groups, fn group ->
        group_slug = group["slug"]

        group_slug
        |> @publishing_mod.list_posts(language)
        |> Enum.filter(&published?/1)
        |> Enum.map(fn post ->
          path = build_file_path(group_slug, get_post_slug(post))
          content = build_post_content(post, group_slug, get_title(post))
          {path, content}
        end)
      end)
    else
      []
    end
  rescue
    error ->
      Logger.warning("LLMText PublishingSource failed to collect page files: #{inspect(error)}")

      []
  end

  @doc """
  Builds the file path for a post's LLM text file.

      iex> build_file_path("blog", "hello-world")
      "blog/hello-world.txt"
  """
  @spec build_file_path(String.t(), String.t()) :: String.t()
  def build_file_path(group_slug, post_slug) do
    "#{group_slug}/#{post_slug}.txt"
  end

  @doc """
  Builds markdown content for a post's LLM text file.
  """
  @spec build_post_content(map(), String.t(), String.t()) :: String.t()
  def build_post_content(post, group_slug, title) do
    url = build_post_url(post, group_slug)
    description = extract_description(post)
    body = Map.get(post, :content, "")

    url_line = if url != "", do: "> Source: #{url}\n\n", else: ""
    desc_line = if description != "", do: "#{description}\n\n", else: ""
    body_part = if is_binary(body), do: body, else: ""

    "# #{title}\n\n#{url_line}#{desc_line}#{body_part}"
  end

  @doc """
  Extracts a description for a post.

  Uses metadata.description if available, otherwise falls back to the first
  160 characters of the post content.
  """
  @spec extract_description(map()) :: String.t()
  def extract_description(post) do
    case post do
      %{metadata: %{description: desc}} when is_binary(desc) and desc != "" ->
        desc

      %{metadata: %{"description" => desc}} when is_binary(desc) and desc != "" ->
        desc

      _ ->
        content = Map.get(post, :content, "")

        if is_binary(content) and content != "" do
          content
          |> String.replace(~r/\s+/, " ")
          |> String.trim()
          |> String.slice(0, 160)
        else
          ""
        end
    end
  end

  # Private helpers

  defp published?(post) do
    case post do
      %{metadata: %{status: "published"}} -> true
      %{metadata: %{"status" => "published"}} -> true
      _ -> false
    end
  end

  defp get_title(post) do
    case post do
      %{metadata: %{title: title}} when is_binary(title) and title != "" -> title
      %{metadata: %{"title" => title}} when is_binary(title) and title != "" -> title
      %{slug: slug} when is_binary(slug) -> format_slug(slug)
      _ -> "Post"
    end
  end

  defp get_post_slug(post) do
    case Map.get(post, :mode) do
      :timestamp ->
        date = Map.get(post, :date)
        time = Map.get(post, :time)

        if date && time do
          time_str = time |> Time.to_string() |> String.slice(0..4) |> String.replace(":", "-")
          "#{Date.to_iso8601(date)}-#{time_str}"
        else
          Map.get(post, :slug, "post") || "post"
        end

      _ ->
        Map.get(post, :url_slug) || Map.get(post, :slug, "post") || "post"
    end
  end

  defp build_post_url(post, group_slug) do
    site_url = get_site_url()
    prefix = get_url_prefix()
    post_slug = get_post_slug(post)

    path_parts =
      [prefix, group_slug, post_slug]
      |> Enum.reject(&(&1 in [nil, "", "/"]))

    path = "/" <> Enum.join(path_parts, "/")

    if site_url != "" do
      String.trim_trailing(site_url, "/") <> path
    else
      path
    end
  end

  defp get_default_language do
    PhoenixKit.Settings.get_content_language()
  rescue
    _ -> nil
  end

  defp get_site_url do
    PhoenixKit.Settings.get_setting("site_url", "")
  rescue
    _ -> ""
  end

  defp get_url_prefix do
    case Routes.url_prefix() do
      "/" -> ""
      prefix -> String.trim(prefix, "/")
    end
  rescue
    _ -> ""
  end

  defp format_slug(slug) do
    slug
    |> String.replace("-", " ")
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end
end
