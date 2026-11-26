defmodule PhoenixKit.Modules.Sitemap.Sources.Source do
  @moduledoc """
  Behaviour for sitemap data sources.

  Each source module must implement this behaviour to provide URL entries
  for sitemap generation.

  ## Required Callbacks

  - `source_name/0` - Unique atom identifier for the source
  - `enabled?/0` - Whether this source is active
  - `collect/1` - Collect URL entries from this source. With Languages on it is
    called once per language and must return only `opts[:language]`'s entries
    (see `c:collect/1`).

  ## Optional Callbacks

  - `sitemap_filename/0` - Custom filename for the module's sitemap file
  - `sub_sitemaps/1` - Split into multiple sub-sitemap files (e.g., per-blog, per-entity-type)
  - `sitemap_settings_schema/0` - Declare source-specific settings for the admin UI
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

  @optional_callbacks [sitemap_filename: 0, sub_sitemaps: 1, sitemap_settings_schema: 0]

  @doc """
  Helper function to check if a source module is valid.
  """
  @spec valid_source?(module()) :: boolean()
  def valid_source?(module) when is_atom(module) do
    case Code.ensure_loaded(module) do
      {:module, _} ->
        function_exported?(module, :source_name, 0) and
          function_exported?(module, :enabled?, 0) and
          function_exported?(module, :collect, 1)

      {:error, _} ->
        false
    end
  end

  def valid_source?(_), do: false

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
  """
  @spec safe_collect(module(), keyword()) :: [UrlEntry.t()]
  def safe_collect(source_module, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if valid_source?(source_module) and (force or source_module.enabled?()) do
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
end
