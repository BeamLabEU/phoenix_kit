defmodule PhoenixKit.Modules.Publishing.Web.Controller.ListingTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Publishing.Web.Controller.Listing

  # ============================================================================
  # Test Data Helpers
  # ============================================================================

  defp build_post(attrs \\ %{}) do
    %{
      slug: "test-post",
      mode: "slug",
      date: nil,
      time: nil,
      available_languages: ["en"],
      language_statuses: %{"en" => "published"},
      language_titles: %{},
      language_excerpts: %{},
      metadata: %{
        title: "Test Post",
        status: "published"
      }
    }
    |> Map.merge(attrs)
  end

  defp build_timestamp_post(date, time, attrs \\ %{}) do
    build_post(
      Map.merge(
        %{
          mode: "timestamp",
          date: date,
          time: time
        },
        attrs
      )
    )
  end

  # ============================================================================
  # filter_published/1
  # ============================================================================

  describe "filter_published/1" do
    test "includes published posts" do
      posts = [build_post()]
      assert length(Listing.filter_published(posts)) == 1
    end

    test "excludes draft posts" do
      posts = [build_post(%{metadata: %{title: "Draft", status: "draft"}})]
      assert Listing.filter_published(posts) == []
    end

    test "excludes archived posts" do
      posts = [build_post(%{metadata: %{title: "Archived", status: "archived"}})]
      assert Listing.filter_published(posts) == []
    end

    test "excludes future timestamp posts" do
      future = Date.add(Date.utc_today(), 30)
      posts = [build_timestamp_post(future, ~T[12:00:00])]
      assert Listing.filter_published(posts) == []
    end

    test "includes past timestamp posts" do
      past = Date.add(Date.utc_today(), -30)
      posts = [build_timestamp_post(past, ~T[12:00:00])]
      assert length(Listing.filter_published(posts)) == 1
    end

    test "includes today's timestamp posts" do
      posts = [build_timestamp_post(Date.utc_today(), ~T[12:00:00])]
      assert length(Listing.filter_published(posts)) == 1
    end

    test "does not exclude future slug-mode posts" do
      future = Date.add(Date.utc_today(), 30)
      posts = [build_post(%{mode: "slug", date: future})]
      assert length(Listing.filter_published(posts)) == 1
    end

    test "handles empty list" do
      assert Listing.filter_published([]) == []
    end
  end

  # ============================================================================
  # paginate/3
  # ============================================================================

  describe "paginate/3" do
    test "returns first page" do
      posts = Enum.map(1..10, &build_post(%{slug: "post-#{&1}"}))
      result = Listing.paginate(posts, 1, 3)
      assert length(result) == 3
      assert hd(result).slug == "post-1"
    end

    test "returns second page" do
      posts = Enum.map(1..10, &build_post(%{slug: "post-#{&1}"}))
      result = Listing.paginate(posts, 2, 3)
      assert length(result) == 3
      assert hd(result).slug == "post-4"
    end

    test "returns partial last page" do
      posts = Enum.map(1..5, &build_post(%{slug: "post-#{&1}"}))
      result = Listing.paginate(posts, 2, 3)
      assert length(result) == 2
    end

    test "returns empty for page beyond range" do
      posts = Enum.map(1..3, &build_post(%{slug: "post-#{&1}"}))
      assert Listing.paginate(posts, 5, 3) == []
    end

    test "handles empty list" do
      assert Listing.paginate([], 1, 10) == []
    end
  end

  # ============================================================================
  # get_page_param/1
  # ============================================================================

  describe "get_page_param/1" do
    test "parses valid page string" do
      assert Listing.get_page_param(%{"page" => "3"}) == 3
    end

    test "defaults to 1 when missing" do
      assert Listing.get_page_param(%{}) == 1
    end

    test "defaults to 1 for zero" do
      assert Listing.get_page_param(%{"page" => "0"}) == 1
    end

    test "defaults to 1 for negative" do
      assert Listing.get_page_param(%{"page" => "-1"}) == 1
    end

    test "defaults to 1 for non-numeric" do
      assert Listing.get_page_param(%{"page" => "abc"}) == 1
    end

    test "accepts integer page" do
      assert Listing.get_page_param(%{"page" => 5}) == 5
    end

    test "defaults to 1 for zero integer" do
      assert Listing.get_page_param(%{"page" => 0}) == 1
    end
  end

  # ============================================================================
  # filter_by_exact_language/3
  # ============================================================================

  describe "filter_by_exact_language/3" do
    test "filters by exact language match" do
      posts = [
        build_post(%{available_languages: ["en", "fr"]}),
        build_post(%{slug: "only-fr", available_languages: ["fr"]})
      ]

      result = Listing.filter_by_exact_language(posts, "blog", "en")
      assert length(result) == 1
      assert hd(result).slug == "test-post"
    end

    test "returns empty when no posts match" do
      posts = [build_post(%{available_languages: ["en"]})]
      assert Listing.filter_by_exact_language(posts, "blog", "de") == []
    end

    test "handles empty posts list" do
      assert Listing.filter_by_exact_language([], "blog", "en") == []
    end
  end

  # ============================================================================
  # filter_by_exact_language_strict/2
  # ============================================================================

  describe "filter_by_exact_language_strict/2" do
    test "only matches exact language code" do
      posts = [
        build_post(%{available_languages: ["en-US"]}),
        build_post(%{slug: "en-post", available_languages: ["en"]})
      ]

      result = Listing.filter_by_exact_language_strict(posts, "en")
      assert length(result) == 1
      assert hd(result).slug == "en-post"
    end

    test "does not match base code for dialects" do
      posts = [build_post(%{available_languages: ["en-US"]})]
      assert Listing.filter_by_exact_language_strict(posts, "en") == []
    end
  end

  # ============================================================================
  # find_matching_language/2
  # ============================================================================

  describe "find_matching_language/2" do
    test "direct match" do
      assert Listing.find_matching_language("en", ["en", "fr"]) == "en"
    end

    test "returns nil when no match" do
      assert Listing.find_matching_language("de", ["en", "fr"]) == nil
    end

    test "handles empty available languages" do
      assert Listing.find_matching_language("en", []) == nil
    end
  end

  # ============================================================================
  # get_fallback_language/2
  # ============================================================================

  describe "get_fallback_language/2" do
    test "returns matching language from first post" do
      posts = [build_post(%{available_languages: ["en", "fr"]})]
      assert Listing.get_fallback_language("en", posts) == "en"
    end

    test "returns requested language when no posts" do
      assert Listing.get_fallback_language("de", []) == "de"
    end
  end
end
