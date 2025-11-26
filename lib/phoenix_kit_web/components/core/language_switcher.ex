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
  alias PhoenixKit.Modules.Languages
  alias PhoenixKitWeb.Components.Core.Icon

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

  attr(:_language_update_key, :any,
    default: nil,
    doc: "Internal: forces re-render when languages change"
  )

  def language_switcher_dropdown(assigns) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Auto-detect current_locale if not explicitly provided
    # This might be a base code (en) or full dialect (en-US)
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        "en-US"

    # Get enabled languages - these are full dialect codes with names
    languages_config = assigns.languages || Languages.get_display_languages()

    # Transform to include both base code (for URLs) and dialect (for preference)
    all_dialects =
      languages_config
      |> Enum.map(fn lang ->
        dialect = lang["code"]
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang["name"],
          "flag" => flag
        }
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
          "flag" => "🌐"
        }

    assigns =
      assigns
      |> assign(:current_locale, locale)
      |> assign(:current_base, current_base)
      |> assign(:languages, filtered_languages)
      |> assign(:current_language, current_language)

    ~H"""
    <div class={["relative", @class]}>
      <details class="dropdown dropdown-end dropdown-bottom" id="language-switcher-dropdown">
        <summary class="btn btn-sm btn-ghost btn-circle">
          <Icon.icon name="hero-globe-alt" class="w-5 h-5" />
        </summary>
        <ul
          class="dropdown-content w-56 rounded-box border border-base-200 bg-base-100 p-2 shadow-xl z-[60] mt-2 list-none space-y-1"
          tabindex="0"
          phx-click-away={JS.remove_attribute("open", to: "#language-switcher-dropdown")}
        >
          <%= for language <- @languages do %>
            <li class="w-full">
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
                      {language["name"]}
                    </span>
                    <%= if @show_native_names && Map.get(language, "native") do %>
                      <span class="text-xs text-base-content/60 block">
                        {language["native"]}
                      </span>
                    <% end %>
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
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Auto-detect current_locale if not explicitly provided
    # This might be a base code (en) or full dialect (en-US)
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        "en-US"

    # Get enabled languages - these are full dialect codes with names
    languages_config = assigns.languages || Languages.get_display_languages()

    # Transform to include both base code (for URLs) and dialect (for preference)
    all_dialects =
      languages_config
      |> Enum.map(fn lang ->
        dialect = lang["code"]
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang["name"],
          "flag" => flag
        }
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
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Auto-detect current_locale if not explicitly provided
    # This might be a base code (en) or full dialect (en-US)
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        "en-US"

    # Get enabled languages - these are full dialect codes with names
    languages_config = assigns.languages || Languages.get_display_languages()

    # Transform to include both base code (for URLs) and dialect (for preference)
    all_dialects =
      languages_config
      |> Enum.map(fn lang ->
        dialect = lang["code"]
        base = DialectMapper.extract_base(dialect)
        flag = get_language_flag(dialect)

        %{
          "base_code" => base,
          "dialect" => dialect,
          "name" => lang["name"],
          "flag" => flag
        }
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

  # Generate URL with ONLY base code - no dialect, no query params
  # This is the clean URL used in href attributes
  # Example: generate_base_code_url("en", "/ru/admin/dashboard") => "/en/admin/dashboard"
  defp generate_base_code_url(base_code, current_path) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Extract base code from current path for proper path processing
    current_base = extract_locale_from_path(current_path)

    # Remove locale from path
    path_without_locale = get_path_without_locale(current_path, current_base)

    # Generate clean URL with base code only
    PhoenixKit.Utils.Routes.path(path_without_locale, locale: base_code)
  end

  # Extract the locale segment from a path
  # /en/admin/dashboard => "en"
  # /en-US/admin/dashboard => "en-US"
  defp extract_locale_from_path(nil), do: nil

  defp extract_locale_from_path(path) do
    case String.split(path, "/", parts: 3) do
      ["", locale, _rest] -> locale
      ["", locale] -> locale
      _ -> nil
    end
  end

  # Helper function to extract path without locale prefix
  # Handles: /en/admin/dashboard → /admin/dashboard
  # Handles: /admin/dashboard → /admin/dashboard (no locale)
  # Handles: nil → / (root)
  defp get_path_without_locale(nil, _current_locale), do: "/"

  defp get_path_without_locale(current_path, current_locale) do
    # Remove locale from path: /en/admin/dashboard → /admin/dashboard
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
