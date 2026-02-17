defmodule PhoenixKit.Modules.Sitemap.SitemapFile do
  @moduledoc """
  Struct representing a generated sitemap file's metadata.

  Used by `Generator` to track per-module file info for sitemapindex generation.

  ## Fields

  - `filename` - Base filename without extension (e.g., "sitemap-posts-1")
  - `url_count` - Number of URLs in this file
  - `lastmod` - Most recent lastmod timestamp across all URLs in the file
  """

  @enforce_keys [:filename, :url_count]
  defstruct [:filename, :url_count, :lastmod]

  @type t :: %__MODULE__{
          filename: String.t(),
          url_count: non_neg_integer(),
          lastmod: DateTime.t() | nil
        }
end
