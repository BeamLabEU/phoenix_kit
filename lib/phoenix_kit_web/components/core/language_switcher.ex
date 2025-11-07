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

  alias PhoenixKit.Module.Languages
  alias PhoenixKitWeb.Components.Core.Icon
  alias Phoenix.LiveView.JS

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
  attr(:current_locale, :string, required: true, doc: "Current active language code")

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

  def language_switcher_dropdown(assigns) do
    # Use provided languages or fetch from Language Module
    # get_display_languages() returns configured languages or defaults (top 12)
    languages = assigns.languages || Languages.get_display_languages()

    # Filter out current language if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(languages, &(&1["code"] != assigns.current_locale))
      else
        languages
      end

    current_language =
      Enum.find(filtered_languages, &(&1["code"] == assigns.current_locale)) ||
        %{"code" => assigns.current_locale, "name" => String.upcase(assigns.current_locale)}

    assigns =
      assigns
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
  attr(:current_locale, :string, required: true, doc: "Current active language code")

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
    # Use provided languages or fetch from Language Module
    # get_display_languages() returns configured languages or defaults (top 12)
    languages = assigns.languages || Languages.get_display_languages()

    # Filter out current language if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(languages, &(&1["code"] != assigns.current_locale))
      else
        languages
      end

    assigns =
      assigns
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
  attr(:current_locale, :string, required: true, doc: "Current active language code")

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
    # Use provided languages or fetch from Language Module
    # get_display_languages() returns configured languages or defaults (top 12)
    languages = assigns.languages || Languages.get_display_languages()

    # Filter out current language if hide_current is enabled
    filtered_languages =
      if assigns.hide_current do
        Enum.filter(languages, &(&1["code"] != assigns.current_locale))
      else
        languages
      end

    assigns =
      assigns
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
  defp generate_language_url(_current_locale, new_locale) do
    # Get current path and replace locale if present
    # This is a simple implementation - you may need to adjust based on your routing
    case get_current_path_from_assigns() do
      nil ->
        # Fallback if path is not available
        "/"

      current_path ->
        # Remove PhoenixKit prefix if present
        normalized_path = String.replace_prefix(current_path, "/phoenix_kit", "")

        # Remove existing locale prefix if it matches a language code
        clean_path =
          case String.split(normalized_path, "/", parts: 3) do
            ["", potential_locale, rest] ->
              if Languages.valid_language?(potential_locale) do
                "/" <> rest
              else
                normalized_path
              end

            _ ->
              normalized_path
          end

        # Build new URL with new locale
        "/#{new_locale}#{clean_path}"
    end
  end

  # Helper to get current path - should be passed via socket assigns
  defp get_current_path_from_assigns do
    # This will be populated by the LiveView or template context
    # For now, return nil - the actual path should be passed as an attribute
    nil
  end
end
