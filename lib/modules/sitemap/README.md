# Sitemap

XML sitemaps (`/sitemap.xml`, per-source files under `/sitemaps/`) and an HTML
sitemap, built from **sources**: modules implementing
`PhoenixKit.Modules.Sitemap.Sources.Source`. Its moduledoc is the reference;
this page is the short version.

## Adding a source

```elixir
config :phoenix_kit, sitemap: [extra_sources: [MyApp.Sitemap.PageSource]]
```

`extra_sources:` adds to the defaults; `sources:` replaces them. A feature
module contributes sources through its `sitemap_sources/0` callback instead.

A source implements `source_name/0`, `enabled?/0` and **one** of:

- `collect(opts)` — returns the full list of `UrlEntry` structs. The generator
  holds it in memory, de-duplicates it, sorts it and (with several languages)
  groups translations into hreflang alternates.
- `stream(opts)` — returns a lazy `Enumerable` of `UrlEntry` structs, for
  sources with too many URLs to hold in memory (hundreds of thousands, millions).

## Streaming sources

```elixir
defmodule MyApp.Sitemap.ProductSource do
  @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

  import Ecto.Query
  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @impl true
  def source_name, do: :products

  @impl true
  def enabled?, do: true

  @impl true
  def stream(opts) do
    base_url = Keyword.fetch!(opts, :base_url)

    from(p in MyApp.Product, where: p.published, order_by: p.id, select: {p.slug, p.updated_at})
    |> MyApp.Repo.stream(max_rows: 1_000)
    |> Stream.map(fn {slug, updated_at} ->
      UrlEntry.new(%{loc: base_url <> "/products/" <> slug, lastmod: updated_at, source: :products})
    end)
  end
end
```

- **Transaction.** `Repo.stream/2` must be enumerated inside a transaction. The
  generator opens it (`repo.transaction(..., timeout: :infinity)` on
  PhoenixKit's repo) around the whole read, so `stream/1` returns the stream
  as above and must not wrap it in a transaction of its own (the stream would
  escape it). A source on another repo returns that repo from `stream_repo/0`;
  one that needs no database returns `nil`.
- **Files.** Written 50,000 URLs at a time as the stream is read:
  `sitemap-products.xml` when it fits one file, otherwise
  `sitemap-products-1.xml`, `-2.xml`, ... (the same names a collected source
  gets). The index lists them, and URL counts are summed while streaming.
- **Order and duplicates.** Written in stream order (order the query);
  duplicates are dropped only within each 50,000-URL chunk.
- **Languages.** `stream/1` is called once per enabled language
  (`opts[:language]`, `opts[:all_languages]`), and nothing is grouped across
  languages: an entry with translations carries its own `alternates`.
- **Flat mode.** Flat mode (Router Discovery on) writes one sorted `<urlset>`,
  which a stream cannot go into. While an enabled streaming source exists the
  site is generated and served in index mode, with a warning in the log.
- **HTML sitemap and domain mode.** A streamed source is not listed URL by
  URL in the HTML sitemap (it shows a link per XML file with its URL count)
  and is not part of the per-domain sitemaps.
- **Errors.** A stream that raises while being read is logged and that
  source's files are left out of the run; the other sources are written as
  usual — the same as a `collect/1` that raises.
