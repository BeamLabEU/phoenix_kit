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

  attr(:_language_update_key, :any,
    default: nil,
    doc: "Internal: forces re-render when languages change"
  )

  def language_switcher_dropdown(assigns) do
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
        dialect = lang["code"]
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang["name"] || dialect || "Unknown",
          "native" => get_native_name(dialect),
          "flag" => flag
        }
      end)
      |> Enum.filter(fn lang ->
        base_code = lang["base_code"]
        is_binary(base_code) and base_code != ""
      end)
      |> Enum.sort_by(& &1["name"])

    # Filter out current dialect if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(all_dialects, &(&1["dialect"] != locale))
      else
        all_dialects
      end

    # Extract base code from current locale for matching
    current_base = DialectMapper.extract_base(locale)

    # Find current language by full dialect code
    current_language =
      Enum.find(all_dialects, &(&1["dialect"] == locale)) ||
        %{
          "base_code" => current_base,
          "dialect" => locale,
          "name" => String.upcase(locale),
          "native" => nil,
          "flag" => "🌐"
        }

    # Determine if we need scroll/search based on language count
    needs_scroll = length(filtered_languages) > assigns.scroll_threshold

    assigns =
      assigns
      |> assign(:current_locale, locale)
      |> assign(:current_base, current_base)
      |> assign(:languages, filtered_languages)
      |> assign(:current_language, current_language)
      |> assign(:needs_scroll, needs_scroll)

    ~H"""
    <div class={["relative", @class]}>
      <details class="dropdown dropdown-end dropdown-bottom" id="language-switcher-dropdown">
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
          <%!-- Search bar (only if many languages) --%>
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

          <%!-- Language list (scrollable if many languages) --%>
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
        dialect = lang["code"]
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang["name"] || dialect || "Unknown",
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
        dialect = lang["code"]
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang["name"] || dialect || "Unknown",
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
  # Default language gets clean URLs (no prefix), other languages get locale prefix
  # Example: generate_base_code_url("en", "/ru/admin") => "/admin" (if en is default)
  # Example: generate_base_code_url("es", "/admin") => "/es/admin"
  # Guard clauses for nil/empty base_code to prevent Phoenix.Param errors
  defp generate_base_code_url(nil, current_path), do: current_path || "/"
  defp generate_base_code_url("", current_path), do: current_path || "/"

  defp generate_base_code_url(base_code, current_path) do
    # Extract base code from current path for proper path processing
    current_base = extract_locale_from_path(current_path)

    # Remove locale from path
    path_without_locale = get_path_without_locale(current_path, current_base)

    # Generate URL using Routes.path which handles default language logic
    # Default language (first admin language, typically "en") gets clean URLs (no prefix)
    # Other languages get the locale prefix
    Routes.path(path_without_locale, locale: base_code)
  end

  # Extract the locale segment from a path
  # /en/admin => "en"
  # /en-US/admin => "en-US"
  defp extract_locale_from_path(nil), do: nil

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

  # Helper function to extract path without locale prefix
  # Handles: /en/admin → /admin
  # Handles: /admin → /admin (no locale)
  # Handles: nil → / (root)
  defp get_path_without_locale(nil, _current_locale), do: "/"

  defp get_path_without_locale(current_path, current_locale) do
    # Remove locale from path: /en/admin → /admin
    case String.split(current_path, "/", parts: 3) do
      ["", ^current_locale, rest] when is_binary(rest) ->
        "/#{rest}"

      ["", ^current_locale] ->
        "/"

      _ ->
        # Path doesn't start with locale, return as-is
        current_path
    end
  end
end
