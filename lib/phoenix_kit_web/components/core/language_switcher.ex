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
        Process.get(:phoenix_kit_current_locale_base) ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        "en"

    # Extract base code for comparison (in case locale is full dialect)
    base_locale = DialectMapper.extract_base(locale)

    # Get enabled languages and group by base code
    languages_config = assigns.languages || Languages.get_display_languages()

    # Group dialects by base language and take first enabled of each
    base_languages =
      languages_config
      |> Enum.group_by(&DialectMapper.extract_base(&1["code"]))
      |> Enum.map(fn {base, dialects} ->
        # Use first enabled dialect for this base language
        first_dialect = List.first(dialects)

        %{
          "code" => base,
          "name" => extract_base_language_name(first_dialect["name"]),
          "flag" => first_dialect["flag"]
        }
      end)
      |> Enum.sort_by(& &1["code"])

    # Filter out current language if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(base_languages, &(&1["code"] != base_locale))
      else
        base_languages
      end

    current_language =
      Enum.find(filtered_languages, &(&1["code"] == base_locale)) ||
        %{"code" => base_locale, "name" => String.upcase(base_locale)}

    assigns =
      assigns
      |> assign(:current_locale, base_locale)
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
                href={
                  if @goto_home,
                    do: "/#{language["code"]}",
                    else: generate_language_url(@current_locale, language["code"])
                }
                class={[
                  "w-full flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200",
                  if(language["code"] == @current_locale, do: "bg-base-200", else: "")
                ]}
              >
                <%= if @show_flags do %>
                  <span class="text-lg">{get_language_flag(language["code"])}</span>
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
                <%= if language["code"] == @current_locale do %>
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

  def language_switcher_buttons(assigns) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Auto-detect current_locale if not explicitly provided
    # This might be a base code (en) or full dialect (en-US)
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale_base) ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        "en"

    # Extract base code for comparison (in case locale is full dialect)
    base_locale = DialectMapper.extract_base(locale)

    # Get enabled languages and group by base code
    languages_config = assigns.languages || Languages.get_display_languages()

    # Group dialects by base language and take first enabled of each
    base_languages =
      languages_config
      |> Enum.group_by(&DialectMapper.extract_base(&1["code"]))
      |> Enum.map(fn {base, dialects} ->
        # Use first enabled dialect for this base language
        first_dialect = List.first(dialects)

        %{
          "code" => base,
          "name" => extract_base_language_name(first_dialect["name"]),
          "flag" => first_dialect["flag"]
        }
      end)
      |> Enum.sort_by(& &1["code"])

    # Filter out current language if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(base_languages, &(&1["code"] != base_locale))
      else
        base_languages
      end

    assigns =
      assigns
      |> assign(:current_locale, base_locale)
      |> assign(:languages, filtered_languages)

    ~H"""
    <div class={["flex gap-2", @class]}>
      <%= for language <- @languages do %>
        <a
          href={
            if @goto_home,
              do: "/#{language["code"]}",
              else: generate_language_url(@current_locale, language["code"])
          }
          class={[
            "btn btn-sm",
            if(language["code"] == @current_locale,
              do: "btn-primary",
              else: "btn-outline"
            )
          ]}
        >
          <%= if @show_flags do %>
            <span>{get_language_flag(language["code"])}</span>
          <% end %>
          <%= if @show_names do %>
            <span>{language["code"] |> String.upcase()}</span>
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

  def language_switcher_inline(assigns) do
    alias PhoenixKit.Modules.Languages.DialectMapper

    # Auto-detect current_locale if not explicitly provided
    # This might be a base code (en) or full dialect (en-US)
    locale =
      assigns.current_locale ||
        Process.get(:phoenix_kit_current_locale_base) ||
        Process.get(:phoenix_kit_current_locale) ||
        Gettext.get_locale(PhoenixKitWeb.Gettext) ||
        "en"

    # Extract base code for comparison (in case locale is full dialect)
    base_locale = DialectMapper.extract_base(locale)

    # Get enabled languages and group by base code
    languages_config = assigns.languages || Languages.get_display_languages()

    # Group dialects by base language and take first enabled of each
    base_languages =
      languages_config
      |> Enum.group_by(&DialectMapper.extract_base(&1["code"]))
      |> Enum.map(fn {base, dialects} ->
        # Use first enabled dialect for this base language
        first_dialect = List.first(dialects)

        %{
          "code" => base,
          "name" => extract_base_language_name(first_dialect["name"]),
          "flag" => first_dialect["flag"]
        }
      end)
      |> Enum.sort_by(& &1["code"])

    # Filter out current language if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(base_languages, &(&1["code"] != base_locale))
      else
        base_languages
      end

    assigns =
      assigns
      |> assign(:current_locale, base_locale)
      |> assign(:languages, filtered_languages)

    ~H"""
    <div class={["flex gap-4 items-center", @class]}>
      <%= for {language, index} <- Enum.with_index(@languages) do %>
        <div class="flex items-center gap-1">
          <%= if index > 0 do %>
            <span class="text-base-content/30">|</span>
          <% end %>
          <a
            href={
              if @goto_home,
                do: "/#{language["code"]}",
                else: generate_language_url(@current_locale, language["code"])
            }
            class={[
              "text-sm transition hover:text-primary",
              if(language["code"] == @current_locale,
                do: "font-bold text-primary",
                else: "text-base-content"
              )
            ]}
          >
            <%= if @show_flags do %>
              <span class="mr-1">{get_language_flag(language["code"])}</span>
            <% end %>
            <%= if @show_names do %>
              {language["code"] |> String.upcase()}
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

  # Helper function to generate language switch URL
  # Current implementation returns home page with new locale
  # Future enhancement: parse current path and preserve it when available via assigns
  defp generate_language_url(_current_locale, new_locale) do
    "/#{new_locale}"
  end

  # Helper function to extract base language name from full name
  # Example: "English (United States)" → "English"
  # Example: "Spanish (Mexico)" → "Spanish"
  # Example: "Japanese" → "Japanese"
  defp extract_base_language_name(full_name) do
    full_name
    |> String.split("(")
    |> List.first()
    |> String.trim()
  end
end
