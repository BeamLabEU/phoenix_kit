defmodule PhoenixKitWeb.Components.LanguageSwitcher do
  @moduledoc """
  Shared language switcher component for PhoenixKit.

  A configurable row of language options that works across all contexts:
  admin form tabs, publishing editors, public page navigation, etc.

  ## Display modes

  - `:auto` (default) — shows full names when ≤ `auto_threshold` languages,
    short codes when more
  - `:full` — always show full names (e.g., "English", "French")
  - `:compact` — always show short codes (e.g., "EN", "FR")

  ## Visual variants

  - `:inline` (default) — pipe-separated items: `EN | FR | ES`
  - `:tabs` — pill-shaped buttons on a rounded background bar
  - `:pills` — individual pill-shaped chips, each with its own background

  ## Interaction modes

  - **Button** — set `on_click` (event name) or `on_click_js` (fn returning `%JS{}`)
  - **Link** — each language map has a `:url` key, renders `<.link navigate={url}>`
  - **Display-only** — no click handler and no URL, renders a `<span>`

  ## Status dots

  When `show_status` is true, a colored dot appears before each language code.
  The dot color is resolved in priority order:

  1. `dot_color` — explicit daisyUI color class (e.g., `"success"`, `"warning"`)
  2. `status` — mapped automatically: `"published"` → green, `"draft"` → yellow,
     `"archived"` → gray
  3. `exists` — `true` → green dot, `false` → dim dot

  This makes the dots work for any use case: publishing post status, form content
  indicators ("has translations"), or custom per-module states.

  ## Examples

      <%!-- Admin form: tabs with primary star, skeleton switching --%>
      <.language_switcher
        languages={@language_tabs}
        current_language={@current_lang}
        on_click_js={&switch_lang_js(&1, @current_lang)}
        show_primary={true}
        primary_divider={true}
        variant={:tabs}
      />

      <%!-- Publishing editor: compact codes with status dots --%>
      <.language_switcher
        languages={@editor_languages}
        current_language={@current_language}
        on_click_js={&switch_lang_js(&1, @current_language)}
        show_status={true}
        show_add={true}
        primary_divider={true}
      />

      <%!-- Public page: navigation links, no dots --%>
      <.language_switcher
        languages={@translations}
        current_language={@current_language}
      />

      <%!-- Post overview: pills with status dots and "Primary" label --%>
      <.language_switcher
        languages={@post_languages}
        current_language={@current_language}
        show_status={true}
        show_primary_label={true}
        variant={:pills}
        prefix_urls={true}
      />

      <%!-- Form with content indicators --%>
      <.language_switcher
        languages={Enum.map(@language_tabs, &Map.put(&1, :exists, has_content?(&1.code)))}
        current_language={@current_lang}
        on_click_js={&switch_lang_js(&1, @current_lang)}
        show_status={true}
        variant={:tabs}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  alias PhoenixKit.Utils.Routes

  @doc """
  Renders a language switcher.

  ## Language map structure

  Each item in `:languages` should be a map with:

  - `code` (required) — language code (e.g., "en-US", "fr")
  - `name` — full display name (e.g., "English"). Falls back to uppercased code.
  - `short_code` — short display code (e.g., "EN"). Auto-derived from code if absent.
  - `flag` — flag emoji (e.g., "🇺🇸")
  - `url` — navigation URL (enables link mode)
  - `is_primary` — boolean, marks the primary language
  - `status` — "published", "draft", "archived", or nil (for dot color)
  - `exists` — boolean, whether content exists (inferred from status if absent)
  - `dot_color` — explicit daisyUI color class override. Valid values:
    `"success"`, `"warning"`, `"error"`, `"info"`, `"primary"`, `"secondary"`,
    `"accent"`, `"neutral"`, `"base-content/20"`, `"base-content/40"`.
    Invalid values are silently ignored (falls back to status/exists color).
  - `enabled` — boolean, whether this language is enabled in the system (default: true)
  - `known` — boolean, whether this language code is recognized (default: true)
  - `uuid` — optional ID, forwarded as `phx-value-uuid` in button mode

  ## Attributes

  - `languages` — list of language maps (required)
  - `current_language` — currently active language code
  - `display` — `:auto`, `:full`, or `:compact`. Default: `:auto`
  - `auto_threshold` — show full names when language count ≤ this. Default: 3
  - `show_status` — show status indicator dots. Default: false
  - `show_flags` — show flag emojis. Default: false
  - `show_primary` — show star icon on primary language. Default: false
  - `show_primary_label` — show "Primary" text label on primary language. Default: false
  - `show_add` — style missing languages as addable (green). Default: false
  - `exclude_primary` — exclude the primary language from the list. Default: false
  - `primary_divider` — show a vertical divider after the primary language. Default: false
  - `on_click` — event name for button click. Default: nil
  - `on_click_js` — `fn(lang_code) -> %JS{}` for custom click. Default: nil
  - `phx_target` — target for phx-click. Default: nil
  - `variant` — `:inline`, `:tabs`, or `:pills`. Default: `:inline`
  - `size` — `:xs`, `:sm`, or `:md`. Default: `:sm`
  - `prefix_urls` — when true, URLs in language maps are passed through
    `PhoenixKit.Utils.Routes.path/1` for prefix-aware routing. Default: false
  - `id` — optional HTML id for the container element. Default: nil
  - `class` — additional CSS classes. Default: ""

  ## Notes

  - `auto_threshold` is evaluated against the *displayed* language count
    (after filtering and `exclude_primary`), so excluding the primary
    language may change the display mode.
  - `on_click_js` must be a pure function returning `%Phoenix.LiveView.JS{}`
    — it is called during render.
  """
  attr :languages, :list, required: true
  attr :current_language, :string, default: nil
  attr :display, :atom, default: :auto, values: [:auto, :full, :compact]
  attr :auto_threshold, :integer, default: 3
  attr :show_status, :boolean, default: false
  attr :show_flags, :boolean, default: false
  attr :show_primary, :boolean, default: false
  attr :show_primary_label, :boolean, default: false
  attr :show_add, :boolean, default: false
  attr :exclude_primary, :boolean, default: false
  attr :primary_divider, :boolean, default: false
  attr :on_click, :string, default: nil
  attr :on_click_js, :any, default: nil
  attr :phx_target, :any, default: nil
  attr :variant, :atom, default: :inline, values: [:inline, :tabs, :pills]
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md]
  attr :prefix_urls, :boolean, default: false
  attr :id, :string, default: nil
  attr :class, :string, default: ""

  def language_switcher(assigns) do
    assigns = coerce_attrs(assigns)
    validate_config(assigns)
    languages = filter_languages(assigns.languages, assigns.show_status)

    languages =
      if assigns.exclude_primary,
        do: Enum.reject(languages, &lang_primary?/1),
        else: languages

    languages =
      if assigns.prefix_urls,
        do: prefix_language_urls(languages),
        else: languages

    use_full_names =
      case assigns.display do
        :full -> true
        :compact -> false
        :auto -> length(languages) <= assigns.auto_threshold
      end

    last_idx = max(length(languages) - 1, 0)

    assigns =
      assigns
      |> assign(:filtered_languages, languages)
      |> assign(:use_full_names, use_full_names)
      |> assign(:last_idx, last_idx)

    ~H"""
    <div
      :if={show_switcher?(@filtered_languages, @variant)}
      id={@id}
      role={if @variant == :tabs, do: "tablist"}
      class={switcher_container_class(@variant, @size, @class)}
    >
      <%= for {lang, idx} <- Enum.with_index(@filtered_languages) do %>
        <% prev_lang = if idx > 0, do: Enum.at(@filtered_languages, idx - 1) %>
        <% prev_had_divider =
          prev_lang && show_divider?(@primary_divider, prev_lang, idx - 1, @last_idx) %>
        <span
          :if={idx > 0 && !prev_had_divider && show_separator?(@variant, @use_full_names)}
          class={["text-base-content/30", size_text_class(@size)]}
        >
          |
        </span>
        <.switcher_item
          lang={lang}
          current_language={@current_language}
          use_full_names={@use_full_names}
          show_status={@show_status}
          show_flags={@show_flags}
          show_primary={@show_primary}
          show_primary_label={@show_primary_label}
          show_add={@show_add}
          on_click={@on_click}
          on_click_js={@on_click_js}
          phx_target={@phx_target}
          variant={@variant}
          size={@size}
        />
        <span
          :if={show_divider?(@primary_divider, lang, idx, @last_idx)}
          class="w-px h-4 bg-base-content/20 self-center"
        />
      <% end %>
    </div>
    """
  end

  # ── Item rendering ─────────────────────────────────────────────

  attr :lang, :map, required: true
  attr :current_language, :string, default: nil
  attr :use_full_names, :boolean, required: true
  attr :show_status, :boolean, default: false
  attr :show_flags, :boolean, default: false
  attr :show_primary, :boolean, default: false
  attr :show_primary_label, :boolean, default: false
  attr :show_add, :boolean, default: false
  attr :on_click, :string, default: nil
  attr :on_click_js, :any, default: nil
  attr :phx_target, :any, default: nil
  attr :variant, :atom, default: :inline
  attr :size, :atom, default: :sm

  defp switcher_item(assigns) do
    lang = assigns.lang
    is_current = assigns.current_language == lang_code(lang)
    exists = lang_exists?(lang)
    is_primary = lang_primary?(lang)
    enabled = lang_enabled?(lang)
    known = lang_known?(lang)
    status = lang_status(lang)

    assigns =
      assigns
      |> assign(:is_current, is_current)
      |> assign(:exists, exists)
      |> assign(:is_primary, is_primary)
      |> assign(:enabled, enabled)
      |> assign(:known, known)
      |> assign(:status, status)
      |> assign(:code, lang_code(lang))
      |> assign(:uuid, lang_field(lang, :uuid))
      |> assign(:url, lang_field(lang, :url))
      |> assign(:flag, lang_field(lang, :flag))
      |> assign(:item_title, build_title(lang, exists, enabled, known, assigns.show_status))
      |> assign(:resolved_click_js, resolve_click_js(assigns.on_click_js, lang_code(lang)))

    ~H"""
    <%= if @on_click_js || @on_click do %>
      <button
        type="button"
        role={if @variant == :tabs, do: "tab"}
        phx-click={@resolved_click_js || @on_click}
        phx-value-language={unless @on_click_js, do: @code}
        phx-value-uuid={unless @on_click_js, do: @uuid}
        phx-value-status={unless @on_click_js, do: @status}
        phx-target={@phx_target}
        class={[
          "cursor-pointer"
          | item_classes(
              @is_current,
              @exists,
              @is_primary,
              @show_add,
              @variant,
              @size,
              @enabled,
              @known
            )
        ]}
        title={@item_title}
        aria-pressed={to_string(@is_current)}
      >
        <.item_content {item_content_assigns(assigns)} />
      </button>
    <% else %>
      <%= if @url do %>
        <.link
          navigate={@url}
          class={[
            "cursor-pointer"
            | item_classes(
                @is_current,
                @exists,
                @is_primary,
                @show_add,
                @variant,
                @size,
                @enabled,
                @known
              )
          ]}
          title={@item_title}
          aria-current={@is_current && "true"}
        >
          <.item_content {item_content_assigns(assigns)} />
        </.link>
      <% else %>
        <span
          class={
            display_only_classes(
              item_classes(
                @is_current,
                @exists,
                @is_primary,
                @show_add,
                @variant,
                @size,
                @enabled,
                @known
              )
            )
          }
          title={@item_title}
          aria-current={@is_current && "true"}
        >
          <.item_content {item_content_assigns(assigns)} />
        </span>
      <% end %>
    <% end %>
    """
  end

  # Extracts the assigns needed by item_content to avoid repeating them 3 times.
  defp item_content_assigns(assigns) do
    Map.take(assigns, [
      :lang,
      :is_current,
      :exists,
      :is_primary,
      :enabled,
      :known,
      :status,
      :flag,
      :use_full_names,
      :show_status,
      :show_flags,
      :show_primary,
      :show_primary_label,
      :variant,
      :size
    ])
  end

  # ── Item content (dot + flag + label + star/label) ─────────────

  attr :lang, :map, required: true
  attr :is_current, :boolean, required: true
  attr :exists, :boolean, required: true
  attr :is_primary, :boolean, required: true
  attr :enabled, :boolean, required: true
  attr :known, :boolean, required: true
  attr :status, :string, default: nil
  attr :flag, :string, default: nil
  attr :use_full_names, :boolean, required: true
  attr :show_status, :boolean, required: true
  attr :show_flags, :boolean, required: true
  attr :show_primary, :boolean, required: true
  attr :show_primary_label, :boolean, required: true
  attr :variant, :atom, required: true
  attr :size, :atom, required: true

  defp item_content(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1">
      <span :if={@show_status} class={dot_classes(@lang, @exists, @size)} />
      <span :if={@show_flags && @flag} class={flag_size_class(@size)}>
        {@flag}
      </span>
      <span class={
        label_classes(
          @exists,
          @status,
          @is_current,
          @is_primary,
          @enabled,
          @known,
          @variant,
          @size
        )
      }>
        {display_label(@lang, @use_full_names)}
      </span>
      <.primary_star :if={@show_primary && @is_primary} size={@size} />
      <span
        :if={@show_primary_label && @is_primary}
        class="text-xs text-primary/70"
      >
        {gettext("Primary")}
      </span>
    </span>
    """
  end

  attr :size, :atom, required: true

  defp primary_star(assigns) do
    ~H"""
    <svg
      xmlns="http://www.w3.org/2000/svg"
      viewBox="0 0 24 24"
      fill="currentColor"
      class={["text-primary", star_size_class(@size)]}
    >
      <path
        fill-rule="evenodd"
        d="M10.788 3.21c.448-1.077 1.976-1.077 2.424 0l2.082 5.006 5.404.434c1.164.093 1.636 1.545.749 2.305l-4.117 3.527 1.257 5.273c.271 1.136-.964 2.033-1.96 1.425L12 18.354 7.373 21.18c-.996.608-2.231-.29-1.96-1.425l1.257-5.273-4.117-3.527c-.887-.76-.415-2.212.749-2.305l5.404-.434 2.082-5.005Z"
        clip-rule="evenodd"
      />
    </svg>
    """
  end

  # ── Language map accessors ─────────────────────────────────────

  @doc false
  def lang_code(%{code: code}), do: code
  def lang_code(%{"code" => code}), do: code
  def lang_code(_), do: nil

  defp lang_exists?(%{exists: exists}) when is_boolean(exists), do: exists
  defp lang_exists?(%{"exists" => exists}) when is_boolean(exists), do: exists
  defp lang_exists?(%{status: status}) when is_binary(status), do: true
  defp lang_exists?(%{"status" => status}) when is_binary(status), do: true
  defp lang_exists?(_), do: false

  defp lang_primary?(%{is_primary: val}) when is_boolean(val), do: val
  defp lang_primary?(%{"is_primary" => val}) when is_boolean(val), do: val
  defp lang_primary?(_), do: false

  defp lang_enabled?(%{enabled: val}) when is_boolean(val), do: val
  defp lang_enabled?(%{"enabled" => val}) when is_boolean(val), do: val
  defp lang_enabled?(_), do: true

  defp lang_known?(%{known: val}) when is_boolean(val), do: val
  defp lang_known?(%{"known" => val}) when is_boolean(val), do: val
  defp lang_known?(_), do: true

  # Prepends cursor-default and strips hover: classes for display-only spans.
  # Preserves title tooltip (unlike pointer-events-none) while removing
  # visual interactivity cues.
  defp display_only_classes(classes) when is_list(classes) do
    ["cursor-default" | Enum.map(classes, &strip_hover/1)]
  end

  defp strip_hover(class) when is_binary(class) do
    class
    |> String.split(" ")
    |> Enum.reject(&String.starts_with?(&1, "hover:"))
    |> Enum.join(" ")
  end

  defp strip_hover(other), do: other

  # Generic field accessor for optional fields (uuid, url, flag, etc.)
  defp lang_field(lang, key) when is_map(lang) and is_atom(key) do
    lang[key] || lang[Atom.to_string(key)]
  end

  defp lang_field(_lang, _key), do: nil

  # Safely invoke on_click_js function, returning nil on error.
  defp resolve_click_js(nil, _code), do: nil

  defp resolve_click_js(fun, code) when is_function(fun, 1) do
    fun.(code)
  rescue
    _ -> nil
  end

  defp resolve_click_js(_invalid, _code), do: nil

  # ── Display helpers ────────────────────────────────────────────

  defp display_label(lang, true = _full_names) when is_map(lang) do
    lang[:name] || lang["name"] || format_short_code(lang)
  end

  defp display_label(lang, false = _compact) when is_map(lang) do
    format_short_code(lang)
  end

  defp format_short_code(lang) when is_map(lang) do
    code =
      lang[:short_code] || lang["short_code"] ||
        lang[:display_code] || lang["display_code"] ||
        derive_short_code(lang)

    if is_binary(code), do: String.upcase(code), else: code
  end

  defp derive_short_code(lang) do
    case lang[:code] || lang["code"] do
      code when is_binary(code) -> code |> String.split("-") |> List.first() |> String.upcase()
      _ -> "?"
    end
  end

  defp prefix_language_urls(languages) do
    Enum.map(languages, fn lang ->
      case lang_field(lang, :url) do
        nil ->
          lang

        url when is_binary(url) ->
          try do
            Map.put(lang, :url, Routes.path(url))
          rescue
            _ -> lang
          end

        _ ->
          lang
      end
    end)
  end

  defp filter_languages(languages, true = _show_status), do: languages

  # When show_status is false (public mode), only show languages with published content.
  # Languages without exists/status fields pass through — they're UI tabs, not content entries.
  defp filter_languages(languages, false = _public) do
    Enum.filter(languages, fn lang ->
      has_content_fields =
        Map.has_key?(lang, :exists) || Map.has_key?(lang, "exists") ||
          Map.has_key?(lang, :status) || Map.has_key?(lang, "status")

      if has_content_fields do
        lang_exists?(lang) && lang_status(lang) in [nil, "published"]
      else
        true
      end
    end)
  end

  defp lang_status(%{status: status}), do: status
  defp lang_status(%{"status" => status}), do: status
  defp lang_status(_), do: nil

  # Pills can render a single language (useful for status display).
  # Inline and tabs need at least 2 to be meaningful.
  defp show_switcher?([], _variant), do: false
  defp show_switcher?(_languages, :pills), do: true
  defp show_switcher?([_single], _variant), do: false
  defp show_switcher?(_languages, _variant), do: true

  # Pipe separators: always for inline, only in compact mode for tabs, never for pills.
  defp show_separator?(:inline, _use_full_names), do: true
  defp show_separator?(:tabs, use_full_names), do: !use_full_names
  defp show_separator?(:pills, _use_full_names), do: false

  defp show_divider?(false, _lang, _idx, _last_idx), do: false

  defp show_divider?(true, lang, idx, last_idx) do
    lang_primary?(lang) && idx < last_idx
  end

  # ── Styling ────────────────────────────────────────────────────

  defp switcher_container_class(:inline, size, extra) do
    ["inline-flex items-center flex-wrap", size_gap_class(size), extra]
  end

  defp switcher_container_class(:tabs, _size, extra) do
    [
      "inline-flex flex-wrap items-center gap-1 p-1 bg-base-200 rounded-box",
      extra
    ]
  end

  defp switcher_container_class(:pills, _size, extra) do
    ["flex flex-wrap gap-2", extra]
  end

  defp item_classes(is_current, exists, is_primary, show_add, variant, size, enabled, known) do
    case variant do
      :pills ->
        pill_classes(is_current, is_primary, exists, show_add, size, enabled, known)

      other ->
        base = [
          "inline-flex items-center rounded transition-all",
          size_padding_class(size)
        ]

        state =
          case other do
            :tabs -> tab_state_class(is_current)
            :inline -> inline_state_class(is_current, exists, show_add, enabled, known)
          end

        base ++ [state]
    end
  end

  defp pill_classes(is_current, is_primary, exists, show_add, size, enabled, known) do
    degraded = !enabled or !known

    base = [
      "inline-flex items-center gap-1.5 rounded-lg transition-all",
      pill_padding_class(size)
    ]

    state = pill_state(is_current, is_primary, exists, show_add, degraded)
    base ++ [state]
  end

  defp pill_state(_current, true = _primary, _exists, _add, true = _degraded),
    do: "bg-primary/10 border border-primary/20 opacity-60"

  defp pill_state(_current, true = _primary, _exists, _add, false),
    do: "bg-primary/10 border border-primary/20 hover:bg-primary/20"

  defp pill_state(true = _current, _primary, _exists, _add, true = _degraded),
    do: "bg-base-300 border border-base-content/20 opacity-60"

  defp pill_state(_current, _primary, _exists, _add, true = _degraded),
    do: "bg-base-200/50 border border-base-content/10 opacity-60"

  defp pill_state(true = _current, _primary, _exists, _add, _degraded),
    do: "bg-base-300 border border-base-content/20"

  defp pill_state(_current, _primary, false = _exists, true = _add, _degraded),
    do: "bg-success/5 border border-dashed border-success/20 hover:bg-success/10"

  defp pill_state(_current, _primary, false = _exists, _add, _degraded),
    do: "bg-base-200/50 border border-dashed border-base-content/10 hover:bg-base-200"

  defp pill_state(_current, _primary, _exists, _add, _degraded),
    do: "bg-base-200 hover:bg-base-300"

  defp pill_padding_class(:xs), do: "px-2 py-1"
  defp pill_padding_class(:sm), do: "px-3 py-1.5"
  defp pill_padding_class(:md), do: "px-4 py-2"

  defp tab_state_class(true = _current), do: "bg-primary/20 text-primary font-semibold shadow-sm"
  defp tab_state_class(false), do: "hover:bg-base-100/50"

  defp inline_state_class(is_current, exists, show_add, enabled, known) do
    cond do
      is_current and (!enabled or !known) ->
        "bg-base-content/30 text-base-content/50 font-semibold"

      !enabled or !known ->
        "text-base-content/40 hover:bg-base-200/50"

      is_current ->
        "bg-primary/30 text-primary font-semibold"

      !exists && show_add ->
        "text-success hover:bg-success/10"

      exists ->
        "hover:bg-base-200"

      true ->
        "text-base-content/40"
    end
  end

  defp label_classes(exists, status, is_current, is_primary, enabled, known, variant, size) do
    base = [size_text_class(size)]

    weight =
      cond do
        is_primary -> "font-bold"
        is_current -> "font-semibold"
        true -> "font-medium"
      end

    decoration = if !enabled or !known, do: "line-through", else: nil
    color = label_color(exists, status, is_current, variant)

    Enum.filter(base ++ [weight, decoration, color], & &1)
  end

  # In :tabs and :pills variants, text color is neutral (controlled by container/pill bg).
  # In :inline variant, text color reflects content status.
  defp label_color(_exists, _status, true = _current, _variant), do: nil
  defp label_color(_exists, _status, _current, :tabs), do: nil
  defp label_color(_exists, _status, _current, :pills), do: nil

  defp label_color(exists, status, false, :inline) do
    cond do
      !exists -> "text-base-content/40"
      status == "published" -> "text-success"
      status == "draft" -> "text-warning"
      status == "archived" -> "text-base-content/40"
      true -> nil
    end
  end

  # Dot color resolution: dot_color > status > exists
  defp dot_classes(lang, exists, size) do
    base = ["rounded-full inline-block", dot_size_class(size)]
    color = resolve_dot_color(lang, exists)
    base ++ [color]
  end

  @valid_dot_colors ~w(success warning error info primary secondary accent neutral base-content/20 base-content/40)

  defp resolve_dot_color(lang, exists) when is_map(lang) do
    explicit = lang[:dot_color] || lang["dot_color"]

    if explicit && explicit in @valid_dot_colors do
      "bg-#{explicit}"
    else
      status_dot_color(lang_status(lang), exists)
    end
  end

  defp status_dot_color("published", _exists), do: "bg-success"
  defp status_dot_color("draft", _exists), do: "bg-warning"
  defp status_dot_color("archived", _exists), do: "bg-base-content/40"
  defp status_dot_color(_status, true), do: "bg-success"
  defp status_dot_color(_status, false), do: "bg-base-content/20"
  defp status_dot_color(_status, _exists), do: "bg-base-content/20"

  # ── Size classes ───────────────────────────────────────────────

  defp dot_size_class(:xs), do: "w-1.5 h-1.5"
  defp dot_size_class(:sm), do: "w-2 h-2"
  defp dot_size_class(:md), do: "w-2.5 h-2.5"

  defp size_text_class(:xs), do: "text-xs"
  defp size_text_class(:sm), do: "text-sm"
  defp size_text_class(:md), do: "text-base"

  defp size_padding_class(:xs), do: "px-1 py-0.5"
  defp size_padding_class(:sm), do: "px-1.5 py-0.5"
  defp size_padding_class(:md), do: "px-2 py-1"

  defp size_gap_class(:xs), do: "gap-0.5"
  defp size_gap_class(:sm), do: "gap-1"
  defp size_gap_class(:md), do: "gap-1.5"

  defp star_size_class(:xs), do: "w-2.5 h-2.5"
  defp star_size_class(:sm), do: "w-3 h-3"
  defp star_size_class(:md), do: "w-3.5 h-3.5"

  defp flag_size_class(:xs), do: "text-sm"
  defp flag_size_class(:sm), do: "text-base"
  defp flag_size_class(:md), do: "text-lg"

  # ── Titles / tooltips ──────────────────────────────────────────

  defp build_title(lang, exists, enabled, known, show_status) when is_map(lang) do
    name = lang[:name] || lang["name"] || derive_short_code(lang)

    if show_status do
      build_status_title(name, exists, lang_status(lang), enabled, known)
    else
      name
    end
  end

  defp build_status_title(name, _exists, _status, _enabled, false = _known) do
    gettext("%{language} (Unknown language)", language: name)
  end

  defp build_status_title(name, exists, status, false = _enabled, _known) do
    if exists do
      status_text = status_label(status)
      gettext("%{language} (Disabled — %{status})", language: name, status: status_text)
    else
      gettext("Add %{language} translation", language: name)
    end
  end

  defp build_status_title(name, false = _exists, _status, _enabled, _known) do
    gettext("Add %{language} translation", language: name)
  end

  defp build_status_title(name, true, "published", _enabled, _known) do
    gettext("%{language} (Published)", language: name)
  end

  defp build_status_title(name, true, "draft", _enabled, _known) do
    gettext("%{language} (Draft)", language: name)
  end

  defp build_status_title(name, true, "archived", _enabled, _known) do
    gettext("%{language} (Archived)", language: name)
  end

  defp build_status_title(name, _, _, _, _), do: name

  defp status_label("published"), do: gettext("Published")
  defp status_label("draft"), do: gettext("Draft")
  defp status_label("archived"), do: gettext("Archived")
  defp status_label(_), do: gettext("Unknown")

  # ── Safe coercion ───────────────────────────────────────────────
  # Ensures invalid attr values don't crash the render. Replaces bad values
  # with safe defaults so the component always produces valid HTML.

  defp coerce_attrs(assigns) do
    assigns
    |> coerce_attr(:languages, &is_list/1, [])
    |> coerce_languages()
    |> coerce_attr(:variant, &(&1 in [:inline, :tabs, :pills]), :inline)
    |> coerce_attr(:size, &(&1 in [:xs, :sm, :md]), :sm)
    |> coerce_attr(:display, &(&1 in [:auto, :full, :compact]), :auto)
    |> coerce_attr(:auto_threshold, &(is_integer(&1) and &1 >= 1), 3)
    |> coerce_on_click_js()
  end

  # Filter out non-map items from the languages list so they never reach switcher_item.
  defp coerce_languages(assigns) do
    languages = assigns.languages

    if Enum.all?(languages, &is_map/1) do
      assigns
    else
      assign(assigns, :languages, Enum.filter(languages, &is_map/1))
    end
  end

  defp coerce_attr(assigns, key, valid_fn, default) do
    if valid_fn.(assigns[key]), do: assigns, else: assign(assigns, key, default)
  end

  defp coerce_on_click_js(assigns) do
    case assigns.on_click_js do
      nil -> assigns
      fun when is_function(fun, 1) -> assigns
      _ -> assign(assigns, :on_click_js, nil)
    end
  end

  # ── Configuration validation ───────────────────────────────────
  # Logs warnings for conflicting or nonsensical attribute combinations.
  # Never crashes — the component renders with sensible precedence regardless.

  require Logger

  defp validate_config(assigns) do
    if Application.get_env(:phoenix_kit, :env) != :prod do
      do_validate_config(assigns)
    end
  end

  defp do_validate_config(assigns) do
    validate_attr_types(assigns)
    validate_click_conflict(assigns)
    validate_exclude_primary_conflicts(assigns)
    validate_show_add(assigns)
    validate_pills_divider(assigns)
    validate_language_codes(assigns)
  end

  @valid_variants [:inline, :tabs, :pills]
  @valid_sizes [:xs, :sm, :md]
  @valid_displays [:auto, :full, :compact]

  defp validate_attr_types(assigns) do
    unless is_list(assigns.languages) do
      Logger.warning(
        "language_switcher: languages must be a list, got #{inspect(assigns.languages)}. " <>
          "Defaulting to empty list."
      )
    end

    unless assigns.variant in @valid_variants do
      Logger.warning(
        "language_switcher: invalid variant #{inspect(assigns.variant)}. " <>
          "Valid values: #{inspect(@valid_variants)}. Falling back to :inline."
      )
    end

    unless assigns.size in @valid_sizes do
      Logger.warning(
        "language_switcher: invalid size #{inspect(assigns.size)}. " <>
          "Valid values: #{inspect(@valid_sizes)}. Falling back to :sm."
      )
    end

    unless assigns.display in @valid_displays do
      Logger.warning(
        "language_switcher: invalid display #{inspect(assigns.display)}. " <>
          "Valid values: #{inspect(@valid_displays)}. Falling back to :auto."
      )
    end

    if assigns.on_click_js && !is_function(assigns.on_click_js, 1) do
      Logger.warning(
        "language_switcher: on_click_js must be a 1-arity function, " <>
          "got #{inspect(assigns.on_click_js)}. It will be ignored."
      )
    end

    if assigns.on_click && !is_binary(assigns.on_click) do
      Logger.warning(
        "language_switcher: on_click must be a string event name, " <>
          "got #{inspect(assigns.on_click)}. It may not work as expected."
      )
    end

    if assigns.auto_threshold &&
         (!is_integer(assigns.auto_threshold) || assigns.auto_threshold < 1) do
      Logger.warning(
        "language_switcher: auto_threshold must be a positive integer, " <>
          "got #{inspect(assigns.auto_threshold)}. Falling back to 3."
      )
    end

    validate_language_maps(assigns.languages)
  end

  defp validate_language_maps(languages) when is_list(languages) do
    non_maps = Enum.count(languages, fn lang -> !is_map(lang) end)

    if non_maps > 0 do
      Logger.warning(
        "language_switcher: #{non_maps} item(s) in languages list are not maps. " <>
          "Each language must be a map with at least a :code key."
      )
    end
  end

  defp validate_language_maps(_), do: :ok

  defp validate_click_conflict(%{on_click: on_click, on_click_js: on_click_js})
       when not is_nil(on_click) and not is_nil(on_click_js) do
    Logger.warning(
      "language_switcher: both on_click and on_click_js are set. " <>
        "on_click_js takes precedence; on_click is used as fallback only if on_click_js returns nil."
    )
  end

  defp validate_click_conflict(_assigns), do: :ok

  defp validate_exclude_primary_conflicts(%{exclude_primary: true} = assigns) do
    if assigns.primary_divider do
      Logger.warning(
        "language_switcher: exclude_primary and primary_divider are both set. " <>
          "The divider has no effect since the primary language is excluded."
      )
    end

    if assigns.show_primary || assigns.show_primary_label do
      Logger.warning(
        "language_switcher: exclude_primary is set with show_primary or show_primary_label. " <>
          "Primary indicators have no effect since the primary language is excluded."
      )
    end
  end

  defp validate_exclude_primary_conflicts(_assigns), do: :ok

  defp validate_show_add(%{show_add: true} = assigns) do
    if !assigns.show_status do
      Logger.warning(
        "language_switcher: show_add is set but show_status is false. " <>
          "Non-existing languages are filtered out when show_status is false, " <>
          "so show_add styling will never be visible. Set show_status={true} to show addable languages."
      )
    end

    if !assigns.on_click && !assigns.on_click_js do
      has_urls = Enum.any?(assigns.languages, fn lang -> lang_field(lang, :url) != nil end)

      unless has_urls do
        Logger.warning(
          "language_switcher: show_add is set but no interaction mode is configured " <>
            "(no on_click, on_click_js, or url keys). " <>
            "Addable languages will be styled but not clickable."
        )
      end
    end
  end

  defp validate_show_add(_assigns), do: :ok

  defp validate_pills_divider(%{variant: :pills, primary_divider: true}) do
    Logger.warning(
      "language_switcher: primary_divider has no visual effect with variant :pills. " <>
        "Pills are separated by gap spacing, not dividers."
    )
  end

  defp validate_pills_divider(_assigns), do: :ok

  defp validate_language_codes(%{languages: languages}) do
    codeless_count =
      Enum.count(languages, fn lang -> lang_code(lang) == nil end)

    if codeless_count > 0 do
      Logger.warning(
        "language_switcher: #{codeless_count} language(s) in the list have no :code key. " <>
          "These items will render with \"?\" as the display code and nil for event values."
      )
    end
  end
end
