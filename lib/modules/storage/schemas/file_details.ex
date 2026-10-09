defmodule PhoenixKit.Modules.Storage.FileDetails do
  @moduledoc """
  A media file's translatable details — title, alt text and description —
  **in one language**.

  Not a table. The text lives on the file row's `data` column (V199), and
  this module is the one read and write path for it:

      %{
        "en-US" => %{"title" => "Harbour", "alt" => "Boats in a harbour"},
        "et" => %{"title" => "Sadam"}
      }

  Every language holds its own text, independently. **No language is marked
  as the primary one in the data**, so a site that changes its primary
  language has nothing to convert: which text stands in for a missing
  translation is decided when it is read.

  This is deliberately not the `PhoenixKit.Utils.Multilang` structure, which
  stores every other language as a diff against an embedded primary. That
  pays off for a record with dozens of fields; for three it buys nothing and
  ties the stored text to a setting that can change.

  ## Reading

      FileDetails.translated_alt(file, "et")      # "" when there is none
      FileDetails.translated_title(file, "et")    # nil when there is none
      FileDetails.for_locale(file, "et")          # all three

  Each field resolves on its own: the language asked for (or a dialect of
  it) → the site's current primary language → any other language. The alt
  text never falls back to the file name: a file name read aloud helps
  nobody, and `alt=""` correctly marks the image as undescribed.

  The site's primary language is read from `PhoenixKit.Utils.Multilang`; a
  caller resolving many files passes it once as `primary:`.

  ## Files from before V199

  They hold a title and description in `metadata`, in no recorded language.
  While a file's `data` is empty that text is its primary-language text. The
  first save moves it into `data`; from then on `data` is the truth, and
  `metadata` only receives a copy of the primary-language text for the
  readers that still look there (the PDF processor's fill-if-missing title,
  the viewer's stored title).

  ## Writing

  A save replaces one language's text and nothing else:

      Storage.update_file_details(file, %{"title" => "Sadam"}, lang: "et")
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Storage.File
  alias PhoenixKit.Utils.Multilang

  @fields ~w(title alt description)
  @field_atoms Enum.map(@fields, &String.to_atom/1)

  @type t :: %__MODULE__{
          title: String.t() | nil,
          alt: String.t() | nil,
          description: String.t() | nil
        }

  @primary_key false
  embedded_schema do
    field :title, :string
    field :alt, :string
    field :description, :string
  end

  @doc "The translatable field names."
  @spec fields() :: [String.t()]
  def fields, do: @fields

  @doc """
  The content language a page shown in `locale` edits and reads: the enabled
  language that `locale` names — so a URL's bare `"et"` and the hook's
  `"et-EE"` store under the one code the site has enabled. A locale that is
  no enabled language (the Gettext default on a site that never enabled it)
  is the primary language: text must not pile up under a code no page is
  ever shown in.

  Options: `:languages` — the enabled language codes, `:primary`.
  """
  @spec content_language(String.t() | nil, keyword()) :: String.t()
  def content_language(locale, opts \\ []) do
    languages = Keyword.get_lazy(opts, :languages, &Multilang.enabled_languages/0)

    cond do
      not is_binary(locale) -> primary(opts)
      locale in languages -> locale
      true -> Enum.find(languages, &same_language?(&1, locale)) || primary(opts)
    end
  end

  @doc """
  The display name of content language `lang` — or `nil` on a site with a
  single language, where there is nothing to tell the editor.
  """
  @spec language_name(String.t()) :: String.t() | nil
  def language_name(lang) do
    if Multilang.enabled?() do
      Enum.find_value(Multilang.build_language_tabs(), lang, fn tab ->
        if tab.code == lang, do: tab.name
      end)
    end
  end

  @doc """
  The text `file` holds in `lang` itself — no fallback to another language,
  so an editor shows what that language really has. "Itself" includes the
  same language stored at another precision (`"en"` for `"en-US"`), which a
  save replaces; it does not include a sibling dialect (`"en-GB"`), which is
  another language — an editor opened on it would save a copy of it.

  Options: `:primary` — the site's primary language (default: the current
  one).
  """
  @spec from_file(File.t(), String.t() | nil, keyword()) :: t()
  def from_file(%File{} = file, lang \\ nil, opts \\ []) do
    primary = primary(opts)
    struct(__MODULE__, atomize(own_text(file, lang || primary, primary, :own)))
  end

  @doc """
  What a form posted, as `%{language => attrs}`.

  The editors send one block per language (`details[et][title]`); a flat map
  with the three keys at its top (`title`, `alt`, `description`: the shape from
  before the editors had language tabs) is the text of `default`. Only a block
  for a language in `allowed` (and `default`) is kept, and only its three
  keys, so a posted code cannot invent a language.
  """
  @spec by_language(map() | nil, String.t(), [String.t()]) :: %{String.t() => map()}
  def by_language(params, default, allowed \\ [])

  def by_language(%{} = params, default, allowed) do
    if Enum.any?(@fields, &Map.has_key?(params, &1)) do
      %{default => Map.take(params, @fields)}
    else
      permitted = [default | allowed]

      for {lang, %{} = attrs} <- params, lang in permitted, into: %{} do
        {lang, Map.take(attrs, @fields)}
      end
    end
  end

  def by_language(_params, _default, _allowed), do: %{}

  @doc """
  Changeset for one language's text. `attrs` holds `"title"`, `"alt"` and
  `"description"`; a key that is absent keeps its current value.
  """
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(%__MODULE__{} = details, attrs) do
    details
    |> cast(attrs, @field_atoms)
    |> update_change(:title, &clean/1)
    |> update_change(:alt, &clean/1)
    |> update_change(:description, &clean/1)
    |> validate_length(:title, max: 255)
    |> validate_length(:alt, max: 500)
    |> validate_length(:description, max: 5000)
  end

  @doc """
  The `File.details_changeset/2` attrs that store `details` as `file`'s text
  in `lang`.

  Only that language's entry in `data` changes (an entry left with no text
  is removed). A file from before V199 first gets its `metadata` text moved
  into `data` under the primary language. When `lang` is the primary
  language, `metadata` receives a copy — a cleared field as `""`, not
  removed: the PDF processor fills a *missing* `"title"` from the document,
  and a title the user cleared must stay cleared.
  """
  @spec file_attrs(File.t(), t(), String.t() | nil, keyword()) :: %{
          metadata: map(),
          data: map()
        }
  def file_attrs(%File{} = file, %__MODULE__{} = details, lang \\ nil, opts \\ []) do
    primary = primary(opts)
    lang = lang || primary
    entry = details |> Map.take(@field_atoms) |> stringify()

    data =
      file
      |> adopt_legacy_text(primary)
      |> drop_entry(lang)
      |> put_entry(lang, entry)

    metadata =
      if same_language?(lang, primary),
        do: mirror(file.metadata || %{}, entry),
        else: file.metadata || %{}

    %{metadata: metadata, data: data}
  end

  # ── Reading ───────────────────────────────────────────────────

  @doc """
  One detail of `file` in `locale`: that language's text, else the primary
  language's, else any language's, else `nil`. A `nil` locale reads the
  primary language.

  Options: `:primary` — the site's primary language (default: the current
  one).
  """
  @spec translated(File.t(), String.t(), String.t() | nil, keyword()) :: String.t() | nil
  def translated(%File{} = file, field, locale \\ nil, opts \\ []) when field in @fields do
    primary = primary(opts)

    own_text(file, locale || primary, primary)[field] ||
      own_text(file, primary, primary)[field] ||
      any_language(file, field)
  end

  @doc "The title in `locale`, or `nil`."
  @spec translated_title(File.t(), String.t() | nil, keyword()) :: String.t() | nil
  def translated_title(file, locale \\ nil, opts \\ []),
    do: translated(file, "title", locale, opts)

  @doc "The description in `locale`, or `nil`."
  @spec translated_description(File.t(), String.t() | nil, keyword()) :: String.t() | nil
  def translated_description(file, locale \\ nil, opts \\ []),
    do: translated(file, "description", locale, opts)

  @doc """
  The alt text in `locale`, ready for an `alt` attribute: `""` when the file
  has none. Never the file name.
  """
  @spec translated_alt(File.t(), String.t() | nil, keyword()) :: String.t()
  def translated_alt(file, locale \\ nil, opts \\ []),
    do: translated(file, "alt", locale, opts) || ""

  @doc "All three details of `file` in `locale`."
  @spec for_locale(File.t(), String.t() | nil, keyword()) :: %{
          title: String.t() | nil,
          alt: String.t(),
          description: String.t() | nil
        }
  def for_locale(%File{} = file, locale \\ nil, opts \\ []) do
    opts = Keyword.put_new_lazy(opts, :primary, &Multilang.primary_language/0)

    %{
      title: translated_title(file, locale, opts),
      alt: translated_alt(file, locale, opts),
      description: translated_description(file, locale, opts)
    }
  end

  # ── Internals ─────────────────────────────────────────────────

  defp primary(opts), do: Keyword.get_lazy(opts, :primary, &Multilang.primary_language/0)

  # The non-blank text the file holds in `lang`, string-keyed. `:read`
  # accepts a sibling dialect's entry; `:own` does not (see `from_file/3`).
  defp own_text(%File{} = file, lang, primary, mode \\ :read) do
    data = languages(file.data)

    entry =
      cond do
        map_size(data) > 0 -> find_entry(data, lang, mode)
        same_language?(lang, primary) -> file.metadata || %{}
        true -> %{}
      end

    for field <- @fields, value = text(entry[field]), into: %{}, do: {field, value}
  end

  defp any_language(%File{} = file, field) do
    file.data
    |> languages()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.find_value(fn {_lang, entry} -> text(entry[field]) end)
  end

  # Only language entries: a map under a string key.
  defp languages(data) when is_map(data) do
    for {lang, %{} = entry} <- data, is_binary(lang), into: %{}, do: {lang, entry}
  end

  defp languages(_), do: %{}

  # Language codes differ per host and over time: the Languages module may
  # register bare base codes ("en") while the locale pipeline resolves URLs
  # to full dialects ("en-US") — or the reverse. An exact miss falls back to
  # the base code, then to the first stored entry sharing the base.
  defp find_entry(data, lang, :read) do
    base = DialectMapper.extract_base(lang)

    data[lang] || data[base] ||
      data
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find_value(%{}, fn {key, entry} ->
        if DialectMapper.extract_base(key) == base, do: entry
      end)
  end

  defp find_entry(data, lang, :own) do
    data[lang] ||
      data
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.find_value(%{}, fn {key, entry} -> if same_language?(key, lang), do: entry end)
  end

  defp adopt_legacy_text(%File{} = file, primary) do
    data = languages(file.data)

    if map_size(data) == 0,
      do: put_entry(data, primary, own_text(file, primary, primary)),
      else: data
  end

  # Removes the entry `lang` is about to replace — also when it sits under
  # the same language at a different precision ("en" while writing "en-US"),
  # where it would shadow or outlive the fresh write. A genuinely distinct
  # dialect ("en-GB" while writing "en-US") is another language and stays.
  defp drop_entry(data, lang) do
    Map.reject(data, fn {key, _entry} -> same_language?(key, lang) end)
  end

  defp put_entry(data, lang, entry) do
    entry = for {field, value} <- entry, text = text(value), into: %{}, do: {field, text}
    if map_size(entry) == 0, do: data, else: Map.put(data, lang, entry)
  end

  defp mirror(metadata, entry) do
    Enum.reduce(@fields, metadata, fn field, acc -> Map.put(acc, field, entry[field] || "") end)
  end

  # Identical codes, or one is the bare base form of the other.
  defp same_language?(a, b) when is_binary(a) and is_binary(b) do
    a == b or a == DialectMapper.extract_base(b) or b == DialectMapper.extract_base(a)
  end

  defp same_language?(_, _), do: false

  defp atomize(entry),
    do: Map.new(entry, fn {field, value} -> {String.to_existing_atom(field), value} end)

  defp stringify(entry),
    do: Map.new(entry, fn {field, value} -> {Atom.to_string(field), value} end)

  # Postgres rejects null bytes in text and jsonb.
  defp clean(value) when is_binary(value),
    do: value |> String.replace("\x00", "") |> String.trim()

  defp clean(value), do: value

  # A cleaned, non-blank string, or nil.
  defp text(value) when is_binary(value) do
    case clean(value) do
      "" -> nil
      cleaned -> cleaned
    end
  end

  defp text(_), do: nil
end
