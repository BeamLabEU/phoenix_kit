defmodule PhoenixKit.Modules.Sitemap.Sources.PublishingTest do
  @moduledoc """
  The slug a Publishing post is listed under in each language's sitemap.

  A translation can carry its own url_slug, and the post page canonicalises
  to it; the sitemap must list the same address, not the post slug, or every
  non-primary language points crawlers at a duplicate.
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

  test "an entry's loc carries its language's slug, its grouping key the post slug" do
    en =
      Publishing.build_post_entry(
        @post,
        "articles",
        "Articles",
        "en-GB",
        false,
        "https://x.test",
        %{}
      )

    ru =
      Publishing.build_post_entry(
        @post,
        "articles",
        "Articles",
        "ru",
        true,
        "https://x.test",
        %{}
      )

    assert en.loc =~ ~r{/articles/antiques-nice-millon-riviera$}
    assert ru.loc =~ ~r{/articles/antikvariat-nitstsa-millon-riviera$}
    assert en.canonical_path == ru.canonical_path
    assert en.canonical_path =~ ~r{/articles/antikvariat-nitstsa-millon-riviera$}
  end

  test "no language means the default language" do
    # Without configured languages the default is "en".
    assert Publishing.post_slug_for_language(@post, nil) == "antiques-nice-millon-riviera"
  end

  test "timestamp-mode posts keep their date path in every language" do
    post = Map.merge(@post, %{mode: :timestamp, date: ~D[2025-12-09]})
    en = Publishing.build_post_entry(post, "blog", "Blog", "en-GB", false, "https://x.test", %{})

    assert en.loc =~ ~r{/blog/2025-12-09$}
  end

  test "the hreflang grouping key is the post slug in every language" do
    assert Publishing.post_slug_for_language(@post, :canonical) == @post.slug
  end
end
