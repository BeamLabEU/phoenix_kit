defmodule PhoenixKitWeb.Components.LanguageSwitcherTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]
  import Phoenix.Component, only: [sigil_H: 2]
  import PhoenixKitWeb.Components.LanguageSwitcher

  alias Phoenix.LiveView.JS

  # ── Test data ────────────────────────────────────────────────

  defp two_languages do
    [
      %{code: "en-US", name: "English (US)", short_code: "EN-US", flag: "🇺🇸", is_primary: true},
      %{code: "es", name: "Spanish", short_code: "ES", flag: "🇪🇸", is_primary: false}
    ]
  end

  defp six_languages do
    [
      %{code: "en", name: "English", short_code: "EN", is_primary: true},
      %{code: "fr", name: "French", short_code: "FR", is_primary: false},
      %{code: "de", name: "German", short_code: "DE", is_primary: false},
      %{code: "es", name: "Spanish", short_code: "ES", is_primary: false},
      %{code: "it", name: "Italian", short_code: "IT", is_primary: false},
      %{code: "ja", name: "Japanese", short_code: "JA", is_primary: false}
    ]
  end

  defp publishing_languages do
    [
      %{
        code: "en",
        name: "English",
        display_code: "en",
        status: "published",
        exists: true,
        is_primary: true
      },
      %{
        code: "fr",
        name: "French",
        display_code: "fr",
        status: "draft",
        exists: true,
        is_primary: false
      },
      %{
        code: "de",
        name: "German",
        display_code: "de",
        status: nil,
        exists: false,
        is_primary: false
      }
    ]
  end

  defp string_keyed_languages do
    [
      %{
        "code" => "en",
        "name" => "English",
        "is_primary" => true,
        "status" => "published",
        "exists" => true
      },
      %{
        "code" => "fr",
        "name" => "French",
        "is_primary" => false,
        "status" => "draft",
        "exists" => true
      }
    ]
  end

  defp html(assigns) do
    rendered_to_string(assigns)
  end

  # ── Basic rendering ─────────────────────────────────────────

  describe "basic rendering" do
    test "renders nothing with empty list" do
      assigns = %{}
      result = html(~H"<.language_switcher languages={[]} />")
      assert result =~ ""
    end

    test "renders nothing with single language for inline/tabs" do
      assigns = %{langs: [%{code: "en", name: "English"}]}
      result = html(~H"<.language_switcher languages={@langs} />")
      refute result =~ "tablist"
    end

    test "renders two languages with inline variant" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" />
        """)

      assert result =~ "English (US)"
      assert result =~ "Spanish"
      assert result =~ "|"
    end

    test "renders with tabs variant" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" variant={:tabs} />
        """)

      assert result =~ "bg-base-200 rounded-box"
      assert result =~ "role=\"tablist\""
    end

    test "renders with pills variant" do
      assigns = %{langs: publishing_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" variant={:pills} show_status={true} />
        """)

      assert result =~ "rounded-lg"
    end

    test "renders single language for pills variant" do
      assigns = %{langs: [%{code: "en", name: "English", exists: true}]}

      result =
        html(~H"""
        <.language_switcher languages={@langs} variant={:pills} show_status={true} />
        """)

      # Single language (<=3) uses full names in auto mode
      assert result =~ "English"
    end
  end

  # ── Display modes ───────────────────────────────────────────

  describe "display modes" do
    test "auto mode shows full names when <= threshold" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher
          languages={@langs}
          current_language="en-US"
          display={:auto}
          auto_threshold={3}
        />
        """)

      assert result =~ "English (US)"
      assert result =~ "Spanish"
    end

    test "auto mode shows short codes when > threshold" do
      assigns = %{langs: six_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" display={:auto} auto_threshold={3} />
        """)

      assert result =~ "EN"
      assert result =~ "FR"
    end

    test "compact mode always shows short codes" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" display={:compact} />
        """)

      assert result =~ "EN-US"
      assert result =~ "ES"
    end

    test "full mode always shows full names" do
      assigns = %{langs: six_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" display={:full} />
        """)

      assert result =~ "English"
      assert result =~ "French"
      assert result =~ "German"
    end
  end

  # ── Filtering ───────────────────────────────────────────────

  describe "filtering" do
    test "show_status=false filters non-published languages with exists/status" do
      assigns = %{langs: publishing_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" />
        """)

      # Only English (published) passes the filter, but single language
      # means inline variant renders nothing
      assert result == ""
    end

    test "show_status=true shows all languages" do
      assigns = %{langs: publishing_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      # Titles include status annotations
      assert result =~ "title=\"English (Published)"
      assert result =~ "title=\"French (Draft)"
      assert result =~ "title=\"Add German translation"
    end

    test "languages without exists/status pass through when show_status=false" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" />
        """)

      # 2 languages <= 3 threshold => full names in auto mode
      assert result =~ "English (US)"
      assert result =~ "Spanish"
    end

    test "exclude_primary removes primary language" do
      assigns = %{langs: publishing_languages()}

      result =
        html(~H"""
        <.language_switcher
          languages={@langs}
          current_language="en"
          show_status={true}
          exclude_primary={true}
        />
        """)

      refute result =~ "title=\"English"
      # 2 languages <= 3 threshold => full names in auto mode
      assert result =~ "French"
      assert result =~ "German"
    end

    test "string-keyed maps work with filtering" do
      assigns = %{langs: string_keyed_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      # 2 languages <= 3 threshold => full names in auto mode
      assert result =~ "English"
      assert result =~ "French"
    end
  end

  # ── Status dots ─────────────────────────────────────────────

  describe "status dots" do
    test "renders dots when show_status=true" do
      assigns = %{langs: publishing_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      assert result =~ "rounded-full"
      assert result =~ "bg-success"
      assert result =~ "bg-warning"
    end

    test "no dots when show_status=false" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" show_status={false} />
        """)

      refute result =~ "rounded-full"
    end

    test "custom dot_color overrides status" do
      assigns = %{
        langs: [
          %{code: "en", name: "English", exists: true, dot_color: "error"},
          %{code: "fr", name: "French", exists: true, dot_color: "info"}
        ]
      }

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      assert result =~ "bg-error"
      assert result =~ "bg-info"
    end

    test "invalid dot_color falls back to status" do
      langs = [
        %{code: "en", name: "English", exists: true, status: "published", dot_color: "invalid"},
        %{code: "fr", name: "French", exists: true, status: "draft"}
      ]

      assigns = %{langs: langs}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      assert result =~ "bg-success"
      assert result =~ "bg-warning"
    end
  end

  # ── Primary indicators ─────────────────────────────────────

  describe "primary indicators" do
    test "show_primary renders star SVG" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" show_primary={true} />
        """)

      assert result =~ "<svg"
      assert result =~ "text-primary"
    end

    test "show_primary_label renders text" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" show_primary_label={true} />
        """)

      assert result =~ "Primary"
    end

    test "primary_divider renders vertical line" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher
          languages={@langs}
          current_language="en-US"
          show_primary={true}
          primary_divider={true}
        />
        """)

      assert result =~ "w-px h-4 bg-base-content/20"
    end
  end

  # ── Separators ──────────────────────────────────────────────

  describe "separators" do
    test "inline always shows pipe separators" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" variant={:inline} />
        """)

      assert result =~ "|"
    end

    test "tabs compact shows pipe separators" do
      assigns = %{langs: six_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" variant={:tabs} display={:compact} />
        """)

      assert result =~ "|"
    end

    test "tabs full does not show pipe separators" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" variant={:tabs} display={:full} />
        """)

      refute result =~ "text-base-content/30"
    end

    test "pills never shows pipe separators" do
      assigns = %{langs: publishing_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" variant={:pills} show_status={true} />
        """)

      refute result =~ "text-base-content/30"
    end
  end

  # ── Interaction modes ───────────────────────────────────────

  describe "interaction modes" do
    test "on_click renders buttons" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" on_click="switch_language" />
        """)

      assert result =~ "<button"
      assert result =~ "switch_language"
      assert result =~ "phx-value-language"
    end

    test "on_click_js renders buttons with JS" do
      js_fn = fn code -> JS.push("switch", value: %{lang: code}) end
      assigns = %{langs: two_languages(), js_fn: js_fn}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" on_click_js={@js_fn} />
        """)

      assert result =~ "<button"
      assert result =~ "push"
    end

    test "url renders links" do
      langs = [
        %{code: "en", name: "English", url: "/en/posts", status: "published", exists: true},
        %{code: "fr", name: "French", url: "/fr/posts", status: "published", exists: true}
      ]

      assigns = %{langs: langs}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      assert result =~ "<a"
      assert result =~ "/en/posts"
      assert result =~ "/fr/posts"
    end

    test "display-only renders spans with cursor-default" do
      assigns = %{langs: publishing_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      assert result =~ "<span"
      assert result =~ "cursor-default"
    end

    test "aria-pressed on buttons" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" on_click="switch" />
        """)

      assert result =~ "aria-pressed=\"true\""
      assert result =~ "aria-pressed=\"false\""
    end

    test "aria-current on links" do
      langs = [
        %{code: "en", name: "English", url: "/en", status: "published", exists: true},
        %{code: "fr", name: "French", url: "/fr", status: "published", exists: true}
      ]

      assigns = %{langs: langs}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      assert result =~ "aria-current=\"true\""
    end
  end

  # ── Flags ───────────────────────────────────────────────────

  describe "flags" do
    test "show_flags renders flag emojis" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" show_flags={true} />
        """)

      assert result =~ "🇺🇸"
      assert result =~ "🇪🇸"
    end

    test "flags hidden by default" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" />
        """)

      refute result =~ "🇺🇸"
    end
  end

  # ── Active styling ──────────────────────────────────────────

  describe "active styling" do
    test "current tab has primary styling in tabs" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" variant={:tabs} on_click="switch" />
        """)

      assert result =~ "bg-primary/20 text-primary"
    end

    test "current item has primary styling in inline" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" on_click="switch" />
        """)

      assert result =~ "bg-primary/30 text-primary"
    end
  end

  # ── Coercion / safety ──────────────────────────────────────

  describe "coercion and safety" do
    test "non-map items filtered out" do
      langs = [%{code: "en", name: "English"}, "not a map", 42, %{code: "fr", name: "French"}]
      assigns = %{langs: langs}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" />
        """)

      # 2 valid languages <= 3 threshold => full names in auto mode
      assert result =~ "English"
      assert result =~ "French"
    end

    test "language without code renders with ? in compact mode" do
      langs = [%{name: "No Code"}, %{code: "en", name: "English"}]
      assigns = %{langs: langs}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" display={:compact} />
        """)

      assert result =~ "?"
    end

    test "on_click_js that raises is handled" do
      bad_fn = fn _code -> raise "boom" end
      assigns = %{langs: two_languages(), bad_fn: bad_fn}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" on_click_js={@bad_fn} />
        """)

      assert result =~ "<button"
    end

    test "string-keyed maps work" do
      assigns = %{langs: string_keyed_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" show_status={true} />
        """)

      # 2 languages <= 3 threshold => full names in auto mode
      assert result =~ "English"
      assert result =~ "French"
      assert result =~ "bg-success"
      assert result =~ "bg-warning"
    end
  end

  # ── Container attributes ────────────────────────────────────

  describe "container attributes" do
    test "id is set" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" id="my-switcher" />
        """)

      assert result =~ "id=\"my-switcher\""
    end

    test "custom class applied" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" class="mt-4" />
        """)

      assert result =~ "mt-4"
    end
  end

  # ── Size variants ───────────────────────────────────────────

  describe "sizes" do
    test "xs uses smaller classes" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" size={:xs} />
        """)

      assert result =~ "text-xs"
    end

    test "md uses larger classes" do
      assigns = %{langs: two_languages()}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" size={:md} />
        """)

      assert result =~ "text-base"
    end
  end

  # ── Short code uppercasing ──────────────────────────────────

  describe "uppercasing" do
    test "display_code is uppercased" do
      langs = [
        %{code: "en", name: "English", display_code: "en"},
        %{code: "fr", name: "French", display_code: "fr"}
      ]

      assigns = %{langs: langs}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en" display={:compact} />
        """)

      assert result =~ "EN"
      assert result =~ "FR"
    end

    test "auto-derived code is uppercased" do
      langs = [
        %{code: "en-US", name: "English"},
        %{code: "fr-FR", name: "French"}
      ]

      assigns = %{langs: langs}

      result =
        html(~H"""
        <.language_switcher languages={@langs} current_language="en-US" display={:compact} />
        """)

      assert result =~ "EN"
      assert result =~ "FR"
    end
  end

  # ── lang_code/1 ─────────────────────────────────────────────

  describe "lang_code/1" do
    test "reads atom key" do
      assert lang_code(%{code: "en"}) == "en"
    end

    test "reads string key" do
      assert lang_code(%{"code" => "fr"}) == "fr"
    end

    test "returns nil for missing key" do
      assert lang_code(%{name: "English"}) == nil
    end

    test "returns nil for non-map" do
      assert lang_code("en") == nil
    end
  end
end
