defmodule PhoenixKitWeb.Components.Core.LanguageSwitcher do
  @moduledoc """
  Language switcher component for frontend applications.

  Provides a reusable language selection dropdown that pulls available languages
  from the Language Module. Supports multiple display styles and configurations.

  ## Examples

      # Basic dropdown switcher
      <.language_switcher_dropdown current_locale={@current_locale} />

      # Button group switcher (for mobile)
      <.language_switcher_buttons current_locale={@current_locale} />

      # Inline switcher with flags
      <.language_switcher_inline current_locale={@current_locale} />

  ## Attributes

  - `current_locale` - Current active language code (e.g., "en", "es")
  - `style` - Display style: `:dropdown`, `:buttons`, `:inline` (default: `:dropdown`)
  - `class` - Additional CSS classes to apply
  - `show_flags` - Show language flags (default: true)
  - `show_native_names` - Show native language names (default: false)
  """

  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias PhoenixKit.Config
  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitWeb.Components.Core.Icon

  @default_locale Config.default_locale()

  @doc """
  Renders a dropdown language switcher.

  Displays a globe icon that opens a dropdown menu with available languages.
  Automatically fetches the configured languages (or default top 12 if not configured).
  Perfect for navigation bars and header areas.

  ## Examples

      <.language_switcher_dropdown current_locale={@current_locale} />

      <.language_switcher_dropdown
        current_locale={@current_locale}
        show_native_names={true}
      />
  """
  attr(:current_locale, :string,
    default: nil,
    doc: "Current active language code (auto-detected if not provided)"
  )

  attr(:languages, :any,
    default: nil,
    doc: "List of language maps. If nil, fetches from Language Module"
  )

  attr(:show_flags, :boolean, default: true, doc: "Show language flags")
  attr(:show_names, :boolean, default: true, doc: "Show language names")
  attr(:show_native_names, :boolean, default: false, doc: "Show native language names")
  attr(:goto_home, :boolean, default: false, doc: "Redirect to home page on language switch")
  attr(:hide_current, :boolean, default: false, doc: "Hide currently selected language from list")
  attr(:class, :string, default: "", doc: "Additional CSS classes")

  attr(:current_path, :string,
    default: nil,
    doc: "Current path to preserve when switching languages"
  )

  attr(:scroll_threshold, :integer,
    default: 10,
    doc: "Number of languages after which to show scrollbar and search"
  )

  attr(:show_current, :boolean,
    default: false,
    doc: "Show current language (flag + name) in dropdown trigger instead of globe icon"
  )

  attr(:continent_threshold, :integer,
    default: 7,
    doc: "Number of languages after which the continent grouping step is shown"
  )

  attr(:_language_update_key, :any,
    default: nil,
    doc: "Internal: forces re-render when languages change"
  )

  def language_switcher_dropdown(assigns) do
    assigns = prepare_dropdown_assigns(assigns)

    ~H"""
    <div class={["relative", @class]}>
      <details
        class="dropdown dropdown-end dropdown-bottom"
        id="language-switcher-dropdown"
        phx-hook="LanguageSwitcherPosition"
      >
        <summary class={[
          "btn btn-sm",
          if(@show_current, do: "gap-2", else: "btn-ghost btn-circle")
        ]}>
          <%= if @show_current do %>
            <span class="text-lg">{@current_language["flag"]}</span>
            <span class="font-medium">{@current_language["name"]}</span>
            <Icon.icon name="hero-chevron-down" class="w-4 h-4" />
          <% else %>
            <Icon.icon name="hero-globe-alt" class="w-5 h-5" />
          <% end %>
        </summary>
        <div
          class="dropdown-content w-56 rounded-box border border-base-200 bg-base-100 shadow-xl z-[60] mt-2"
          tabindex="0"
          phx-click-away={JS.remove_attribute("open", to: "#language-switcher-dropdown")}
        >
          <%= if @use_continents do %>
            <%!-- Continent-grouped two-step navigation using JS commands --%>

            <%!-- Step 1: Continent list --%>
            <ul id="ls-continents" class="p-2 list-none space-y-1 max-h-72 overflow-y-auto">
              <%= for {continent, langs} <- @continent_groups do %>
                <% continent_id = "ls-cont-" <> slug(continent) %>
                <li class="w-full">
                  <button
                    type="button"
                    phx-click={
                      JS.hide(to: "#ls-continents")
                      |> JS.show(to: "#ls-back")
                      |> JS.show(to: "##{continent_id}")
                    }
                    class="w-full flex items-center justify-between rounded-lg px-3 py-2 text-sm transition hover:bg-base-200 cursor-pointer"
                  >
                    <span class="font-medium text-base-content">{continent}</span>
                    <span class="badge badge-ghost badge-sm">{length(langs)}</span>
                  </button>
                </li>
              <% end %>
            </ul>

            <%!-- Back button (hidden initially) --%>
            <button
              id="ls-back"
              type="button"
              phx-click={
                JS.hide(to: "#ls-back")
                |> hide_all_continent_panels(@continent_groups)
                |> JS.show(to: "#ls-continents")
              }
              class="hidden flex items-center gap-2 px-3 py-2 text-sm font-medium text-primary hover:bg-base-200 border-b border-base-200 cursor-pointer"
            >
              <Icon.icon name="hero-arrow-left" class="w-4 h-4" />
              <span>All regions</span>
            </button>

            <%!-- Step 2: Language panels per continent (all hidden initially) --%>
            <%= for {continent, langs} <- @continent_groups do %>
              <% continent_id = "ls-cont-" <> slug(continent) %>
              <ul id={continent_id} class="hidden p-2 list-none space-y-1 max-h-64 overflow-y-auto">
                <%= if length(langs) > @continent_threshold do %>
                  <li class="pb-1">
                    <input
                      type="text"
                      placeholder="Search languages..."
                      class="input input-sm input-bordered w-full"
                      id={"ls-search-" <> slug(continent)}
                      autocomplete="off"
                      oninput="
                        var t=this.value.toLowerCase().trim();
                        var ul=this.closest('ul');
                        var any=false;
                        ul.querySelectorAll('.language-item').forEach(function(i){
                          var n=i.dataset.name||'',v=i.dataset.native||'';
                          var m=!t||n.includes(t)||v.includes(t);
                          i.style.display=m?'':'none';
                          if(m)any=true;
                        });
                        var empty=ul.querySelector('.ls-no-results');
                        if(empty)empty.style.display=any?'none':'';
                      "
                    />
                  </li>
                <% end %>
                <%= for language <- langs do %>
                  <li
                    class="w-full language-item"
                    data-name={String.downcase(language["name"] || "")}
                    data-native={String.downcase(language["native"] || "")}
                  >
                    <a
                      href={generate_base_code_url(language["base_code"], @current_path)}
                      phx-click="phoenix_kit_set_locale"
                      phx-value-locale={language["base_code"]}
                      phx-value-url={generate_base_code_url(language["base_code"], @current_path)}
                      class={[
                        "w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200",
                        if(language["base_code"] == @current_base, do: "bg-base-200", else: "")
                      ]}
                    >
                      <%= if @show_flags do %>
                        <span class="text-lg">{language["flag"]}</span>
                      <% end %>
                      <div class="flex-1">
                        <span class="font-medium text-base-content">{language["name"]}</span>
                      </div>
                      <%= if language["base_code"] == @current_base do %>
                        <span class="ml-auto">✓</span>
                      <% end %>
                    </a>
                  </li>
                <% end %>
                <li class="ls-no-results px-3 py-2 text-sm text-base-content/50" style="display:none">
                  No languages found
                </li>
              </ul>
            <% end %>
          <% else %>
            <%!-- Flat language list (when <= threshold) --%>
            <%= if @needs_scroll do %>
              <div class="p-2 border-b border-base-200">
                <input
                  type="text"
                  placeholder="Search languages..."
                  class="input input-sm input-bordered w-full"
                  phx-hook="LanguageSwitcherSearch"
                  id="language-search-input"
                  autocomplete="off"
                />
              </div>
            <% end %>

            <ul
              class={[
                "p-2 list-none space-y-1",
                @needs_scroll && "max-h-64 overflow-y-auto"
              ]}
              id="language-switcher-list"
            >
              <%= for language <- @languages do %>
                <li
                  class="w-full language-item"
                  data-name={String.downcase(language["name"] || "")}
                  data-native={String.downcase(language["native"] || "")}
                >
                  <a
                    href={generate_base_code_url(language["base_code"], @current_path)}
                    phx-click="phoenix_kit_set_locale"
                    phx-value-locale={language["base_code"]}
                    phx-value-url={generate_base_code_url(language["base_code"], @current_path)}
                    class={[
                      "w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200",
                      if(language["base_code"] == @current_base, do: "bg-base-200", else: "")
                    ]}
                  >
                    <%= if @show_flags do %>
                      <span class="text-lg">{language["flag"]}</span>
                    <% end %>
                    <%= if @show_names do %>
                      <div class="flex-1">
                        <span class="font-medium text-base-content">
                          <%= if @show_native_names && Map.get(language, "native") do %>
                            {language["native"]}
                          <% else %>
                            {language["name"]}
                          <% end %>
                        </span>
                      </div>
                    <% else %>
                      <div class="flex-1"></div>
                    <% end %>
                    <%= if language["base_code"] == @current_base do %>
                      <span class="ml-auto">✓</span>
                    <% end %>
                  </a>
                </li>
              <% end %>
            </ul>
          <% end %>
        </div>
      </details>
    </div>
    """
  end

  @doc """
  Renders a button group language switcher.

  Displays language buttons in a row. Good for mobile layouts and areas
  where space allows for multiple buttons. Automatically fetches the configured
  languages (or default top 12 if not configured).

  ## Examples

      <.language_switcher_buttons current_locale={@current_locale} />
  """
  attr(:current_locale, :string,
    default: nil,
    doc: "Current active language code (auto-detected if not provided)"
  )

  attr(:languages, :any,
    default: nil,
    doc: "List of language maps. If nil, fetches from Language Module"
  )

  attr(:show_flags, :boolean, default: true, doc: "Show language flags")
  attr(:show_names, :boolean, default: true, doc: "Show language names")
  attr(:goto_home, :boolean, default: false, doc: "Redirect to home page on language switch")
  attr(:hide_current, :boolean, default: false, doc: "Hide currently selected language from list")
  attr(:class, :string, default: "", doc: "Additional CSS classes")

  attr(:current_path, :string,
    default: nil,
    doc: "Current path to preserve when switching languages"
  )

  def language_switcher_buttons(assigns) do
    # Auto-detect current_locale if not explicitly provided
    # This might be a base code (en) or full dialect (en-US)
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        @default_locale

    # Get enabled languages - these are full dialect codes with names
    # Ensure we always have a list, even if nil is returned
    languages_config = assigns.languages || Languages.get_display_languages() || []

    # Transform to include both base code (for URLs) and dialect (for preference)
    # Filter out any nil entries or entries with nil/empty base_code to prevent routing errors
    all_dialects =
      languages_config
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn lang ->
        dialect = lang.code
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang.name || dialect || "Unknown",
          "flag" => flag
        }
      end)
      |> Enum.filter(fn lang ->
        base_code = lang["base_code"]
        is_binary(base_code) and base_code != ""
      end)
      |> Enum.sort_by(& &1["name"])

    # Extract base code from current locale for matching
    current_base = DialectMapper.extract_base(locale)

    # Filter out current dialect if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(all_dialects, &(&1["base_code"] != current_base))
      else
        all_dialects
      end

    assigns =
      assigns
      |> assign(:current_locale, locale)
      |> assign(:current_base, current_base)
      |> assign(:languages, filtered_languages)

    ~H"""
    <div class={["flex gap-2", @class]}>
      <%= for language <- @languages do %>
        <a
          href={generate_base_code_url(language["base_code"], @current_path)}
          phx-click="phoenix_kit_set_locale"
          phx-value-locale={language["base_code"]}
          phx-value-url={generate_base_code_url(language["base_code"], @current_path)}
          class={[
            "btn btn-sm",
            if(language["base_code"] == @current_base,
              do: "btn-primary",
              else: "btn-outline"
            )
          ]}
        >
          <%= if @show_flags do %>
            <span>{language["flag"]}</span>
          <% end %>
          <%= if @show_names do %>
            <span>{language["base_code"] |> String.upcase()}</span>
          <% end %>
        </a>
      <% end %>
    </div>
    """
  end

  @doc """
  Renders an inline language switcher.

  Displays languages as inline text links. Minimal design perfect for footers
  or compact navigation areas. Automatically fetches the configured languages
  (or default top 12 if not configured).

  ## Examples

      <.language_switcher_inline current_locale={@current_locale} />
  """
  attr(:current_locale, :string,
    default: nil,
    doc: "Current active language code (auto-detected if not provided)"
  )

  attr(:languages, :any,
    default: nil,
    doc: "List of language maps. If nil, fetches from Language Module"
  )

  attr(:show_flags, :boolean, default: true, doc: "Show language flags")
  attr(:show_names, :boolean, default: true, doc: "Show language names")
  attr(:goto_home, :boolean, default: false, doc: "Redirect to home page on language switch")
  attr(:hide_current, :boolean, default: false, doc: "Hide currently selected language from list")
  attr(:class, :string, default: "", doc: "Additional CSS classes")

  attr(:current_path, :string,
    default: nil,
    doc: "Current path to preserve when switching languages"
  )

  def language_switcher_inline(assigns) do
    # Auto-detect current_locale if not explicitly provided
    # This might be a base code (en) or full dialect (en-US)
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        @default_locale

    # Get enabled languages - these are full dialect codes with names
    # Ensure we always have a list, even if nil is returned
    languages_config = assigns.languages || Languages.get_display_languages() || []

    # Transform to include both base code (for URLs) and dialect (for preference)
    # Filter out any nil entries or entries with nil/empty base_code to prevent routing errors
    all_dialects =
      languages_config
      |> Enum.reject(&is_nil/1)
      |> Enum.filter(&is_map/1)
      |> Enum.map(fn lang ->
        dialect = lang.code
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang.name || dialect || "Unknown",
          "flag" => flag
        }
      end)
      |> Enum.filter(fn lang ->
        base_code = lang["base_code"]
        is_binary(base_code) and base_code != ""
      end)
      |> Enum.sort_by(& &1["name"])

    # Extract base code from current locale for matching
    current_base = DialectMapper.extract_base(locale)

    # Filter out current dialect if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(all_dialects, &(&1["base_code"] != current_base))
      else
        all_dialects
      end

    assigns =
      assigns
      |> assign(:current_locale, locale)
      |> assign(:current_base, current_base)
      |> assign(:languages, filtered_languages)

    ~H"""
    <div class={["flex gap-4 items-center", @class]}>
      <%= for {language, index} <- Enum.with_index(@languages) do %>
        <div class="flex items-center gap-1">
          <%= if index > 0 do %>
            <span class="text-base-content/30">|</span>
          <% end %>
          <a
            href={generate_base_code_url(language["base_code"], @current_path)}
            phx-click="phoenix_kit_set_locale"
            phx-value-locale={language["base_code"]}
            phx-value-url={generate_base_code_url(language["base_code"], @current_path)}
            class={[
              "text-sm transition hover:text-primary",
              if(language["base_code"] == @current_base,
                do: "font-bold text-primary",
                else: "text-base-content"
              )
            ]}
          >
            <%= if @show_flags do %>
              <span class="mr-1">{language["flag"]}</span>
            <% end %>
            <%= if @show_names do %>
              {language["base_code"] |> String.upcase()}
            <% end %>
          </a>
        </div>
      <% end %>
    </div>
    """
  end

  # Chains JS.hide commands to hide all continent language panels
  defp hide_all_continent_panels(js, continent_groups) do
    Enum.reduce(continent_groups, js, fn {continent, _}, acc ->
      JS.hide(acc, to: "#ls-cont-#{slug(continent)}")
    end)
  end

  # Converts a continent name to a URL-safe slug for DOM IDs
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Prepares all assigns needed by the dropdown template
  defp prepare_dropdown_assigns(assigns) do
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        @default_locale

    languages_config = assigns.languages || Languages.get_display_languages() || []

    all_dialects = build_dialect_list(languages_config)

    filtered_languages =
      if assigns.hide_current do
        Enum.filter(all_dialects, &(&1["dialect"] != locale))
      else
        all_dialects
      end

    current_base = DialectMapper.extract_base(locale)

    current_language =
      Enum.find(all_dialects, &(&1["dialect"] == locale)) ||
        %{
          "base_code" => current_base,
          "dialect" => locale,
          "name" => String.upcase(locale),
          "native" => nil,
          "flag" => "🌐"
        }

    use_continents = length(filtered_languages) > assigns.continent_threshold

    continent_groups =
      if use_continents do
        Languages.get_enabled_languages_by_continent()
        |> Enum.map(fn {continent, langs} ->
          {continent, langs_to_dialect_maps(langs)}
        end)
      else
        []
      end

    needs_scroll = not use_continents and length(filtered_languages) > assigns.scroll_threshold

    assigns
    |> assign(:current_locale, locale)
    |> assign(:current_base, current_base)
    |> assign(:languages, filtered_languages)
    |> assign(:current_language, current_language)
    |> assign(:needs_scroll, needs_scroll)
    |> assign(:use_continents, use_continents)
    |> assign(:continent_groups, continent_groups)
  end

  # Transforms Language structs/maps from grouped continent data into dialect maps
  defp langs_to_dialect_maps(langs) do
    langs
    |> Enum.map(fn lang ->
      code = if is_struct(lang), do: lang.code, else: lang[:code]
      name = if is_struct(lang), do: lang.name, else: lang[:name]

      %{
        "base_code" => DialectMapper.extract_base(code),
        "dialect" => code,
        "name" => name || code || "Unknown",
        "flag" => get_language_flag(code)
      }
    end)
    |> Enum.sort_by(& &1["name"])
  end

  # Transforms language config into dialect maps for display
  defp build_dialect_list(languages_config) do
    languages_config
    |> Enum.reject(&is_nil/1)
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn lang ->
      dialect = lang.code
      base = DialectMapper.extract_base(dialect)

      %{
        "base_code" => base,
        "dialect" => dialect,
        "name" => lang.name || dialect || "Unknown",
        "native" => get_native_name(dialect),
        "flag" => get_language_flag(dialect)
      }
    end)
    |> Enum.filter(fn lang ->
      base_code = lang["base_code"]
      is_binary(base_code) and base_code != ""
    end)
    |> Enum.sort_by(& &1["name"])
  end

  # Helper function to get language flag emoji
  defp get_language_flag(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{flag: flag} -> flag
      nil -> "🌐"
    end
  end

  # Helper function to get native language name
  defp get_native_name(code) when is_binary(code) do
    case Languages.get_predefined_language(code) do
      %{native: native} -> native
      nil -> nil
    end
  end

  # Generate URL with ONLY base code - no dialect, no query params
  # This is the clean URL used in href attributes
  # Default language (from Languages module) gets clean URLs (no prefix),
  # other languages get locale prefix
  # Guard clauses for nil/empty base_code to prevent Phoenix.Param errors
  defp generate_base_code_url(nil, current_path), do: current_path || "/"
  defp generate_base_code_url("", current_path), do: current_path || "/"

  defp generate_base_code_url(base_code, current_path) do
    # Strip the URL prefix first (e.g., /phoenix_kit)
    url_prefix = PhoenixKit.Config.get_url_prefix()
    prefix_to_remove = if url_prefix == "/", do: "", else: url_prefix
    normalized = String.replace_prefix(current_path || "/", prefix_to_remove, "")

    # Ensure path starts with /
    normalized =
      if normalized == "" or not String.starts_with?(normalized, "/"), do: "/", else: normalized

    # Extract and strip the locale from the remaining path
    current_base = extract_locale_from_path(normalized)
    clean_path = strip_locale_from_path(normalized, current_base)

    # Admin paths use Routes.admin_path to keep locale in URL
    if String.contains?(clean_path, "/admin") do
      Routes.admin_path(clean_path, base_code)
    else
      Routes.path(clean_path, locale: base_code)
    end
  end

  # Extract the locale segment from a path (after prefix removal)
  # /en/admin => "en"
  # /en-US/admin => "en-US"
  defp extract_locale_from_path(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, _rest] ->
        if DialectMapper.valid_base_code?(locale), do: locale, else: nil

      ["", locale] ->
        if DialectMapper.valid_base_code?(locale), do: locale, else: nil

      _ ->
        nil
    end
  end

  # Strip locale prefix from path: /en/admin → /admin
  defp strip_locale_from_path(path, nil), do: path

  defp strip_locale_from_path(path, locale) do
    case String.split(path, "/", parts: 3) do
      ["", ^locale, rest] when is_binary(rest) -> "/#{rest}"
      ["", ^locale] -> "/"
      _ -> path
    end
  end
end
