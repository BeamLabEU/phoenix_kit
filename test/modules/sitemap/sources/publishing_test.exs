defmodule PhoenixKit.Modules.Sitemap.Sources.PublishingTest do
  @moduledoc """
  The slug a Publishing post is listed under in each language's sitemap.

  A translation can carry its own url_slug, and the post page canonicalises
  to it; the sitemap must list the same address, not the post slug, or every
  non-primary language points crawlers at a duplicate.

  Publishing is not a dependency of core, so these tests run the source's
  stand-in resolver (exact, then base-code match). In an app the source
  uses Publishing's own `LanguageHelpers.resolve_language_key/2`, whose
  tie-break between sibling dialects (primary, then enabled order) is
  covered by Publishing's suite, not here.
  """
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Sitemap.Sources.Publishing

  @post %{
    slug: "antikvariat-nitstsa-millon-riviera",
    mode: :slug,
    language_slugs: %{
      "ru" => "antikvariat-nitstsa-millon-riviera",
      "en-GB" => "antiques-nice-millon-riviera",
      "fr-FR" => "antiquites-nice-millon-riviera",
      "it" => "antiquariato-nizza-millon-riviera"
    }
  }

  test "each language gets its own url_slug" do
    assert Publishing.post_slug_for_language(@post, "en-GB") == "antiques-nice-millon-riviera"
    assert Publishing.post_slug_for_language(@post, "it") == "antiquariato-nizza-millon-riviera"
    assert Publishing.post_slug_for_language(@post, "ru") == "antikvariat-nitstsa-millon-riviera"
  end

  test "a base code finds its dialect, whatever the case" do
    assert Publishing.post_slug_for_language(@post, "en") == "antiques-nice-millon-riviera"
    assert Publishing.post_slug_for_language(@post, "fr") == "antiquites-nice-millon-riviera"
    assert Publishing.post_slug_for_language(@post, "EN-gb") == "antiques-nice-millon-riviera"
  end

  test "a language without a translation, or with a blank slug, falls back to the post slug" do
    assert Publishing.post_slug_for_language(@post, "de") == @post.slug

    post = put_in(@post, [:language_slugs, "en-GB"], "")
    assert Publishing.post_slug_for_language(post, "en-GB") == @post.slug
  end

  test "a post map without language_slugs keeps the post slug" do
    post = Map.delete(@post, :language_slugs)
    assert Publishing.post_slug_for_language(post, "en-GB") == @post.slug

    assert Publishing.post_slug_for_language(
             %{post | slug: nil} |> Map.put(:path, "a/b/my-post.md"),
             "en"
           ) ==
             "my-post"
  end

  test "each language's entry has its own loc and all share one grouping key" do
    entries =
      for {lang, default?} <- [{"ru", true}, {"en-GB", false}, {"fr-FR", false}, {"it", false}] do
        {lang,
         Publishing.build_post_entry(
           @post,
           "articles",
           "Articles",
           lang,
           default?,
           "https://x.test",
           %{}
         )}
      end

    for {lang, entry} <- entries do
      assert String.ends_with?(entry.loc, "/articles/" <> @post.language_slugs[lang])
    end

    assert entries |> Enum.map(fn {_, e} -> e.canonical_path end) |> Enum.uniq() ==
             ["/phoenix_kit/articles/antikvariat-nitstsa-millon-riviera"]
  end

  test "no language means the default language" do
    # Without configured languages the default is "en".
    assert Publishing.post_slug_for_language(@post, nil) == "antiques-nice-millon-riviera"
  end

  test "timestamp-mode posts keep their date path in every language" do
    post = Map.merge(@post, %{mode: :timestamp, date: ~D[2025-12-09]})

    for lang <- ["ru", "en-GB", "it"] do
      entry =
        Publishing.build_post_entry(post, "blog", "Blog", lang, false, "https://x.test", %{})

      assert String.ends_with?(entry.loc, "/blog/2025-12-09")
    end
  end

  test "a post with neither slug nor path is not listed" do
    refute Publishing.slugless?(@post)
    refute Publishing.slugless?(%{@post | slug: nil} |> Map.put(:path, "a/b/my-post.md"))
    assert Publishing.slugless?(%{@post | slug: nil})
    refute Publishing.slugless?(%{mode: :timestamp, slug: nil})
  end
end
