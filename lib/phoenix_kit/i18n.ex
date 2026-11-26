defmodule PhoenixKit.I18n do
  @moduledoc """
  The site's languages, for a host application's own localized pages.

  The kit's Languages settings (Admin → Settings → Languages) decide which
  languages the site serves, which one is primary, and whether the primary is
  served without a locale segment. This module hands those decisions to the
  host, so a host's `scope "/:locale"` accepts exactly the languages the kit
  serves and its links, `hreflang` tags and language switcher agree with the
  kit's own.

  The kit never mounts a `/:locale` scope for the host. The host declares it
  and puts `PhoenixKitWeb.Plugs.HostLocale` (a plug and an `on_mount` hook) in
  front of it; see the "Host locale routes" section of
  `guides/locale-routing.md`.

  ## Languages

  Each language is a map:

    * `:code` — the URL segment that serves it (`"et"`, or `"en-gb"` for an
      enabled sibling dialect next to an `en-US` that owns `/en/`)
    * `:locale` — the full dialect the kit resolves that segment to
      (`"et-EE"` or `"et"`, as configured; `"en-GB"`)
    * `:base` — the base language code (`"et"`, `"en"`)
    * `:hreflang` — the value for an `hreflang` attribute (`"et"`, `"en-GB"`)
    * `:name`, `:native_name`, `:flag` — for display
    * `:primary?` — the site's primary language
    * `:prefixless?` — served without a segment (the primary language, when
      the site serves it prefixless; always the case on a single-language
      site)

  ## URL builders

  The kit does not guess the shape of a host's URLs. `localized_url/3`,
  `hreflang_links/2` and `language_links/2` take one of:

    * `url: fun` — the host's builder. Called with the language's URL segment,
      or `nil` when the language is served without one, and (arity 2) the
      language map. Returns a path or an absolute URL:

          url: fn
            nil -> ~p"/products/\#{@product.slug}"
            locale -> ~p"/\#{locale}/products/\#{@product.slug}"
          end

    * `strategy: :path` — the current page with its leading locale segment
      replaced (`Routes.locale_switch_path(path, locale, prefix: false)`). Right
      for a host whose localized routes are `/:locale/...` at the root, with the
      same path after the segment in every language.
    * `strategy: :query` — the current page with a `?locale=` query parameter
      (`:query_param` to rename it), removed for a prefixless primary.
    * `strategy: :kit` — the current page as one of the kit's own pages
      (`Routes.locale_switch_path/3` with the kit's `url_prefix`).

  Without one of them these functions raise `ArgumentError`.

  The current page comes from `:current_path` in the options, or from the
  context: a `Plug.Conn` (its request path and query), a LiveView socket or an
  assigns map (`:phoenix_kit_current_path`, which `HostLocale`'s `on_mount`
  keeps up to date, then `:url_path`, then `:current_path`).
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  @type language :: %{
          code: String.t(),
          locale: String.t(),
          base: String.t(),
          hreflang: String.t(),
          name: String.t(),
          native_name: String.t() | nil,
          flag: String.t() | nil,
          primary?: boolean(),
          prefixless?: boolean()
        }

  @type language_link :: %{
          code: String.t(),
          locale: String.t(),
          base: String.t(),
          hreflang: String.t(),
          name: String.t(),
          native_name: String.t() | nil,
          flag: String.t() | nil,
          primary?: boolean(),
          current?: boolean(),
          url: String.t()
        }

  @type context :: Plug.Conn.t() | Phoenix.LiveView.Socket.t() | map() | nil

  @doc """
  The URL segments the site serves, in the order the languages are
  configured (Admin → Settings → Languages).

  On a single-language site (multi-language support off) this is the primary
  language's segment only — and the primary is served without it.

      iex> PhoenixKit.I18n.enabled_locales()
      ["en", "et", "ru"]
  """
  @spec enabled_locales() :: [String.t()]
  def enabled_locales, do: Enum.map(languages(), & &1.code)

  @doc """
  The languages the site serves, as maps (see the moduledoc), in configured
  order. One entry per URL segment.
  """
  @spec languages() :: [language()]
  def languages do
    primary_code = Languages.primary_language_code()
    primary_segment = segment_for(primary_code)
    prefixless? = prefixless_primary?()

    configured =
      if Languages.enabled?() do
        Languages.get_enabled_languages()
      else
        []
      end

    configured
    |> Enum.map(&segment_for(&1.code))
    |> Enum.uniq()
    |> case do
      [] -> [primary_segment]
      segments -> segments
    end
    |> Enum.map(&build_language(&1, configured, primary_segment, prefixless?))
  end

  @doc "The primary language's map (see the moduledoc)."
  @spec primary_language() :: language()
  def primary_language do
    Enum.find(languages(), & &1.primary?) || hd(languages())
  end

  @doc """
  Whether the primary language is served without a locale segment: always on a
  single-language site, and on a multilingual one when "Primary language
  without prefix" is on.
  """
  @spec prefixless_primary?() :: boolean()
  def prefixless_primary? do
    Languages.single_language_safe?() or Languages.prefixless_primary_safe?()
  end

  @doc """
  Resolves a URL segment against the languages the site serves.

    * `{:ok, language}` — the segment serves `language`.
    * `{:redirect, language}` — another spelling of a served language's
      segment (`"ET"`, `"en-US"` where `en-US` owns `/en/`, `"en-GB"` for
      `/en-gb/`); its canonical URL uses `language.code`.
    * `:error` — not a language the site serves.
  """
  @spec resolve_segment(String.t()) :: {:ok, language()} | {:redirect, language()} | :error
  def resolve_segment(segment) when is_binary(segment) do
    langs = languages()

    case Enum.find(langs, &(&1.code == segment)) do
      %{} = lang -> {:ok, lang}
      nil -> resolve_alias(segment, langs)
    end
  end

  def resolve_segment(_segment), do: :error

  defp resolve_alias(segment, langs) do
    if segment =~ ~r/\A[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{2,8})?\z/ do
      down = segment |> String.replace("_", "-") |> String.downcase()

      canonical =
        Enum.find(langs, &(&1.code == down)) ||
          Enum.find(langs, &(String.downcase(&1.locale) == down)) ||
          (String.contains?(down, "-") &&
             Enum.find(langs, &(&1.code == DialectMapper.extract_base(down))))

      case canonical do
        %{} = lang -> {:redirect, lang}
        _ -> :error
      end
    else
      :error
    end
  end

  @doc """
  Finds a served language by URL segment, full dialect or base code; `nil` when
  the site does not serve it.
  """
  @spec find_language(String.t() | language() | nil) :: language() | nil
  def find_language(%{code: code, locale: _}), do: find_language(code)

  def find_language(code) when is_binary(code) do
    case resolve_segment(code) do
      {:ok, lang} -> lang
      {:redirect, lang} -> lang
      :error -> nil
    end
  end

  def find_language(_), do: nil

  @doc """
  The language of the current request or page.

  Read from the context's `:current_language` / `:current_locale` assigns
  (which `PhoenixKitWeb.Plugs.HostLocale` and the kit's own hooks set), then
  the dialect recorded on this process, then the primary language.
  """
  @spec current_language(context()) :: language()
  def current_language(context \\ nil) do
    assigns = assigns_of(context)

    [
      assigns[:current_language],
      assigns[:current_locale],
      assigns[:current_locale_base],
      Languages.request_locale()
    ]
    |> Enum.find_value(&find_language/1) || primary_language()
  end

  @doc """
  The URL of the current page (as the URL builder in `opts` makes it) in
  `locale` — a URL segment, a full dialect or a base code. `nil` when the site
  does not serve that language.

  See the moduledoc for the builder options. The result is what the builder
  returns, a path or an absolute URL; pass `absolute: true` to get an absolute
  URL (a path is put on `:base_url`, default `Routes.base_url/0`).

      PhoenixKit.I18n.localized_url(conn, "et", url: &~p"/\#{&1}/products")
  """
  @spec localized_url(context(), String.t(), keyword()) :: String.t() | nil
  def localized_url(context, locale, opts \\ []) do
    builder = builder!(opts)

    case find_language(locale) do
      nil -> nil
      lang -> build(builder, lang, context, opts)
    end
  end

  @doc """
  `<link rel="alternate" hreflang>` entries for the current page: one per
  served language plus `x-default` (the primary language's URL), as
  `[%{hreflang: "et", href: "https://…"}]` — the same shape as a sitemap
  `UrlEntry`'s `alternates`, so a host sitemap source can reuse it.

  Hrefs are absolute: a builder's path is put on `:base_url` (default
  `Routes.base_url/0`, the site URL the kit uses for emails). A builder that
  returns absolute URLs (a domain per language) is used as is.

  Options: the URL builder (see the moduledoc), `:base_url`,
  `x_default: false` to leave out `x-default`. A single-language site gets
  `[]` — there is no alternate.

  Rendered by `PhoenixKitWeb.Components.Core.LanguageSwitcher.hreflang_tags/1`.
  """
  @spec hreflang_links(context(), keyword()) :: [%{hreflang: String.t(), href: String.t()}]
  def hreflang_links(context, opts \\ []) do
    builder = builder!(opts)
    opts = Keyword.put(opts, :absolute, true)

    case languages() do
      [_single] ->
        []

      langs ->
        links =
          for lang <- langs,
              do: %{hreflang: lang.hreflang, href: build(builder, lang, context, opts)}

        if Keyword.get(opts, :x_default, true) do
          primary = Enum.find(langs, & &1.primary?) || hd(langs)
          links ++ [%{hreflang: "x-default", href: build(builder, primary, context, opts)}]
        else
          links
        end
    end
  end

  @doc """
  Everything a language switcher needs, without markup: one entry per served
  language, `[%{code, locale, base, hreflang, name, native_name, flag, url,
  current?, primary?}]`, in configured order.

  Options: the URL builder (see the moduledoc), `hide_current: true` to leave
  out the current language, `:current` to name the current language instead of
  reading it from the context, `absolute: true` / `:base_url` as in
  `localized_url/3`.

  Rendered by `PhoenixKitWeb.Components.Core.LanguageSwitcher.language_switcher_items/1`.
  """
  @spec language_links(context(), keyword()) :: [language_link()]
  def language_links(context, opts \\ []) do
    builder = builder!(opts)

    current =
      case opts[:current] do
        nil -> current_language(context)
        code -> find_language(code) || current_language(context)
      end

    links =
      for lang <- languages() do
        lang
        |> Map.delete(:prefixless?)
        |> Map.put(:current?, lang.code == current.code)
        |> Map.put(:url, build(builder, lang, context, opts))
      end

    if opts[:hide_current], do: Enum.reject(links, & &1.current?), else: links
  end

  # ── building ────────────────────────────────────────────────────────

  @strategies [:path, :query, :kit]

  defp builder!(opts) do
    case {opts[:url], opts[:strategy]} do
      {fun, _} when is_function(fun, 1) or is_function(fun, 2) ->
        {:fun, fun}

      {nil, strategy} when strategy in @strategies ->
        strategy

      {nil, nil} ->
        raise ArgumentError,
              "PhoenixKit.I18n needs to know how the host builds a localized URL: " <>
                "pass `url: fn locale_segment_or_nil -> path end` or " <>
                "`strategy: :path | :query | :kit`"

      other ->
        raise ArgumentError,
              "PhoenixKit.I18n: `url:` must be a function of arity 1 or 2 and `strategy:` one of " <>
                "#{inspect(@strategies)}; got #{inspect(other)}"
    end
  end

  defp build(builder, lang, context, opts) do
    segment = if lang.prefixless?, do: nil, else: lang.code

    builder
    |> run_builder(segment, lang, context, opts)
    |> local_path(builder)
    |> maybe_absolute(opts)
  end

  # A strategy builds from the request's own path, which is the visitor's to shape:
  # `/et//evil.com` routes as `/:locale/:slug`, and with the segment replaced it is
  # `//evil.com`, a link to another site. A leading run of slashes (or backslashes, which
  # browsers read as slashes) becomes one slash. The host's own `url:` builder is trusted.
  defp local_path(url, {:fun, _fun}), do: url
  defp local_path(url, _strategy), do: String.replace(url, ~r{\A[/\\]+}, "/")

  defp run_builder({:fun, fun}, segment, _lang, _context, _opts) when is_function(fun, 1),
    do: to_string(fun.(segment))

  defp run_builder({:fun, fun}, segment, lang, _context, _opts),
    do: to_string(fun.(segment, lang))

  defp run_builder(:path, _segment, lang, context, opts) do
    Routes.locale_switch_path(current_path(context, opts), lang.locale,
      prefix: false,
      current_locale: current_language(context).code
    )
  end

  defp run_builder(:kit, _segment, lang, context, opts) do
    Routes.locale_switch_path(current_path(context, opts), lang.locale,
      current_locale: current_language(context).code
    )
  end

  defp run_builder(:query, segment, _lang, context, opts) do
    param = to_string(Keyword.get(opts, :query_param, "locale"))
    uri = URI.parse(current_path(context, opts))
    query = URI.decode_query(uri.query || "")

    query =
      case segment do
        nil -> Map.delete(query, param)
        code -> Map.put(query, param, code)
      end

    query = if query == %{}, do: nil, else: URI.encode_query(query)
    URI.to_string(%{uri | path: uri.path || "/", query: query})
  end

  defp maybe_absolute(url, opts) do
    if opts[:absolute] && String.starts_with?(url, "/") && not String.starts_with?(url, "//") do
      base = opts[:base_url] || Routes.base_url()
      String.trim_trailing(base, "/") <> url
    else
      url
    end
  end

  defp current_path(context, opts) do
    case opts[:current_path] do
      path when is_binary(path) -> path
      _ -> context_path(context)
    end
  end

  defp context_path(%Plug.Conn{request_path: path, query_string: ""}), do: path
  defp context_path(%Plug.Conn{request_path: path, query_string: query}), do: path <> "?" <> query

  defp context_path(context) do
    assigns = assigns_of(context)
    assigns[:phoenix_kit_current_path] || assigns[:url_path] || assigns[:current_path] || "/"
  end

  defp assigns_of(%Plug.Conn{assigns: assigns}), do: assigns
  defp assigns_of(%{__struct__: Phoenix.LiveView.Socket, assigns: assigns}), do: assigns
  defp assigns_of(%{} = assigns), do: assigns
  defp assigns_of(_), do: %{}

  # ── languages ───────────────────────────────────────────────────────

  defp segment_for(code), do: Languages.url_locale_segment(code)

  defp build_language(segment, configured, primary_segment, prefixless?) do
    locale = locale_for(segment, configured)
    stored = Enum.find(configured, &(&1.code == locale))
    predefined = locale |> Languages.get_predefined_language() |> plain_map()
    primary? = segment == primary_segment
    base = DialectMapper.extract_base(locale)

    %{
      code: segment,
      locale: locale,
      base: base,
      hreflang: if(String.contains?(segment, "-"), do: locale, else: segment),
      name: (stored && stored.name) || predefined[:name] || locale,
      native_name: (stored && stored.native) || predefined[:native],
      flag: (stored && stored.flag) || predefined[:flag],
      primary?: primary?,
      prefixless?: primary? and prefixless?
    }
  end

  defp plain_map(%_{} = struct), do: Map.from_struct(struct)
  defp plain_map(_), do: %{}

  # The dialect the kit serves a segment as: a sibling segment names its
  # dialect; a base segment resolves as the kit's locale plug does it
  # (`Auth.resolve_active_dialect/1`). The primary keeps its configured code
  # on a single-language site, where nothing is enabled.
  defp locale_for(segment, []), do: single_language_locale(segment)

  defp locale_for(segment, configured) do
    if String.contains?(segment, "-") do
      Enum.find_value(configured, segment, fn lang ->
        if String.downcase(lang.code) == segment, do: lang.code
      end)
    else
      Auth.resolve_active_dialect(segment)
    end
  end

  defp single_language_locale(segment) do
    primary = Languages.primary_language_code()

    if DialectMapper.extract_base(primary) == segment,
      do: primary,
      else: DialectMapper.resolve_dialect(segment)
  end
end
