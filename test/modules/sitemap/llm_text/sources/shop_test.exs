defmodule PhoenixKit.Modules.Sitemap.LLMText.Sources.ShopTest do
  use ExUnit.Case, async: true

  alias PhoenixKit.Modules.Sitemap.LLMText.Sources.Shop

  describe "source_name/0" do
    test "returns :shop" do
      assert Shop.source_name() == :shop
    end
  end

  describe "enabled?/0" do
    test "returns false when PhoenixKitEcommerce module is not loaded" do
      # PhoenixKitEcommerce is not available in the test environment
      assert Shop.enabled?() == false
    end
  end

  describe "collect_index_entries/1" do
    test "returns [] when disabled" do
      assert Shop.collect_index_entries("en") == []
    end

    test "returns [] for nil language when disabled" do
      assert Shop.collect_index_entries(nil) == []
    end
  end

  describe "serve_page/2" do
    test "returns :not_found when disabled" do
      assert Shop.serve_page(["shop", "product", "some-product.md"], "en") == :not_found
    end

    test "returns :not_found for unrecognized path when disabled" do
      assert Shop.serve_page(["unknown"], "en") == :not_found
    end
  end

  describe "extract_localized/3" do
    test "extracts value for the given language" do
      assert Shop.extract_localized(%{"en" => "hello", "et" => "tere"}, "en", "fallback") ==
               "hello"
    end

    test "falls back to another language when requested language not present" do
      assert Shop.extract_localized(%{"et" => "tere"}, "en", "fallback") == "tere"
    end

    test "returns plain string as-is" do
      assert Shop.extract_localized("plain string", "en", "fallback") == "plain string"
    end

    test "returns default for nil" do
      assert Shop.extract_localized(nil, "en", "fallback") == "fallback"
    end

    test "returns default for empty string" do
      assert Shop.extract_localized("", "en", "fallback") == "fallback"
    end

    test "returns default for empty map" do
      assert Shop.extract_localized(%{}, "en", "fallback") == "fallback"
    end

    test "handles nil language by using en fallback" do
      assert Shop.extract_localized(%{"en" => "hello"}, nil, "fallback") == "hello"
    end
  end
end
