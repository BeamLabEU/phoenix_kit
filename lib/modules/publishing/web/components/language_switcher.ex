defmodule PhoenixKit.Modules.Publishing.Web.Components.LanguageSwitcher do
  @moduledoc """
  Unified language switcher component for publishing posts.

  Displays available languages as a compact inline list with status indicators.
  Flexible enough for admin interfaces (with status dots) and public pages (links only).

  ## Display Format

  Admin mode: ● EN | ● FR | ○ ES
  - Green dot (●): Published
  - Yellow dot (●): Draft
  - Gray dot (●): Archived
  - Empty dot (○): No translation exists

  Public mode: EN | FR | ES
  - No status indicators
  - Only shows languages with published translations

  ## Examples

      # Admin: publishing listing with edit links and status indicators
      <.publishing_language_switcher
        languages={@languages}
        current_language="en"
        on_click="switch_language"
        show_status={true}
      />

      # Admin: editor with switch functionality
      <.publishing_language_switcher
        languages={@languages}
        current_language={@current_language}
        on_click="switch_language"
        show_status={true}
        show_add={true}
      />

      # Public: post page with translation links
      <.publishing_language_switcher
        languages={@translations}
        current_language={@current_language}
        show_status={false}
      />
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitWeb.Gettext

  @doc """
  Renders a compact inline language switcher.

  ## Attributes

  - `languages` - List of language maps with keys: `code`, `name`, `status`, `url`, `exists`
  - `current_language` - Currently active language code
  - `show_status` - Show status indicator dots (default: true)
  - `show_add` - Show "add" option for missing languages (default: false)
  - `show_flags` - Show flag emojis (default: false)
  - `on_click` - Event name for click handler (optional, uses href if not provided)
  - `class` - Additional CSS classes
  - `size` - Size variant: :xs, :sm, :md (default: :sm)

  ## Language Map Structure

  Each language in the list should have:
  - `code` - Language code (e.g., "en", "fr")
  - `name` - Display name (e.g., "English", "French") - optional
  - `flag` - Flag emoji (e.g., "🇺🇸") - optional
  - `status` - Post status: "published", "draft", "archived", or nil if not exists
  - `url` - URL to navigate to (for public mode or href navigation)
  - `exists` - Boolean, whether translation file exists (default: inferred from status)
  - `enabled` - Boolean, whether the language is enabled in the Languages module (default: true)
  - `known` - Boolean, whether the language code is recognized (default: true)
  """
  attr :languages, :list, required: true
  attr :current_language, :string, default: nil
  attr :show_status, :boolean, default: true
  attr :show_add, :boolean, default: false
  attr :show_flags, :boolean, default: false
  attr :on_click, :string, default: nil
  attr :phx_target, :any, default: nil
  attr :class, :string, default: ""
  attr :size, :atom, default: :sm, values: [:xs, :sm, :md]

  def publishing_language_switcher(assigns) do
    # Filter languages for public mode (only show existing/published)
    languages =
      if assigns.show_status do
        assigns.languages
      else
        Enum.filter(assigns.languages, fn lang ->
          lang_exists?(lang) && lang[:status] == "published"
        end)
      end

    assigns = assign(assigns, :filtered_languages, languages)

    ~H"""
    <div class={["flex items-center flex-wrap", size_gap_class(@size), @class]}>
      <%= for {lang, index} <- Enum.with_index(@filtered_languages) do %>
        <%= if index > 0 do %>
          <span class={["text-base-content/30", size_separator_class(@size)]}>|</span>
        <% end %>
        <.language_item
          lang={lang}
          current_language={@current_language}
          show_status={@show_status}
          show_add={@show_add}
          show_flags={@show_flags}
          on_click={@on_click}
          phx_target={@phx_target}
          size={@size}
        />
      <% end %>
    </div>
    """
  end

  attr :lang, :map, required: true
  attr :current_language, :string, default: nil
  attr :show_status, :boolean, default: true
  attr :show_add, :boolean, default: false
  attr :show_flags, :boolean, default: false
  attr :on_click, :string, default: nil
  attr :phx_target, :any, default: nil
  attr :size, :atom, default: :sm

  defp language_item(assigns) do
    lang = assigns.lang
    is_current = assigns.current_language == lang[:code]
    exists = lang_exists?(lang)
    status = lang[:status]
    enabled = lang_enabled?(lang)
    known = lang_known?(lang)
    is_master = lang_is_master?(lang)

    assigns =
      assigns
      |> assign(:is_current, is_current)
      |> assign(:exists, exists)
      |> assign(:status, status)
      |> assign(:enabled, enabled)
      |> assign(:known, known)
      |> assign(:is_master, is_master)

    ~H"""
    <%= if @on_click do %>
      <button
        type="button"
        phx-click={@on_click}
        phx-value-language={@lang[:code]}
        phx-value-path={@lang[:path]}
        phx-value-post_path={@lang[:post_path]}
        phx-value-status={@status}
        phx-target={@phx_target}
        class={item_classes(@is_current, @exists, @show_add, @size, @enabled, @known)}
        title={language_title(@lang, @exists, @status, @show_status, @enabled, @known)}
        aria-pressed={to_string(@is_current)}
      >
        <.language_content
          lang={@lang}
          exists={@exists}
          status={@status}
          show_status={@show_status}
          show_add={@show_add}
          show_flags={@show_flags}
          is_current={@is_current}
          size={@size}
          enabled={@enabled}
          known={@known}
          is_master={@is_master}
        />
      </button>
    <% else %>
      <%= if @lang[:url] do %>
        <a
          href={@lang[:url]}
          class={item_classes(@is_current, @exists, @show_add, @size, @enabled, @known)}
          title={language_title(@lang, @exists, @status, @show_status, @enabled, @known)}
        >
          <.language_content
            lang={@lang}
            exists={@exists}
            status={@status}
            show_status={@show_status}
            show_add={@show_add}
            show_flags={@show_flags}
            is_current={@is_current}
            size={@size}
            enabled={@enabled}
            known={@known}
            is_master={@is_master}
          />
        </a>
      <% else %>
        <span
          class={item_classes(@is_current, @exists, @show_add, @size, @enabled, @known)}
          title={language_title(@lang, @exists, @status, @show_status, @enabled, @known)}
        >
          <.language_content
            lang={@lang}
            exists={@exists}
            status={@status}
            show_status={@show_status}
            show_add={@show_add}
            show_flags={@show_flags}
            is_current={@is_current}
            size={@size}
            enabled={@enabled}
            known={@known}
            is_master={@is_master}
          />
        </span>
      <% end %>
    <% end %>
    """
  end

  attr :lang, :map, required: true
  attr :exists, :boolean, required: true
  attr :status, :string, default: nil
  attr :show_status, :boolean, default: true
  attr :show_add, :boolean, default: false
  attr :show_flags, :boolean, default: false
  attr :is_current, :boolean, default: false
  attr :size, :atom, default: :sm
  attr :enabled, :boolean, default: true
  attr :known, :boolean, default: true
  attr :is_master, :boolean, default: false

  defp language_content(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1">
      <%= if @show_status do %>
        <span class={status_dot_classes(@exists, @status, @size, @enabled, @known)}></span>
      <% end %>
      <%= if @show_flags && @lang[:flag] do %>
        <span class={flag_size_class(@size)}>{@lang[:flag]}</span>
      <% end %>
      <span class={code_classes(@is_current, @size, @enabled, @known, @is_master)}>
        {get_display_code(@lang)}
      </span>
    </span>
    """
  end

  # Check if language translation exists
  defp lang_exists?(%{exists: exists}) when is_boolean(exists), do: exists
  defp lang_exists?(%{status: status}) when is_binary(status), do: true
  defp lang_exists?(%{"exists" => exists}) when is_boolean(exists), do: exists
  defp lang_exists?(%{"status" => status}) when is_binary(status), do: true
  defp lang_exists?(_), do: false

  # Check if language is enabled in the Languages module (default: true for backwards compat)
  defp lang_enabled?(%{enabled: enabled}) when is_boolean(enabled), do: enabled
  defp lang_enabled?(%{"enabled" => enabled}) when is_boolean(enabled), do: enabled
  defp lang_enabled?(_), do: true

  # Check if language code is a recognized/known language (default: true for backwards compat)
  defp lang_known?(%{known: known}) when is_boolean(known), do: known
  defp lang_known?(%{"known" => known}) when is_boolean(known), do: known
  defp lang_known?(_), do: true

  # Check if language is the master/primary language (default: false for backwards compat)
  defp lang_is_master?(%{is_master: is_master}) when is_boolean(is_master), do: is_master
  defp lang_is_master?(%{"is_master" => is_master}) when is_boolean(is_master), do: is_master
  defp lang_is_master?(_), do: false

  # Get display code for a language
  # Uses display_code if provided (for dialect-aware display), otherwise formats code
  defp get_display_code(%{display_code: display_code}) when is_binary(display_code) do
    String.upcase(display_code)
  end

  defp get_display_code(%{"display_code" => display_code}) when is_binary(display_code) do
    String.upcase(display_code)
  end

  defp get_display_code(%{code: code}) when is_binary(code) do
    format_code(code)
  end

  defp get_display_code(%{"code" => code}) when is_binary(code) do
    format_code(code)
  end

  defp get_display_code(_), do: ""

  # Format language code for display (base code only)
  defp format_code(nil), do: ""

  defp format_code(code) when is_binary(code) do
    code
    |> String.split("-")
    |> List.first()
    |> String.upcase()
  end

  # Status dot styling
  # Dot color follows status regardless of enabled/known state
  # (strikethrough on text indicates disabled/unknown, not the dot)
  defp status_dot_classes(exists, status, size, _enabled, _known) do
    base = ["rounded-full", "inline-block", dot_size_class(size)]

    color =
      cond do
        !exists -> "bg-base-content/20"
        status == "published" -> "bg-success"
        status == "draft" -> "bg-warning"
        status == "archived" -> "bg-base-content/40"
        true -> "bg-base-content/20"
      end

    base ++ [color]
  end

  # Item container classes
  defp item_classes(is_current, exists, show_add, size, enabled, known) do
    base = [
      "inline-flex items-center rounded transition-colors",
      size_padding_class(size)
    ]

    state =
      cond do
        # Disabled or unknown languages: grey styling but still clickable
        is_current and (!enabled or !known) ->
          "bg-base-content/10 text-base-content/50 font-semibold cursor-pointer"

        (!enabled or !known) and exists ->
          "text-base-content/40 hover:bg-base-200/50 cursor-pointer"

        is_current ->
          "bg-primary/10 text-primary font-semibold"

        !exists && show_add ->
          "text-success hover:bg-success/10 cursor-pointer"

        exists ->
          "hover:bg-base-200 cursor-pointer"

        true ->
          "text-base-content/40"
      end

    base ++ [state]
  end

  # Code text classes
  defp code_classes(is_current, size, enabled, known, is_master) do
    base = [size_text_class(size)]

    # Master language gets bold, current gets semibold, others get medium
    weight =
      cond do
        is_master -> "font-bold"
        is_current -> "font-semibold"
        true -> "font-medium"
      end

    # Add line-through for disabled or unknown languages
    decoration = if !enabled or !known, do: "line-through", else: nil

    Enum.filter(base ++ [weight, decoration], & &1)
  end

  # Size-based classes
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

  defp size_separator_class(:xs), do: "text-xs"
  defp size_separator_class(:sm), do: "text-sm"
  defp size_separator_class(:md), do: "text-base"

  defp flag_size_class(:xs), do: "text-sm"
  defp flag_size_class(:sm), do: "text-base"
  defp flag_size_class(:md), do: "text-lg"

  # Generate title/tooltip text
  # Only show status in tooltip when show_status is true (admin mode)
  defp language_title(lang, exists, status, show_status, enabled, known) do
    name = lang[:name] || lang["name"] || format_code(lang[:code])

    if show_status do
      build_admin_title(name, exists, status, enabled, known)
    else
      name
    end
  end

  # Build title for admin mode with status indicators
  defp build_admin_title(name, exists, status, enabled, known) do
    cond do
      !known and exists -> gettext("%{language} (Unknown language file)", language: name)
      !enabled and exists -> build_disabled_title(name, status)
      !exists -> gettext("Add %{language} translation", language: name)
      true -> build_status_title(name, status)
    end
  end

  defp build_disabled_title(name, status) do
    status_text = status_label(status)
    gettext("%{language} (Disabled - %{status})", language: name, status: status_text)
  end

  defp build_status_title(name, "published"),
    do: gettext("%{language} (Published)", language: name)

  defp build_status_title(name, "draft"), do: gettext("%{language} (Draft)", language: name)
  defp build_status_title(name, "archived"), do: gettext("%{language} (Archived)", language: name)
  defp build_status_title(name, _), do: name

  defp status_label("published"), do: gettext("Published")
  defp status_label("draft"), do: gettext("Draft")
  defp status_label("archived"), do: gettext("Archived")
  defp status_label(_), do: gettext("Unknown")
end
