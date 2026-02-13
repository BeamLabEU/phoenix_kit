defmodule PhoenixKit.Modules.Sitemap.HtmlGenerator do
  @moduledoc """
  HTML sitemap renderer for PhoenixKit.

  Generates human-readable HTML sitemaps in three styles:
  - **hierarchical** - grouped by category, then by first letter
  - **grouped** - grouped by category/source
  - **flat** - single alphabetical list with multi-column layout

  HTML sitemaps are generated on-the-fly and cached in ETS via `Cache`.
  They are NOT written to disk (unlike XML sitemaps).
  """

  alias PhoenixKit.Modules.Sitemap.Cache
  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @doc """
  Renders an HTML sitemap from pre-collected URL entries.

  Validation and cache lookup are handled by the caller (`Generator.generate_html/1`).
  This function only renders HTML and optionally caches the result.

  ## Parameters

  - `opts` - Options (`:style`, `:title`)
  - `entries` - Pre-collected URL entries
  - `cache_key` - Atom key for ETS cache storage
  - `cache_opts` - Optional: `[cache: false]` to skip caching
  """
  @spec generate(keyword(), [UrlEntry.t()], atom(), keyword()) :: {:ok, String.t()}
  def generate(opts, entries, cache_key, cache_opts \\ []) when is_list(entries) do
    style = Keyword.get(opts, :style, "hierarchical")
    title = Keyword.get(opts, :title, "Sitemap")
    cache_enabled = Keyword.get(cache_opts, :cache, true)

    html =
      case style do
        "hierarchical" -> render_hierarchical(entries, title)
        "grouped" -> render_grouped(entries, title)
        "flat" -> render_flat(entries, title)
      end

    if cache_enabled, do: Cache.put(cache_key, html)

    {:ok, html}
  end

  # ── Internal: rendering ───────────────────────────────────────────

  defp render_hierarchical(entries, title) do
    grouped =
      entries
      |> Enum.group_by(fn entry -> entry.category || "Other" end)
      |> Enum.sort_by(fn {category, _} -> category end)

    category_sections =
      Enum.map_join(grouped, "\n", fn {category, category_entries} ->
        letter_groups =
          category_entries
          |> Enum.group_by(fn entry ->
            t = entry.title || entry.loc
            String.upcase(String.at(t, 0) || "")
          end)
          |> Enum.sort_by(fn {letter, _} -> letter end)

        letter_sections =
          Enum.map_join(letter_groups, "\n", fn {letter, letter_entries} ->
            links =
              letter_entries
              |> Enum.sort_by(fn entry -> entry.title || entry.loc end)
              |> Enum.map_join("\n          ", &render_link/1)

            """
                  <div class="mb-4">
                    <h4 class="text-sm font-semibold text-muted mb-2">#{letter}</h4>
                    <ul class="ml-4 space-y-1">
                      #{links}
                    </ul>
                  </div>
            """
          end)

        """
              <div class="card mb-4">
                <div class="card-body">
                  <h3 class="card-title text-lg">#{UrlEntry.escape_xml(category)}</h3>
                  <div class="mt-2">
        #{letter_sections}
                  </div>
                </div>
              </div>
        """
      end)

    """
    <!DOCTYPE html>
    <html>
      <head>
    #{html_head(title)}</head>
      <body>
        <div class="container px-4 py-8 max-w-6xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
          <div class="grid md:grid-cols-2 gap-4">
    #{category_sections}
          </div>
        </div>
      </body>
    </html>
    """
  end

  defp render_grouped(entries, title) do
    grouped =
      entries
      |> Enum.group_by(fn entry ->
        entry.category || (entry.source && to_string(entry.source)) || "Other"
      end)
      |> Enum.sort_by(fn {group, _} -> group end)

    sections =
      Enum.map_join(grouped, "\n", fn {group, group_entries} ->
        links =
          group_entries
          |> Enum.sort_by(fn entry -> entry.title || entry.loc end)
          |> Enum.map_join("\n          ", &render_link/1)

        """
              <div class="card mb-6">
                <div class="card-body">
                  <h2 class="card-title">#{UrlEntry.escape_xml(group)}</h2>
                  <ul class="list-disc list-inside space-y-2 mt-2">
        #{links}
                  </ul>
                  <div class="text-sm text-muted mt-2">
                    #{length(group_entries)} page#{if length(group_entries) != 1, do: "s", else: ""}
                  </div>
                </div>
              </div>
        """
      end)

    """
    <!DOCTYPE html>
    <html>
      <head>
    #{html_head(title)}</head>
      <body>
        <div class="container px-4 py-8 max-w-4xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
    #{sections}
        </div>
      </body>
    </html>
    """
  end

  defp render_flat(entries, title) do
    links =
      entries
      |> Enum.sort_by(fn entry -> entry.title || entry.loc end)
      |> Enum.map_join("\n          ", &render_link/1)

    """
    <!DOCTYPE html>
    <html>
      <head>
    #{html_head(title)}</head>
      <body>
        <div class="container px-4 py-8 max-w-4xl">
          <h1 class="text-4xl font-bold mb-8 text-center">#{UrlEntry.escape_xml(title)}</h1>
          <div class="card">
            <div class="card-body">
              <p class="text-muted mb-4">Total: #{length(entries)} pages</p>
              <ul class="list-disc list-inside space-y-2 columns-1 md:columns-2 lg:columns-3">
    #{links}
              </ul>
            </div>
          </div>
        </div>
      </body>
    </html>
    """
  end

  # ── Shared helpers ────────────────────────────────────────────────

  defp render_link(entry) do
    display_title = entry.title || entry.loc

    ~s(<li><a href="#{UrlEntry.escape_xml(entry.loc)}" class="link">#{UrlEntry.escape_xml(display_title)}</a></li>)
  end

  defp html_head(title) do
    """
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>#{UrlEntry.escape_xml(title)}</title>
        <style>
          :root {
            --base-100: #ffffff;
            --base-200: #f3f4f6;
            --base-content: #1f2937;
            --primary: #3b82f6;
            color-scheme: light dark;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --base-100: #1f2937;
              --base-200: #374151;
              --base-content: #f3f4f6;
              --primary: #60a5fa;
            }
          }
          * { box-sizing: border-box; margin: 0; padding: 0; }
          body {
            font-family: system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background-color: var(--base-100);
            color: var(--base-content);
            line-height: 1.5;
          }
          .container { width: 100%; max-width: 1280px; margin: 0 auto; }
          .px-4 { padding-left: 1rem; padding-right: 1rem; }
          .py-8 { padding-top: 2rem; padding-bottom: 2rem; }
          .max-w-4xl { max-width: 56rem; }
          .max-w-6xl { max-width: 72rem; }
          .text-4xl { font-size: 2.25rem; font-weight: 700; }
          .text-lg { font-size: 1.125rem; }
          .text-sm { font-size: 0.875rem; }
          .font-bold { font-weight: 700; }
          .font-semibold { font-weight: 600; }
          .text-center { text-align: center; }
          .mb-2 { margin-bottom: 0.5rem; }
          .mb-4 { margin-bottom: 1rem; }
          .mb-6 { margin-bottom: 1.5rem; }
          .mb-8 { margin-bottom: 2rem; }
          .mt-2 { margin-top: 0.5rem; }
          .ml-4 { margin-left: 1rem; }
          .card {
            background-color: var(--base-200);
            border-radius: 0.75rem;
            box-shadow: 0 1px 3px rgba(0, 0, 0, 0.1);
          }
          .card-body { padding: 1.5rem; }
          .card-title {
            font-size: 1.25rem;
            font-weight: 600;
            margin-bottom: 0.5rem;
          }
          .grid { display: grid; gap: 1rem; }
          .gap-4 { gap: 1rem; }
          @media (min-width: 768px) {
            .md\\:grid-cols-2 { grid-template-columns: repeat(2, 1fr); }
            .md\\:columns-2 { column-count: 2; }
          }
          @media (min-width: 1024px) {
            .lg\\:columns-3 { column-count: 3; }
          }
          ul { list-style: none; }
          .list-disc { list-style-type: disc; }
          .list-inside { list-style-position: inside; }
          .space-y-1 > * + * { margin-top: 0.25rem; }
          .space-y-2 > * + * { margin-top: 0.5rem; }
          a.link {
            color: var(--primary);
            text-decoration: none;
            transition: opacity 0.15s;
          }
          a.link:hover { opacity: 0.8; text-decoration: underline; }
          .text-muted { opacity: 0.7; }
          .columns-1 { column-count: 1; }
        </style>
    """
  end
end
