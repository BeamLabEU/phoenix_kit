defmodule PhoenixKitWeb.OAuth.Language do
  @moduledoc """
  The language of the HTML pages of the authorization flow (the consent screen, the page of a
  person at the ceiling, the error pages), chosen per request. The routes carry no locale
  segment (`/oauth` is a reserved segment), and the site's locale plug takes the language from
  the URL only, so without this plug every person would get the site's default language.

  Each candidate is checked against the languages the install has **enabled**
  (`PhoenixKit.Modules.Languages.enabled_locale_codes/0`) and is ignored when it is not one of
  them. The first that is enabled wins:

    1. the query parameter `lang`: the person's own choice on the language switcher of the page;
    2. the signed-in person's `custom_fields["preferred_locale"]`, on the routes that know a
       person (`person: true`);
    3. the `Accept-Language` header, by quality, the first enabled tag (a wildcard names nothing);
    4. the install's default language.

  A dialect (`ru-RU`, `en-GB`) is mapped to the enabled language of its base, as the site's
  locale plug does for a URL. Nothing a client sends is ever written into a page or a link: the
  `lang` attribute, the switcher and the `?lang=` of the links the pages generate are always one
  of the enabled codes, never the request's own text. The login page of the host is not covered:
  it is the host's, and it keeps the site's language.

  Use as a plug of a controller: `plug PhoenixKitWeb.OAuth.Language` (the authorize endpoint,
  where nobody is known) or `plug PhoenixKitWeb.OAuth.Language, person: true`. It sets the Gettext
  locale of the request and remembers the choice for `assigns/3` and `url/2`.

  The language is kept across the round trips of the flow only through the URL: a `lang` chosen on
  a page is added to the links and form actions that page generates (`url/2`), and it is not
  stored anywhere (no cookie, no column).
  """

  @behaviour Plug

  import Plug.Conn

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Utils.RecipientLocale
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Users.Auth

  @private :phoenix_kit_oauth_language
  @max_header 1024
  @max_entries 16
  @max_query 2048
  @tag ~r/\A[A-Za-z]{2,3}(?:[-_][A-Za-z0-9]{1,8}){0,3}\z/

  @type choice :: %{code: String.t(), explicit?: boolean(), enabled: [String.t()]}

  @impl Plug
  def init(opts), do: Keyword.get(opts, :person, false)

  @impl Plug
  def call(conn, person?) do
    enabled = enabled_codes()
    {code, explicit?} = choose(conn, enabled, person?)

    Auth.put_gettext_locale(code)

    put_private(conn, @private, %{code: code, explicit?: explicit?, enabled: enabled})
  end

  @doc """
  The assigns every page takes for its language: `lang` (the `lang` attribute of the document) and
  `languages` (the switcher: `code`, `name`, `href`, `current?` of each enabled language, empty
  when there is only one, or when there is no `path`). `path` is the page the switcher links to and `query` the raw query
  string of the request when it is part of that page (the authorize endpoint), otherwise `nil`;
  a `lang` in it is replaced.
  """
  @spec assigns(Plug.Conn.t(), String.t() | nil, String.t() | nil) :: map()
  def assigns(conn, path, query \\ nil) do
    case conn.private do
      %{@private => %{code: code, enabled: enabled}} ->
        %{lang: code, languages: switcher(code, enabled, path, query)}

      _ ->
        %{}
    end
  end

  @doc """
  `path` with the language the person chose on the page (`?lang=`), so that it survives a link, a
  form post or a redirect. A language that came from the browser or the person's profile is not
  added: the next request resolves it the same way.
  """
  @spec url(Plug.Conn.t(), String.t()) :: String.t()
  def url(conn, path) do
    case conn.private do
      %{@private => %{code: code, explicit?: true}} ->
        path <> "?lang=" <> URI.encode_www_form(code)

      _ ->
        path
    end
  end

  # --- the choice -----------------------------------------------------------------------------

  defp choose(conn, enabled, person?) do
    cond do
      code = from_param(conn, enabled) -> {code, true}
      code = person? && from_person(conn, enabled) -> {code, false}
      code = from_header(conn, enabled) -> {code, false}
      true -> {default(enabled), false}
    end
  end

  defp from_param(conn, enabled) do
    case conn.query_params do
      %{"lang" => lang} when is_binary(lang) -> match(lang, enabled)
      _ -> nil
    end
  end

  defp from_person(conn, enabled) do
    case conn.assigns[:phoenix_kit_current_user] |> RecipientLocale.preferred() do
      locale when is_binary(locale) -> match(locale, enabled)
      _ -> nil
    end
  end

  defp from_header(conn, enabled) do
    conn
    |> accepted()
    |> Enum.find_value(&match(&1, enabled))
  end

  # The install's default: what a URL without a locale gets in the site's own pages.
  defp default(enabled) do
    dialect = Auth.resolve_active_dialect(Routes.get_default_admin_locale())
    match(dialect, enabled) || dialect
  end

  # --- matching ---------------------------------------------------------------------------------

  # The enabled code `candidate` stands for, or nil: the same code (any case, `_` or `-`), else
  # the enabled language of its base.
  defp match(candidate, enabled) when is_binary(candidate) do
    if byte_size(candidate) <= 35 and Regex.match?(@tag, candidate) do
      tag = candidate |> String.replace("_", "-") |> String.downcase()

      Enum.find(enabled, &(String.downcase(&1) == tag)) || by_base(base(tag), enabled)
    end
  end

  defp by_base(base, enabled) do
    case Enum.filter(enabled, &(base(&1) == base)) do
      [] ->
        nil

      same ->
        active = Auth.resolve_active_dialect(base)
        Enum.find(same, &(&1 == active)) || hd(same)
    end
  end

  defp base(code), do: code |> String.split(["-", "_"]) |> hd() |> String.downcase()

  # --- Accept-Language --------------------------------------------------------------------------

  # The tags of the header, the best quality first (the order of the header among equals). A
  # quality of 0 means "not acceptable", a wildcard or a malformed entry names nothing.
  defp accepted(conn) do
    header = conn |> get_req_header("accept-language") |> Enum.join(",")

    if byte_size(header) in 1..@max_header//1 do
      header
      |> String.split(",")
      |> Enum.take(@max_entries)
      |> Enum.with_index()
      |> Enum.flat_map(&entry/1)
      |> Enum.sort()
      |> Enum.map(fn {_neg_quality, _position, tag} -> tag end)
    else
      []
    end
  end

  defp entry({part, position}) do
    [tag | params] = String.split(part, ";")
    tag = String.trim(tag)

    with true <- Regex.match?(@tag, tag),
         {:ok, quality} when quality > 0 <- quality(params) do
      [{-quality, position, tag}]
    else
      _ -> []
    end
  end

  defp quality(params) do
    params
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.find(&String.starts_with?(&1, "q="))
    |> case do
      nil -> {:ok, 1.0}
      "q=" <> number -> number(number)
    end
  end

  defp number(text) do
    case Float.parse(text) do
      {value, ""} when value >= 0 and value <= 1 -> {:ok, value}
      _ -> :error
    end
  end

  # --- the enabled languages --------------------------------------------------------------------

  defp enabled_codes do
    Languages.enabled_locale_codes()
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp switcher(code, enabled, path, query) do
    if is_binary(path) and length(enabled) > 1 do
      current = match(code, enabled)
      names = names()

      Enum.map(enabled, fn each ->
        %{
          code: each,
          name: Map.get(names, each) || each,
          href: href(path, query, each),
          current?: each == current
        }
      end)
    else
      []
    end
  end

  # The names the languages call themselves.
  defp names do
    Map.new(Languages.get_enabled_languages(), fn language ->
      {language.code, language.native || native(language.code) || language.name}
    end)
  rescue
    _ -> %{}
  catch
    :exit, _ -> %{}
  end

  defp native(code) do
    case Languages.get_predefined_language(code) do
      %{native: native} -> native
      _ -> nil
    end
  end

  defp href(path, query, code) do
    kept = if is_binary(query) and byte_size(query) <= @max_query, do: pairs(query), else: []
    path <> "?" <> Enum.join(kept ++ ["lang=" <> URI.encode_www_form(code)], "&")
  end

  # The raw pairs of a query without any `lang`, as they were sent.
  defp pairs(query) do
    query
    |> String.split("&", trim: true)
    |> Enum.reject(fn pair -> pair |> String.split("=", parts: 2) |> hd() |> lang_name?() end)
  end

  defp lang_name?(name) do
    URI.decode_www_form(name) == "lang"
  rescue
    _ -> false
  end
end
