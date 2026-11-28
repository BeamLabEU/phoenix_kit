defmodule PhoenixKitWeb.Components.LanguageSwitcherItemsTest do
  @moduledoc """
  The headless switcher (`language_switcher_items/1`) and `hreflang_tags/1`.
  """
  use ExUnit.Case, async: false

  import Phoenix.Component
  import Phoenix.LiveViewTest

  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  setup do
    LanguageSettings.multilingual!(languages: ~w(en-US et ru), no_prefix: true)
  end

  defp builder(nil), do: "/products"
  defp builder(segment), do: "/#{segment}/products"

  test "the :let inner block renders the host's markup per language" do
    assigns = %{url: &builder/1}

    html =
      rendered_to_string(~H"""
      <LanguageSwitcher.language_switcher_items
        :let={link}
        url={@url}
        current_locale="et"
        class="langs"
      >
        <a href={link.url} data-current={to_string(link.current?)}>{link.code}</a>
      </LanguageSwitcher.language_switcher_items>
      """)

    assert html =~ ~s(<nav class="langs">)
    assert html =~ ~s(<a href="/products" data-current="false">en</a>)
    assert html =~ ~s(<a href="/et/products" data-current="true">et</a>)
    assert html =~ ~s(<a href="/ru/products" data-current="false">ru</a>)
    refute html =~ "btn"
  end

  test "an :item slot with precomputed links and a custom tag" do
    assigns = %{
      links: PhoenixKit.I18n.language_links(%{current_locale: "ru"}, url: &builder/1)
    }

    html =
      rendered_to_string(~H"""
      <LanguageSwitcher.language_switcher_items links={@links} tag="ul" aria-label="Language">
        <:item :let={link}>
          <li class={link.current? && "on"}>{link.hreflang}</li>
        </:item>
      </LanguageSwitcher.language_switcher_items>
      """)

    assert html =~ ~s(<ul aria-label="Language">)
    assert html =~ ~s(<li class="on">ru</li>)
    assert html =~ ~s(>en</li>)
    refute html =~ ~s(<li class="on">en</li>)
  end

  test "without a slot it renders plain links" do
    assigns = %{url: &builder/1}

    html =
      rendered_to_string(~H"""
      <LanguageSwitcher.language_switcher_items url={@url} current_locale="et" hide_current />
      """)

    assert html =~ ~s(href="/ru/products")
    assert html =~ ~s(hreflang="ru")
    refute html =~ ~s(href="/et/products")
  end

  test "strategy: :path builds from the current path" do
    assigns = %{}

    html =
      rendered_to_string(~H"""
      <LanguageSwitcher.language_switcher_items
        strategy={:path}
        current_path="/et/about"
        current_locale="et"
      />
      """)

    assert html =~ ~s(href="/about")
    assert html =~ ~s(href="/ru/about")
  end

  test "hreflang_tags/1 renders alternate links with x-default" do
    assigns = %{url: &builder/1}

    html =
      rendered_to_string(~H"""
      <LanguageSwitcher.hreflang_tags url={@url} base_url="https://example.com" />
      """)

    assert html =~ ~s(<link rel="alternate" hreflang="et" href="https://example.com/et/products">)

    assert html =~
             ~s(<link rel="alternate" hreflang="x-default" href="https://example.com/products">)
  end
end
