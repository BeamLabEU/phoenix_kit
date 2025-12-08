defmodule PhoenixKitWeb.Components.Core.BlogLanguageSwitcher do
  @moduledoc """
  Unified language switcher component for blog posts.

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

      # Admin: blog listing with edit links and status indicators
      <.blog_language_switcher
        languages={@languages}
        current_language="en"
        on_click="switch_language"
        show_status={true}
      />

      # Admin: editor with switch functionality
      <.blog_language_switcher
        languages={@languages}
        current_language={@current_language}
        on_click="switch_language"
        show_status={true}
        show_add={true}
      />

      # Public: post page with translation links
      <.blog_language_switcher
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

  def blog_language_switcher(assigns) do
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

    assigns =
      assigns
      |> assign(:is_current, is_current)
      |> assign(:exists, exists)
      |> assign(:status, status)

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
        class={item_classes(@is_current, @exists, @show_add, @size)}
        title={language_title(@lang, @exists, @status, @show_status)}
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
        />
      </button>
    <% else %>
      <%= if @lang[:url] do %>
        <a
          href={@lang[:url]}
          class={item_classes(@is_current, @exists, @show_add, @size)}
          title={language_title(@lang, @exists, @status, @show_status)}
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
          />
        </a>
      <% else %>
        <span
          class={item_classes(@is_current, @exists, @show_add, @size)}
          title={language_title(@lang, @exists, @status, @show_status)}
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

  defp language_content(assigns) do
    ~H"""
    <span class="inline-flex items-center gap-1">
      <%= if @show_status do %>
        <span class={status_dot_classes(@exists, @status, @size)}></span>
      <% end %>
      <%= if @show_flags && @lang[:flag] do %>
        <span class={flag_size_class(@size)}>{@lang[:flag]}</span>
      <% end %>
      <span class={code_classes(@is_current, @size)}>
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
  defp status_dot_classes(exists, status, size) do
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
  defp item_classes(is_current, exists, show_add, size) do
    base = [
      "inline-flex items-center rounded transition-colors",
      size_padding_class(size)
    ]

    state =
      cond do
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
  defp code_classes(is_current, size) do
    base = [size_text_class(size)]

    weight = if is_current, do: "font-semibold", else: "font-medium"

    base ++ [weight]
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
  defp language_title(lang, exists, status, show_status) do
    name = lang[:name] || lang["name"] || format_code(lang[:code])

    cond do
      !exists and show_status -> gettext("Add %{language} translation", language: name)
      show_status and status == "published" -> gettext("%{language} (Published)", language: name)
      show_status and status == "draft" -> gettext("%{language} (Draft)", language: name)
      show_status and status == "archived" -> gettext("%{language} (Archived)", language: name)
      true -> name
    end
  end
end
