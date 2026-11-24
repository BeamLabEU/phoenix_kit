defmodule PhoenixKitWeb.Components.Core.LanguageSwitcherTest do
  @moduledoc """
  Tests the `:per_translation_urls` attr on `Components.Core.LanguageSwitcher`.

  When a feature module (e.g. `phoenix_kit_publishing`) computes per-translation
  URLs that the simple locale-rewrite default can't reproduce, the consumer
  passes them through this attr and the switcher uses those explicit URLs
  instead of `generate_base_code_url/2`. Falls back to the default when no
  entry matches the requested base code.
  """
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]

  alias PhoenixKit.Test.LanguageSettings
  alias PhoenixKitWeb.Components.Core.LanguageSwitcher

  # The switcher is for a multilingual site: with the switch off no URL carries
  # a locale segment. Primed on, so the cache (a global process) makes the file
  # `async: false`.
  setup do
    LanguageSettings.multilingual!()
  end

  defp two_languages do
    [
      %{code: "en-US", name: "English (US)", is_primary: true},
      %{code: "fr", name: "French", is_primary: false}
    ]
  end

  describe "per_translation_urls — atom-keyed list (publishing's shape)" do
    test "uses the publishing URL when the language's base code matches" do
      assigns = %{
        per_urls: [
          %{code: "en", url: "/blog/my-post"},
          %{code: "fr", url: "/fr/blog/mon-article"}
        ],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      # Both entries should link to publishing's explicit URLs, NOT the locale-rewrite
      # default (which would prepend the configured url_prefix and locale segment).
      assert html =~ ~s(href="/blog/my-post")
      assert html =~ ~s(href="/fr/blog/mon-article")
    end

    test "falls back to locale-rewrite default when base code not in the list" do
      # The locale-rewrite default uses `Routes.path/2` which prepends the
      # configured `url_prefix` (set to `/phoenix_kit` in test config).
      assigns = %{
        per_urls: [%{code: "en", url: "/blog/my-post"}],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      # English uses the override (no url_prefix prepended).
      assert html =~ ~s(href="/blog/my-post")
      # French has no override → locale-rewrite default with url_prefix.
      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end

    test "a list holding a dialect and the bare base language gives the first, as it always did" do
      for {per_urls, expected} <- [
            {[%{code: "en-US", url: "/blog/a"}, %{code: "en", url: "/blog/b"}], "/blog/a"},
            {[%{code: "en", url: "/blog/b"}, %{code: "en-US", url: "/blog/a"}], "/blog/b"},
            {[%{code: "en-US", url: "/blog/a"}, %{code: "en", url: nil}], "/blog/a"}
          ] do
        assigns = %{per_urls: per_urls, languages: two_languages()}

        html =
          rendered_to_string(~H"""
          <LanguageSwitcher.language_switcher_dropdown
            current_locale="fr"
            languages={@languages}
            current_path="/some/page"
            per_translation_urls={@per_urls}
          />
          """)

        assert html =~ ~s(href="#{expected}")
      end
    end

    test "a first entry without a url falls back to the default, not to the next entry" do
      assigns = %{
        per_urls: [%{code: "en-US", url: nil}, %{code: "en", url: "/blog/b"}],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="fr"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      refute html =~ ~s(href="/blog/b")
    end

    test "normalizes full dialect codes to base codes for lookup" do
      # The list entry uses full code 'en-US' but the switcher iterates languages
      # by base code 'en' — DialectMapper.extract_base/1 normalizes both sides.
      assigns = %{
        per_urls: [%{code: "en-US", url: "/blog/normalized"}],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en-US"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      assert html =~ ~s(href="/blog/normalized")
    end
  end

  describe "per_translation_urls — string-keyed list" do
    test "accepts both atom and string keys for the entry's `code` field" do
      assigns = %{
        per_urls: [%{"code" => "fr", "url" => "/fr/string-keyed"}],
        languages: two_languages()
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={@per_urls}
        />
        """)

      assert html =~ ~s(href="/fr/string-keyed")
    end
  end

  describe "per_translation_urls — pass-through cases" do
    test "nil falls back to default URL for every language (no override applied)" do
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={nil}
        />
        """)

      # Both languages use the locale-rewrite default with url_prefix.
      # `default_language_no_prefix` is OFF (the default) and no DB is
      # reachable for this unit test, so the primary locale ALSO gets a
      # prefix. The "ON" branch (prefixless primary) is covered DB-side
      # in `test/integration/languages/default_language_no_prefix_test.exs`.
      assert html =~ ~s(href="/phoenix_kit/en/some/page")
      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end

    test "empty list falls back to default URL for every language" do
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
          per_translation_urls={[]}
        />
        """)

      # Setting OFF (default) + no DB → primary locale also gets prefix.
      assert html =~ ~s(href="/phoenix_kit/en/some/page")
      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end

    test "missing attr (default nil) preserves the historical default behavior" do
      # No per_translation_urls passed at all — same as the pre-feature
      # caller pattern. Pinning test that the default attr value of nil
      # doesn't accidentally short-circuit `resolve_url/3`.
      assigns = %{languages: two_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/some/page"
        />
        """)

      assert html =~ ~s(href="/phoenix_kit/fr/some/page")
    end
  end

  describe "single-vs-multi-dialect label dedup" do
    # `build_dialect_list/1` strips the country qualifier from each
    # rendered name when only one dialect of that base language is
    # configured. As soon as a second dialect of the *same* base shows
    # up, both English entries reacquire the qualifier so the user can
    # distinguish them. Other languages with only one dialect stay
    # bare.

    test "single dialect per language → bare language names render" do
      assigns = %{
        languages: [
          %{code: "en-US", name: "English (United States)"},
          %{code: "et-EE", name: "Estonian (Estonia)"},
          %{code: "fr-FR", name: "French (France)"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/p"
        />
        """)

      assert html =~ "English"
      assert html =~ "Estonian"
      assert html =~ "French"
      refute html =~ "(United States)"
      refute html =~ "(Estonia)"
      refute html =~ "(France)"
    end

    test "multiple dialects of the same base → that base reacquires the country qualifier" do
      assigns = %{
        languages: [
          %{code: "en-US", name: "English (United States)"},
          %{code: "en-GB", name: "English (United Kingdom)"},
          %{code: "et-EE", name: "Estonian (Estonia)"},
          %{code: "fr-FR", name: "French (France)"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/p"
        />
        """)

      # English variants need disambiguation
      assert html =~ "English (United States)"
      assert html =~ "English (United Kingdom)"

      # Sibling-free languages still render bare
      assert html =~ "Estonian"
      assert html =~ "French"
      refute html =~ "(Estonia)"
      refute html =~ "(France)"
    end

    test "dedupe_names/1 — public helper called from admin_nav + user_dashboard_nav" do
      # Single dialect → strip qualifier
      input = [
        %{code: "de-DE", name: "German (Germany)", flag: "🇩🇪"},
        %{code: "zh", name: "Chinese (Simplified)", flag: "🇨🇳"},
        %{code: "lv", name: "Latvian", flag: "🇱🇻"}
      ]

      assert [
               %{code: "de-DE", name: "German", flag: "🇩🇪"},
               %{code: "zh", name: "Chinese", flag: "🇨🇳"},
               %{code: "lv", name: "Latvian", flag: "🇱🇻"}
             ] = LanguageSwitcher.dedupe_names(input)

      # Multi-dialect → keep qualifier
      multi = [
        %{code: "en-US", name: "English (United States)"},
        %{code: "en-GB", name: "English (United Kingdom)"},
        %{code: "de-DE", name: "German (Germany)"}
      ]

      assert [
               %{code: "en-US", name: "English (United States)"},
               %{code: "en-GB", name: "English (United Kingdom)"},
               %{code: "de-DE", name: "German"}
             ] = LanguageSwitcher.dedupe_names(multi)
    end

    test "dedupe_names/1 supports string-keyed maps" do
      input = [
        %{"code" => "de-DE", "name" => "German (Germany)"},
        %{"code" => "fr-FR", "name" => "French (France)"}
      ]

      assert [
               %{"code" => "de-DE", "name" => "German"},
               %{"code" => "fr-FR", "name" => "French"}
             ] = LanguageSwitcher.dedupe_names(input)
    end

    test "unknown base code parses the bare name from the configured name" do
      assigns = %{
        languages: [
          %{code: "fil-PH", name: "Filipino (Philippines)"}
        ]
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="fil"
          languages={@languages}
          current_path="/p"
        />
        """)

      # Single dialect → strip the parenthetical from the configured
      # name. Works for any base code without a predefined map.
      assert html =~ "Filipino"
      refute html =~ "(Philippines)"
    end
  end

  describe "ai_translate — per-language sparkle + bulk action" do
    # The `:ai_translate` opt-in attr surfaces a sparkle button next to
    # missing-language items and a bulk CTA below the list. The
    # component emits `phx-click={ai_translate.event}` — host handlers
    # enqueue the actual translation worker.
    #
    # `nil` (default) → no AI UI; today's behavior. `:enabled, false`
    # → same. Anything else → component reads `:missing` /
    # `:in_flight` / `:completed` to decide what to render.

    defp three_languages do
      [
        %{code: "en-US", name: "English (US)", is_primary: true},
        %{code: "fr", name: "French"},
        %{code: "es", name: "Spanish"}
      ]
    end

    test "nil ai_translate renders no sparkle and no bulk button" do
      assigns = %{languages: three_languages()}

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
        />
        """)

      refute html =~ "✨"
      refute html =~ "Translate all missing"
    end

    test "enabled with missing list shows sparkle next to each missing language" do
      assigns = %{
        languages: three_languages(),
        ai: %{enabled: true, event: "translate_lang", missing: ["fr", "es"]}
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      # Two missing langs → two sparkle buttons + the bulk CTA (≥2 trigger).
      assert html =~ ~s|phx-click="translate_lang"|
      assert html =~ ~s|phx-value-lang="fr"|
      assert html =~ ~s|phx-value-lang="es"|
      assert html =~ ~s|phx-value-lang="*"|
      assert html =~ "Translate all missing"
    end

    test "single missing language shows the sparkle but skips the bulk CTA" do
      assigns = %{
        languages: three_languages(),
        ai: %{enabled: true, event: "translate_lang", missing: ["es"]}
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      assert html =~ ~s|phx-value-lang="es"|
      refute html =~ "Translate all missing"
      refute html =~ ~s|phx-value-lang="*"|
    end

    test "in_flight swaps sparkle for spinner and removes phx-click on that language" do
      assigns = %{
        languages: three_languages(),
        ai: %{
          enabled: true,
          event: "translate_lang",
          missing: ["fr", "es"],
          in_flight: ["fr"]
        }
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      # `fr` is in-flight → spinner present, no phx-click for fr-only.
      assert html =~ "loading-spinner"
      assert html =~ "Translation in progress"
      # `es` still has the click button.
      assert html =~ ~s|phx-value-lang="es"|
    end

    test "enabled: false is treated the same as nil (no AI UI)" do
      assigns = %{
        languages: three_languages(),
        ai: %{enabled: false, event: "translate_lang", missing: ["fr"]}
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      refute html =~ "✨"
      refute html =~ "Translate all missing"
    end

    test "completed languages (no longer in missing) get no sparkle even with stale state" do
      # Host removes "fr" from missing after the translation worker
      # finishes; the sparkle disappears naturally. Tests that the
      # component reads `missing` strictly, not derived from `in_flight`
      # or `completed`.
      assigns = %{
        languages: three_languages(),
        ai: %{
          enabled: true,
          event: "translate_lang",
          missing: ["es"],
          completed: ["fr"]
        }
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      assert html =~ ~s|phx-value-lang="es"|
      refute html =~ ~s|phx-value-lang="fr"|
    end

    test "string-keyed ai_translate map works (JSON/JSONB hosts)" do
      assigns = %{
        languages: three_languages(),
        ai: %{
          "enabled" => true,
          "event" => "translate_lang",
          "missing" => ["fr", "es"]
        }
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      assert html =~ ~s|phx-click="translate_lang"|
      assert html =~ "Translate all missing"
    end

    test "missing or blank event renders no AI UI (no dead clickable)" do
      # Three ways a host can misconfigure: forget `:event` entirely,
      # pass an empty string, or pass whitespace. Component hides the
      # affordance in all of them.
      assigns = %{languages: three_languages()}

      for cfg <- [
            %{enabled: true, missing: ["fr"]},
            %{enabled: true, event: "", missing: ["fr"]},
            %{enabled: true, event: "   ", missing: ["fr"]},
            %{enabled: true, event: nil, missing: ["fr"]}
          ] do
        assigns = Map.put(assigns, :ai, cfg)

        html =
          rendered_to_string(~H"""
          <LanguageSwitcher.language_switcher_dropdown
            current_locale="en"
            languages={@languages}
            current_path="/blog/post"
            ai_translate={@ai}
          />
          """)

        refute html =~ "✨"
        refute html =~ "Translate all missing"
      end
    end

    test "bulk count subtracts in_flight (doesn't re-enqueue what's already queued)" do
      # Three missing langs, two already in flight → only 1 actionable.
      # Bulk button needs ≥2 actionable to render, so it should be
      # hidden here.
      assigns = %{
        languages: [
          %{code: "en-US", name: "English (US)", is_primary: true},
          %{code: "fr", name: "French"},
          %{code: "es", name: "Spanish"},
          %{code: "de", name: "German"}
        ],
        ai: %{
          enabled: true,
          event: "translate_lang",
          missing: ["fr", "es", "de"],
          in_flight: ["fr", "es"]
        }
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      refute html =~ "Translate all missing"
      # Spinners for fr + es, sparkle still on de.
      assert html =~ "loading-spinner"
      assert html =~ ~s|phx-value-lang="de"|
    end

    test "bulk count shows the actionable number (missing minus in_flight)" do
      assigns = %{
        languages: [
          %{code: "en-US", name: "English (US)", is_primary: true},
          %{code: "fr", name: "French"},
          %{code: "es", name: "Spanish"},
          %{code: "de", name: "German"}
        ],
        ai: %{
          enabled: true,
          event: "translate_lang",
          missing: ["fr", "es", "de"],
          in_flight: ["fr"]
        }
      }

      html =
        rendered_to_string(~H"""
        <LanguageSwitcher.language_switcher_dropdown
          current_locale="en"
          languages={@languages}
          current_path="/blog/post"
          ai_translate={@ai}
        />
        """)

      # 3 missing minus 1 in-flight = 2 actionable
      assert html =~ "Translate all missing (2)"
    end
  end
end
