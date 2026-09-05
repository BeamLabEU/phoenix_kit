defmodule PhoenixKit.Modules.Sitemap.DomainMode do
  @moduledoc """
  Multi-domain sitemap post-processing (one domain = one canonical language).

  Activated by a host-app provider:

      config :phoenix_kit, :sitemap_domains_provider, {MyAppWeb.SEO, :sitemap_domains}

  The provider returns `[%{host: "example.fr", language: "fr", primary: false}, ...]`.
  The result is VALIDATED here — exactly one `primary: true`, every host a
  distinct language (base-code level), well-formed hosts. Any violation
  deactivates domain mode (with a warning) rather than silently producing
  malformed URLs or dropping x-default.

  `rebuild_for_domains/2` regroups the entries the generator already
  collected across languages: for the domain of language L, every canonical
  group that HAS an L entry contributes one URL — L's own entry re-hosted on
  that domain with its locale prefix stripped (L is the default there) —
  carrying an alternates set computed ONCE per group (identical across all
  domain files by construction): each group language on its home URL, plus
  `x-default` for the primary domain's language when the group has it
  (omitted otherwise — never mislabel another language as x-default).

  An enabled language that has NO domain of its own keeps its locale prefix
  and lives on the primary domain, so its URLs are published from the primary
  domain's file (they are already what this module's alternates point at).
  Mapped hosts stay strictly single-language.

  Runs inside Oban jobs and unpiped controller requests: language resolution
  here never consults the request-scoped default-language override — the
  unprefixed-entry fallback reads the raw `is_default` flag, mirroring the
  generator's hardened `get_languages/0`.

  NB: the generator's `base_url` (Settings `site_url`) and the provider's
  primary host are independently-edited settings that must refer to the same
  site; rel-path extraction below is host-string-agnostic, so a mismatch
  yields consistent (if unexpected-host) URLs rather than corruption.
  """

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Sitemap.UrlEntry

  @host_re ~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/
  @locale_prefix_re ~r/^\/([a-z]{2,3}(?:-[A-Za-z]{2,4})?)(?:\/|$)/

  @type domain :: %{host: String.t(), language: String.t(), primary: boolean()}

  @doc "Validated provider domains; [] (inactive) on any contract violation."
  @spec domains() :: [domain()]
  def domains do
    case Application.get_env(:phoenix_kit, :sitemap_domains_provider) do
      {mod, fun} -> mod |> apply(fun, []) |> validate()
      _ -> []
    end
  rescue
    error ->
      Logger.warning("[Sitemap] sitemap_domains_provider raised: #{Exception.message(error)}")
      []
  end

  @doc false
  @spec active?() :: boolean()
  def active?, do: domains() != []

  defp validate(list) when is_list(list) and list != [] do
    normalized =
      Enum.map(list, fn %{host: host, language: language} = d ->
        %{
          host: host |> to_string() |> String.downcase(),
          language: DialectMapper.extract_base(to_string(language)),
          primary: Map.get(d, :primary, false) == true
        }
      end)

    cond do
      Enum.any?(normalized, &(not Regex.match?(@host_re, &1.host))) ->
        warn_invalid("malformed host")

      Enum.count(normalized, & &1.primary) != 1 ->
        warn_invalid("exactly one primary domain required")

      normalized |> Enum.map(& &1.language) |> Enum.uniq() |> length() != length(normalized) ->
        warn_invalid("each host must map a distinct language")

      true ->
        normalized
    end
  rescue
    error ->
      Logger.warning("[Sitemap] invalid sitemap_domains_provider data: #{inspect(error)}")
      []
  end

  defp validate(_), do: []

  defp warn_invalid(reason) do
    Logger.warning("[Sitemap] domain mode disabled: #{reason}")
    []
  end

  @doc """
  Regroups collected entries into per-domain URL sets: `%{host => [UrlEntry.t()]}`.
  """
  @spec rebuild_for_domains([UrlEntry.t()], String.t()) :: %{String.t() => [UrlEntry.t()]}
  def rebuild_for_domains(entries, base_url) do
    case domains() do
      [] ->
        %{}

      domains ->
        default_lang = raw_default_language()
        enabled_bases = enabled_language_bases()
        host_by_lang = Map.new(domains, &{&1.language, &1.host})
        primary = Enum.find(domains, & &1.primary)

        groups =
          entries
          |> Enum.group_by(fn e -> e.canonical_path || {:loc, e.loc} end)
          |> Map.values()
          |> Enum.map(&group_by_language(&1, base_url, default_lang, enabled_bases))

        # One host's file must list a URL once, and two producers can reach the
        # same <loc> here: a locale-prefixed clone route (/de, /fr on the home
        # LiveView) is discovered with no canonical_path, so it forms its own
        # group, and re-hosting strips the prefix onto exactly the home URL the
        # static source already placed on that language's domain. The two groups
        # cannot merge, so the file listed the home twice. Resolved by the same
        # richness policy the flat generator uses (UrlEntry.dedupe_by_loc/1).
        Map.new(domains, fn %{host: host, language: lang, primary: primary?} ->
          own = domain_entries(groups, lang, host_by_lang, primary, base_url)

          entries =
            if primary?,
              do: own ++ extra_for_primary(own, groups, host_by_lang, primary, base_url),
              else: own

          {host, entries |> UrlEntry.dedupe_by_loc() |> Enum.sort_by(& &1.loc)}
        end)
    end
  end

  # The primary domain's own language owns its URLs. A domainless language's
  # entry can land on the same URL when the site's default language is NOT the
  # primary domain's language and has no domain: its URLs carry no locale
  # prefix, so re-hosting puts them on the primary's root — where that domain's
  # own language already is. Publishing both would put the same <loc> in one
  # file twice; the host's own language wins.
  defp extra_for_primary(own, groups, host_by_lang, primary, base_url) do
    taken = MapSet.new(own, & &1.loc)

    groups
    |> domainless_entries(host_by_lang, primary, base_url)
    |> Enum.reject(&MapSet.member?(taken, &1.loc))
  end

  # An enabled language that has no domain of its own is served with its locale
  # prefix on the primary domain — that is exactly the URL `home_url/5` already
  # builds for it, and what every group's alternates already point at. Those
  # pages need a `<loc>` of their own somewhere, and the primary domain's file
  # is the only set served from the host they live on.
  #
  # Without this, activating domain mode silently DROPS every URL of such a
  # language: the legacy set that used to carry them is only served to
  # unmapped hosts, and no mapped host's file admits a foreign language.
  defp domainless_entries(groups, host_by_lang, primary, base_url) do
    Enum.flat_map(groups, fn by_lang ->
      case Enum.reject(by_lang, fn {lang, _} -> Map.has_key?(host_by_lang, lang) end) do
        [] ->
          []

        domainless ->
          # Same alternates as every other duplicate of this group — computed
          # once here for the same reason `domain_entries/5` computes it once.
          alternates = group_alternates(by_lang, host_by_lang, primary, base_url)

          Enum.map(domainless, fn {lang, entry} ->
            %{
              entry
              | loc: home_url(lang, entry, host_by_lang, primary, base_url),
                alternates: alternates
            }
          end)
      end
    end)
  end

  defp group_by_language(members, base_url, default_lang, enabled_bases) do
    Map.new(members, fn e -> {entry_language(e, base_url, default_lang, enabled_bases), e} end)
  end

  defp domain_entries(groups, lang, host_by_lang, primary, base_url) do
    groups
    |> Enum.flat_map(fn by_lang ->
      case by_lang[lang] do
        nil ->
          []

        entry ->
          alternates = group_alternates(by_lang, host_by_lang, primary, base_url)

          [
            %{
              entry
              | loc: home_url(lang, entry, host_by_lang, primary, base_url),
                alternates: alternates
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.loc)
  end

  # Computed once per group and reused verbatim for every domain that carries
  # the group — the spec's "identical hreflang set on every duplicate".
  #
  # A group with only one language present is not a hreflang set: the app's
  # own page-level builders (`Decor3dprintWeb.SEO.with_x_default/1`,
  # `PhoenixKitEcommerce.Web.SEOHelpers.dedup_or_empty/1`) already drop
  # under-2-entry sets as noise rather than emit a lone self+x-default pair.
  # Without this guard here, an untranslated product/page's <head> carried
  # NO hreflang tags (per that same rule) while its sitemap entry advertised
  # one — the live page silently failed to back up a promise its own sitemap
  # made for the identical URL.
  defp group_alternates(by_lang, _host_by_lang, _primary, _base_url) when map_size(by_lang) < 2,
    do: []

  defp group_alternates(by_lang, host_by_lang, primary, base_url) do
    links =
      by_lang
      |> Enum.sort_by(fn {lang, _} -> lang end)
      |> Enum.map(fn {lang, entry} ->
        %{hreflang: lang, href: home_url(lang, entry, host_by_lang, primary, base_url)}
      end)

    case by_lang[primary.language] do
      nil ->
        links

      primary_entry ->
        links ++
          [
            %{
              hreflang: "x-default",
              href: home_url(primary.language, primary_entry, host_by_lang, primary, base_url)
            }
          ]
    end
  end

  defp home_url(lang, %UrlEntry{loc: loc}, host_by_lang, primary, base_url) do
    rel = String.replace_prefix(loc, String.trim_trailing(base_url, "/"), "")
    rel = if String.starts_with?(rel, "/"), do: rel, else: "/" <> rel

    case host_by_lang[lang] do
      nil -> "https://#{primary.host}#{rel}"
      host -> "https://#{host}#{strip_own_prefix(rel, lang)}"
    end
  end

  defp strip_own_prefix(rel, lang) do
    case String.split(rel, "/", parts: 3) do
      ["", ^lang] -> "/"
      ["", ^lang, rest] -> "/" <> rest
      _ -> rel
    end
  end

  # Language of an entry, from its loc's locale prefix — only when the
  # segment is a real enabled language (a "/api/..." first segment is not a
  # locale). Unprefixed entries (home, router-discovery) belong to the site
  # default. Reads the RAW is_default flag — never the request-scoped
  # override (Oban/unpiped safe).
  defp entry_language(%UrlEntry{loc: loc}, base_url, default_lang, enabled_bases) do
    rel = String.replace_prefix(loc, String.trim_trailing(base_url, "/"), "")

    with [_, code] <- Regex.run(@locale_prefix_re, rel),
         base = DialectMapper.extract_base(code),
         true <- base in enabled_bases do
      base
    else
      _ -> default_lang
    end
  end

  defp enabled_language_bases do
    if Languages.enabled?() do
      Languages.get_enabled_languages()
      |> Enum.map(&DialectMapper.extract_base(&1.code))
      |> MapSet.new()
    else
      MapSet.new()
    end
  rescue
    _ -> MapSet.new()
  end

  defp raw_default_language do
    if Languages.enabled?() do
      case Enum.find(Languages.get_languages(), & &1.is_default) do
        %{code: code} -> DialectMapper.extract_base(code)
        _ -> "en"
      end
    else
      "en"
    end
  rescue
    _ -> "en"
  end
end
