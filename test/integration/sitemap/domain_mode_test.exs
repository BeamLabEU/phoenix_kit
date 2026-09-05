defmodule PhoenixKit.Integration.Sitemap.DomainModeProviderStub do
  @moduledoc false
  def ok do
    [
      %{host: "site.example.com", language: "en", primary: true},
      %{host: "site.example.fr", language: "fr", primary: false}
    ]
  end

  # Every enabled language (en, fr, de) has a domain of its own — the shape a
  # site reaches once it stops leaving languages domainless.
  def all_mapped, do: ok() ++ [%{host: "site.example.de", language: "de", primary: false}]

  def no_primary, do: Enum.map(ok(), &%{&1 | primary: false})
  def two_primaries, do: Enum.map(ok(), &%{&1 | primary: true})

  def duplicate_language,
    do: ok() ++ [%{host: "other.example.fr", language: "fr-FR", primary: false}]

  def raising, do: raise("boom")
  def empty, do: []

  def malformed_host,
    do: [%{host: "../etc/passwd", language: "en", primary: true}]
end

defmodule PhoenixKit.Integration.Sitemap.DomainModeTest do
  use PhoenixKit.DataCase, async: false

  alias PhoenixKit.Integration.Sitemap.DomainModeProviderStub, as: Stub
  alias PhoenixKit.Modules.Sitemap.DomainMode
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Settings

  @base "https://legacy.example.com"

  setup do
    Settings.update_setting("languages_enabled", "true")

    Settings.update_json_setting("languages_config", %{
      "languages" => [
        %{"code" => "en-US", "name" => "English", "is_default" => true, "is_enabled" => true},
        %{"code" => "fr", "name" => "French", "is_default" => false, "is_enabled" => true},
        %{"code" => "de", "name" => "German", "is_default" => false, "is_enabled" => true}
      ]
    })

    on_exit(fn ->
      Application.delete_env(:phoenix_kit, :sitemap_domains_provider)
      Settings.update_setting("languages_enabled", "false")
    end)

    :ok
  end

  defp put_provider(fun) do
    Application.put_env(:phoenix_kit, :sitemap_domains_provider, {Stub, fun})
  end

  defp entry(loc, canonical_path) do
    UrlEntry.new(%{loc: @base <> loc, canonical_path: canonical_path, source: :test})
  end

  describe "domains/0 validation (B1)" do
    test "valid provider activates" do
      put_provider(:ok)
      assert [%{host: "site.example.com", primary: true} | _] = DomainMode.domains()
      assert DomainMode.active?()
    end

    test "no primary / two primaries / duplicate language / raising / empty / bad host ⇒ inactive" do
      for fun <- [
            :no_primary,
            :two_primaries,
            :duplicate_language,
            :raising,
            :empty,
            :malformed_host
          ] do
        put_provider(fun)
        assert DomainMode.domains() == [], "expected inactive for #{fun}"
      end
    end

    test "absent provider config ⇒ inactive" do
      Application.delete_env(:phoenix_kit, :sitemap_domains_provider)
      refute DomainMode.active?()
    end
  end

  describe "rebuild_for_domains/2" do
    setup do
      put_provider(:ok)
      :ok
    end

    test "fully translated group: membership, re-hosting, identical alternates, x-default" do
      entries = [
        entry("/decor/post", "/decor/post"),
        entry("/fr/decor/le-post", "/decor/post"),
        entry("/de/decor/der-post", "/decor/post")
      ]

      result = DomainMode.rebuild_for_domains(entries, @base)

      # de has no domain of its own, so it rides the primary domain, prefixed
      primary_locs = Enum.map(result["site.example.com"], & &1.loc)
      assert "https://site.example.com/de/decor/der-post" in primary_locs

      en_entry = Enum.find(result["site.example.com"], &(&1.loc =~ "/decor/post"))
      [fr_entry] = result["site.example.fr"]

      assert en_entry.loc == "https://site.example.com/decor/post"
      # fr loses its own prefix on its home domain
      assert fr_entry.loc == "https://site.example.fr/decor/le-post"

      # identical alternates on both duplicates
      assert en_entry.alternates == fr_entry.alternates

      hrefs = Map.new(en_entry.alternates, &{&1.hreflang, &1.href})
      assert hrefs["en"] == "https://site.example.com/decor/post"
      assert hrefs["fr"] == "https://site.example.fr/decor/le-post"
      # unmapped language stays prefixed on the primary domain
      assert hrefs["de"] == "https://site.example.com/de/decor/der-post"
      assert hrefs["x-default"] == "https://site.example.com/decor/post"
    end

    test "a language with no domain is published, prefixed, from the primary domain" do
      entries = [
        entry("/decor/post", "/decor/post"),
        entry("/de/decor/der-post", "/decor/post"),
        entry("/de/only-german", "/only-german")
      ]

      result = DomainMode.rebuild_for_domains(entries, @base)

      locs = result["site.example.com"] |> Enum.map(& &1.loc) |> Enum.sort()

      assert locs == [
               "https://site.example.com/de/decor/der-post",
               "https://site.example.com/de/only-german",
               "https://site.example.com/decor/post"
             ]

      # a domainless language rides the primary host only — never a mapped
      # sibling's file, which must stay single-language
      assert result["site.example.fr"] == []

      # and it carries the same group alternates as its translated sibling
      de = Enum.find(result["site.example.com"], &(&1.loc =~ "/de/decor/"))

      en =
        Enum.find(result["site.example.com"], &(&1.loc == "https://site.example.com/decor/post"))

      assert de.alternates == en.alternates
    end

    test "every enabled language mapped ⇒ no domainless entries are added" do
      put_provider(:all_mapped)

      entries = [
        entry("/decor/post", "/decor/post"),
        entry("/fr/decor/le-post", "/decor/post"),
        entry("/de/decor/der-post", "/decor/post")
      ]

      result = DomainMode.rebuild_for_domains(entries, @base)

      assert Enum.map(result["site.example.com"], & &1.loc) ==
               ["https://site.example.com/decor/post"]

      assert Enum.map(result["site.example.fr"], & &1.loc) ==
               ["https://site.example.fr/decor/le-post"]

      assert Enum.map(result["site.example.de"], & &1.loc) ==
               ["https://site.example.de/decor/der-post"]
    end

    test "untranslated group appears only on its language's domain" do
      entries = [entry("/fr/only-french", "/only-french")]
      result = DomainMode.rebuild_for_domains(entries, @base)

      assert result["site.example.com"] == []
      [fr_entry] = result["site.example.fr"]
      assert fr_entry.loc == "https://site.example.fr/only-french"
      # One language is not a hreflang set, so this URL carries none at all.
      # m2 (no x-default when the primary's language is absent) is NOT what
      # this asserts — against an empty list any `refute Enum.any?` passes
      # vacuously. m2 is covered by the two-language test below.
      assert fr_entry.alternates == []
    end

    test "no x-default when the group has no entry for the primary's language (m2)" do
      # Two non-primary languages, so the group is a real hreflang set and the
      # single-language guard does not fire — only then does the absence of
      # x-default mean the rule holds rather than the list simply being empty.
      put_provider(:all_mapped)

      entries = [
        entry("/fr/only-french", "/only-french"),
        entry("/de/nur-deutsch", "/only-french")
      ]

      result = DomainMode.rebuild_for_domains(entries, @base)

      assert result["site.example.com"] == []
      [fr_entry] = result["site.example.fr"]

      assert Enum.map(fr_entry.alternates, & &1.hreflang) == ["de", "fr"]
      refute Enum.any?(fr_entry.alternates, &(&1.hreflang == "x-default"))
    end

    test "canonical_path-less entry forms its own single-language group (m1)" do
      entries = [
        %{entry("/some/tool", nil) | canonical_path: nil}
      ]

      result = DomainMode.rebuild_for_domains(entries, @base)

      # unprefixed ⇒ default language (en) ⇒ primary domain only
      [en_entry] = result["site.example.com"]
      assert en_entry.loc == "https://site.example.com/some/tool"
      assert result["site.example.fr"] == []
    end

    test "a single-language group on the PRIMARY's own language carries no alternates at all" do
      # Regression: an untranslated product/page whose only language happens
      # to be the primary domain's would previously get a self+x-default
      # pair here — a lone entry, i.e. exactly the "hreflang for a single
      # language is noise" case the app's own page-level builders already
      # special-case. Left unguarded, the sitemap advertised an alternate
      # set for this URL that the live page's <head> never repeated (it
      # correctly emits none), so a crawler following the sitemap saw a
      # promise the page itself did not keep.
      entries = [entry("/only-english", "/only-english")]
      result = DomainMode.rebuild_for_domains(entries, @base)

      [en_entry] = result["site.example.com"]
      assert en_entry.loc == "https://site.example.com/only-english"
      assert en_entry.alternates == []
      assert result["site.example.fr"] == []
    end

    test "one host lists a <loc> once when two sources produce it, keeping the richer entry" do
      # Regression: a locale-prefixed clone route (`live "/fr"` pointing at the
      # home LiveView) is discovered from the router with no canonical_path, so
      # it forms its own single-language group. Re-hosting strips the prefix and
      # lands it on `https://<fr-host>/` — exactly where the static home, grouped
      # with the default language's `/` under canonical_path "/", already sits.
      # The two groups cannot merge, so the French file listed its home twice:
      # once with the full cross-domain alternates, once bare.
      entries = [
        entry("/", "/"),
        entry("/fr/", "/"),
        entry("/fr", nil)
      ]

      result = DomainMode.rebuild_for_domains(entries, @base)

      assert [fr_home] = result["site.example.fr"]
      assert fr_home.loc == "https://site.example.fr/"

      # The survivor is the entry carrying the hreflang set, not the bare clone.
      assert Enum.map(fr_home.alternates, & &1.hreflang) == ["en", "fr", "x-default"]

      # The primary is unaffected — its own home is still listed exactly once.
      assert [en_home] = result["site.example.com"]
      assert en_home.loc == "https://site.example.com/"
    end

    test "a non-locale first segment is not treated as a language" do
      entries = [entry("/api/docs", nil)]
      result = DomainMode.rebuild_for_domains(entries, @base)

      [en_entry] = result["site.example.com"]
      assert en_entry.loc == "https://site.example.com/api/docs"
    end

    test "inactive provider yields empty map" do
      Application.delete_env(:phoenix_kit, :sitemap_domains_provider)
      assert DomainMode.rebuild_for_domains([entry("/x", "/x")], @base) == %{}
    end
  end
end
