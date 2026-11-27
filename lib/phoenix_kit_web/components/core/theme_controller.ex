defmodule PhoenixKitWeb.Components.Core.ThemeController do
  @moduledoc """
  Shared theme controller component for admin and dashboard.

  Provides a dropdown to select from available daisyUI themes.
  Supports filtering to show only specific themes.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias Phoenix.LiveView.JS
  alias PhoenixKit.ThemeConfig

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Icons, only: [icon_system: 1, icon_check: 1]

  @doc """
  Renders a theme controller dropdown.

  ## Attributes

  - `themes` - List of theme names to show, or `:all` for all themes (default: `:all`)
  - `id` - Unique ID for the dropdown (default: "theme-dropdown")
  - `class` - Additional CSS classes

  ## Examples

      <%!-- All themes --%>
      <.theme_controller />

      <%!-- Only specific themes --%>
      <.theme_controller themes={["system", "light", "dark", "nord", "dracula"]} />

      <%!-- From config --%>
      <.theme_controller themes={Application.get_env(:phoenix_kit, :dashboard_themes, :all)} />
  """
  attr :themes, :any, default: :all
  attr :id, :string, default: "theme-dropdown"
  attr :class, :string, default: nil

  attr :mode, :atom,
    default: :auto,
    values: [:auto, :dropdown, :toggle, :inline],
    doc: """
    :auto renders a toggle when the theme list is exactly two concrete
    themes of DIFFERING base (one light, one dark) and a dropdown otherwise;
    :dropdown and :toggle force the shape. :toggle raises unless the list is
    such a pair — a toggle over three states would have hidden state, and
    sun/moon semantics over two themes of the same base are false. (A :cycle
    mode was considered and rejected: hidden state, no accessibility story,
    and it makes configuration ORDER behavioural.)

    :inline is a group of icon buttons, one per theme, every choice in view:
    for a SHORT list inside something that is already a menu (the account
    menu's System / Light / Dark row), where a dropdown would open a menu
    inside a menu. Never chosen by :auto.
    """

  attr :rest, :global

  def theme_controller(assigns) do
    dropdown_themes = ThemeConfig.dropdown_themes(assigns.themes)

    assigns = assign(assigns, :dropdown_themes, dropdown_themes)

    # A toggle needs a pair AND both bases: sun/moon icons and aria-pressed
    # "dark on" semantics are simply false over two themes of the same base.
    pair? =
      match?([%{type: :theme}, %{type: :theme}], dropdown_themes) and
        dropdown_themes |> Enum.map(&toggle_base(&1.value)) |> Enum.uniq() |> length() == 2

    case {assigns.mode, pair?} do
      {:inline, _} ->
        theme_inline(assigns)

      {:toggle, false} ->
        raise ArgumentError,
              "theme_controller mode: :toggle needs exactly two concrete themes, " <>
                "one light and one dark, got: #{inspect(Enum.map(dropdown_themes, & &1.value))}"

      {:dropdown, _} ->
        theme_dropdown(assigns)

      {_, true} ->
        theme_toggle_pair(assigns)

      _ ->
        theme_dropdown(assigns)
    end
  end

  # ONE persistent button, not one-per-theme. The first version rendered a
  # button per theme and hid the active one — which removed the element the
  # keyboard user had just focused, dropping focus to <body> on every
  # activation. This button never disappears: aria-pressed says whether the
  # dark half of the pair is on, CSS keyed off html[data-theme] shows the
  # right sun/moon icon from the first paint, and the theme script keeps
  # data-phx-theme pointing at the OTHER theme.
  #
  # The click is a real JS.dispatch, same contract as the dropdown options:
  # phx:set-theme bubbles to window, where BOTH the kit's ThemeControllerScript
  # and the stock Phoenix root-layout script read e.target.dataset.phxTheme.
  # An earlier version relied solely on a click listener inside the kit
  # script, which made the button silently dead in host layouts that render
  # this component without the kit's layouts.
  defp theme_toggle_pair(assigns) do
    [a, b] = assigns.dropdown_themes
    {light, dark} = if toggle_base(a.value) == "dark", do: {b, a}, else: {a, b}

    assigns = assign(assigns, light: light, dark: dark)

    ~H"""
    <div class={["flex items-center", @class]} {@rest} id={@id}>
      <%!-- Icon visibility is CSS, keyed off html[data-theme] — which the
           pre-paint bootstrap stamps — so the correct icon shows from the
           first paint. The JS-swapped version flashed the sun at dark-mode
           users until the end-of-body script initialized. --%>
      {Phoenix.HTML.raw(toggle_icon_css(@dark.value))}
      <button
        type="button"
        data-theme-role="toggle"
        data-theme-target={@dark.value}
        data-phx-theme={@dark.value}
        data-theme-light={@light.value}
        data-theme-dark={@dark.value}
        phx-click={JS.dispatch("phx:set-theme")}
        title={"#{@light.label} / #{@dark.label}"}
        aria-label={"#{@light.label} / #{@dark.label}"}
        aria-pressed="false"
        class="btn btn-sm btn-ghost btn-circle"
      >
        <span data-toggle-icon="light"><.icon name="hero-sun" class="w-5 h-5" /></span>
        <span data-toggle-icon="dark"><.icon name="hero-moon" class="w-5 h-5" /></span>
      </button>
    </div>
    """
  end

  # Scoped by [data-theme-dark=...] rather than by id, so multiple toggles —
  # even over different pairs — coexist without any id requirement. The name
  # is safe to interpolate: dropdown_themes/1 filters to KNOWN theme names,
  # and the regex is the belt to that suspender.
  defp toggle_icon_css(dark_value) do
    if dark_value =~ ~r/\A[a-z0-9_-]+\z/ do
      # A plain string, not HEEx: the nonce is interpolated, never `nonce={…}`.
      """
      <style#{PhoenixKitWeb.CSP.attr(:style)}>
        html[data-theme="#{dark_value}"] [data-theme-dark="#{dark_value}"] [data-toggle-icon="light"] { display: none; }
        html:not([data-theme="#{dark_value}"]) [data-theme-dark="#{dark_value}"] [data-toggle-icon="dark"] { display: none; }
      </style>
      """
    else
      ""
    end
  end

  defp toggle_base(theme), do: Map.get(ThemeConfig.base_map(), theme, "light")

  # A group of toggle buttons. Which one is chosen is CSS, keyed off
  # html[data-theme-choice] — the SAVED choice ("system" or a theme's name),
  # stamped before the first paint by ThemeBootstrap and kept by the theme
  # script. Not html[data-theme]: that is the theme in effect, and cannot tell
  # "system, which is dark right now" from "dark". And not a class the script
  # toggles: a LiveView patch of the menu would take it off again until the
  # next navigation.
  #
  # For assistive technology the script sets aria-pressed. The buttons ask
  # LiveView to leave that attribute alone, or a patch of the menu would
  # announce all three as not pressed, and they ask the script to stamp it
  # when they appear (phoenix_kit:theme-sync): a row that arrives in a patch
  # comes after the script's own start. Toggle buttons, not role="radio": a
  # radio group promises one tab stop and arrow keys, and these are three
  # ordinary buttons, each reached by Tab and pressed with Enter or Space.
  defp theme_inline(assigns) do
    ~H"""
    <div class={["flex items-center", @class]} id={@id} {@rest}>
      {Phoenix.HTML.raw(inline_choice_css(@dropdown_themes))}
      <div class="join" role="group" aria-label={gettext("Theme")}>
        <button
          :for={theme <- @dropdown_themes}
          type="button"
          aria-pressed="false"
          aria-label={theme.label}
          title={theme.label}
          phx-mounted={
            JS.ignore_attributes(["aria-pressed"]) |> JS.dispatch("phoenix_kit:theme-sync")
          }
          phx-click={JS.dispatch("phx:set-theme", detail: %{theme: theme.value})}
          data-phx-theme={theme.value}
          data-theme-target={theme.value}
          data-theme-role="inline-option"
          data-theme-option={theme.value}
          class="btn btn-sm join-item px-2.5"
        >
          <%= cond do %>
            <% theme.type == :system -> %>
              <.icon_system class="size-4" />
            <% toggle_base(theme.value) == "dark" -> %>
              <.icon name="hero-moon" class="size-4" />
            <% true -> %>
              <.icon name="hero-sun" class="size-4" />
          <% end %>
        </button>
      </div>
    </div>
    """
  end

  # One rule per offered theme: CSS has no "these two attributes are equal".
  # Names are safe to interpolate for the reason given at toggle_icon_css/1.
  defp inline_choice_css(themes) do
    selectors =
      for %{value: value} <- themes, value =~ ~r/\A[a-z0-9_-]+\z/ do
        ~s(html[data-theme-choice="#{value}"] [data-theme-option="#{value}"])
      end

    if selectors == [] do
      ""
    else
      # A plain string, not HEEx: the nonce is interpolated, never `nonce={…}`.
      """
      <style#{PhoenixKitWeb.CSP.attr(:style)}>
        #{Enum.join(selectors, ",\n  ")} {
          background-color: var(--color-primary);
          border-color: var(--color-primary);
          color: var(--color-primary-content);
        }
      </style>
      """
    end
  end

  defp theme_dropdown(assigns) do
    ~H"""
    <div class={["flex flex-col gap-3 w-full", @class]} {@rest}>
      <div class="relative w-full" data-theme-dropdown>
        <details class="dropdown dropdown-end dropdown-bottom" id={@id}>
          <summary class="btn btn-sm btn-ghost btn-circle">
            <.icon name="hero-swatch" class="w-5 h-5" />
          </summary>
          <ul
            class="dropdown-content w-72 min-w-0 rounded-box border border-base-200 bg-base-100 p-2 shadow-xl z-[60] mt-2 max-h-[80vh] overflow-y-auto overflow-x-hidden list-none space-y-1"
            tabindex="0"
            phx-click-away={JS.remove_attribute("open", to: "##{@id}")}
          >
            <%= for theme <- @dropdown_themes do %>
              <li class="w-full">
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:set-theme", detail: %{theme: theme.value})}
                  data-phx-theme={theme.value}
                  data-tip={theme.value}
                  data-theme-target={theme.value}
                  data-theme-role="dropdown-option"
                  role="option"
                  aria-pressed="false"
                  class="w-full group flex items-center gap-3 rounded-lg px-3 py-2 text-sm transition hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary cursor-pointer"
                >
                  <%= case theme.type do %>
                    <% :system -> %>
                      <div class="flex h-8 w-8 shrink-0 items-center justify-center rounded-md border border-base-200 bg-base-100 shadow-sm">
                        <.icon_system class="size-4 opacity-90" />
                      </div>
                    <% :theme -> %>
                      <div
                        data-theme={theme.preview_theme}
                        class="grid h-8 w-8 shrink-0 grid-cols-2 gap-0.5 rounded-md border border-base-200 bg-base-100 p-0.5 shadow-sm"
                      >
                        <div class="rounded-full bg-base-content"></div>
                        <div class="rounded-full bg-primary"></div>
                        <div class="rounded-full bg-secondary"></div>
                        <div class="rounded-full bg-accent"></div>
                      </div>
                  <% end %>
                  <span class="flex-1 text-left font-medium text-base-content truncate">
                    {theme.label}
                  </span>
                  <span data-theme-active-indicator>
                    <.icon_check class="size-4 text-primary opacity-0 scale-75 transition-all" />
                  </span>
                </button>
              </li>
            <% end %>
          </ul>
        </details>
      </div>
    </div>
    """
  end
end
