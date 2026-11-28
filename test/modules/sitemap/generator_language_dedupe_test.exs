defmodule PhoenixKit.Modules.Sitemap.GeneratorLanguageDedupeTest do
  @moduledoc """
  A source written while Languages was off returns every language's URLs on
  each call. With Languages on the generator calls it once per language, so
  each URL arrived three times and every hreflang alternate was listed three
  times (lab2: 2,940 alternate links instead of 1,176). The generator now
  collapses the repeats; a source that honours `opts[:language]` gets the
  same result.
  """
  # Primes the global settings cache.
  use ExUnit.Case, async: false

  alias PhoenixKit.Modules.Sitemap.Generator
  alias PhoenixKit.Modules.Sitemap.UrlEntry
  alias PhoenixKit.Test.LanguageSettings

  @base "https://example.com"

  defp entry(prefix) do
    UrlEntry.new(%{
      loc: "#{@base}#{prefix}/page",
      canonical_path: "/page",
      source: :fake
    })
  end

  defmodule LanguageBlindSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :language_blind
    @impl true
    def enabled?, do: true

    @impl true
    def collect(_opts) do
      for prefix <- ["", "/et", "/ru"] do
        UrlEntry.new(%{
          loc: "https://example.com#{prefix}/page",
          canonical_path: "/page",
          source: :language_blind
        })
      end
    end
  end

  defmodule LanguageAwareSource do
    @moduledoc false
    @behaviour PhoenixKit.Modules.Sitemap.Sources.Source

    @impl true
    def source_name, do: :language_aware
    @impl true
    def enabled?, do: true

    @impl true
    def collect(opts) do
      prefix = if opts[:is_default_language], do: "", else: "/#{opts[:language]}"

      [
        UrlEntry.new(%{
          loc: "https://example.com#{prefix}/page",
          canonical_path: "/page",
          source: :language_aware
        })
      ]
    end
  end

  setup do
    LanguageSettings.multilingual!(languages: ~w(en-US et ru))
    :ok
  end

  test "a source that ignores :language yields each URL once, each alternate once" do
    entries = Generator.collect_all_entries([base_url: @base], [LanguageBlindSource])

    assert Enum.map(entries, & &1.loc) ==
             Enum.sort([entry("").loc, entry("/et").loc, entry("/ru").loc])

    for e <- entries do
      assert length(e.alternates) == 4
      assert e.alternates == Enum.uniq(e.alternates)

      assert e.alternates |> Enum.map(& &1.hreflang) |> Enum.sort() ==
               ~w(en et ru x-default)
    end
  end

  test "it produces the same sitemap as a source that honours :language" do
    blind = Generator.collect_all_entries([base_url: @base], [LanguageBlindSource])
    aware = Generator.collect_all_entries([base_url: @base], [LanguageAwareSource])

    strip = fn entries -> Enum.map(entries, &{&1.loc, Enum.sort(&1.alternates)}) end
    assert strip.(blind) == strip.(aware)
  end
end
