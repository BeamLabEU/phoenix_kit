defmodule PhoenixKit.Modules.Sitemap.Sources.Source do
  @moduledoc """
  Behaviour for sitemap data sources.

  Each source module must implement this behaviour to provide URL entries
  for sitemap generation.

  ## Required Callbacks

  - `source_name/0` - Unique atom identifier for the source
  - `enabled?/0` - Whether this source is active
  - `collect/1` **or** `stream/1` - The source's URL entries, as a list
    (`collect/1`) or as a lazy enumerable (`stream/1`). Implement one of the two.
    With Languages on either is called once per language and must return only
    `opts[:language]`'s entries (see `c:collect/1`).

  ## Optional Callbacks

  - `sitemap_filename/0` - Custom filename for the module's sitemap file
  - `sub_sitemaps/1` - Split into multiple sub-sitemap files (e.g., per-blog, per-entity-type)
  - `sitemap_settings_schema/0` - Declare source-specific settings for the admin UI
  - `stream_repo/0` - The repo whose transaction a `stream/1` source is read in

  ## Streaming sources (millions of URLs)

  `collect/1` returns the whole list, and the generator keeps it in memory,
  sorts it and de-duplicates it. That is fine for thousands of URLs, not for
  millions. A source that big implements `stream/1` instead and returns a
  lazy `Enumerable` of `UrlEntry` structs. In index mode the generator reads
  it in chunks of 50,000 and writes each `sitemap-{source}-N.xml` file as it
  goes, so at most two chunks are held at once. The file names are the same
  as for a collected source: one file is `sitemap-{source}.xml`, more than
  50,000 entries become `sitemap-{source}-1.xml`, `-2.xml`, ...

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

  **`Repo.stream/2` only works inside a transaction**, and the transaction
  has to be open while the stream is *enumerated*, not just while `stream/1`
  runs — so don't wrap `stream/1`'s body in `Repo.transaction/2` (the stream
  escapes it and fails on first read). The generator opens the transaction
  for you: it enumerates a streaming source inside
  `repo.transaction(fn -> ... end, timeout: :infinity)` on the repo PhoenixKit
  is configured with. A source reading another repo returns it from
  `stream_repo/0`; one that needs no database (a file, an API) returns `nil`
  there to skip the transaction.

  What the generator does **not** do for a streamed source, because each would
  need the whole list in memory:

  - **No sorting and no de-duplication across the stream.** Entries are
    written in the order the stream yields them (order your query), and
    duplicates are removed only within each 50,000-entry chunk. Don't emit the
    same `loc` twice.
  - **No hreflang grouping.** With several languages the generator calls
    `stream/1` once per language (`opts[:language]`, `opts[:is_default_language]`,
    `opts[:all_languages]`, as for `collect/1`) and writes the language streams
    one after another. It does not group entries across languages, so a
    streamed entry must carry its own `alternates` (see `UrlEntry`) if it has
    translations.
  - **No flat mode.** Flat mode writes one sorted `<urlset>` and cannot hold a
    stream, so while an enabled streaming source exists the generator uses
    index mode even when Router Discovery (flat mode) is on, and logs a
    warning. Router Discovery's URLs then go to their own `sitemap-routes.xml`.
  - **Not in the HTML sitemap or the per-domain sitemaps** (domain mode). The
    HTML sitemap shows a line per streamed file with its URL count and a link
    to the XML file instead of listing the URLs.

  A stream that raises while being read is logged and that source's files are
  left out of this run (the files it had written so far are removed), the same
  as a `collect/1` that raises; the other sources are generated normally.

  `sub_sitemaps/1` may return enumerables in place of lists too; a group whose
  entries are not a list is written in chunks the same way.
  """

  require Logger

  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @typedoc """
  Describes one source-specific setting for the admin settings UI.

  - `key` - the `PhoenixKit.Settings` key this field reads/writes
  - `type` - controls both the input widget and how the stored string is
    parsed (`:boolean` -> toggle, `:string` -> text input, `:integer` -> number input)
  - `label` - field label shown to the admin
  - `help` - optional helper text shown below the label
  - `default` - value used when the setting has never been saved
  """
  @type settings_field :: %{
          key: String.t(),
          type: :boolean | :string | :integer,
          label: String.t(),
          help: String.t() | nil,
          default: term()
        }

  @doc """
  Returns the unique name/identifier for this source.
  """
  @callback source_name() :: atom()

  @doc """
  Checks if this source is enabled and should be included in sitemap.
  """
  @callback enabled?() :: boolean()

  @doc """
  Collects the URL entries of this source.

  ## Options the generator passes

    * `:base_url` — the site's base URL, for building absolute `loc`s.
    * `:language` — set only when the Languages module is on with more than
      one language. The generator then calls `collect/1` **once per enabled
      language**, and each call must return **only the entries of that
      language** (its locale-prefixed URLs, or the prefix-free ones for the
      default language), each with a `canonical_path` (the path without the
      locale segment) so the generator can link the translations to each other
      with hreflang alternates.
    * `:is_default_language` — whether `:language` is the site's default.
    * `:all_languages` — every enabled language code, for reference.

  When `:language` is absent the site is single-language: return every entry
  once, without a locale segment.

  A source written while Languages was off often ignores `:language` and
  returns every URL on each call. The generator drops the repeats (each `loc`
  is listed once, each alternate once), but the source still does the work
  once per language; honour `opts[:language]`.
  """
  @callback collect(opts :: keyword()) :: [UrlEntry.t()]

  @doc """
  Returns this source's URL entries as a lazy enumerable (for sources with
  too many URLs to hold in memory). Implement this **instead of** `collect/1`;
  when both exist the generator only calls `stream/1`. See "Streaming sources"
  in the moduledoc for what the generator does and does not do with it.
  """
  @callback stream(opts :: keyword()) :: Enumerable.t()

  @doc """
  The repo whose transaction a `stream/1` source is enumerated in, or `nil`
  for no transaction. Default: the repo PhoenixKit is configured with.
  """
  @callback stream_repo() :: module() | nil

  @doc """
  Returns the base filename for this source's sitemap file (without .xml extension).

  Default: `"sitemap-\#{source_name()}"`
  """
  @callback sitemap_filename() :: String.t()

  @doc """
  Returns a list of sub-sitemaps for sources that produce multiple files.

  Return `nil` for a single file, or a list of `{group_name, entries}` tuples
  for per-group splitting (e.g., per-blog, per-entity-type).

  Each group will be saved as `sitemap-{source}-{group_name}.xml`.
  """
  @callback sub_sitemaps(opts :: keyword()) :: [{String.t(), [UrlEntry.t()]}] | nil

  @doc """
  Declares source-specific settings for the sitemap admin settings page.

  Optional. A source that implements this returns a list of field
  descriptors; the settings page renders one input per field (grouped
  under the source's name), reads/writes each through `PhoenixKit.Settings`
  using its `key` and `default`, and invalidates the sitemap cache on save
  — the same way the page's built-in settings work.

  Only add this for settings that don't already have a UI. Don't
  reimplement fields the core sitemap settings page already exposes (e.g.
  the built-in `sitemap_include_*` toggles).

  ## Example

      def sitemap_settings_schema do
        [
          %{
            key: "sitemap_entities_include_index",
            type: :boolean,
            label: "Include entity index pages",
            help: "Adds the /entities listing page alongside individual entries",
            default: true
          }
        ]
      end
  """
  @callback sitemap_settings_schema() :: [settings_field()]

  @optional_callbacks [
    collect: 1,
    stream: 1,
    stream_repo: 0,
    sitemap_filename: 0,
    sub_sitemaps: 1,
    sitemap_settings_schema: 0
  ]

  @doc """
  Helper function to check if a source module is valid.
  """
  @spec valid_source?(module()) :: boolean()
  def valid_source?(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        function_exported?(module, :source_name, 0) and
          function_exported?(module, :enabled?, 0) and
          (function_exported?(module, :collect, 1) or function_exported?(module, :stream, 1))

      {:error, _} ->
        false
    end
  end

  def valid_source?(_), do: false

  @doc """
  True when the source implements `stream/1` (and is therefore read lazily,
  never through `collect/1`).
  """
  @spec streaming?(module()) :: boolean()
  def streaming?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :stream, 1)
  end

  def streaming?(_), do: false

  @doc """
  Returns the sitemap filename for a source module.

  Calls the optional `sitemap_filename/0` callback if implemented,
  otherwise returns `"sitemap-\#{source_name()}"`.
  """
  @spec get_sitemap_filename(module()) :: String.t()
  def get_sitemap_filename(source_module) do
    if function_exported?(source_module, :sitemap_filename, 0) do
      source_module.sitemap_filename()
    else
      "sitemap-#{source_module.source_name()}"
    end
  end

  @doc """
  Returns sub-sitemaps for a source module, or nil if not implemented.
  """
  @spec get_sub_sitemaps(module(), keyword()) :: [{String.t(), [UrlEntry.t()]}] | nil
  def get_sub_sitemaps(source_module, opts \\ []) do
    if function_exported?(source_module, :sub_sitemaps, 1) do
      source_module.sub_sitemaps(opts)
    else
      nil
    end
  end

  @doc """
  Returns the settings schema for a source module.

  Calls the optional `sitemap_settings_schema/0` callback if implemented,
  otherwise returns `[]` (no source-specific settings to render).
  """
  @spec get_settings_schema(module()) :: [settings_field()]
  def get_settings_schema(source_module) do
    if function_exported?(source_module, :sitemap_settings_schema, 0) do
      source_module.sitemap_settings_schema()
    else
      []
    end
  end

  @doc """
  Safely collects entries from a source, handling errors gracefully.

  A streaming source (`streaming?/1`) is never collected: this returns `[]`
  for it, so no list-based path (flat mode, the HTML sitemap, domain mode)
  materialises a stream. Read one with `safe_stream/2`.
  """
  @spec safe_collect(module(), keyword()) :: [UrlEntry.t()]
  def safe_collect(source_module, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if valid_source?(source_module) and not streaming?(source_module) and
         (force or source_module.enabled?()) do
      source_module.collect(opts)
    else
      []
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap source #{inspect(source_module)} failed to collect: #{inspect(error)}"
      )

      []
  end

  @doc """
  The streaming counterpart of `safe_collect/2`.

  Returns `{:ok, enumerable}` for a valid, enabled (or `force: true`)
  streaming source, `:skip` for anything else (not a streaming source,
  disabled, or `stream/1` raised, exited or returned something that is not
  enumerable — those are logged).

  Unlike a list, a stream can still fail while it is being read, after part
  of it has been written out. The returned enumerable logs such a failure
  with the source's name and then raises `PhoenixKit.Modules.Sitemap.Sources.Source.StreamError`,
  so the consumer can drop what it wrote for this source (the generator
  does) instead of publishing a silently truncated sitemap. An `:exit` (a
  dead connection pool) is turned into the same exception.
  """
  @spec safe_stream(module(), keyword()) :: {:ok, Enumerable.t()} | :skip
  def safe_stream(source_module, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if valid_source?(source_module) and streaming?(source_module) and
         (force or source_module.enabled?()) do
      case source_module.stream(opts) do
        stream when is_list(stream) or is_struct(stream) or is_function(stream, 2) ->
          {:ok, guard_stream(stream, source_module)}

        other ->
          Logger.warning(
            "Sitemap source #{inspect(source_module)} stream/1 returned a non-enumerable: " <>
              inspect(other, limit: 5)
          )

          :skip
      end
    else
      :skip
    end
  rescue
    error ->
      Logger.warning(
        "Sitemap source #{inspect(source_module)} failed to stream: #{inspect(error)}"
      )

      :skip
  catch
    :exit, reason ->
      Logger.warning(
        "Sitemap source #{inspect(source_module)} failed to stream: #{inspect(reason)}"
      )

      :skip
  end

  @doc """
  The repo a streaming source is enumerated in a transaction of, or `nil`.

  `stream_repo/0` when the source implements it, otherwise the repo
  PhoenixKit is configured with (`nil` when there is none).
  """
  @spec stream_repo(module()) :: module() | nil
  def stream_repo(source_module) do
    if function_exported?(source_module, :stream_repo, 0) do
      source_module.stream_repo()
    else
      PhoenixKit.Config.get(:repo, nil)
    end
  end

  # Wraps every pull of the source's enumerable so a failure mid-way is
  # logged once, with the source's name, and surfaces as one exception type.
  # Suspended continuations are wrapped too, so a consumer that suspends
  # (zip, take) stays guarded on every resume.
  defp guard_stream(enumerable, source_module) do
    fn acc, fun ->
      guarded(&Enumerable.reduce(enumerable, &1, fun), source_module).(acc)
    end
  end

  defp guarded(reduce, source_module) do
    fn acc ->
      try do
        case reduce.(acc) do
          {:suspended, acc, continuation} ->
            {:suspended, acc, guarded(continuation, source_module)}

          other ->
            other
        end
      rescue
        error in __MODULE__.StreamError ->
          reraise error, __STACKTRACE__

        error ->
          raise_stream_error(source_module, error)
      catch
        :exit, reason ->
          raise_stream_error(source_module, {:exit, reason})
      end
    end
  end

  defp raise_stream_error(source_module, reason) do
    Logger.warning(
      "Sitemap source #{inspect(source_module)} failed while streaming: #{inspect(reason)}"
    )

    raise __MODULE__.StreamError, source: source_module, reason: reason
  end

  defmodule StreamError do
    @moduledoc """
    Raised by the enumerable `PhoenixKit.Modules.Sitemap.Sources.Source.safe_stream/2`
    returns when the source's stream fails while being read.
    """
    defexception [:source, :reason]

    @impl true
    def message(%{source: source, reason: reason}) do
      "sitemap source #{inspect(source)} failed while streaming: #{inspect(reason)}"
    end
  end
end
